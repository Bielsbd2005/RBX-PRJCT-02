--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local RagdollCleanup = require(Shared.Locker.killEffects.RagdollCleanup)
local CollisionGroups = require(Shared:WaitForChild("CollisionGroups"))
local BotNames = require(Shared.constants.BotNames)
local BotConfig = require(Shared.constants.BotConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)

local LastAttackerStore = require(ReplicatedStorage:WaitForChild("WeaponsSystem"):WaitForChild("Libraries"):WaitForChild("LastAttackerStore"))
local BotAI = require(script:WaitForChild("BotAI"))
local BotAppearance = require(script:WaitForChild("BotAppearance"))
local BotPersonality = require(script:WaitForChild("BotPersonality"))
local RoamGraph = require(script:WaitForChild("nav"):WaitForChild("RoamGraph"))
local PathfindingQueue = require(script:WaitForChild("nav"):WaitForChild("PathfindingQueue"))
local StuckViz = require(script:WaitForChild("debug"):WaitForChild("StuckViz"))

local DataServiceMod = require(script.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

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
	-- Inyectado por MatchService (SpawnSelector, mismas reservas que los jugadores)
	-- para no depender de match. Si falta o devuelve nil, spawn aleatorio.
	selectSpawnPoint: ((team: "A" | "B") -> BasePart?)?,
	-- Se llama cuando el spawn pump termina de rellenar el roster.
	onRosterChanged: (() -> ())?,
}

type BotRecord = {
	model: Model,
	humanoid: Humanoid,
	team: "A" | "B",
	deathConnection: RBXScriptConnection?,
	hasDeathBeenReported: boolean,
	-- Se dispara desde Humanoid.Died y, como fallback, desde _refreshAliveLists.
	handleDeath: (() -> ())?,
	ai: BotAI.BotAIInstance,
	descendantConn: RBXScriptConnection?,
}

local _dataServiceRef: DataService? = nil

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
-- Sube en cada OnRoundEnd. El death handler (que puede correr diferido) no toca
-- estado de ronda si la generación cambió: reinsertaría una identidad cuyo
-- fakeUserId colisiona tras reiniciarse _fakeUserIdCounter.
local _roundGeneration = 0
local _mapRoot: Instance? = nil
local _roamGraph: RoamGraph.RoamGraph? = nil
local _spawnPoints: { BasePart } = {}
local _selectSpawnPoint: ((team: "A" | "B") -> BasePart?)? = nil
local _onBotDied: ((string, string, Humanoid, number) -> ())? = nil
-- SetBotTargets vuelve antes de que el pump acabe: MatchService re-emite el roster aquí.
local _onRosterChanged: (() -> ())? = nil
local _botsByName: { [string]: BotRecord } = {}
-- os.clock() mínimo para reemplazar a un bot muerto de cada equipo
-- (BotConfig.Lifecycle.RespawnDelay). Los rellenos de inicio de ronda no esperan.
local _spawnHoldUntil = { A = 0, B = 0 }
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

-- Objetivos vivos (jugadores + bots) compartidos por todos los BotAI, mantenidos
-- por señales. hum/root se resuelven al añadir; BotAI los refresca si mueren.
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
	local last = #_aliveTargets
	if idx ~= last then
		local moved = _aliveTargets[last]
		_aliveTargets[idx] = moved
		_aliveTargetIndex[moved.model] = idx
	end
	_aliveTargets[last] = nil
end

-- Dedupe: un jugador que entra entre el PlayerAdded:Connect y el bucle inicial
-- llegaría dos veces.
local _wiredPlayers: { [Player]: true } = {}

local function _wirePlayerAliveTracking(player: Player)
	if _wiredPlayers[player] then
		return
	end
	_wiredPlayers[player] = true

	local function onChar(char: Model)
		-- Remove defensivo: la entrada previa puede seguir si Roblox recicla el Model.
		_removeAliveTarget(char)
		_addAliveTarget(char)
		-- El char puede destruirse sin Died (respawn instantáneo, kick).
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

game:BindToClose(function()
	for _, record in pairs(_botsByName) do
		if record and record.ai then
			pcall(function()
				record.ai:Stop()
			end)
		end
	end
end)

-- Las identidades del pool son usuarios reales de Roblox: se descartan las que
-- coincidan con un jugador presente (compartirían nombre y foto).
type TakenIdentitySet = { userIds: { [number]: true }, names: { [string]: true } }

