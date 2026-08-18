--!strict
--[[
	SpawnService.luau
	TODOS los caminos de aparición de jugadores en un solo módulo:

	  • SpawnAtLobby(player)        — lobby: join, muerte fuera de ronda,
	                                  vuelta al menú y fin de ronda.
	  • SpawnOnAssignedTeam(player) — spawn/respawn en el mapa de la ronda:
	                                  selección inteligente de punto, body
	                                  swap, protección de spawn y loadout.
	  • SelectBotSpawnPoint(side)   — selección de punto para bots (AIService):
	                                  mismo scoring y mapa de reservas que los
	                                  jugadores, inyectado vía MatchService.

	Los workarounds anti-carrera del body-swap (anclar el root mientras se
	reposiciona, WaitForChild del HumanoidRootPart) viven aquí UNA sola vez.
	MatchService inyecta vía Start los getters del estado que necesita la
	selección de spawn (mapa activo, lado del jugador, team instances y
	muertes recientes por spawn point).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local TeamUtils = require(Shared.utils.TeamUtils)
local SpawnSelector = require(script.Parent:WaitForChild("SpawnSelector"))
local LoadoutService = require(script.Parent:WaitForChild("LoadoutService"))

type TeamSide = "A" | "B"

type Deps = {
	dataService: any,
	-- Mapa activo de la ronda (nil fuera de Loading/InRound).
	getActiveMapModel: () -> Instance?,
	getActiveMapName: () -> string,
	-- Lado asignado del jugador (nil si no está en la ronda).
	getPlayerSide: (player: Player) -> TeamSide?,
	getTeamInstance: (side: TeamSide) -> Team?,
	-- Muertes recientes por spawn point de la ronda activa (anti spawn-trap).
	getRecentDeathBySpawn: () -> { [BasePart]: number },
}

local SpawnService = {}

local _deps: Deps = nil :: any
local _started = false

-- Caches por-mapa. Los spawn points y la carpeta de bots no cambian durante
-- un round, así evitamos escanear el mapa (potencialmente miles de instances)
-- en cada respawn. MatchService invalida con InvalidateMapCache() al desmontar.
local _cachedSpawnPoints: { BasePart }? = nil
local _cachedBotsFolder: Instance? = nil

-- time() at which each spawn point was last handed out. Shared by players AND
-- bots so a burst (round start) never gives the same point twice within
-- SpawnSelector's reuse window. Stamped at SELECTION time, not landing time:
-- the player body-swap yields, so two selections can run before either body
-- exists in the map. Cleared with the map (keys are map parts).
local _spawnUsedAt: { [BasePart]: number } = {}

function SpawnService.Start(deps: Deps)
	if _started then
		return
	end
	_started = true
	_deps = deps
end

function SpawnService.InvalidateMapCache()
	_cachedSpawnPoints = nil
	_cachedBotsFolder = nil
	table.clear(_spawnUsedAt)
end

-- ── Spawn points del mapa activo ─────────────────────────────

function SpawnService.GetSpawnPoints(): { BasePart }
	if _cachedSpawnPoints then
		return _cachedSpawnPoints :: { BasePart }
	end

	local mapModel = _deps.getActiveMapModel()
	if not mapModel then
		return {}
	end

	local points = {} :: { BasePart }
	local spawnsRoot = mapModel:FindFirstChild("Spawns", true)
	if spawnsRoot then
		for _, node in spawnsRoot:GetDescendants() do
			if node:IsA("BasePart") then
				table.insert(points, node)
			end
		end
	end

	_cachedSpawnPoints = points
	return points
end

function SpawnService.FindNearestSpawn(position: Vector3): BasePart?
	local spawns = SpawnService.GetSpawnPoints()
	if #spawns == 0 then
		return nil
	end

	local nearest: BasePart? = nil
	local nearestDistance = math.huge
	for _, spawn in spawns do
		local distance = (spawn.Position - position).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearest = spawn
		end
	end

	return nearest
end

-- ── Helpers privados ─────────────────────────────────────────

local function _getMapDefinitionByName(mapName: string): GameConfig.MapDefinition?
	for _, mapDef in GameConfig.Maps do
		if mapDef.Name == mapName then
			return mapDef
		end
	end

	return nil
end

local function _extractCharacterRootPart(character: Model): BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end

	return root
end

-- Recolecta posiciones + lookVectors de combatientes vivos por lado
-- (excluyendo al jugador que pide el respawn). Combina jugadores humanos y
-- NPCs en una sola pasada — los bots viven en `mapRoot.Bots` (top-level),
-- nunca se escanea el mapa entero.
local function _collectAllCombatantData(excludePlayer: Player?): (
	{ A: { Vector3 }, B: { Vector3 } },
	{ A: { Vector3 }, B: { Vector3 } }
)
	local positionsBySide = {
		A = {} :: { Vector3 },
		B = {} :: { Vector3 },
	}
	local lookVectorsBySide = {
		A = {} :: { Vector3 },
		B = {} :: { Vector3 },
	}

	for _, candidatePlayer in Players:GetPlayers() do
		if candidatePlayer == excludePlayer then
			continue
		end

		local candidateSide = _deps.getPlayerSide(candidatePlayer)
		if candidateSide ~= "A" and candidateSide ~= "B" then
			continue
		end

		local character = candidatePlayer.Character
		if not character then
			continue
		end

		local root = _extractCharacterRootPart(character)
		if root then
			table.insert(positionsBySide[candidateSide], root.Position)
			table.insert(lookVectorsBySide[candidateSide], root.CFrame.LookVector)
		end
	end

	local mapModel = _deps.getActiveMapModel()
	if not mapModel then
		return positionsBySide, lookVectorsBySide
	end

	if _cachedBotsFolder == nil or _cachedBotsFolder.Parent == nil then
		_cachedBotsFolder = mapModel:FindFirstChild("Bots")
	end
	local botsFolder = _cachedBotsFolder
	if botsFolder then
		for _, node in botsFolder:GetChildren() do
			if not node:IsA("Model") then
				continue
			end

			-- Ignorar NPCs muertos/ragdollados — no son amenaza, no deben influir
			-- en la elección de spawn point.
			local npcSide = TeamUtils.getSide(node)
			if npcSide ~= "A" and npcSide ~= "B" then
				continue
			end

			local root = _extractCharacterRootPart(node)
			if root then
				table.insert(positionsBySide[npcSide], root.Position)
				table.insert(lookVectorsBySide[npcSide], root.CFrame.LookVector)
			end
		end
	end

	return positionsBySide, lookVectorsBySide
end

-- Single selection path for players and bots: same scoring, same availability
-- rules, same reservation map. `excludePlayer` omits the respawning player
-- from the combatant scan (their soon-to-be-replaced body shouldn't count).
local function _selectSpawnPoint(side: TeamSide, excludePlayer: Player?): BasePart?
	local spawnPoints = SpawnService.GetSpawnPoints()
	if #spawnPoints == 0 then
		return nil
	end

	local mapDefinition = _getMapDefinitionByName(_deps.getActiveMapName())
	local useIntelligentSpawning = mapDefinition ~= nil and mapDefinition.UseIntelligentSpawning == true
	local enemySide: TeamSide = if side == "A" then "B" else "A"
	-- Single-pass sobre Players + bots, devuelve datos de ambos lados.
	local positionsBySide, lookVectorsBySide = _collectAllCombatantData(excludePlayer)
	local chosenSpawn = SpawnSelector.select(spawnPoints, {
		enemyPositions = positionsBySide[enemySide],
		enemyLookVectors = lookVectorsBySide[enemySide],
		allyPositions = positionsBySide[side],
		recentDeaths = _deps.getRecentDeathBySpawn(),
		recentSpawnUses = _spawnUsedAt,
		now = time(),
	}, useIntelligentSpawning)

	if chosenSpawn then
		_spawnUsedAt[chosenSpawn] = time()
	end

	return chosenSpawn
end

-- Carga el cuerpo del jugador y lo reposiciona sobre `spawnPoint`.
--
-- player:LoadCharacter() coloca el cuerpo en el spawn por defecto y NOSOTROS
-- lo reposicionamos. El bug del "vacío": tras un body-swap el rig puede tardar
-- un instante en estar completo, y leer HumanoidRootPart con FindFirstChild
-- demasiado pronto devolvía nil → la reposición se saltaba → el cuerpo caía al
-- vacío. WaitForChild con timeout corto evita esa carrera; si aun así no
-- aparece, el spawn falla limpio. El root se ancla durante el frame de
-- reposición para que la física no lo arrastre.
local function _teleportCharacterToSpawn(player: Player, spawnPoint: BasePart): Model?
	if player.Parent ~= Players then
		return nil
	end

	LoadoutService.loadCharacterWithBody(player, _deps.dataService)
	local character = player.Character or player.CharacterAdded:Wait()
	if player.Parent ~= Players or not character or not character.Parent then
		return nil
	end

	local rootInstance = character:FindFirstChild("HumanoidRootPart")
		or character:WaitForChild("HumanoidRootPart", 3)
	if not rootInstance or not rootInstance:IsA("BasePart") then
		return nil
	end
	local root = rootInstance :: BasePart

	root.Anchored = true
	root.CFrame = spawnPoint.CFrame + Vector3.new(0, 4, 0)

	-- Yaw del spawn para la ShoulderCamera del cliente: que el jugador aparezca
	-- mirando hacia donde apunta la part de spawn (rotar la part controla la
	-- orientación de aparición, igual que los bots). Se estampa como atributo para
	-- que el cliente lo lea sin carrera con la replicación del CFrame del root.
	local spawnLook = spawnPoint.CFrame.LookVector
	character:SetAttribute("SpawnYaw", math.atan2(-spawnLook.X, -spawnLook.Z))

	task.defer(function()
		if root.Parent then
			root.Anchored = false
		end
	end)

	return character
end

-- LobbySpawn vive directamente bajo Workspace.
local function _findLobbySpawn(): BasePart?
	local direct = Workspace:FindFirstChild("LobbySpawn")
	if direct and direct:IsA("BasePart") then
		return direct
	end

	return nil
end

-- ── API pública de spawn ─────────────────────────────────────

-- Garantiza un SpawnLocation Neutral+Enabled en el lobby.
--
-- El bug del "vacío al morir": en partida el jugador está en Team A/B. Al
-- morir, el auto-respawn del MOTOR busca un SpawnLocation de SU equipo; los
-- spawns del mapa son Part normales, así que el motor no encuentra punto
-- válido y aparece en el origen (0,0,0) → el vacío. Un SpawnLocation Neutral
-- sirve para CUALQUIER equipo. Invisible y no-colisionable para no estorbar.
function SpawnService.EnsureLobbySpawnLocation()
	local lobby = _findLobbySpawn()
	if not lobby then
		warn("[SpawnService] Workspace.LobbySpawn no encontrado; el auto-respawn del motor caería al vacío.")
		return
	end

	-- Si LobbySpawn ya es un SpawnLocation, basta con dejarlo neutral y activo.
	if lobby:IsA("SpawnLocation") then
		local sl = lobby :: SpawnLocation
		sl.Enabled = true
		sl.Neutral = true
		return
	end

	-- Reusar o crear un SpawnLocation invisible colocado sobre LobbySpawn.
	local existing = Workspace:FindFirstChild("LobbyAutoSpawn")
	local spawnLocation: SpawnLocation
	if existing and existing:IsA("SpawnLocation") then
		spawnLocation = existing :: SpawnLocation
	else
		spawnLocation = Instance.new("SpawnLocation")
		spawnLocation.Name = "LobbyAutoSpawn"
	end
	spawnLocation.Enabled = true
	spawnLocation.Neutral = true
	spawnLocation.Duration = 0 -- sin ForceField al aparecer en el lobby
	spawnLocation.Transparency = 1
	spawnLocation.CanCollide = false
	spawnLocation.CanTouch = false
	spawnLocation.Anchored = true
	spawnLocation.Size = lobby.Size
	spawnLocation.CFrame = lobby.CFrame
	spawnLocation.Parent = Workspace
end

-- Coloca al jugador en el lobby de forma controlada: carga su cuerpo y lo
-- teleporta a Workspace.LobbySpawn (sin armas). Con CharacterAutoLoads
-- desactivado, TODO spawn fuera de partida pasa por aquí (join, muerte→lobby,
-- vuelta a menú, fin de ronda); el motor nunca respawnea solo, así que nunca
-- cae al vacío.
function SpawnService.SpawnAtLobby(player: Player)
	if player.Parent ~= Players then
		return
	end
	-- En el lobby el jugador es neutral (sin equipo de combate).
	player.Neutral = true
	local lobbySpawn = _findLobbySpawn()
	if lobbySpawn then
		_teleportCharacterToSpawn(player, lobbySpawn)
	else
		LoadoutService.loadCharacterWithBody(player, _deps.dataService)
	end
end

-- Spawn/respawn en el mapa de la ronda, en el lado ya asignado del jugador.
-- Devuelve false si no hay mapa, lado, punto de spawn o el body-swap falla.
function SpawnService.SpawnOnAssignedTeam(player: Player): boolean
	local mapModel = _deps.getActiveMapModel()
	if not mapModel then
		return false
	end

	local side = _deps.getPlayerSide(player)
	if not side then
		return false
	end

	local team = _deps.getTeamInstance(side)
	if team then
		player.Neutral = false
		player.Team = team
	end

	local chosenSpawn = _selectSpawnPoint(side, player)
	if not chosenSpawn then
		return false
	end

	local spawnedCharacter = _teleportCharacterToSpawn(player, chosenSpawn)
	if not spawnedCharacter then
		return false
	end

	-- Inmunidad al spawn: ForceField nativo bloquea Humanoid:TakeDamage (la
	-- ruta que usan WeaponsSystem y BotAI) — no toca el pipeline de daño. El
	-- shield expira solo por tiempo vía Debris. El attribute
	-- SpawnProtectedUntil lo lee BotAI en _getBestTarget (más barato que
	-- FindFirstChildOfClass("ForceField") por candidato).
	if GameConfig.SpawnProtectionDuration > 0 then
		local forceField = Instance.new("ForceField")
		forceField.Visible = true
		forceField.Parent = spawnedCharacter
		Debris:AddItem(forceField, GameConfig.SpawnProtectionDuration)
		spawnedCharacter:SetAttribute("SpawnProtectedUntil", time() + GameConfig.SpawnProtectionDuration)
	end

	LoadoutService.applyCosmetics(player, spawnedCharacter, _deps.dataService)

	task.spawn(function()
		LoadoutService.grantWeaponsWithRetry(player, _deps.dataService, 8)
	end)
	return true
end

-- Spawn-point selection for bots (AIService). Same SpawnSelector scoring and
-- reservation map as players — bots no longer pick a pure-random point, can't
-- spawn into enemy crossfire, and can't share a point with a player or bot
-- spawning in the same burst. Injected into AIService via MatchService
-- (AI must not require match modules directly).
function SpawnService.SelectBotSpawnPoint(side: TeamSide): BasePart?
	return _selectSpawnPoint(side, nil)
end

return SpawnService
