--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TeamsService = game:GetService("Teams")
local Workspace = game:GetService("Workspace")

local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Network = require(Shared.networking.Network)

local BOTS_PER_TEAM = 3

type MapDefinition = {
	Name: string,
	Modes: { string },
	PlaceholderImage: string,
}

type ActiveVoteState = {
	options: { MapDefinition },
	optionNames: { string },
	optionImages: { [string]: string },
	optionModes: { [string]: string },
	voteCounts: { [string]: number },
	votesByUserId: { [number]: string },
	endAt: number,
	duration: number,
}

local MatchService = {}
MatchService.__index = MatchService

local _started = false
local _activeVote: ActiveVoteState? = nil
local _hasCompletedInitialVote = false
local _voteCooldownsByUserId: { [number]: number } = {}
local _phase = "Idle"

local _isMapLoading = false
local _isPlayEnabled = false
local _activeMapName = ""
local _activeMapContainer: BasePart? = nil
local _activeMapModel: Instance? = nil
local _roundId = 0
local _isRoundActive = false
local _roundEndAt = 0
local _roundScoreA = 0
local _roundScoreB = 0

local _teamByUserId: { [number]: "A" | "B" } = {}
local _isInMenuByUserId: { [number]: boolean } = {}
local _roundEndEligibleByUserId: { [number]: true } = {}
local _joinDebounceByUserId: { [number]: boolean } = {}
local _pendingSpawnByUserId: { [number]: boolean } = {}
local _deathConnectionsByUserId: { [number]: RBXScriptConnection } = {}
local _characterConnectionsByUserId: { [number]: RBXScriptConnection } = {}
local _deathAtByUserId: { [number]: number } = {}
local _respawnDebounceByUserId: { [number]: boolean } = {}
local _matchKillsByUserId: { [number]: number } = {}
local _killStreakByUserId: { [number]: number } = {}

local _teamA: Team? = nil
local _teamB: Team? = nil
local _finishRoundAndScheduleRestart: any = nil
local _AIService: any = nil
local _dataService: any = nil

local VOTE_CHANGE_COOLDOWN = 0.15
local DEFAULT_PLACEHOLDER_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"
local WEAPON_TOOLS_ROOT_NAME = "WeaponTools"
local MATCH_LOADOUT_TOOL_ATTRIBUTE = "MatchLoadoutTool"

local function _log(message: string)
	print("[MatchService] " .. message)
end

local function _setPhase(nextPhase: string, reason: string?)
	if _phase == nextPhase then
		return
	end

	local suffix = if reason and reason ~= "" then (" | " .. reason) else ""
	_log(string.format("Phase: %s -> %s%s", _phase, nextPhase, suffix))
	_phase = nextPhase
end

local function _sendMapLoadStateToAll()
	Network.Match.MapLoadState.SendToAll({
		isLoading = _isMapLoading,
		playEnabled = _isPlayEnabled,
		mapName = _activeMapName,
	})
end

local function _sendMapLoadStateToPlayer(player: Player)
	local ok, err = pcall(function()
		Network.Match.MapLoadState.SendTo({
			isLoading = _isMapLoading,
			playEnabled = _isPlayEnabled,
			mapName = _activeMapName,
		}, player)
	end)
	if not ok then
		_log(string.format("Failed MapLoadState snapshot to %s: %s", player.Name, tostring(err)))
	end
end

local function _buildRoundStatePacket(timeLeft: number)
	return {
		scoreA = _roundScoreA,
		scoreB = _roundScoreB,
		timeLeft = math.max(0, timeLeft),
	}
end

local function _broadcastRoundState()
	if not _isRoundActive then
		return
	end

	local timeLeft = math.ceil(math.max(0, _roundEndAt - time()))
	Network.Match.RoundState.SendToAll(_buildRoundStatePacket(timeLeft))
end

local function _sendRoundStateToPlayer(player: Player)
	if not _isRoundActive then
		return
	end

	local timeLeft = math.ceil(math.max(0, _roundEndAt - time()))
	local ok, err = pcall(function()
		Network.Match.RoundState.SendTo(_buildRoundStatePacket(timeLeft), player)
	end)
	if not ok then
		_log(string.format("Failed RoundState snapshot to %s: %s", player.Name, tostring(err)))
	end
end

local function _sendPlayerStreakToAll(userId: number)
	Network.Match.PlayerStreakState.SendToAll({
		userId = tostring(userId),
		kills = _matchKillsByUserId[userId] or 0,
		streak = _killStreakByUserId[userId] or 0,
	})
end

local function _sendPlayerStreakToPlayer(player: Player, userId: number)
	local ok, err = pcall(function()
		Network.Match.PlayerStreakState.SendTo({
			userId = tostring(userId),
			kills = _matchKillsByUserId[userId] or 0,
			streak = _killStreakByUserId[userId] or 0,
		}, player)
	end)

	if not ok then
		_log(string.format("Failed PlayerStreakState snapshot to %s for user %d: %s", player.Name, userId, tostring(err)))
	end
end

local function _sendAllPlayerStreaksToPlayer(player: Player)
	for _, otherPlayer in Players:GetPlayers() do
		_sendPlayerStreakToPlayer(player, otherPlayer.UserId)
	end
end

local function _resetAllPlayerStreakState()
	table.clear(_matchKillsByUserId)
	table.clear(_killStreakByUserId)

	for _, player in Players:GetPlayers() do
		_matchKillsByUserId[player.UserId] = 0
		_killStreakByUserId[player.UserId] = 0
		_sendPlayerStreakToAll(player.UserId)
	end
