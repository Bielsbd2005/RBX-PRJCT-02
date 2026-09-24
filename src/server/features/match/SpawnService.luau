--!strict
--[[
	Todos los caminos de aparición: lobby (SpawnAtLobby), mapa de la ronda
	(SpawnOnAssignedTeam) y punto de spawn de bots (SelectBotSpawnPoint, inyectado
	en AIService vía MatchService porque AI no debe requerir módulos de match).

	Contrato del cuerpo de lobby: anclado para siempre, de pie y sin Team. Nadie lo
	desancla: todo spawn posterior crea un cuerpo nuevo con LoadCharacter.
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
	-- nil fuera de Loading/InRound/Results (en Results sigue montado: es el escenario).
	getActiveMapModel: () -> Instance?,
	getActiveMapName: () -> string,
	getPlayerSide: (player: Player) -> TeamSide?,
	getTeamInstance: (side: TeamSide) -> Team?,
	-- Anti spawn-trap.
	getRecentDeathBySpawn: () -> { [BasePart]: number },
}

local SpawnService = {}

local _deps: Deps = nil :: any
local _started = false

-- Caché por mapa; MatchService llama a InvalidateMapCache() al desmontarlo.
local _cachedSpawnPoints: { BasePart }? = nil
local _cachedBotsFolder: Instance? = nil

-- time() de la última entrega de cada punto, compartido por jugadores y bots.
-- Se marca al SELECCIONAR, no al aterrizar: el body-swap cede y dos selecciones
-- pueden correr antes de que exista ningún cuerpo.
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

-- Los bots se leen de `mapRoot.Bots`, nunca se escanea el mapa entero.
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

			-- Sin lado = muerto/ragdollado: no cuenta.
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

-- `excludePlayer`: su cuerpo va a ser reemplazado, no cuenta en el escaneo.
local function _selectSpawnPoint(side: TeamSide, excludePlayer: Player?): BasePart?
	local spawnPoints = SpawnService.GetSpawnPoints()
	if #spawnPoints == 0 then
		return nil
	end

	local mapDefinition = _getMapDefinitionByName(_deps.getActiveMapName())
	local useIntelligentSpawning = mapDefinition ~= nil and mapDefinition.UseIntelligentSpawning == true
	local enemySide: TeamSide = if side == "A" then "B" else "A"
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

-- Margen para que el Humanoid no interseque la part de spawn. En R6 HipHeight es 0,
-- así que la altura de piernas va a mano.
local LOBBY_STAND_EPSILON = 0.1
local R6_LEG_HEIGHT = 2

-- Misma convención de rotación que el spawn normal, así SpawnYaw sigue siendo válido.
local function _standingRootCFrame(spawnPoint: BasePart, character: Model, root: BasePart): CFrame
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local legs = if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15
		then humanoid.HipHeight
		else R6_LEG_HEIGHT
	local offset = spawnPoint.Size.Y / 2 + legs + root.Size.Y / 2 + LOBBY_STAND_EPSILON
	return spawnPoint.CFrame + Vector3.new(0, offset, 0)
end

-- LoadCharacter coloca el cuerpo en el spawn por defecto y aquí se reposiciona.
-- Tras un body-swap el rig puede tardar en completarse: WaitForChild del root o
-- el cuerpo caería al vacío. El root va anclado durante la reposición.
-- keepAnchored (lobby): no se desancla nunca (la física del character es del cliente).
local function _teleportCharacterToSpawn(player: Player, spawnPoint: BasePart, keepAnchored: boolean?): Model?
	if player.Parent ~= Players then
		return nil
	end

	-- LoadCharacter es síncrono: si al volver no hay Character es que falló (p. ej. el
	-- jugador salió esperando el lock de body swap). Un CharacterAdded:Wait() aquí no
	-- volvería nunca y colgaría a quien llama (el bucle de _enterResults).
	LoadoutService.loadCharacterWithBody(player, _deps.dataService)
	local character = player.Character
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
	if keepAnchored then
		root.CFrame = _standingRootCFrame(spawnPoint, character, root)
	else
		root.CFrame = spawnPoint.CFrame + Vector3.new(0, 4, 0)
	end

	-- Atributo y no CFrame del root para que la ShoulderCamera del cliente lo lea sin
	-- carrera de replicación. Rotar la part de spawn orienta la aparición.
	local spawnLook = spawnPoint.CFrame.LookVector
	character:SetAttribute("SpawnYaw", math.atan2(-spawnLook.X, -spawnLook.Z))

	if not keepAnchored then
		task.defer(function()
			if root.Parent then
				root.Anchored = false
			end
		end)
	end

	return character
end

local function _findLobbySpawn(): BasePart?
	local direct = Workspace:FindFirstChild("LobbySpawn")
	if direct and direct:IsA("BasePart") then
		return direct
	end

	return nil
end

-- El auto-respawn del motor busca un SpawnLocation del equipo del jugador; los
-- spawns del mapa son Parts, así que sin uno Neutral aparecería en (0,0,0).
function SpawnService.EnsureLobbySpawnLocation()
	local lobby = _findLobbySpawn()
	if not lobby then
		warn("[SpawnService] Workspace.LobbySpawn no encontrado; el auto-respawn del motor caería al vacío.")
		return
	end

	if lobby:IsA("SpawnLocation") then
		local sl = lobby :: SpawnLocation
		sl.Enabled = true
		sl.Neutral = true
		return
	end

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

-- Con CharacterAutoLoads desactivado, todo spawn fuera de partida pasa por aquí.
function SpawnService.SpawnAtLobby(player: Player)
	if player.Parent ~= Players then
		return
	end
	-- Team = nil además de Neutral: TeamUtils.getSide mira player.Team primero y
	-- el cuerpo de lobby seguiría siendo objetivo de los bots.
	player.Neutral = true
	player.Team = nil
	local lobbySpawn = _findLobbySpawn()
	if lobbySpawn then
		_teleportCharacterToSpawn(player, lobbySpawn, true)
	else
		LoadoutService.loadCharacterWithBody(player, _deps.dataService)
	end
end

-- false si no hay mapa, lado, punto de spawn o falla el body-swap.
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

	local spawnedCharacter = _teleportCharacterToSpawn(player, chosenSpawn, false)
	if not spawnedCharacter then
		return false
	end

	-- ForceField nativo: bloquea Humanoid:TakeDamage sin tocar el pipeline de daño.
	-- SpawnProtectedUntil lo lee BotAI._getBestTarget.
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

function SpawnService.SelectBotSpawnPoint(side: TeamSide): BasePart?
	return _selectSpawnPoint(side, nil)
end

return SpawnService
