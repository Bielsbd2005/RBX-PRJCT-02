--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local CollisionGroups = require(Shared:WaitForChild("CollisionGroups"))
local BotNames = require(Shared.constants.BotNames)
local BotConfig = require(Shared.constants.BotConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)

local LastAttackerStore = require(ReplicatedStorage:WaitForChild("WeaponsSystem"):WaitForChild("Libraries"):WaitForChild("LastAttackerStore"))
local BotAI = require(script:WaitForChild("BotAI"))
local BotAppearance = require(script:WaitForChild("BotAppearance"))
local BotPersonality = require(script:WaitForChild("BotPersonality"))
local NavMetrics = require(script:WaitForChild("telemetry"):WaitForChild("NavMetrics"))
local RoamGraph = require(script:WaitForChild("nav"):WaitForChild("RoamGraph"))
local PathfindingQueue = require(script:WaitForChild("nav"):WaitForChild("PathfindingQueue"))

type BotIdentity = {
	name: string,
	image: string,
	personalityId: string,
	level: number,
	historicalKills: number,
	appearance: BotAppearance.BotAppearance,
}

type RoundStartConfig = {
	spawnPoints: { BasePart },
	mapRoot: Instance?,
	onBotDied: ((string, string, Humanoid, number) -> ())?,
}

type BotRecord = {
	model: Model,
	humanoid: Humanoid,
	team: "A" | "B",
	deathConnection: RBXScriptConnection?,
	hasDeathBeenReported: boolean,
	ai: typeof(BotAI.new(({} :: any), "A")),
	descendantConn: RBXScriptConnection?,
}

local _dataServiceRef: any = nil

local function _getKillEffectForBotAttacker(humanoid: Humanoid): string
	local lastAttacker = LastAttackerStore.get(humanoid)
	if not lastAttacker then
		return ItemDefaults.ITEM_ID
	end
	if lastAttacker.At > 0 and math.abs(time() - lastAttacker.At) > GameConfig.KillAttributionWindow then
		return ItemDefaults.ITEM_ID
	end
	local attackerUserId = lastAttacker.UserId
	if not attackerUserId then
		return ItemDefaults.ITEM_ID
	end
	local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
	if not attackerPlayer then
		return ItemDefaults.ITEM_ID
	end
	local profile = nil :: any
	local dataService = _dataServiceRef
	if dataService and dataService.GetProfile then
		profile = dataService:GetProfile(attackerPlayer)
	end
	if profile and profile.Data and profile.Data.Loadout then
		local killEffect = profile.Data.Loadout.KillEffect
		if type(killEffect) == "string" and killEffect ~= "" then
			return killEffect
		end
	end
	return ItemDefaults.ITEM_ID
end

local AIService = {}

local _isRoundActive = false
local _mapRoot: Instance? = nil
local _roamGraph: RoamGraph.RoamGraph? = nil
local _spawnPoints: { BasePart } = {}
local _onBotDied: ((string, string, Humanoid, number) -> ())? = nil
local _botsByName: { [string]: BotRecord } = {}
local _activeBotCount = 0
-- B6: index O(1) por FakeUserId para _findAttackerModel. Antes scan lineal
-- sobre aliveTargets por cada damage event (peor caso 16 events/100ms × 16
-- candidatos = 2560 comparaciones/seg).
local _botModelByFakeUserId: { [number]: Model } = {}
local _botNamesByTeam: { A: { string }, B: { string } } = {
	A = {},
	B = {},
}
local _nextBotId = 1
local _fakeUserIdCounter = 0
local _usedIdentityIndices: { [number]: boolean } = {}
local _botIdentityByName: { [string]: BotIdentity } = {}
local _recycledByTeam: { A: { { identity: BotIdentity, fakeUserId: number } }, B: { { identity: BotIdentity, fakeUserId: number } } } = { A = {}, B = {} }
local _identityByFakeUserId: { [number]: BotIdentity } = {}
local _teamByFakeUserId: { [number]: string } = {}
local _botFakeUserIdByName: { [string]: number } = {}