end

local function _registerKillEvent(deadPlayer: Player, attackerUserId: number?)
	_killStreakByUserId[deadPlayer.UserId] = 0
	if _matchKillsByUserId[deadPlayer.UserId] == nil then
		_matchKillsByUserId[deadPlayer.UserId] = 0
	end
	_sendPlayerStreakToAll(deadPlayer.UserId)

	if not attackerUserId or attackerUserId == deadPlayer.UserId then
		return
	end

	local attacker = Players:GetPlayerByUserId(attackerUserId)
	if not attacker then
		return
	end

	if _isInMenuByUserId[attackerUserId] then
		return
	end

	_matchKillsByUserId[attackerUserId] = (_matchKillsByUserId[attackerUserId] or 0) + 1
	_killStreakByUserId[attackerUserId] = (_killStreakByUserId[attackerUserId] or 0) + 1
	_sendPlayerStreakToAll(attackerUserId)
end

local function _ensureTeams()
	if _teamA and _teamB then
		return
	end

	local function getOrCreateTeam(name: string, color: Color3): Team
		local existing = TeamsService:FindFirstChild(name)
		if existing and existing:IsA("Team") then
			existing.TeamColor = BrickColor.new(color)
			return existing
		end

		local team = Instance.new("Team")
		team.Name = name
		team.TeamColor = BrickColor.new(color)
		team.AutoAssignable = false
		team.Parent = TeamsService
		return team
	end

	_teamA = getOrCreateTeam(GameConfig.Teams.A.Name, GameConfig.Teams.A.Color)
	_teamB = getOrCreateTeam(GameConfig.Teams.B.Name, GameConfig.Teams.B.Color)
end

local function _countAssignments(): (number, number)
	local connectedByUserId = {} :: { [number]: true }
	for _, player in Players:GetPlayers() do
		connectedByUserId[player.UserId] = true
	end

	local a = 0
	local b = 0
	for userId, side in _teamByUserId do
		if connectedByUserId[userId] then
			if side == "A" then
				a += 1
			else
				b += 1
			end
		end
	end

	return a, b
end

local function _pickBalancedTeam(userId: number): "A" | "B"
	local assigned = _teamByUserId[userId]
	if assigned then
		return assigned
	end

	local countA, countB = _countAssignments()
	local selected: "A" | "B"
	if countA < countB then
		selected = "A"
	elseif countB < countA then
		selected = "B"
	else
		selected = if math.random() < 0.5 then "A" else "B"
	end

	_teamByUserId[userId] = selected
	return selected
end

local function _collectSpawnPointsForTeam(activeMapRoot: Instance, side: "A" | "B"): { BasePart }
	local spawnsRoot = activeMapRoot:FindFirstChild("Spawns", true)
	if not spawnsRoot then
		return {}
	end

	local teamFolderName = if side == "A" then "TeamA" else "TeamB"
	local teamFolder = spawnsRoot:FindFirstChild(teamFolderName)
	if not teamFolder then
		return {}
	end

	local points = {} :: { BasePart }
	for _, node in teamFolder:GetDescendants() do
		if node:IsA("BasePart") then
			table.insert(points, node)
		end
	end

	return points
end

local function _disconnectDeathConnection(userId: number)
	local conn = _deathConnectionsByUserId[userId]
	if conn then
		conn:Disconnect()
		_deathConnectionsByUserId[userId] = nil
	end
end

local function _registerDeathListener(player: Player, character: Model)
	_disconnectDeathConnection(player.UserId)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	_deathConnectionsByUserId[player.UserId] = humanoid.Died:Connect(function()
		if not _isRoundActive then
			return
		end

		if _isInMenuByUserId[player.UserId] then
			return
		end

		local deadSide = _teamByUserId[player.UserId]
		if deadSide == nil then
			return
		end

		_deathAtByUserId[player.UserId] = time()
		_respawnDebounceByUserId[player.UserId] = nil
		local attackerUserIdAttr = humanoid:GetAttribute("LastAttackerUserId")
		local attackerAtAttr = humanoid:GetAttribute("LastAttackerAt")
		local attackerWeaponNameAttr = humanoid:GetAttribute("LastAttackerWeaponName")
		local attackerUserId = if type(attackerUserIdAttr) == "number" then attackerUserIdAttr else nil
		local attackerAt = if type(attackerAtAttr) == "number" then attackerAtAttr else 0
		local attackerWeaponName = if type(attackerWeaponNameAttr) == "string" then attackerWeaponNameAttr else ""
		if attackerAt > 0 and math.abs(time() - attackerAt) > 4 then
			attackerUserId = nil
		end
		local attackerPlayer = if attackerUserId then Players:GetPlayerByUserId(attackerUserId) else nil
		local killerName = if attackerPlayer then attackerPlayer.Name else ""
		_registerKillEvent(player, attackerUserId)

		if deadSide == "A" then
			_roundScoreB += 1
		else
			_roundScoreA += 1
		end

		_broadcastRoundState()

		if _roundScoreA >= GameConfig.WinScoreLimit then
			_finishRoundAndScheduleRestart("win score limit reached", "A")
			return
		elseif _roundScoreB >= GameConfig.WinScoreLimit then
			_finishRoundAndScheduleRestart("win score limit reached", "B")
			return
		end

		if player.Parent == Players then
			Network.Match.DeathScreenShow.SendTo({
				respawnCooldown = GameConfig.RespawnCooldown,
				killerUserId = if attackerUserId then tostring(attackerUserId) else "",
				killerName = killerName,
				weaponName = attackerWeaponName,
			}, player)
		end
	end)