local _lowerNameByPoolIndex: { [number]: string } = {}
for index, source in BotNames do
	_lowerNameByPoolIndex[index] = source.name:lower()
end

local function _buildTakenIdentitySet(): TakenIdentitySet
	local userIds: { [number]: true } = {}
	local names: { [string]: true } = {}
	for _, player in Players:GetPlayers() do
		userIds[player.UserId] = true
		names[player.Name:lower()] = true
		names[player.DisplayName:lower()] = true
	end
	return { userIds = userIds, names = names }
end

local function _isIdentityTakenByRealPlayer(index: number, source: BotNames.BotIdentity, taken: TakenIdentitySet): boolean
	if taken.userIds[source.userId] then
		return true
	end
	local lowerName = _lowerNameByPoolIndex[index] or source.name:lower()
	return taken.names[lowerName] == true
end

local function _assignIdentity(): (BotIdentity, number)
	_fakeUserIdCounter -= 1
	local fakeUserId = _fakeUserIdCounter
	local available = {}
	local taken = _buildTakenIdentitySet()
	for i, source in BotNames do
		if not _usedIdentityIndices[i] and not _isIdentityTakenByRealPlayer(i, source, taken) then
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
		-- Pool agotado. No usar prefijo "Player": colisiona con usernames reales.
		name = "Bot_" .. tostring(math.abs(fakeUserId))
		image = "rbxassetid://0"
	end

	local personalityId, personality = BotPersonality.rollPersonality()
	local level, historicalKills = BotPersonality.rollStats(personality)

	-- Personalidad y apariencia viven en la identity: al reciclarse tras morir, el
	-- bot mantiene su look toda la ronda; se re-rolean al limpiar en OnRoundEnd.
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

	local deadUnreported: { BotRecord }? = nil
	for name, bot in _botsByName do
		if bot.model.Parent == nil then
			if bot.deathConnection then
				bot.deathConnection:Disconnect()
				bot.deathConnection = nil
			end
			_botsByName[name] = nil
		elseif bot.humanoid.Health <= 0 then
			-- NO desconectar deathConnection aquí: el cuerpo quedaría sin ragdoll ni
			-- Destroy. Si Died no corrió, se dispara diferido como fallback.
			if not bot.hasDeathBeenReported then
				deadUnreported = deadUnreported or {}
				table.insert(deadUnreported, bot)
			end
		else
			if bot.team == "A" then
				table.insert(listA, name)
			else
				table.insert(listB, name)
			end
		end
	end

	if deadUnreported then
		for _, bot in deadUnreported do
			task.defer(function()
				if not bot.hasDeathBeenReported and bot.handleDeath then
					bot.handleDeath()
				end
			end)
		end
	end
end