-- ────────────────────────────────────────────────────────────────
-- ALIVE TARGETS CACHE (compartido entre todos los BotAI)
--
-- Mantiene una lista de Models vivos (chars de jugadores reales + bots)
-- que pueden ser objetivos de los bots. Se actualiza vía signals
-- (PlayerAdded/CharacterAdded/Died/AncestryChanged) — sin polling.
--
-- Antes cada bot iteraba `workspace:GetChildren()` + `mapRoot/Bots:GetChildren()`
-- en cada tick (60Hz Heartbeat × 8 bots = ~5760 raycasts/seg en peor caso).
-- Esta cache global elimina la iteración masiva — el bot solo pasea sobre
-- los ~16 candidatos relevantes.
-- ────────────────────────────────────────────────────────────────

-- B4: tupla en lugar de Model. Antes _getBestTarget hacía
-- FindFirstChildOfClass + FindFirstChild por cada candidato cada tick
-- (16 bots × 24 chars × 2 × 10Hz ≈ 7680 lookups/seg en PATROL).
-- Resuelto al add-time + lazy refresh si el ref muere (respawn streaming).
export type AliveTarget = {
	model: Model,
	hum: Humanoid?,
	root: BasePart?,
}

local _aliveTargets: { AliveTarget } = {}
local _aliveTargetIndex: { [Model]: number } = {}

local function _addAliveTarget(model: Model)
	if _aliveTargetIndex[model] then return end
	local entry: AliveTarget = {
		model = model,
		hum = model:FindFirstChildOfClass("Humanoid"),
		root = model:FindFirstChild("HumanoidRootPart") :: BasePart?,
	}
	table.insert(_aliveTargets, entry)
	_aliveTargetIndex[model] = #_aliveTargets
end

local function _removeAliveTarget(model: Model)
	local idx = _aliveTargetIndex[model]
	if not idx then return end
	_aliveTargetIndex[model] = nil
	-- Swap-remove O(1): mover el último al hueco si no es el mismo.
	local last = #_aliveTargets
	if idx ~= last then
		local moved = _aliveTargets[last]
		_aliveTargets[idx] = moved
		_aliveTargetIndex[moved.model] = idx
	end
	_aliveTargets[last] = nil
end

-- Dedupe: protege contra la race del module-load donde un jugador que
-- aparece entre Players.PlayerAdded:Connect y el for-loop inicial era
-- wired DOS veces (CharacterAdded:Connect duplicado → 2× AncestryChanged
-- y Died listeners por char en cada respawn).
local _wiredPlayers: { [Player]: true } = {}

local function _wirePlayerAliveTracking(player: Player)
	if _wiredPlayers[player] then
		return
	end
	_wiredPlayers[player] = true

	local function onChar(char: Model)
		-- Audit mobile: remove defensivo del char anterior. _addAliveTarget
		-- ya dedupea por index, pero el char del respawn previo puede no
		-- haber salido todavía (AncestryChanged tarda un frame) → la nueva
		-- entry quedaría apuntando al char correcto pero la vieja seguiría
		-- referenciada por _aliveTargetIndex con el mismo Model si Roblox
		-- recicla la ref (raro pero posible al reusar rigs del LoadCharacter).
		_removeAliveTarget(char)
		_addAliveTarget(char)
		-- El char puede ser destruido sin Died (respawn instantáneo, kick, etc.).
		-- AncestryChanged lo cubre todos los casos sin duplicar lógica.
		char.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				_removeAliveTarget(char)
			end
		end)
		local hum = char:WaitForChild("Humanoid", 5)
		if hum and hum:IsA("Humanoid") then
			(hum :: Humanoid).Died:Connect(function()
				_removeAliveTarget(char)
			end)
		end
	end

	if player.Character then
		onChar(player.Character)
	end
	player.CharacterAdded:Connect(onChar)
