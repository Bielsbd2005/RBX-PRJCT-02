--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local KillEffectsRegistry = require(Shared.locker.killEffects.KillEffectsRegistry)
local BotNames = require(Shared.constants.BotNames)

local BotAI = require(script:WaitForChild("BotAI"))

type BotIdentity = { name: string, image: string }

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
	deathReported: boolean,
	ai: typeof(BotAI.new(({} :: any), "A")),
}

local BOT_RAGDOLL_CLEANUP_DELAY = 5
local _dataServiceRef: any = nil

local function _getKillEffectForBotAttacker(humanoid: Humanoid): string
	local attackerUserIdAttr = humanoid:GetAttribute("LastAttackerUserId")
	local attackerAtAttr = humanoid:GetAttribute("LastAttackerAt")
	local attackerUserId = if type(attackerUserIdAttr) == "number" then attackerUserIdAttr else nil
	local attackerAt = if type(attackerAtAttr) == "number" then attackerAtAttr else 0
	if attackerAt > 0 and math.abs(time() - attackerAt) > 4 then
		return "Default"
	end
	if not attackerUserId then
		return "Default"
	end
	local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
	if not attackerPlayer then
		return "Default"
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
	return "Default"
end

local AIService = {}

local _isRoundActive = false
local _mapRoot: Instance? = nil
local _spawnPoints: { BasePart } = {}
local _onBotDied: ((string, string, Humanoid, number) -> ())? = nil
local _botsByName: { [string]: BotRecord } = {}
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
	local identity: BotIdentity
	if #available > 0 then
		local idx = available[math.random(1, #available)]
		_usedIdentityIndices[idx] = true
		identity = BotNames[idx]
	else
		-- Fallback: all identities used, generate unique name
		identity = { name = "Player" .. tostring(math.abs(fakeUserId)), image = "rbxassetid://0" }
	end
	return identity, fakeUserId
end

local function _clearTeamList(team: "A" | "B")
	local list = _botNamesByTeam[team]
	table.clear(list)
	for name, bot in _botsByName do
		if bot.team == team and bot.model.Parent ~= nil and bot.humanoid.Health > 0 then
			table.insert(list, name)
		end
	end
end

local function _refreshAliveLists()
	for name, bot in _botsByName do
		if bot.model.Parent == nil or bot.humanoid.Health <= 0 then
			if bot.deathConnection then
				bot.deathConnection:Disconnect()
				bot.deathConnection = nil
			end
			_botsByName[name] = nil
		end
	end

	_clearTeamList("A")
	_clearTeamList("B")
end

local function _getRandomSpawnPoint(): BasePart?
	if #_spawnPoints == 0 then
		return nil
	end

	return _spawnPoints[math.random(1, #_spawnPoints)]
end

local function _findTemplateBot(): Model?
	local replicatedDirect = ReplicatedStorage:FindFirstChild("NPC")
	if replicatedDirect and replicatedDirect:IsA("Model") then
		return replicatedDirect
	end

	local replicatedBotsFolder = ReplicatedStorage:FindFirstChild("Bots")
	if replicatedBotsFolder and replicatedBotsFolder:IsA("Folder") then
		local replicatedTemplate = replicatedBotsFolder:FindFirstChild("NPC")
		if replicatedTemplate and replicatedTemplate:IsA("Model") then
			return replicatedTemplate
		end
	end

	local botsFolder = ServerStorage:FindFirstChild("Bots")
	if botsFolder and botsFolder:IsA("Folder") then
		local template = botsFolder:FindFirstChild("BotTemplate")
		if template and template:IsA("Model") then
			return template
		end
	end

	local direct = ServerStorage:FindFirstChild("BotTemplate")
	if direct and direct:IsA("Model") then
		return direct
	end

	return nil
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

local function _createBotModel(botName: string): Model
	local template = _findTemplateBot()
	if template then
		local clone = template:Clone()
		clone.Name = botName
		return clone
	end

	return _buildFallbackBotModel(botName)
end

local function _removeBotByName(botName: string)
	local bot = _botsByName[botName]
	if not bot then
		return
	end

	bot.ai:Stop()

	if bot.deathConnection then
		bot.deathConnection:Disconnect()
		bot.deathConnection = nil
	end

	-- Clean identity tracking so GetBotRoster no longer includes this bot
	local fakeUserId = _botFakeUserIdByName[botName]
	if fakeUserId then
		_identityByFakeUserId[fakeUserId] = nil
		_teamByFakeUserId[fakeUserId] = nil
	end
	_botIdentityByName[botName] = nil
	_botFakeUserIdByName[botName] = nil

	if bot.model.Parent ~= nil then
		bot.model:Destroy()
	end

	_botsByName[botName] = nil
	_refreshAliveLists()
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

	local botModel = _createBotModel(botName)
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
	local hum = botModel:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayName = identity.name
	end

	local botAIInstance = BotAI.new(botModel, team, fakeUserId)

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

	local record: BotRecord = {
		model = botModel,
		humanoid = humanoid,
		team = team,
		deathConnection = nil,
		deathReported = false,
		ai = botAIInstance,
	}

	botAIInstance:Start(mapRoot)

	record.deathConnection = humanoid.Died:Connect(function()
		if record.deathReported then
			return
		end
		record.deathReported = true

		-- 1. Aplicar kill effect del asesino (ragdoll visible para todos)
		local effectId = _getKillEffectForBotAttacker(humanoid)
		pcall(KillEffectsRegistry.apply, effectId, botModel)

		-- 2. Parar la IA y animaciones ANTES del callback de juego. El callback
		-- _onBotDied es pesado (persistencia, remotes, rebalance de bots) y si
		-- alguna de esas operaciones lanza un error, el resto del handler se
		-- cancela en cascada — dejando al bot con la animación de correr
		-- congelada y sin programar nunca su destrucción.
		record.ai:Stop()
		if record.deathConnection then
			record.deathConnection:Disconnect()
			record.deathConnection = nil
		end

		-- 3. Recycle identity so the replacement bot keeps the same fakeUserId+name
		table.insert(_recycledByTeam[team], { identity = identity, fakeUserId = fakeUserId })
		_botsByName[botName] = nil
		_refreshAliveLists()

		-- 4. Programar destrucción siempre, incluso si _onBotDied falla.
		task.delay(BOT_RAGDOLL_CLEANUP_DELAY, function()
			if botModel.Parent ~= nil then
				botModel:Destroy()
			end
		end)

		-- 5. Callback de lógica de juego aislado: cualquier error aquí no debe
		-- impedir la limpieza del NPC (animación congelada / modelo persistente).
		if _onBotDied then
			local ok, err = pcall(_onBotDied, team, botName, humanoid, fakeUserId)
			if not ok then
				warn(string.format("[AIService] _onBotDied error en %s: %s", botName, tostring(err)))
			end
		end
	end)

	_botsByName[botName] = record
	table.insert(_botNamesByTeam[team], botName)
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
	_onBotDied = nil
	table.clear(_usedIdentityIndices)
	table.clear(_botIdentityByName)
	table.clear(_botFakeUserIdByName)
	table.clear(_recycledByTeam.A)
	table.clear(_recycledByTeam.B)
	table.clear(_identityByFakeUserId)
	table.clear(_teamByFakeUserId)
end

function AIService:DisarmAllBots()
	for _, bot in _botsByName do
		bot.ai:Stop()
		if bot.humanoid then
			pcall(function()
				bot.humanoid:UnequipTools()
			end)
		end
		for _, child in bot.model:GetChildren() do
			if child:IsA("Tool") then
				child.Parent = nil
			end
		end
	end
end

function AIService:GetBotRoster(): { { fakeUserId: number, displayName: string, team: string, image: string } }
	local roster = {}
	for fakeUserId, identity in _identityByFakeUserId do
		local team = _teamByFakeUserId[fakeUserId]
		if team then
			table.insert(roster, {
				fakeUserId = fakeUserId,
				displayName = identity.name,
				team = team,
				image = identity.image,
			})
		end
	end
	return roster
end

function AIService:GetBotDisplayName(fakeUserId: number): string?
	local identity = _identityByFakeUserId[fakeUserId]
	return if identity then identity.name else nil
end

return AIService