end

local function _teleportCharacterToSpawn(player: Player, spawnPoint: BasePart)
	if player.Parent ~= Players then
		return nil
	end

	player:LoadCharacter()
	local character = player.Character or player.CharacterAdded:Wait()
	if player.Parent ~= Players then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.CFrame = spawnPoint.CFrame + Vector3.new(0, 4, 0)
	end

	return character
end

local function _getWeaponToolsRoot(): Folder?
	local root = ServerStorage:FindFirstChild(WEAPON_TOOLS_ROOT_NAME)
	if root and root:IsA("Folder") then
		return root
	end

	if root ~= nil then
		warn(string.format("[MatchService] ServerStorage.%s existe pero no es Folder.", WEAPON_TOOLS_ROOT_NAME))
	end

	return nil
end

local function _findLoadoutToolTemplate(loadoutCategory: "Main" | "Special", weaponId: string): Tool?
	if weaponId == "" then
		return nil
	end

	local root = _getWeaponToolsRoot()
	if not root then
		return nil
	end

	local byCategory = root:FindFirstChild(loadoutCategory)
	if byCategory then
		local direct = byCategory:FindFirstChild(weaponId)
		if direct and direct:IsA("Tool") then
			return direct
		end
	end

	local fallback = root:FindFirstChild(weaponId)
	if fallback and fallback:IsA("Tool") then
		return fallback
	end

	return nil
end

local function _clearMatchLoadoutTools(player: Player)
	local containers = {
		player:FindFirstChild("Backpack"),
		player:FindFirstChild("StarterGear"),
		player.Character,
	}

	for _, container in containers do
		if not container then
			continue
		end
		for _, child in container:GetChildren() do
			if child:IsA("Tool") and child:GetAttribute(MATCH_LOADOUT_TOOL_ATTRIBUTE) == true then
				child:Destroy()
			end
		end
	end
end

local function _grantMatchLoadoutTools(player: Player): (boolean, boolean)
	local profile = if _dataService then _dataService:GetProfile(player) else nil
	if not profile or not profile.Data or not profile.Data.Loadout then
		return false, true
	end

	local loadout = profile.Data.Loadout
	local mainWeaponId = if type(loadout.MainWeapon) == "string" and loadout.MainWeapon ~= "" then loadout.MainWeapon else "Default"
	local specialWeaponId = if type(loadout.SpecialWeapon) == "string" and loadout.SpecialWeapon ~= "" then loadout.SpecialWeapon else "Default"

	local backpackNode = player:FindFirstChild("Backpack") or player:WaitForChild("Backpack", 1)
	local backpack = if backpackNode and backpackNode:IsA("Backpack") then backpackNode else nil
	if not backpack then
		return false, true
	end

	_clearMatchLoadoutTools(player)

	local function cloneIntoInventory(loadoutCategory: "Main" | "Special", weaponId: string): boolean
		local template = _findLoadoutToolTemplate(loadoutCategory, weaponId)
		if not template then
			warn(string.format("[MatchService] Tool no encontrada para %s/%s en ServerStorage.%s.", loadoutCategory, weaponId, WEAPON_TOOLS_ROOT_NAME))
			return false
		end

		local backpackClone = template:Clone()
		backpackClone:SetAttribute(MATCH_LOADOUT_TOOL_ATTRIBUTE, true)
		backpackClone.Parent = backpack
		return true
	end

	local mainOk = cloneIntoInventory("Main", mainWeaponId)
	local specialOk = cloneIntoInventory("Special", specialWeaponId)
	if not mainOk or not specialOk then
		return false, false
	end

	return true, false
end

local function _grantMatchLoadoutToolsWithRetry(player: Player, timeoutSec: number)
	local endAt = time() + math.max(0.5, timeoutSec)
	while player.Parent == Players do
		local success, retryable = _grantMatchLoadoutTools(player)
		if success then
			return
		end
		if not retryable then
			return
		end
		if time() >= endAt then
			warn(string.format("[MatchService] Timeout entregando tools de loadout a %s (perfil/backpack no listos).", player.Name))
			return
		end
		task.wait(0.2)
	end
end

local function _findLobbySpawn(): BasePart?
	local direct = Workspace:FindFirstChild("LobbySpawn")
	if direct and direct:IsA("BasePart") then
		return direct
	end

	local nested = Workspace:FindFirstChild("LobbySpawn", true)
	if nested and nested:IsA("BasePart") then
		return nested
	end

	return nil
end