end

Players.PlayerAdded:Connect(_wirePlayerAliveTracking)
for _, p in Players:GetPlayers() do
	_wirePlayerAliveTracking(p)
end

Players.PlayerRemoving:Connect(function(player)
	_wiredPlayers[player] = nil
	if player.Character then
		_removeAliveTarget(player.Character)
	end
end)

-- Graceful shutdown: cuando el servidor cierra, paramos los loops de todos los
-- bots para que no se queden ejecutando contra un DataModel a punto de morir.
-- Esto evita warnings/errores ruidosos durante el shutdown y permite que las
-- coroutines salgan limpiamente.
game:BindToClose(function()
	for _, record in pairs(_botsByName) do
		if record and record.ai then
			pcall(function()
				record.ai:Stop()
			end)
		end
	end
end)

local function _assignIdentity(): (BotIdentity, number)
	_fakeUserIdCounter -= 1
	local fakeUserId = _fakeUserIdCounter
	-- Pick an unused identity from the pool
	local available = {}
	for i, _ in BotNames do
		if not _usedIdentityIndices[i] then
			table.insert(available, i)
		end
	end
	local name: string
	local image: string
	if #available > 0 then
		local idx = available[math.random(1, #available)]
		_usedIdentityIndices[idx] = true
		local source = BotNames[idx]
		name = source.name
		image = source.image
	else
		-- Fallback: pool agotado (>20 bots/team). Prefijo "Bot_" en lugar de
		-- "Player" para evitar colisiones con usernames reales de Roblox que
		-- empiezan por "Player".
		name = "Bot_" .. tostring(math.abs(fakeUserId))
		image = "rbxassetid://0"
	end

	-- Personality drives apariencia + stats fingidas. Se rolea una vez por
	-- identidad: igual que appearance, sobrevive al recycle pool y se
	-- re-randomiza solo en OnRoundEnd cuando se limpian las identidades.
	local personalityId, personality = BotPersonality.rollPersonality()
	local level, historicalKills = BotPersonality.rollStats(personality)

	-- Construir identity fresca con apariencia cacheada. La apariencia
	-- vive en la identity para que el recycle pool tras la muerte del bot
	-- (init.luau:613) mantenga la misma hat/face/wrap durante todo el match.
	-- En OnRoundEnd se limpian _usedIdentityIndices y _recycledByTeam, así
	-- que la siguiente ronda re-rolea automáticamente.
	local identity: BotIdentity = {
		name = name,
		image = image,
		personalityId = personalityId,
		level = level,
		historicalKills = historicalKills,
		appearance = BotAppearance.roll(personality),
	}
	return identity, fakeUserId
end

local function _refreshAliveLists()
	local listA = _botNamesByTeam.A
	local listB = _botNamesByTeam.B
	table.clear(listA)
	table.clear(listB)

	local count = 0
	for name, bot in _botsByName do
		if bot.model.Parent == nil or bot.humanoid.Health <= 0 then
			if bot.deathConnection then
				bot.deathConnection:Disconnect()
				bot.deathConnection = nil
			end
			_botsByName[name] = nil
		else
			count += 1
			if bot.team == "A" then
				table.insert(listA, name)
			else
				table.insert(listB, name)
			end
		end
	end
	_activeBotCount = count
end

local function _getRandomSpawnPoint(): BasePart?
	if #_spawnPoints == 0 then
		return nil
	end

	return _spawnPoints[math.random(1, #_spawnPoints)]
end

local function _buildFallbackBotModel(botName: string): Model
	local model = Instance.new("Model")
	model.Name = botName

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.CanCollide = false
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.CanCollide = true
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.CanCollide = true
	head.Parent = model

	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0 = root
	rootJoint.Part1 = torso
	rootJoint.Parent = root

	local neck = Instance.new("Motor6D")
	neck.Name = "Neck"
	neck.Part0 = torso
	neck.Part1 = head
	neck.C0 = CFrame.new(0, 1, 0)
	neck.C1 = CFrame.new(0, -0.5, 0)
	neck.Parent = torso

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = model

	model.PrimaryPart = root
	return model
end

local _hasWarnedMissingTemplate = false

-- B5: pool async de Models pre-clonados. Desacopla el coste de Model:Clone
-- (con sus 30+ parts/accessories) del path crítico de _spawnOneBot. El refill
-- corre en task.spawn — la siguiente vez que un bot muere y se necesita uno
-- nuevo, el pool ya tiene un rig caliente listo.
--
-- No se reutilizan rigs entre vidas (no es un pool de "ressurect"): la
-- Humanoid en estado Dead no se puede revivir limpiamente sin reemplazar el
-- Humanoid entero. Esta variante mata complejidad pero no la ganancia de
-- decouplear cloning del spawn moment.
--
-- Pool por outfit: con apariencia variable, cada outfit es un Model distinto
-- en ServerStorage.Bodies. Un único pool compartido implicaría todos los bots
-- con el mismo body. La key del pool es el outfitId.
local _botRigPoolByKey: { [string]: { Model } } = {}
local _botRigRefillingByKey: { [string]: boolean } = {}
local BOT_RIG_POOL_TARGET = 3
local _botRigParkFolder: Folder? = nil

local function _ensureParkFolder(): Folder
	if _botRigParkFolder and _botRigParkFolder.Parent then
		return _botRigParkFolder
	end
	-- ServerStorage no replica al cliente — los rigs parked no se ven.
	local existing = ServerStorage:FindFirstChild("_BotRigPool")
	if existing and existing:IsA("Folder") then
		_botRigParkFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "_BotRigPool"
	folder.Parent = ServerStorage
	_botRigParkFolder = folder
	return folder
end

local function _clonePreparedRig(poolKey: string): Model?
	local template = BotAppearance.findBodyTemplate(poolKey)
	if not template then return nil end
	local clone = template:Clone()
	-- Parented a ServerStorage para que Roblox no intente streaming/replicación
	-- ni dispare ChildAdded en el workspace mientras está en el pool.
	clone.Parent = _ensureParkFolder()
	return clone
end

local function _refillBotRigPoolAsync(poolKey: string)
	if _botRigRefillingByKey[poolKey] then return end
	_botRigRefillingByKey[poolKey] = true
	task.spawn(function()
		local pool = _botRigPoolByKey[poolKey]
		if not pool then
			pool = {}
			_botRigPoolByKey[poolKey] = pool
		end
		while #pool < BOT_RIG_POOL_TARGET do
			local rig = _clonePreparedRig(poolKey)
			if not rig then break end -- template missing → abandona refill
			table.insert(pool, rig)
		end
		_botRigRefillingByKey[poolKey] = false
	end)
end

local function _takeBotRigFromPool(poolKey: string): Model?
	local pool = _botRigPoolByKey[poolKey]
	if pool and #pool > 0 then
		local rig = pool[#pool]
		pool[#pool] = nil
		_refillBotRigPoolAsync(poolKey)
		return rig
	end
	-- Pool vacío (e.g., burst inicial de spawns, primer take para este outfit)
	-- → fallback sync.
	_refillBotRigPoolAsync(poolKey)
	return _clonePreparedRig(poolKey)
end

-- Resuelve qué pool usar para un outfitId dado. Prefiere el outfit pedido si
-- su body existe; cae a "Default" si está. Devuelve nil si no hay ningún
-- body disponible → _createBotModel cae al rig barebones.
local function _resolvePoolKeyForOutfit(outfitId: string?): string?
	if outfitId and BotAppearance.findBodyTemplate(outfitId) then
		return outfitId
	end
	if BotAppearance.findBodyTemplate("Default") then
		return "Default"
	end
	return nil
end

local function _createBotModel(botName: string, outfitId: string?): Model
	local poolKey = _resolvePoolKeyForOutfit(outfitId)
	if poolKey then
		local clone = _takeBotRigFromPool(poolKey)
		if clone then
			clone.Name = botName
			return clone
		end
	end

	-- Audit P2: warn una sola vez por proceso. Antes el fallback silencioso
	-- producía bots T-pose sin tool en producción y nadie se enteraba salvo
	-- viendo en vivo. Si el template falta, todos los bots del round caen
	-- al fallback — no necesitamos N warns iguales, solo uno con contexto.
	if not _hasWarnedMissingTemplate then
		_hasWarnedMissingTemplate = true
		warn("[AIService] BotTemplate no encontrado (esperado en ServerStorage.Bodies.<outfitId> o ServerStorage.Bodies.Default). Usando modelo barebones — los bots aparecerán en T-pose y sin arma hasta que se restaure el template.")
	end
	return _buildFallbackBotModel(botName)
end

-- Warm-up: pre-rellena un pool por outfit disponible al cargar AIService para
-- que la primera oleada de spawns no pague el coste de Clone en el path
-- crítico. Si no hay bodies, _createBotModel cae al rig barebones.
do
	for _, outfitId in BotAppearance.getAvailableOutfitIds() do
		_refillBotRigPoolAsync(outfitId)
	end
end

local function _notifyActiveBotCount()
	NavMetrics.SetActiveBotCount(_activeBotCount)
end

local function _removeBotByName(botName: string)
	local bot = _botsByName[botName]
	if not bot then
		return
	end

	bot.ai:Stop()
	_removeAliveTarget(bot.model)

	if bot.deathConnection then
		bot.deathConnection:Disconnect()
		bot.deathConnection = nil
	end

	-- Clean identity tracking so GetBotRoster no longer includes this bot
	local fakeUserId = _botFakeUserIdByName[botName]
	if fakeUserId then
		_identityByFakeUserId[fakeUserId] = nil
		_teamByFakeUserId[fakeUserId] = nil
		_botModelByFakeUserId[fakeUserId] = nil
	end
	_botIdentityByName[botName] = nil
	_botFakeUserIdByName[botName] = nil

	if bot.model.Parent ~= nil then
		bot.model:Destroy()
	end

	_botsByName[botName] = nil
	_activeBotCount = math.max(0, _activeBotCount - 1)
	_refreshAliveLists()
	_notifyActiveBotCount()
end

local function _markBotTeam(model: Model, team: "A" | "B")
	model:SetAttribute("Team", team)
	model:SetAttribute("TeamSide", team)
	model:SetAttribute("BotTeam", team)

	local leaderstats = model:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = model
	end

	local teamValue = leaderstats:FindFirstChild("Team")
	if not teamValue or not teamValue:IsA("StringValue") then
		if teamValue then
			teamValue:Destroy()
		end
		teamValue = Instance.new("StringValue")
		teamValue.Name = "Team"
		teamValue.Parent = leaderstats
	end

	(teamValue :: StringValue).Value = team
end

local function _spawnOneBot(team: "A" | "B"): boolean
	if not _isRoundActive then
		return false
	end

	local mapRoot = _mapRoot
	if not mapRoot then
		return false
	end

	local spawnPoint = _getRandomSpawnPoint()
	if not spawnPoint then
		return false
	end

	local botName = string.format("Bot_%s_%d", team, _nextBotId)
	_nextBotId += 1

	local identity: BotIdentity
	local fakeUserId: number
	local recycled = _recycledByTeam[team]
	if #recycled > 0 then
		local entry = table.remove(recycled, #recycled)
		identity = entry.identity
		fakeUserId = entry.fakeUserId
	else
		identity, fakeUserId = _assignIdentity()
	end
	_botIdentityByName[botName] = identity
	_botFakeUserIdByName[botName] = fakeUserId
	_identityByFakeUserId[fakeUserId] = identity
	_teamByFakeUserId[fakeUserId] = team

	local outfitId = if identity.appearance then identity.appearance.outfitId else nil
	local botModel = _createBotModel(botName, outfitId)
	local humanoid = botModel:FindFirstChildOfClass("Humanoid")
	local root = botModel:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		botModel:Destroy()
		warn(string.format("[AIService] Bot template inválido para %s (falta Humanoid/HumanoidRootPart)", botName))
		return false
	end

	_markBotTeam(botModel, team)

	-- Stamp identity on model
	botModel:SetAttribute("DisplayName", identity.name)
	botModel:SetAttribute("FakeUserId", fakeUserId)
	botModel:SetAttribute("ProfileImage", identity.image)
	_botModelByFakeUserId[fakeUserId] = botModel
	local hum = botModel:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayName = identity.name
	end

	-- Apariencia (hat + face). El wrap se aplica dentro de BotAI:_setupTool
	-- tras clonar el tool, vía el wrapId que pasamos al constructor.
	BotAppearance.apply(botModel, identity.appearance)

	local wrapId = if identity.appearance then identity.appearance.wrapId else nil
	local botAIInstance = BotAI.new(botModel, team, fakeUserId, wrapId)

	local botsFolder = mapRoot:FindFirstChild("Bots")
	if not botsFolder then
		botsFolder = Instance.new("Folder")
		botsFolder.Name = "Bots"
		botsFolder.Parent = mapRoot
	end

	botModel.Parent = botsFolder
	root.CFrame = spawnPoint.CFrame + Vector3.new(0, 4, 0)
	humanoid.Health = humanoid.MaxHealth
	humanoid.BreakJointsOnDeath = false

	-- Mismo tratamiento que los jugadores: CHARACTERS group para que players
	-- vivos no choquen con cadáveres. Al morir, el kill effect migra al grupo
	-- RAGDOLL. Watcher cubre tools/accesorios que se parenten después.
	CollisionGroups.setGroupForCharacter(botModel, CollisionGroups.CHARACTERS)
	-- Audit mobile: guardar la conexión para desconectarla en el Died handler
	-- antes del kill effect. El ragdoll/VFX parentea ~10 nuevos BaseParts y
	-- el listener se dispararía para cada uno (se ejecuta el switch
	-- CollisionGroup innecesario sobre un modelo en cleanup).
	local descendantConn = botModel.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = CollisionGroups.groupForNewPart(botModel)
		end
	end)

	-- Misma inmunidad al spawn que los jugadores (ver MatchService). ForceField
	-- nativo, no se rompe al disparar, expira por tiempo vía Debris.
	-- Audit mobile: Visible=false. El FF de los players sí se muestra
	-- (UX del propio jugador), pero las esferas azules de 16 bots
	-- recién spawneados clutterean móviles low-end sin valor de UX. El
	-- jugador que dispare a un bot recién spawneado ve "0 daño visible"
	-- durante 2s; el bot se mueve rápido y la situación se resuelve sola.
	-- Attribute SpawnProtectedUntil para que BotAI._getBestTarget skipee
	-- bots inmunes sin hacer FindFirstChildOfClass por candidato.
	if GameConfig.SpawnProtectionDuration > 0 then
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = botModel
		Debris:AddItem(forceField, GameConfig.SpawnProtectionDuration)
		botModel:SetAttribute("SpawnProtectedUntil", time() + GameConfig.SpawnProtectionDuration)
	end

	-- Registrar el bot en la cache global de targets para que otros bots
	-- puedan elegirlo sin iterar workspace.
	_addAliveTarget(botModel)

	local record: BotRecord = {
		model = botModel,
		humanoid = humanoid,
		team = team,
		deathConnection = nil,
		hasDeathBeenReported = false,
		ai = botAIInstance,
		descendantConn = descendantConn,
	}

	botAIInstance:Start(mapRoot, _aliveTargets, _roamGraph, _botModelByFakeUserId)

	record.deathConnection = humanoid.Died:Connect(function()
		if record.hasDeathBeenReported then
			return
		end
		record.hasDeathBeenReported = true

		-- 0. Limpieza visual FIRST — orden crítico: estas operaciones tienen que
		-- correr aunque la lógica de juego de abajo falle. Si están más abajo y
		-- algo entre medias throws, el bot queda "corriendo tumbado" para
		-- siempre. Cada una en pcall por separado para que un fallo no cancele
		-- las demás.

		-- 0a-pre. Cortar el listener de CollisionGroup antes del kill effect:
		-- éste parentea N parts nuevos al ragdoll y dispararía el handler
		-- innecesariamente sobre un modelo en cleanup.
		if record.descendantConn then
			record.descendantConn:Disconnect()
			record.descendantConn = nil
		end

		-- 0a. Destrucción programada SIEMPRE. Aunque todo lo demás falle, el
		-- bot eventualmente desaparece.
		task.delay(BotConfig.Lifecycle.RagdollCleanupDelay, function()
			if botModel.Parent ~= nil then
				botModel:Destroy()
			end
		end)

		-- 0b. Parar IA + animaciones. Antes sin pcall: si throwea, las
		-- animaciones de correr siguen jugando aunque haya ragdoll.
		pcall(function()
			record.ai:Stop()
		end)

		-- 0c. Kill effect (ragdoll). Ya estaba en pcall.
		local effectId = _getKillEffectForBotAttacker(humanoid)
		pcall(KillEffectsRegistry.apply, effectId, botModel)

		-- 0d. Quitar del cache de targets vivos.
		pcall(_removeAliveTarget, botModel)

		if record.deathConnection then
			record.deathConnection:Disconnect()
			record.deathConnection = nil
		end

		-- 1. Lógica de juego: recycle identity, refresh lists, notify. Cualquier
		-- error aquí ya no afecta la limpieza visual de arriba. En pcall
		-- envolvente para no romper el bucle de spawn de otros bots.
		pcall(function()
			table.insert(_recycledByTeam[team], { identity = identity, fakeUserId = fakeUserId })
			-- B6: clear el index — el nuevo bot se asignará en _spawnOneBot.
			_botModelByFakeUserId[fakeUserId] = nil
			_botsByName[botName] = nil
			_activeBotCount = math.max(0, _activeBotCount - 1)
			_botIdentityByName[botName] = nil
			_botFakeUserIdByName[botName] = nil
			_refreshAliveLists()
			_notifyActiveBotCount()
			NavMetrics.RecordBotDied()
		end)

		-- 2. Callback externo de juego (persistencia, streak, remotes). Ya
		-- estaba en pcall.
		if _onBotDied then
			local ok, err = pcall(_onBotDied, team, botName, humanoid, fakeUserId)
			if not ok then
				warn(string.format("[AIService] _onBotDied error en %s: %s", botName, tostring(err)))
			end
		end
	end)

	_botsByName[botName] = record
	_activeBotCount += 1
	table.insert(_botNamesByTeam[team], botName)
	_notifyActiveBotCount()
	NavMetrics.RecordBotSpawned()
	return true
end

local function _setTargetForTeam(team: "A" | "B", targetCount: number)
	_refreshAliveLists()
	local target = math.max(0, targetCount)
	local current = #_botNamesByTeam[team]

	while current < target do
		if not _spawnOneBot(team) then
			break
		end
		current += 1
	end

	while current > target do
		local list = _botNamesByTeam[team]
		local botName = list[#list]
		if not botName then
			break
		end
		_removeBotByName(botName)
		current -= 1
	end

	-- Trim excess recycled identities so roster matches the new target
	local recycledPool = _recycledByTeam[team]
	local aliveNow = #_botNamesByTeam[team]
	local maxRecycled = math.max(0, target - aliveNow)
	while #recycledPool > maxRecycled do
		local removed = table.remove(recycledPool, #recycledPool)
		if removed then
			_identityByFakeUserId[removed.fakeUserId] = nil
			_teamByFakeUserId[removed.fakeUserId] = nil
		end
	end
end

function AIService:SetDataService(dataService: any)
	_dataServiceRef = dataService
end

function AIService:OnRoundStart(config: RoundStartConfig)
	self:OnRoundEnd()
	_isRoundActive = true
	_mapRoot = config.mapRoot
	_spawnPoints = table.clone(config.spawnPoints or {})
	_onBotDied = config.onBotDied
	_nextBotId = 1
	_fakeUserIdCounter = 0
	table.clear(_usedIdentityIndices)
	table.clear(_botIdentityByName)
	table.clear(_botFakeUserIdByName)
	table.clear(_recycledByTeam.A)
	table.clear(_recycledByTeam.B)
	table.clear(_identityByFakeUserId)
	table.clear(_teamByFakeUserId)
	NavMetrics.ResetCounts()
	NavMetrics.SetActiveBotCount(0)
	-- RoamGraph cacheado por mapRoot. Si el mapa es el mismo del round
	-- anterior, reusa el pool ya construido (cero coste). Si es distinto,
	-- construye uno nuevo en el primer pickRandomNavigablePoint.
	if _mapRoot then
		_roamGraph = RoamGraph.forMap(_mapRoot)
	else
		_roamGraph = nil
	end
end

function AIService:SetBotTargets(targetA: number, targetB: number)
	if not _isRoundActive then
		return
	end

	_setTargetForTeam("A", targetA)
	_setTargetForTeam("B", targetB)
end

function AIService:OnRoundEnd()
	_isRoundActive = false

	local namesToRemove = {} :: { string }
	for botName in _botsByName do
		table.insert(namesToRemove, botName)
	end

	for _, botName in namesToRemove do
		_removeBotByName(botName)
	end

	table.clear(_botsByName)
	table.clear(_botNamesByTeam.A)
	table.clear(_botNamesByTeam.B)
	_spawnPoints = {}
	_mapRoot = nil
	-- No destruir _roamGraph aquí: si la siguiente ronda usa el mismo mapRoot,
	-- queremos reusar la caché. AncestryChanged limpia automáticamente cuando
	-- el modelo del mapa se destruya.
	_roamGraph = nil
	_onBotDied = nil
	-- Purgar la cola global. Las callbacks ya guardan _stopped, así que no
	-- es funcional — solo libera closures con refs a Path/Navigator viejos.
	PathfindingQueue.clear()
	table.clear(_usedIdentityIndices)
	table.clear(_botIdentityByName)
	table.clear(_botFakeUserIdByName)
	table.clear(_recycledByTeam.A)
	table.clear(_recycledByTeam.B)
	table.clear(_identityByFakeUserId)
	table.clear(_teamByFakeUserId)
end

function AIService:GetBotRoster(): { { fakeUserId: number, displayName: string, team: string, image: string, level: number, historicalKills: number } }
	local roster = {}
	for fakeUserId, identity in _identityByFakeUserId do
		local team = _teamByFakeUserId[fakeUserId]
		if team then
			table.insert(roster, {
				fakeUserId = fakeUserId,
				displayName = identity.name,
				team = team,
				image = identity.image,
				level = identity.level,
				historicalKills = identity.historicalKills,
			})
		end
	end
	return roster
end

function AIService:GetBotDisplayName(fakeUserId: number): string?
	local identity = _identityByFakeUserId[fakeUserId]
	return if identity then identity.name else nil
end

--- Devuelve la identity completa (con level + historicalKills + personalityId
--- + appearance) por fakeUserId. Usado por MatchService para sustituir stats
--- de killer cuando el atacante es un bot. Devuelve nil si no se conoce.
function AIService:GetBotIdentity(fakeUserId: number): BotIdentity?
	return _identityByFakeUserId[fakeUserId]
end

return AIService