local function _getRandomSpawnPoint(): BasePart?
	if #_spawnPoints == 0 then
		return nil
	end

	return _spawnPoints[math.random(1, #_spawnPoints)]
end

local function _getSpawnPoint(team: "A" | "B"): BasePart?
	local selector = _selectSpawnPoint
	if selector then
		local point = selector(team)
		if point then
			return point
		end
	end

	return _getRandomSpawnPoint()
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

-- Pools de rigs pre-clonados por outfitId (Shared.Bodies.<outfitId>) para sacar
-- el Clone del spawn. Los rigs no se reutilizan entre vidas: un Humanoid Dead no
-- se puede revivir limpiamente.
local _botRigPoolByKey: { [string]: { Model } } = {}
local _botRigRefillingByKey: { [string]: boolean } = {}
local BOT_RIG_POOL_TARGET = 3
-- Tope global de rigs aparcados (la memoria no crece con el catálogo de outfits):
-- 2× el máximo de bots simultáneos cubre una oleada completa de respawns.
local MAX_TOTAL_PARKED_RIGS = GameConfig.TeamSizeTarget * 4
-- Tamaño de cada pool entre rondas (las identidades se re-rolean); el prewarm de
-- la fase Voting rellena el resto.
local BOT_RIG_POOL_IDLE_TARGET = 1
local _botRigParkFolder: Folder? = nil

local function _ensureParkFolder(): Folder
	if _botRigParkFolder and _botRigParkFolder.Parent then
		return _botRigParkFolder
	end
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
	clone.Parent = _ensureParkFolder()
	return clone
end

local function _countParkedRigs(): number
	local total = 0
	for _, pool in _botRigPoolByKey do
		total += #pool
	end
	return total
end

local function _trimRigPools(perPoolTarget: number)
	for _, pool in _botRigPoolByKey do
		while #pool > perPoolTarget do
			local rig = table.remove(pool, #pool)
			if rig then
				rig:Destroy()
			end
		end
	end
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
		while #pool < BOT_RIG_POOL_TARGET and _countParkedRigs() < MAX_TOTAL_PARKED_RIGS do
			local rig = _clonePreparedRig(poolKey)
			if not rig then break end
			table.insert(pool, rig)
			-- Sin este yield todos los clones caerían en el mismo frame.
			task.wait()
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
	_refillBotRigPoolAsync(poolKey)
	return _clonePreparedRig(poolKey)
end

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

	if not _hasWarnedMissingTemplate then
		_hasWarnedMissingTemplate = true
		warn("[AIService] BotTemplate no encontrado (esperado en Shared.Bodies.<outfitId> o Shared.Bodies.Default). Usando modelo barebones — los bots aparecerán en T-pose y sin arma hasta que se restaure el template.")
	end
	return _buildFallbackBotModel(botName)
end

-- Serializado (un pool cada vez) para costar ~1 clone por frame. Corre al cargar
-- y al abrir la fase Voting (MatchService).
local _prewarmRunning = false
local function _prewarmRigPools()
	if _prewarmRunning then
		return
	end
	_prewarmRunning = true
	task.spawn(function()
		for _, outfitId in BotAppearance.getAvailableOutfitIds() do
			_refillBotRigPoolAsync(outfitId)
			while _botRigRefillingByKey[outfitId] do
				task.wait()
			end
		end
		_prewarmRunning = false
	end)
end

_prewarmRigPools()

local function _removeBotByName(botName: string, skipRefresh: boolean?)
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
	if not skipRefresh then
		_refreshAliveLists()
	end
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

	local spawnPoint = _getSpawnPoint(team)
	if not spawnPoint then
		return false
	end

	local botName = string.format("Bot_%s_%d", team, _nextBotId)
	_nextBotId += 1
	local spawnGeneration = _roundGeneration

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

	botModel:SetAttribute("DisplayName", identity.name)
	botModel:SetAttribute("FakeUserId", fakeUserId)
	botModel:SetAttribute("ProfileImage", identity.image)
	_botModelByFakeUserId[fakeUserId] = botModel
	humanoid.DisplayName = identity.name

	-- El wrap no va aquí: lo aplica BotAI:_setupTool al clonar el tool.
	BotAppearance.apply(botModel, identity.appearance)

	local wrapId = if identity.appearance then identity.appearance.wrapId else nil
	local weaponId = if identity.appearance then identity.appearance.weaponId else nil
	local personality = BotPersonality.getById(identity.personalityId)
	local botAIInstance = BotAI.new(botModel, team, fakeUserId, wrapId, if personality then personality.combat else nil, weaponId)

	local botsFolder = mapRoot:FindFirstChild("Bots")
	if not botsFolder then
		botsFolder = Instance.new("Folder")
		botsFolder.Name = "Bots"
		botsFolder.Parent = mapRoot
	end

	-- Posicionar antes de parentear, y con PivotTo (no root.CFrame): fuera del
	-- Workspace los WeldConstraint no son rígidos y la ropa quedaría descolocada.
	-- rootToPivot deja el HumanoidRootPart exactamente sobre el spawn.
	local rootToPivot = root.CFrame:ToObjectSpace(botModel:GetPivot())
	botModel:PivotTo((spawnPoint.CFrame + Vector3.new(0, 4, 0)) * rootToPivot)
	botModel.Parent = botsFolder
	humanoid.Health = humanoid.MaxHealth
	humanoid.BreakJointsOnDeath = false

	-- Dead/Running/Jumping/Freefall/Landed deben seguir activos (movimiento,
	-- animaciones y Died). Los kill effects no usan Ragdoll/FallingDown.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	-- Bot↔bot sin colisión a propósito: dos bots empujándose disparan el StuckDetector.
	CollisionGroups.setGroupForCharacter(botModel, CollisionGroups.BOTS)
	-- Se desconecta al morir, antes de que el kill effect añada sus parts.
	local descendantConn = botModel.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			CollisionGroups.applyToNewPart(botModel, descendant)
		end
	end)

	-- Inmunidad al spawn como los jugadores (MatchService), pero invisible por coste
	-- en móvil. SpawnProtectedUntil lo lee BotAI._getBestTarget.
	if GameConfig.SpawnProtectionDuration > 0 then
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = botModel
		Debris:AddItem(forceField, GameConfig.SpawnProtectionDuration)
		botModel:SetAttribute("SpawnProtectedUntil", time() + GameConfig.SpawnProtectionDuration)
	end

	_addAliveTarget(botModel)

	local record: BotRecord = {
		model = botModel,
		humanoid = humanoid,
		team = team,
		deathConnection = nil,
		hasDeathBeenReported = false,
		handleDeath = nil,
		ai = botAIInstance,
		descendantConn = descendantConn,
	}

	botAIInstance:Start(mapRoot, _aliveTargets, _roamGraph, _botModelByFakeUserId)

	-- Idempotente (hasDeathBeenReported): lo llaman Died y el fallback de _refreshAliveLists.
	local function handleBotDeath()
		if record.hasDeathBeenReported then
			return
		end
		record.hasDeathBeenReported = true

		-- Orden crítico: la limpieza visual va primero y cada paso en su pcall, para
		-- que un error en la lógica de juego no deje al bot corriendo tumbado.
		if record.descendantConn then
			record.descendantConn:Disconnect()
			record.descendantConn = nil
		end

		-- Destrucción programada antes que nada: el bot desaparece aunque todo lo demás falle.
		local ragdollMin = BotConfig.Lifecycle.RagdollCleanupDelay
		RagdollCleanup.scheduleDestroy(botModel, {
			minTime = ragdollMin,
			maxTime = ragdollMin + 1,
			fadeTime = 0.4,
		})

		pcall(function()
			record.ai:Stop()
		end)

		local effectId = _getKillEffectForBotAttacker(humanoid)
		pcall(KillEffectsRegistry.apply, effectId, botModel)

		pcall(_removeAliveTarget, botModel)

		if record.deathConnection then
			record.deathConnection:Disconnect()
			record.deathConnection = nil
		end

		-- Handler tardío (ronda ya terminada): nada de estado de ronda; _onBotDied
		-- acreditaría la kill en la ronda equivocada.
		if _roundGeneration ~= spawnGeneration then
			return
		end

		pcall(function()
			if BotConfig.Lifecycle.RespawnDelay > 0 then
				_spawnHoldUntil[team] = os.clock() + BotConfig.Lifecycle.RespawnDelay
			end
			table.insert(_recycledByTeam[team], { identity = identity, fakeUserId = fakeUserId })
			_botModelByFakeUserId[fakeUserId] = nil
			_botsByName[botName] = nil
			_botIdentityByName[botName] = nil
			_botFakeUserIdByName[botName] = nil
			_refreshAliveLists()
		end)

		if _onBotDied then
			local ok, err = pcall(_onBotDied, team, botName, humanoid, fakeUserId)
			if not ok then
				warn(string.format("[AIService] _onBotDied error en %s: %s", botName, tostring(err)))
			end
		end
	end

	record.handleDeath = handleBotDeath
	record.deathConnection = humanoid.Died:Connect(handleBotDeath)

	_botsByName[botName] = record
	table.insert(_botNamesByTeam[team], botName)
	return true
end

-- Los spawns se reparten entre Heartbeats (MAX_SPAWNS_PER_STEP por paso). El pump
-- relee objetivos y recuentos en cada iteración, así que los rebalanceos a mitad
-- se reconcilian solos. Las bajas son síncronas: un bot sobrante no debe seguir disparando.
local _desiredBotTargets: { A: number, B: number } = { A = 0, B = 0 }
local _spawnPumpRunning = false
local MAX_SPAWNS_PER_STEP = 2

local function _notifyRosterChanged()
	local cb = _onRosterChanged
	if cb then
		pcall(cb)
	end
end

-- Un jugador que entra a mitad de ronda puede coincidir con la identidad de un
-- bot ya spawneado: el bot la cambia en caliente.

local _poolIndexByName: { [string]: number } = {}
for index, source in BotNames do
	_poolIndexByName[source.name:lower()] = index
end

local function _identityCollidesWith(identity: BotIdentity, player: Player): boolean
	local name = identity.name:lower()
	return name == player.Name:lower() or name == player.DisplayName:lower()
end

-- Muta `identity` en sitio: la tabla es compartida con _identityByFakeUserId y
-- las entradas recicladas.
local function _swapIdentityInPlace(identity: BotIdentity): boolean
	local replacementIndex: number? = nil
	local taken = _buildTakenIdentitySet()
	for index, source in BotNames do
		if not _usedIdentityIndices[index] and not _isIdentityTakenByRealPlayer(index, source, taken) then
			replacementIndex = index
			break
		end
	end
	if not replacementIndex then
		return false
	end

	local previousIndex = _poolIndexByName[identity.name:lower()]
	if previousIndex then
		_usedIdentityIndices[previousIndex] = nil
	end
	_usedIdentityIndices[replacementIndex] = true

	local source = BotNames[replacementIndex]
	identity.name = source.name
	identity.image = source.image
	return true
end

local function _reassignIdentitiesTakenBy(player: Player)
	if not _isRoundActive then
		return
	end
	local swapped = false

	for botName, identity in _botIdentityByName do
		if not _identityCollidesWith(identity, player) then
			continue
		end
		if not _swapIdentityInPlace(identity) then
			continue
		end
		swapped = true

		local fakeUserId = _botFakeUserIdByName[botName]
		local model = if fakeUserId then _botModelByFakeUserId[fakeUserId] else nil
		if model then
			model:SetAttribute("DisplayName", identity.name)
			model:SetAttribute("ProfileImage", identity.image)
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.DisplayName = identity.name
			end
		end
	end

	for _, list in { _recycledByTeam.A, _recycledByTeam.B } do
		for _, entry in list do
			if _identityCollidesWith(entry.identity, player) and _swapIdentityInPlace(entry.identity) then
				swapped = true
			end
		end
	end

	if swapped then
		_notifyRosterChanged()
	end
end

Players.PlayerAdded:Connect(_reassignIdentitiesTakenBy)

local function _trimTeamToTarget(team: "A" | "B", target: number)
	local list = _botNamesByTeam[team]
	while #list > target do
		local botName = list[#list]
		if not botName then
			break
		end
		_removeBotByName(botName)
	end

	local recycledPool = _recycledByTeam[team]
	local maxRecycled = math.max(0, target - #list)
	while #recycledPool > maxRecycled do
		local removed = table.remove(recycledPool, #recycledPool)
		if removed then
			_identityByFakeUserId[removed.fakeUserId] = nil
			_teamByFakeUserId[removed.fakeUserId] = nil
		end
	end
end

local function _spawnDeficit(team: "A" | "B"): number
	return _desiredBotTargets[team] - #_botNamesByTeam[team]
end

local function _ensureSpawnPump()
	if _spawnPumpRunning then
		return
	end
	_spawnPumpRunning = true
	-- task.spawn corre síncrono hasta el primer task.wait: un respawn suelto se
	-- completa dentro de la llamada a SetBotTargets.
	task.spawn(function()
		local spawnedAny = false
		while _isRoundActive do
			local budget = MAX_SPAWNS_PER_STEP
			while budget > 0 do
				-- Un equipo en espera cuenta 0 aquí, pero la salida exterior usa el déficit
				-- real: el pump sigue vivo hasta que expire la espera.
				local now = os.clock()
				local deficitA = if now >= _spawnHoldUntil.A then _spawnDeficit("A") else 0
				local deficitB = if now >= _spawnHoldUntil.B then _spawnDeficit("B") else 0
				if deficitA <= 0 and deficitB <= 0 then
					break
				end
				local team: "A" | "B" = if deficitA >= deficitB then "A" else "B"
				if not _spawnOneBot(team) then
					-- Fallo de spawn: abandonar; el próximo rebalanceo rearma el pump.
					_spawnPumpRunning = false
					if spawnedAny then
						_notifyRosterChanged()
					end
					return
				end
				spawnedAny = true
				budget -= 1
			end
			if _spawnDeficit("A") <= 0 and _spawnDeficit("B") <= 0 then
				break
			end
			task.wait()
		end
		_spawnPumpRunning = false
		if spawnedAny then
			_notifyRosterChanged()
		end
	end)
end

function AIService:SetDataService(dataService: DataService)
	_dataServiceRef = dataService
end

function AIService:OnRoundStart(config: RoundStartConfig)
	self:OnRoundEnd()
	_isRoundActive = true
	_mapRoot = config.mapRoot
	_spawnPoints = table.clone(config.spawnPoints or {})
	StuckViz.setSpawnPoints(_spawnPoints)
	_selectSpawnPoint = config.selectSpawnPoint
	_onBotDied = config.onBotDied
	_onRosterChanged = config.onRosterChanged
	_nextBotId = 1
	_fakeUserIdCounter = 0
	table.clear(_usedIdentityIndices)
	table.clear(_botIdentityByName)
	table.clear(_botFakeUserIdByName)
	table.clear(_recycledByTeam.A)
	table.clear(_recycledByTeam.B)
	table.clear(_identityByFakeUserId)
	table.clear(_teamByFakeUserId)
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

	_refreshAliveLists()
	_desiredBotTargets.A = math.max(0, targetA)
	_desiredBotTargets.B = math.max(0, targetB)
	_trimTeamToTarget("A", _desiredBotTargets.A)
	_trimTeamToTarget("B", _desiredBotTargets.B)
	_ensureSpawnPump()
end

-- MatchService lo llama al abrir la fase Voting.
function AIService:PrewarmRigPools()
	_prewarmRigPools()
end

function AIService:OnRoundEnd()
	-- OnRoundStart también llama aquí: el recorte de pools solo en un fin de ronda
	-- real, o destruiría los rigs del prewarm de Voting.
	local wasActive = _isRoundActive
	_isRoundActive = false
	_roundGeneration += 1
	_desiredBotTargets.A = 0
	_desiredBotTargets.B = 0
	_spawnHoldUntil.A = 0
	_spawnHoldUntil.B = 0

	local namesToRemove = {} :: { string }
	for botName in _botsByName do
		table.insert(namesToRemove, botName)
	end

	for _, botName in namesToRemove do
		_removeBotByName(botName, true)
	end

	table.clear(_botsByName)
	table.clear(_botNamesByTeam.A)
	table.clear(_botNamesByTeam.B)
	_spawnPoints = {}
	_selectSpawnPoint = nil
	_mapRoot = nil
	-- No destruir: la siguiente ronda con el mismo mapRoot reusa la caché.
	_roamGraph = nil
	_onBotDied = nil
	_onRosterChanged = nil
	if wasActive then
		_trimRigPools(BOT_RIG_POOL_IDLE_TARGET)
	end
	-- No funcional (las callbacks miran _stopped): solo libera closures viejas.
	PathfindingQueue.clear()
	table.clear(_usedIdentityIndices)
	table.clear(_botIdentityByName)
	table.clear(_botFakeUserIdByName)
	table.clear(_recycledByTeam.A)
	table.clear(_recycledByTeam.B)
	table.clear(_identityByFakeUserId)
	table.clear(_teamByFakeUserId)
end

function AIService:GetBotRoster(): { { fakeUserId: number, displayName: string, team: string, image: string, level: number, historicalKills: number, outfitId: string, faceId: string, hatId: string } }
	local roster = {}
	for fakeUserId, identity in _identityByFakeUserId do
		local team = _teamByFakeUserId[fakeUserId]
		if team then
			-- La apariencia la usa la pantalla de Resultados para reconstruir al bot.
			local appearance = identity.appearance
			table.insert(roster, {
				fakeUserId = fakeUserId,
				displayName = identity.name,
				team = team,
				image = identity.image,
				level = identity.level,
				historicalKills = identity.historicalKills,
				outfitId = if appearance and appearance.outfitId then appearance.outfitId else "",
				faceId = if appearance and appearance.faceId then appearance.faceId else "",
				hatId = if appearance and appearance.hatId then appearance.hatId else "",
			})
		end
	end
	return roster
end

function AIService:GetBotDisplayName(fakeUserId: number): string?
	local identity = _identityByFakeUserId[fakeUserId]
	return if identity then identity.name else nil
end

function AIService:GetBotIdentity(fakeUserId: number): BotIdentity?
	return _identityByFakeUserId[fakeUserId]
end

return AIService