local function _spawnPlayerOnAssignedTeam(player: Player): boolean
	if not _activeMapModel then
		return false
	end

	local side = _teamByUserId[player.UserId]
	if not side then
		return false
	end

	local team = if side == "A" then _teamA else _teamB
	if team then
		player.Neutral = false
		player.Team = team
	end

	local spawnPoints = _collectSpawnPointsForTeam(_activeMapModel :: Instance, side)
	if #spawnPoints == 0 then
		return false
	end

	local chosenSpawn = spawnPoints[math.random(1, #spawnPoints)]
	local spawnedCharacter = _teleportCharacterToSpawn(player, chosenSpawn)
	if not spawnedCharacter then
		return false
	end

	task.spawn(function()
		_grantMatchLoadoutToolsWithRetry(player, 8)
	end)
	return true
end

local function _ensureActiveMapContainer(): BasePart
	local existing = Workspace:FindFirstChild("ActiveMap")
	if existing and existing:IsA("BasePart") then
		existing:ClearAllChildren()
		existing.Transparency = 1
		existing.CanCollide = false
		existing.Anchored = true
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local container = Instance.new("Part")
	container.Name = "ActiveMap"
	container.Size = Vector3.new(8, 1, 8)
	container.Anchored = true
	container.CanCollide = false
	container.Transparency = 1
	container.CFrame = CFrame.new(0, -1000, 0)
	container.Parent = Workspace
	return container
end

local function _clearActiveMap()
	if _activeMapContainer and _activeMapContainer.Parent then
		_activeMapContainer:Destroy()
	end
	_activeMapContainer = nil
	_activeMapModel = nil
	_activeMapName = ""
end

local function _containsMode(modes: { string }, mode: string): boolean
	for _, candidate in modes do
		if candidate == mode then
			return true
		end
	end

	return false
end

local function _collectCompatibleMaps(mode: string): { MapDefinition }
	local compatible = {} :: { MapDefinition }

	for _, mapDef in GameConfig.Maps do
		if mapDef.Name ~= "" and _containsMode(mapDef.Modes, mode) then
			table.insert(compatible, mapDef)
		end
	end

	return compatible
end

local function _pickRandomMapOptions(pool: { MapDefinition }, count: number): { MapDefinition }
	local shuffled = table.clone(pool)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	local picked = {} :: { MapDefinition }
	for i = 1, math.min(count, #shuffled) do
		table.insert(picked, shuffled[i])
	end

	return picked
end

local function _buildVoteStatePacket(vote: ActiveVoteState, timeLeft: number)
	return {
		optionAName = vote.optionNames[1],
		optionAVotes = vote.voteCounts[vote.optionNames[1]] or 0,
		optionBName = vote.optionNames[2],
		optionBVotes = vote.voteCounts[vote.optionNames[2]] or 0,
		optionCName = vote.optionNames[3],
		optionCVotes = vote.voteCounts[vote.optionNames[3]] or 0,
		timeLeft = math.max(0, timeLeft),
	}
end

local function _broadcastVoteState(vote: ActiveVoteState)
	local timeLeft = math.ceil(math.max(0, vote.endAt - time()))
	Network.Match.VoteState.SendToAll(_buildVoteStatePacket(vote, timeLeft))
end

local function _sendActiveVoteToPlayer(player: Player)
	local vote = _activeVote
	if not vote then
		return
	end

	local optionAName = vote.optionNames[1]
	local optionBName = vote.optionNames[2]
	local optionCName = vote.optionNames[3]
	if not optionAName or not optionBName or not optionCName then
		_log("Skipped active vote snapshot: incomplete option names.")
		return
	end

	local okStart, errStart = pcall(function()
		Network.Match.StartVote.SendTo({
			optionAName = optionAName,
			optionAImage = vote.optionImages[optionAName] or DEFAULT_PLACEHOLDER_IMAGE,
			optionAMode = vote.optionModes[optionAName] or "TeamDeathmatch",
			optionBName = optionBName,
			optionBImage = vote.optionImages[optionBName] or DEFAULT_PLACEHOLDER_IMAGE,
			optionBMode = vote.optionModes[optionBName] or "TeamDeathmatch",
			optionCName = optionCName,
			optionCImage = vote.optionImages[optionCName] or DEFAULT_PLACEHOLDER_IMAGE,
			optionCMode = vote.optionModes[optionCName] or "TeamDeathmatch",
			duration = vote.duration,
		}, player)
	end)

	if not okStart then
		_log(string.format("Failed StartVote snapshot to %s: %s", player.Name, tostring(errStart)))
		return
	end

	local timeLeft = math.ceil(math.max(0, vote.endAt - time()))
	local okState, errState = pcall(function()
		Network.Match.VoteState.SendTo(_buildVoteStatePacket(vote, timeLeft), player)
	end)

	if not okState then
		_log(string.format("Failed VoteState snapshot to %s: %s", player.Name, tostring(errState)))
		return
	end

	_log(string.format("Sent active vote snapshot to %s (timeLeft=%ds).", player.Name, timeLeft))
end

local function _loadMapCloneWithTimeout(mapName: string, timeoutSec: number): (boolean, string)
	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	if not mapsFolder then
		return false, "ServerStorage/Maps no existe"
	end

	local mapTemplate = mapsFolder:FindFirstChild(mapName)
	if not mapTemplate then
		return false, string.format("No existe ServerStorage/Maps/%s", mapName)
	end

	local done = false
	local cancelled = false
	local cloned: Instance? = nil
	local cloneError: string? = nil

	task.spawn(function()
		local ok, result = pcall(function()
			return mapTemplate:Clone()
		end)
		if not ok then
			cloneError = tostring(result)
			done = true
			return
		end

		if cancelled then
			(result :: Instance):Destroy()
			done = true
			return
		end

		cloned = result :: Instance
		done = true
	end)

	local startedAt = time()
	while not done do
		if time() - startedAt >= timeoutSec then
			cancelled = true
			return false, string.format("Map clone timeout (%ds)", timeoutSec)
		end
		task.wait(0.05)
	end

	if cloneError then
		return false, "Error clonando mapa: " .. cloneError
	end

	if not cloned then
		return false, "El mapa clonado resulto nil"
	end

	local container = _ensureActiveMapContainer()
	cloned.Parent = container
	_activeMapContainer = container
	_activeMapModel = cloned
	_activeMapName = mapName

	return true, "ok"
end

local function _resolveScoreWinner(): string
	if _roundScoreA > _roundScoreB then
		return "A"
	elseif _roundScoreB > _roundScoreA then
		return "B"
	end

	return "Tie"
end

local function _captureRoundEndEligiblePlayers()
	table.clear(_roundEndEligibleByUserId)
	for _, player in Players:GetPlayers() do
		if not _isInMenuByUserId[player.UserId] then
			_roundEndEligibleByUserId[player.UserId] = true
		end
	end
end

local function _endRoundAndRestartVoting(reason: string)
	_log("Round finalizing: " .. reason)
	_setPhase("RoundEnding", reason)

	_isRoundActive = false
	_isMapLoading = false
	_isPlayEnabled = false
	_roundEndAt = 0
	_sendMapLoadStateToAll()

	-- Despawnear todos los bots de IA
	if _AIService then
		_AIService:OnRoundEnd()
	end

	_clearActiveMap()
	for userId in _deathConnectionsByUserId do
		_disconnectDeathConnection(userId)
	end
	table.clear(_teamByUserId)
	table.clear(_isInMenuByUserId)
	table.clear(_pendingSpawnByUserId)
	table.clear(_joinDebounceByUserId)
	table.clear(_deathAtByUserId)
	table.clear(_respawnDebounceByUserId)
	table.clear(_roundEndEligibleByUserId)
	table.clear(_matchKillsByUserId)
	table.clear(_killStreakByUserId)

	_hasCompletedInitialVote = false
	_setPhase("Idle", "round cleaned; starting next vote")
	task.defer(function()
		_startVoteIfPossible()
	end)
end

function _finishRoundAndScheduleRestart(reason: string, winnerTeam: string)
	if not _isRoundActive then
		return
	end

	_captureRoundEndEligiblePlayers()
	_isRoundActive = false
	_isPlayEnabled = false
	_sendMapLoadStateToAll()
	for _, player in Players:GetPlayers() do
		Network.Match.DeathScreenHide.SendTo({}, player)
	end
	_setPhase("RoundEnded", reason .. " | winner=" .. winnerTeam)
	for _, player in Players:GetPlayers() do
		if _roundEndEligibleByUserId[player.UserId] then
			Network.Match.RoundEnded.SendTo({
				winnerTeam = winnerTeam,
				scoreA = _roundScoreA,
				scoreB = _roundScoreB,
			}, player)
		end
	end

	task.delay(GameConfig.EndResultsDuration, function()
		if _isRoundActive then
			return
		end

		local lobbySpawn = _findLobbySpawn()
		for _, player in Players:GetPlayers() do
			if not _roundEndEligibleByUserId[player.UserId] then
				continue
			end

			_isInMenuByUserId[player.UserId] = true
			_respawnDebounceByUserId[player.UserId] = nil
			_pendingSpawnByUserId[player.UserId] = nil

			if lobbySpawn then
				_teleportCharacterToSpawn(player, lobbySpawn)
			else
				player:LoadCharacter()
			end

			if player.Parent == Players then
				Network.Match.DeathScreenHide.SendTo({}, player)
				Network.Match.ReturnToMenuDone.SendTo({}, player)
				_sendMapLoadStateToPlayer(player)
			end
		end

		_endRoundAndRestartVoting(reason)
	end)
end

local function _runRoundTimer(roundId: number)
	while _isRoundActive and roundId == _roundId do
		local timeLeft = _roundEndAt - time()
		if timeLeft <= 0 then
			_finishRoundAndScheduleRestart("max round duration reached", _resolveScoreWinner())
			return
		end

		_broadcastRoundState()
		task.wait(1)
	end
end

local function _startMapLoadFlow(winnerMapName: string)
	_isMapLoading = true
	_isPlayEnabled = false
	_activeMapName = winnerMapName
	_setPhase("MapLoading", winnerMapName)
	_sendMapLoadStateToAll()

	local success, reason = _loadMapCloneWithTimeout(winnerMapName, GameConfig.MapLoadTimeout)
	if not success then
		warn("[MatchService] Error loading map:", reason)
		_isMapLoading = false
		_isPlayEnabled = false
		_activeMapName = ""
		_sendMapLoadStateToAll()

		_hasCompletedInitialVote = false
		_setPhase("Idle", "map load failed; retry vote")
		_startVoteIfPossible()
		return
	end

	_isMapLoading = false
	_isPlayEnabled = true
	_isRoundActive = true
	_roundScoreA = 0
	_roundScoreB = 0
	_roundEndAt = time() + GameConfig.MaxRoundDuration
	_resetAllPlayerStreakState()
	table.clear(_teamByUserId)
	table.clear(_isInMenuByUserId)
	table.clear(_pendingSpawnByUserId)
	table.clear(_joinDebounceByUserId)
	table.clear(_deathAtByUserId)
	table.clear(_respawnDebounceByUserId)
	for _, player in Players:GetPlayers() do
		_isInMenuByUserId[player.UserId] = true
	end
	_setPhase("PregameReady", "map loaded; play enabled")
	_sendMapLoadStateToAll()
	_broadcastRoundState()

	-- Spawnear bots de IA en ambos equipos
	if _AIService then
		_AIService:OnRoundStart(BOTS_PER_TEAM, function(botTeam: string, _botName: string)
			if not _isRoundActive then
				return
			end

			-- Sumar score al equipo contrario (igual que cuando muere un jugador)
			if botTeam == "A" then
				_roundScoreB += 1
			else
				_roundScoreA += 1
			end

			_broadcastRoundState()

			if _roundScoreA >= GameConfig.WinScoreLimit then
				_finishRoundAndScheduleRestart("win score limit reached", "A")
			elseif _roundScoreB >= GameConfig.WinScoreLimit then
				_finishRoundAndScheduleRestart("win score limit reached", "B")
			end
		end)
	end

	_roundId += 1
	task.spawn(_runRoundTimer, _roundId)
end

local function _onRequestVoteSync(_: {}, player: Player)
	_log(string.format("Received RequestVoteSync from %s.", player.Name))
	_sendActiveVoteToPlayer(player)
	_sendMapLoadStateToPlayer(player)
	_sendRoundStateToPlayer(player)
	_sendAllPlayerStreaksToPlayer(player)
end

local function _disconnectVoteForPlayer(userId: number)
	local vote = _activeVote
	if not vote then
		return
	end

	local previous = vote.votesByUserId[userId]
	if not previous then
		return
	end

	vote.votesByUserId[userId] = nil
	local oldCount = vote.voteCounts[previous] or 0
	vote.voteCounts[previous] = math.max(0, oldCount - 1)
	_log(string.format("Player %d left vote. Removed vote from map '%s'.", userId, previous))
	_broadcastVoteState(vote)
end

local function _isVoteChangeAllowed(player: Player): boolean
	local now = time()
	local last = _voteCooldownsByUserId[player.UserId] or 0
	if now - last < VOTE_CHANGE_COOLDOWN then
		return false
	end

	_voteCooldownsByUserId[player.UserId] = now
	return true
end

local function _isValidOption(vote: ActiveVoteState, mapName: string): boolean
	for _, optionName in vote.optionNames do
		if optionName == mapName then
			return true
		end
	end

	return false
end

local function _onCastVote(data: { mapName: string }, player: Player)
	local vote = _activeVote
	if not vote then
		_log(string.format("Ignored vote from %s: no active vote.", player.Name))
		return
	end

	if not _isVoteChangeAllowed(player) then
		_log(string.format("Rate-limited vote from %s.", player.Name))
		return
	end

	local mapName = data.mapName
	if mapName == "" or not _isValidOption(vote, mapName) then
		_log(string.format("Ignored invalid vote from %s for map '%s'.", player.Name, mapName))
		return
	end

	local previous = vote.votesByUserId[player.UserId]
	if previous == mapName then
		_log(string.format("Ignored duplicate vote from %s for map '%s'.", player.Name, mapName))
		return
	end

	if previous then
		local oldCount = vote.voteCounts[previous] or 0
		vote.voteCounts[previous] = math.max(0, oldCount - 1)
	end

	vote.votesByUserId[player.UserId] = mapName
	vote.voteCounts[mapName] = (vote.voteCounts[mapName] or 0) + 1
	_log(string.format("Vote updated: %s -> '%s' (previous: %s)", player.Name, mapName, previous or "none"))

	_broadcastVoteState(vote)
end

local function _resolveWinner(vote: ActiveVoteState): string
	local connectedByUserId = {} :: { [number]: true }
	for _, player in Players:GetPlayers() do
		connectedByUserId[player.UserId] = true
	end

	local validCounts = {} :: { [string]: number }
	for _, optionName in vote.optionNames do
		validCounts[optionName] = 0
	end

	for userId, mapName in vote.votesByUserId do
		if connectedByUserId[userId] and validCounts[mapName] ~= nil then
			validCounts[mapName] += 1
		end
	end

	local maxVotes = -1
	local tied = {} :: { string }
	for _, optionName in vote.optionNames do
		local count = validCounts[optionName] or 0
		if count > maxVotes then
			maxVotes = count
			table.clear(tied)
			table.insert(tied, optionName)
		elseif count == maxVotes then
			table.insert(tied, optionName)
		end
	end

	if #tied == 0 then
		return vote.optionNames[math.random(1, #vote.optionNames)]
	end

	return tied[math.random(1, #tied)]
end

local function _runVoteTimer(vote: ActiveVoteState)
	_setPhase("Voting", string.format("options=[%s, %s, %s], duration=%ds", vote.optionNames[1], vote.optionNames[2], vote.optionNames[3], vote.duration))

	while _activeVote == vote do
		local remaining = vote.endAt - time()
		if remaining <= 0 then
			break
		end

		_broadcastVoteState(vote)
		task.wait(1)
	end

	if _activeVote ~= vote then
		return
	end

	_broadcastVoteState(vote)
	local winner = _resolveWinner(vote)
	_setPhase("VoteEnded", "winner=" .. winner)
	_log(string.format("Vote finished. Winner map: '%s'.", winner))
	Network.Match.EndVote.SendToAll({ winnerMapName = winner })

	_activeVote = nil
	_hasCompletedInitialVote = true
	task.defer(function()
		_startMapLoadFlow(winner)
	end)
end

function _startVoteIfPossible()
	if _activeVote ~= nil or _hasCompletedInitialVote then
		if _activeVote ~= nil then
			_log("Vote start skipped: already voting.")
		else
			_log("Vote start skipped: initial vote already completed.")
		end
		return
	end

	if _isMapLoading or _isPlayEnabled then
		_log("Vote start skipped: map flow already active.")
		return
	end

	local playerCount = #Players:GetPlayers()
	if playerCount < GameConfig.MinPlayersToStart then
		_log(string.format("Vote start blocked: players=%d, required=%d.", playerCount, GameConfig.MinPlayersToStart))
		return
	end

	local pool = _collectCompatibleMaps("TeamDeathmatch")
	if #pool < 3 then
		_log(string.format("Vote start blocked: compatible maps=%d, required=3.", #pool))
		warn("[MatchService] Se requieren al menos 3 mapas compatibles para iniciar la votacion.")
		return
	end

	local options = _pickRandomMapOptions(pool, 3)
	if #options < 3 then
		_log(string.format("Vote start blocked: random option selection returned %d maps.", #options))
		return
	end

	_setPhase("VoteStarting", string.format("players=%d", playerCount))

	local optionNames = {
		options[1].Name,
		options[2].Name,
		options[3].Name,
	}

	local voteCounts = {
		[optionNames[1]] = 0,
		[optionNames[2]] = 0,
		[optionNames[3]] = 0,
	}

	local optionImages = {
		[optionNames[1]] = options[1].PlaceholderImage ~= "" and options[1].PlaceholderImage or DEFAULT_PLACEHOLDER_IMAGE,
		[optionNames[2]] = options[2].PlaceholderImage ~= "" and options[2].PlaceholderImage or DEFAULT_PLACEHOLDER_IMAGE,
		[optionNames[3]] = options[3].PlaceholderImage ~= "" and options[3].PlaceholderImage or DEFAULT_PLACEHOLDER_IMAGE,
	}

	local optionModes = {
		[optionNames[1]] = options[1].Modes[1] or "TeamDeathmatch",
		[optionNames[2]] = options[2].Modes[1] or "TeamDeathmatch",
		[optionNames[3]] = options[3].Modes[1] or "TeamDeathmatch",
	}

	local voteState: ActiveVoteState = {
		options = options,
		optionNames = optionNames,
		optionImages = optionImages,
		optionModes = optionModes,
		voteCounts = voteCounts,
		votesByUserId = {},
		endAt = time() + GameConfig.VoteDuration,
		duration = GameConfig.VoteDuration,
	}

	_activeVote = voteState
	_log(string.format("Vote started with maps: '%s', '%s', '%s'.", optionNames[1], optionNames[2], optionNames[3]))

	Network.Match.StartVote.SendToAll({
		optionAName = optionNames[1],
		optionAImage = optionImages[optionNames[1]],
		optionAMode = optionModes[optionNames[1]],
		optionBName = optionNames[2],
		optionBImage = optionImages[optionNames[2]],
		optionBMode = optionModes[optionNames[2]],
		optionCName = optionNames[3],
		optionCImage = optionImages[optionNames[3]],
		optionCMode = optionModes[optionNames[3]],
		duration = GameConfig.VoteDuration,
	})

	_broadcastVoteState(voteState)
	task.spawn(_runVoteTimer, voteState)
end

local function _bindCharacterTracking(player: Player)
	local old = _characterConnectionsByUserId[player.UserId]
	if old then
		old:Disconnect()
		_characterConnectionsByUserId[player.UserId] = nil
	end

	_characterConnectionsByUserId[player.UserId] = player.CharacterAdded:Connect(function(character)
		_registerDeathListener(player, character)
		if _isRoundActive and not _isInMenuByUserId[player.UserId] then
			task.defer(function()
				if player.Parent ~= Players then
					return
				end
				_grantMatchLoadoutToolsWithRetry(player, 12)
			end)
		end
	end)

	if player.Character then
		_registerDeathListener(player, player.Character)
	end
end

local function _onRequestJoinMatch(_: {}, player: Player)
	if not _isPlayEnabled or not _activeMapModel then
		_log(string.format("Ignored RequestJoinMatch from %s: play not enabled.", player.Name))
		return
	end

	if _joinDebounceByUserId[player.UserId] then
		_log(string.format("Ignored duplicate RequestJoinMatch from %s.", player.Name))
		return
	end

	_joinDebounceByUserId[player.UserId] = true
	_pendingSpawnByUserId[player.UserId] = true
	_isInMenuByUserId[player.UserId] = false
	if _matchKillsByUserId[player.UserId] == nil then
		_matchKillsByUserId[player.UserId] = 0
	end
	if _killStreakByUserId[player.UserId] == nil then
		_killStreakByUserId[player.UserId] = 0
	end
	_sendPlayerStreakToAll(player.UserId)

	task.defer(function()
		if player.Parent ~= Players then
			_pendingSpawnByUserId[player.UserId] = nil
			_joinDebounceByUserId[player.UserId] = nil
			return
		end

		_pickBalancedTeam(player.UserId)
		local team = if _teamByUserId[player.UserId] == "A" then _teamA else _teamB
		if not team then
			warn("[MatchService] Teams no inicializados.")
			_pendingSpawnByUserId[player.UserId] = nil
			_joinDebounceByUserId[player.UserId] = nil
			return
		end

		if not _spawnPlayerOnAssignedTeam(player) then
			warn("[MatchService] No fue posible spawnear al jugador en su equipo.")
			_pendingSpawnByUserId[player.UserId] = nil
			_joinDebounceByUserId[player.UserId] = nil
			return
		end

		_pendingSpawnByUserId[player.UserId] = nil
		_joinDebounceByUserId[player.UserId] = nil
		_deathAtByUserId[player.UserId] = 0
		Network.Match.DeathScreenHide.SendTo({}, player)

		if player.Parent == Players then
			Network.Match.JoinMatchSpawned.SendTo({}, player)
			_log(string.format("Player %s joined and spawned.", player.Name))
		end
	end)
end

local function _onRequestRespawn(_: {}, player: Player)
	if not _isRoundActive or _isInMenuByUserId[player.UserId] then
		return
	end

	if _respawnDebounceByUserId[player.UserId] then
		return
	end

	local deathAt = _deathAtByUserId[player.UserId] or 0
	if time() - deathAt < GameConfig.RespawnCooldown then
		return
	end

	_respawnDebounceByUserId[player.UserId] = true
	task.defer(function()
		_respawnDebounceByUserId[player.UserId] = nil
		if player.Parent ~= Players or not _isRoundActive or _isInMenuByUserId[player.UserId] then
			return
		end

		if _spawnPlayerOnAssignedTeam(player) then
			_deathAtByUserId[player.UserId] = 0
			Network.Match.DeathScreenHide.SendTo({}, player)
		end
	end)
end

local function _onRequestReturnToMenu(_: {}, player: Player)
	_isInMenuByUserId[player.UserId] = true
	_respawnDebounceByUserId[player.UserId] = nil
	_pendingSpawnByUserId[player.UserId] = nil
	_killStreakByUserId[player.UserId] = 0
	if _matchKillsByUserId[player.UserId] == nil then
		_matchKillsByUserId[player.UserId] = 0
	end
	_sendPlayerStreakToAll(player.UserId)

	local lobbySpawn = _findLobbySpawn()
	if lobbySpawn then
		_teleportCharacterToSpawn(player, lobbySpawn)
	else
		player:LoadCharacter()
	end

	if player.Parent == Players then
		Network.Match.DeathScreenHide.SendTo({}, player)
		Network.Match.ReturnToMenuDone.SendTo({}, player)
		_sendMapLoadStateToPlayer(player)
		_sendRoundStateToPlayer(player)
	end
end

function MatchService:Start(dataService: any): ()
	if _started then
		_log("Start ignored: service already started.")
		return
	end

	_dataService = dataService

	_started = true
	_ensureTeams()

	-- Cargar AIService (require lazy para evitar dependencia circular)
	local serverRoot = ServerScriptService:FindFirstChild("Server")
	if serverRoot then
		local aiModule = serverRoot:FindFirstChild("AI")
		if aiModule then
			local ok, result = pcall(require, aiModule)
			if ok then
				_AIService = result
				_log("AIService loaded successfully.")
			else
				warn("[MatchService] Failed to load AIService: " .. tostring(result))
			end
		end
	end

	_setPhase("Idle", "service started")
	_log("MatchService started. Waiting for conditions to begin map vote.")

	Players.PlayerAdded:Connect(function(player)
		_log(string.format("Player added. Connected players=%d.", #Players:GetPlayers()))
		_isInMenuByUserId[player.UserId] = true
		_deathAtByUserId[player.UserId] = 0
		_matchKillsByUserId[player.UserId] = 0
		_killStreakByUserId[player.UserId] = 0
		_sendPlayerStreakToAll(player.UserId)
		_bindCharacterTracking(player)
		_startVoteIfPossible()

		task.delay(0.75, function()
			if player.Parent == Players then
				_sendActiveVoteToPlayer(player)
				_sendMapLoadStateToPlayer(player)
				_sendRoundStateToPlayer(player)
				_sendAllPlayerStreaksToPlayer(player)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		_voteCooldownsByUserId[player.UserId] = nil
		_isInMenuByUserId[player.UserId] = nil
		_deathAtByUserId[player.UserId] = nil
		_respawnDebounceByUserId[player.UserId] = nil
		_matchKillsByUserId[player.UserId] = nil
		_killStreakByUserId[player.UserId] = nil
		_log(string.format("Player removing: %s (%d).", player.Name, player.UserId))
		_disconnectVoteForPlayer(player.UserId)
		_joinDebounceByUserId[player.UserId] = nil
		_disconnectDeathConnection(player.UserId)

		local charConn = _characterConnectionsByUserId[player.UserId]
		if charConn then
			charConn:Disconnect()
			_characterConnectionsByUserId[player.UserId] = nil
		end

		if _pendingSpawnByUserId[player.UserId] then
			_teamByUserId[player.UserId] = nil
			_pendingSpawnByUserId[player.UserId] = nil
			_log(string.format("Released team assignment for %s (left before spawn).", player.Name))
		end
	end)

	Network.Match.CastVote.Listen(_onCastVote)
	Network.Match.RequestVoteSync.Listen(_onRequestVoteSync)
	Network.Match.RequestJoinMatch.Listen(_onRequestJoinMatch)
	Network.Match.RequestRespawn.Listen(_onRequestRespawn)
	Network.Match.RequestReturnToMenu.Listen(_onRequestReturnToMenu)

	for _, player in Players:GetPlayers() do
		_isInMenuByUserId[player.UserId] = true
		_deathAtByUserId[player.UserId] = 0
		_matchKillsByUserId[player.UserId] = 0
		_killStreakByUserId[player.UserId] = 0
		_bindCharacterTracking(player)
	end

	_startVoteIfPossible()
end

return MatchService
