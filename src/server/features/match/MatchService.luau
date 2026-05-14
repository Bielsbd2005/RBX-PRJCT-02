--!strict

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TeamsService = game:GetService("Teams")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local SpawnSelector = require(script.Parent:WaitForChild("SpawnSelector"))
local LoadoutService = require(script.Parent:WaitForChild("LoadoutService"))
local HealthPickupService = require(script.Parent:WaitForChild("HealthPickupService"))
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local ActionRewards = require(Shared.constants.ActionRewards)
local WeaponCategory = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local DailyTasksService = require(script.Parent.Parent.dailyTasks.DailyTasksService)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

type MapDefinition = {
	Name: string,
	Modes: { string },
	PlaceholderImage: string,
	UseIntelligentSpawning: boolean?,
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
local _matchDeathsByUserId: { [number]: number } = {}
local _killStreakTimeoutByUserId: { [number]: thread? } = {}
local _lastMapLoadStateBroadcastKey: string? = nil
local _lastRoundStateBroadcastKey: string? = nil
local _lastBotRosterJsonBroadcast: string? = nil
local _lastBroadcastStreakKeyByUserId: { [number]: string } = {}
-- Timestamp de la última muerte registrada en cada spawn point. Usado por
-- SpawnSelector para penalizar respawnear donde alguien acaba de morir y evitar
-- spawn-trap loops. Se limpia en cada round restart.
local _recentDeathBySpawn: { [BasePart]: number } = {}

local _teamA: Team? = nil
local _teamB: Team? = nil
local _finishRoundAndScheduleRestart: any = nil
local _AIService: any = nil
local _dataService: DataService = nil :: any
local _tieBreakToA = false

-- Cooldown entre cambios de voto del mismo jugador. 0.5s permite ~2 cambios/seg
-- — suficiente para UX responsive sin permitir spam que sature broadcasts.
local VOTE_CHANGE_COOLDOWN = 0.5
-- Ventana máxima entre el último daño y la muerte para acreditar el kill.
-- Más allá de este tiempo, el kill se considera "muerte natural" / no atribuible.
local KILL_ATTRIBUTION_WINDOW = 2
local DEFAULT_PLACEHOLDER_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"

local function _log(message: string)
	return
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
	local key = string.format("%s|%s|%s", tostring(_isMapLoading), tostring(_isPlayEnabled), _activeMapName)
	if _lastMapLoadStateBroadcastKey == key then
		return
	end
	_lastMapLoadStateBroadcastKey = key

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
	local key = string.format("%d|%d|%d", _roundScoreA, _roundScoreB, timeLeft)
	if _lastRoundStateBroadcastKey == key then
		return
	end
	_lastRoundStateBroadcastKey = key
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

local _sendPlayerStreakToAll: (userId: number) -> ()

local function _resetStreakTimeout(userId: number)
	if _killStreakTimeoutByUserId[userId] then
		if type(task.cancel) == "function" then
			pcall(task.cancel, _killStreakTimeoutByUserId[userId])
		end
		_killStreakTimeoutByUserId[userId] = nil
	end
end

local function _setupStreakTimeout(userId: number)
	_resetStreakTimeout(userId)
	_killStreakTimeoutByUserId[userId] = task.delay(7, function()
		_killStreakByUserId[userId] = 0
		_killStreakTimeoutByUserId[userId] = nil
		_sendPlayerStreakToAll(userId)
	end)
end

_sendPlayerStreakToAll = function(userId: number)
	local streak = _killStreakByUserId[userId] or 0
	local kills = _matchKillsByUserId[userId] or 0
	local deaths = _matchDeathsByUserId[userId] or 0
	local key = string.format("%d|%d|%d", kills, streak, deaths)
	if _lastBroadcastStreakKeyByUserId[userId] == key then
		return
	end
	_lastBroadcastStreakKeyByUserId[userId] = key
	Network.Match.PlayerStreakState.SendToAll({
		userId = tostring(userId),
		kills = kills,
		streak = streak,
		deaths = deaths,
	})
end

local function _sendPlayerStreakToPlayer(player: Player, userId: number)
	local ok, err = pcall(function()
		Network.Match.PlayerStreakState.SendTo({
			userId = tostring(userId),
			kills = _matchKillsByUserId[userId] or 0,
			streak = _killStreakByUserId[userId] or 0,
			deaths = _matchDeathsByUserId[userId] or 0,
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
	-- Para bots, enviar solo si tienen actividad.
	for botUserId in _matchKillsByUserId do
		if botUserId < 0 then
			local kills = _matchKillsByUserId[botUserId] or 0
			local deaths = _matchDeathsByUserId[botUserId] or 0
			local streak = _killStreakByUserId[botUserId] or 0
			if kills > 0 or deaths > 0 or streak > 0 then
				_sendPlayerStreakToPlayer(player, botUserId)
			end
		end
	end
end

local function _broadcastBotRoster()
	if not _AIService then return end
	local roster = _AIService:GetBotRoster()
	local ok, json = pcall(HttpService.JSONEncode, HttpService, roster)
	if ok then
		if _lastBotRosterJsonBroadcast == json then
			return
		end
		_lastBotRosterJsonBroadcast = json
		Network.Match.BotRoster.SendToAll({ json = json })
	end
end

local function _sendBotRosterToPlayer(player: Player)
	if not _AIService then return end
	local roster = _AIService:GetBotRoster()
	local ok, json = pcall(HttpService.JSONEncode, HttpService, roster)
	if ok then
		pcall(function()
			Network.Match.BotRoster.SendTo({ json = json }, player)
		end)
	end
end

local function _resolveBotKillerName(attackerUserId: number): string
	if _AIService and _AIService.GetBotDisplayName then
		return _AIService:GetBotDisplayName(attackerUserId) or ""
	end
	return ""
end

local function _resetAllPlayerStreakState()
	table.clear(_matchKillsByUserId)
	table.clear(_killStreakByUserId)
	table.clear(_matchDeathsByUserId)
	table.clear(_lastBroadcastStreakKeyByUserId)

	-- Clear all streak timeouts
	for userId, timeout in _killStreakTimeoutByUserId do
		if timeout then
			if type(task.cancel) == "function" then
				pcall(task.cancel, timeout)
			end
		end
	end
	table.clear(_killStreakTimeoutByUserId)

	for _, player in Players:GetPlayers() do
		_matchKillsByUserId[player.UserId] = 0
		_killStreakByUserId[player.UserId] = 0
		_matchDeathsByUserId[player.UserId] = 0
		_sendPlayerStreakToAll(player.UserId)
	end
end

local function _resolveWeaponItem(weaponId: string?): (string?, string?)
	if type(weaponId) ~= "string" or weaponId == "" then
		return nil, nil
	end

	for _, category in WeaponCategory.ALL do
		local categoryConfig = ItemsConfig[category]
		if type(categoryConfig) == "table" then
			if type(categoryConfig[weaponId]) == "table" then
				return category, weaponId
			end
			for itemId, definition in categoryConfig do
				if type(definition) == "table" and definition.Name == weaponId then
					return category, itemId
				end
			end
		end
	end

	return nil, nil
end

--[[
	Cola de acciones diferidas por player a la espera de que el profile cargue.
	C2: Sin esto, kills/deaths/XP en la window inicial (antes de que el profile
	esté listo) se pierden silenciosamente — _dataService:GetProfile() devuelve
	nil y :Increment/:AddXP/:BatchUpdate retornan early.

	Cualquier helper de persistencia llama a _deferUntilProfile(player, fn) si
	el profile aún no está. ProfileLoaded handler hace flush en orden FIFO.
]]
local _pendingProfileActionsByUserId: { [number]: { () -> () } } = {}

local function _deferUntilProfile(player: Player, fn: () -> ()): ()
	local userId = player.UserId
	local queue = _pendingProfileActionsByUserId[userId]
	if not queue then
		queue = {}
		_pendingProfileActionsByUserId[userId] = queue
	end
	table.insert(queue, fn)
end

local function _hasProfile(player: Player): boolean
	return _dataService ~= nil and _dataService:GetProfile(player) ~= nil
end

local function _grantActionRewardsToAttacker(attackerUserId: number?, action: string)
	if not _dataService or not attackerUserId or attackerUserId <= 0 then
		return
	end

	local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
	if not attackerPlayer then
		return
	end

	-- C2: si el profile aún no cargó, encolar y reintentar tras ProfileLoaded.
	if not _hasProfile(attackerPlayer) then
		_deferUntilProfile(attackerPlayer, function()
			_grantActionRewardsToAttacker(attackerUserId, action)
		end)
		return
	end

	local xpAmount = ActionRewards.GetXP(action)
	local cashAmount = ActionRewards.GetCash(action)

	if xpAmount > 0 and type((_dataService :: any).AddXP) == "function" then
		local ok, err = pcall((_dataService :: any).AddXP, _dataService, attackerPlayer, xpAmount)
		if not ok then
			warn("[MatchService] AddXP error: " .. tostring(err))
		end
	end

	if cashAmount > 0 and type((_dataService :: any).Increment) == "function" then
		local ok, err = pcall((_dataService :: any).Increment, _dataService, attackerPlayer, { "Stats", "Cash" }, cashAmount)
		if not ok then
			warn("[MatchService] Cash Increment error: " .. tostring(err))
		end
	end
end

local function _grantMasteryWrapsIfEligible(player: Player, weaponCategory: string, weaponId: string, newKillCount: number)
	if not _dataService or newKillCount <= 0 then
		return
	end

	local weaponWrapsConfig = ItemsConfig.WeaponWraps
	if type(weaponWrapsConfig) ~= "table" then
		return
	end

	local profile = (_dataService :: any).GetProfile and _dataService:GetProfile(player)
	if not profile or not profile.Data then
		return
	end

	local inventory = profile.Data.Inventory
	local byWeapon = if type(inventory) == "table" then inventory.WeaponWrapsByWeapon else nil
	local categoryMap = if type(byWeapon) == "table" then byWeapon[weaponCategory] else nil
	local weaponMap = if type(categoryMap) == "table" then categoryMap[weaponId] else nil

	-- Acumular todos los wraps elegibles en un solo BatchUpdate. Antes hacíamos
	-- N SetValues separados → N mensajes de red al cliente y N entradas dirty.
	local updates: { { path: { string }, value: any } } = {}
	for wrapKey, definition in weaponWrapsConfig do
		if type(definition) == "table" then
			local challenge = (definition :: any).KillChallenge
			local kills: number? = nil
			if type(challenge) == "table" then
				kills = tonumber((challenge :: any).Kills)
			end
			if kills and kills > 0 and newKillCount >= kills then
				local alreadyOwned = type(weaponMap) == "table" and weaponMap[wrapKey] == true
				if not alreadyOwned then
					table.insert(updates, {
						path = { "Inventory", "WeaponWrapsByWeapon", weaponCategory, weaponId, wrapKey },
						value = true,
					})
				end
			end
		end
	end

	if #updates == 0 then
		return
	end

	local ok, err = pcall(function()
		_dataService:BatchUpdate(player, updates)
	end)
	if not ok then
		warn("[MatchService] Mastery wraps BatchUpdate error: " .. tostring(err))
	end
end

local function _registerWeaponKillForAttacker(attackerUserId: number?, weaponId: string?)
	if not _dataService or not attackerUserId or attackerUserId <= 0 then
		return
	end

	local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
	if not attackerPlayer then
		return
	end

	-- C2: si el profile aún no cargó, encolar y reintentar tras ProfileLoaded.
	if not _hasProfile(attackerPlayer) then
		_deferUntilProfile(attackerPlayer, function()
			_registerWeaponKillForAttacker(attackerUserId, weaponId)
		end)
		return
	end

	local weaponCategory, resolvedWeaponId = _resolveWeaponItem(weaponId)
	if not weaponCategory or not resolvedWeaponId then
		return
	end

	local incrementFn = (_dataService :: any).IncrementWeaponKills
	if type(incrementFn) ~= "function" then
		return
	end

	local ok, success, newCount = pcall(incrementFn, _dataService, attackerPlayer, weaponCategory, resolvedWeaponId, 1)
	if not ok then
		warn("[MatchService] IncrementWeaponKills error: " .. tostring(success))
		return
	end

	if success and type(newCount) == "number" then
		_grantMasteryWrapsIfEligible(attackerPlayer, weaponCategory, resolvedWeaponId, newCount)
	end
end

--[[
	Persiste Stats lifetime del atacante en UN BatchUpdate atómico:
	  • Stats.Kills += 1
	  • Stats.Headshots += 1 si headshot
	  • Stats.KillStreakBest = newStreak si mejora

	Llamado desde el path PvP (_registerKillEvent) y PvE (onBotDied) para que
	las kills lifetime se acumulen igual sea la víctima jugador o bot.
]]
local function _persistAttackerKillStats(attacker: Player, wasHeadshot: boolean, newStreak: number)
	if not _dataService then
		return
	end

	-- C2: si el profile aún no cargó, encolar y reintentar tras ProfileLoaded.
	if not _hasProfile(attacker) then
		_deferUntilProfile(attacker, function()
			_persistAttackerKillStats(attacker, wasHeadshot, newStreak)
		end)
		return
	end

	local updates = {
		{ path = { "Stats", "Kills" }, delta = 1 },
	}
	if wasHeadshot then
		table.insert(updates, { path = { "Stats", "Headshots" }, delta = 1 })
	end

	local profile = _dataService:GetProfile(attacker)
	local lifetimeBest = if profile and profile.Data.Stats
		then (profile.Data.Stats.KillStreakBest or 0)
		else 0
	if newStreak > lifetimeBest then
		-- Solo añadimos el update si mejora — evita writes redundantes.
		-- La race residual entre kills concurrentes se mitiga porque newStreak
		-- refleja _killStreakByUserId, que se incrementa síncronamente; la kill
		-- posterior siempre tendrá newStreak > la anterior.
		table.insert(updates, { path = { "Stats", "KillStreakBest" }, value = newStreak })
	end

	pcall(function()
		_dataService:BatchUpdate(attacker, updates)
	end)
end

local function _registerKillEvent(deadPlayer: Player, attackerUserId: number?, attackerWeaponId: string?, attackerWasHeadshot: boolean?)
	_killStreakByUserId[deadPlayer.UserId] = 0
	_resetStreakTimeout(deadPlayer.UserId)
	if _matchKillsByUserId[deadPlayer.UserId] == nil then
		_matchKillsByUserId[deadPlayer.UserId] = 0
	end
	_matchDeathsByUserId[deadPlayer.UserId] = (_matchDeathsByUserId[deadPlayer.UserId] or 0) + 1
	_sendPlayerStreakToAll(deadPlayer.UserId)

	-- Persistir Stats.Deaths lifetime del que muere (siempre que sea jugador).
	-- C2: si el profile aún no cargó, encolar para flush en ProfileLoaded.
	if _dataService and (_dataService :: any).Increment then
		if _hasProfile(deadPlayer) then
			pcall((_dataService :: any).Increment, _dataService, deadPlayer, { "Stats", "Deaths" }, 1)
		else
			_deferUntilProfile(deadPlayer, function()
				pcall((_dataService :: any).Increment, _dataService, deadPlayer, { "Stats", "Deaths" }, 1)
			end)
		end
	end

	if not attackerUserId or attackerUserId == deadPlayer.UserId then
		return
	end

	-- Solo contar kills de jugadores, NO de bots
	if attackerUserId < 0 then
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
	_setupStreakTimeout(attackerUserId)
	_sendPlayerStreakToAll(attackerUserId)
	_registerWeaponKillForAttacker(attackerUserId, attackerWeaponId)
	_grantActionRewardsToAttacker(attackerUserId, "Kill")
	if attackerWasHeadshot then
		_grantActionRewardsToAttacker(attackerUserId, "Headshot")
	end
	local newStreak = _killStreakByUserId[attackerUserId] or 0
	if newStreak == 3 then
		_grantActionRewardsToAttacker(attackerUserId, "Streak3")
	elseif newStreak == 5 then
		_grantActionRewardsToAttacker(attackerUserId, "Streak5")
	end

	_persistAttackerKillStats(attacker, attackerWasHeadshot == true, newStreak)
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

local function _countActiveRealAssignments(): (number, number)
	local connectedByUserId = {} :: { [number]: true }
	for _, player in Players:GetPlayers() do
		connectedByUserId[player.UserId] = true
	end

	local a = 0
	local b = 0
	for userId, side in _teamByUserId do
		local isConnected = connectedByUserId[userId] == true
		local isActiveOrPending = (_isInMenuByUserId[userId] == false) or (_pendingSpawnByUserId[userId] == true)
		if isConnected and isActiveOrPending then
			if side == "A" then
				a += 1
			else
				b += 1
			end
		end
	end

	return a, b
end

local function _pickTeamByScoreTieBreak(): "A" | "B"
	if _roundScoreA < _roundScoreB then
		return "A"
	end

	if _roundScoreB < _roundScoreA then
		return "B"
	end

	_tieBreakToA = not _tieBreakToA
	return if _tieBreakToA then "A" else "B"
end

local function _pickBalancedTeam(userId: number): ("A" | "B")?
	local assigned = _teamByUserId[userId]
	local countA, countB = _countActiveRealAssignments()
	local cap = GameConfig.TeamSizeTarget

	if assigned then
		if assigned == "A" and countA < cap then
			return "A"
		elseif assigned == "B" and countB < cap then
			return "B"
		elseif assigned == "A" and countB < cap then
			_teamByUserId[userId] = "B"
			return "B"
		elseif assigned == "B" and countA < cap then
			_teamByUserId[userId] = "A"
			return "A"
		end

		return nil
	end

	local selected: "A" | "B"
	local canJoinA = countA < cap
	local canJoinB = countB < cap

	if canJoinA and canJoinB then
		if countA < countB then
			selected = "A"
		elseif countB < countA then
			selected = "B"
		else
			selected = _pickTeamByScoreTieBreak()
		end
	elseif canJoinA then
		selected = "A"
	elseif canJoinB then
		selected = "B"
	else
		return nil
	end

	_teamByUserId[userId] = selected
	return selected
end

local function _rebalanceBotsForCurrentRound(reason: string)
	if not _isRoundActive or not _AIService then
		return
	end

	local realA, realB = _countActiveRealAssignments()
	local targetA = math.max(0, GameConfig.TeamSizeTarget - realA)
	local targetB = math.max(0, GameConfig.TeamSizeTarget - realB)

	local ok, err = pcall(function()
		_AIService:SetBotTargets(targetA, targetB)
	end)
	if not ok then
		warn(string.format("[MatchService] Failed to rebalance bots (%s): %s", reason, tostring(err)))
		return
	end

	-- Enviar BotRoster de forma asincrónica para no bloquear
	task.defer(_broadcastBotRoster)
end

local function _collectSharedSpawnPoints(activeMapRoot: Instance): { BasePart }
	local spawnsRoot = activeMapRoot:FindFirstChild("Spawns", true)
	if not spawnsRoot then
		return {}
	end

	local points = {} :: { BasePart }
	for _, node in spawnsRoot:GetDescendants() do
		if node:IsA("BasePart") then
			table.insert(points, node)
		end
	end

	return points
end

local function _findNearestSpawnToPosition(position: Vector3): BasePart?
	if not _activeMapModel then
		return nil
	end

	local spawns = _collectSharedSpawnPoints(_activeMapModel :: Instance)
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

local function _getMapDefinitionByName(mapName: string): MapDefinition?
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

local function _extractCharacterRootPosition(character: Model): Vector3?
	local root = _extractCharacterRootPart(character)
	return if root then root.Position else nil
end

local TeamUtils = require(Shared.utils.TeamUtils)

local function _resolveNpcSide(character: Model): "A" | "B"?
	return TeamUtils.getSide(character) :: any
end

-- Recolecta posiciones + lookVectors de combatientes vivos en un lado determinado
-- (excluyendo opcionalmente al jugador que pide el respawn). Combina jugadores
-- humanos y NPCs en una sola pasada por el mapa.
local function _collectCombatantDataForSide(side: "A" | "B", excludePlayer: Player?): ({ Vector3 }, { Vector3 })
	local positions = {} :: { Vector3 }
	local lookVectors = {} :: { Vector3 }

	for _, candidatePlayer in Players:GetPlayers() do
		if candidatePlayer == excludePlayer then
			continue
		end

		local candidateSide = _teamByUserId[candidatePlayer.UserId]
		if not candidateSide or candidateSide ~= side then
			continue
		end

		local character = candidatePlayer.Character
		if not character then
			continue
		end

		local root = _extractCharacterRootPart(character)
		if root then
			table.insert(positions, root.Position)
			table.insert(lookVectors, root.CFrame.LookVector)
		end
	end

	if not _activeMapModel then
		return positions, lookVectors
	end

	for _, node in (_activeMapModel :: Instance):GetDescendants() do
		if not node:IsA("Model") then
			continue
		end

		local npcPlayer = Players:GetPlayerFromCharacter(node)
		if npcPlayer ~= nil then
			continue
		end

		-- Ignorar NPCs muertos/ragdollados — no son amenaza, no deben influir en la
		-- elección de spawn point.
		local npcSide = _resolveNpcSide(node)
		if not npcSide or npcSide ~= side then
			continue
		end

		local root = _extractCharacterRootPart(node)
		if root then
			table.insert(positions, root.Position)
			table.insert(lookVectors, root.CFrame.LookVector)
		end
	end

	return positions, lookVectors
end

local function _disconnectDeathConnection(userId: number)
	local conn = _deathConnectionsByUserId[userId]
	if conn then
		conn:Disconnect()
		_deathConnectionsByUserId[userId] = nil
	end
end

local function _getKillEffectIdForAttacker(attackerUserId: number?): string
	if not attackerUserId then
		return ItemDefaults.ITEM_ID
	end
	local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
	if not attackerPlayer then
		return ItemDefaults.ITEM_ID
	end
	local profile = if _dataService then _dataService:GetProfile(attackerPlayer) else nil
	if profile and profile.Data and profile.Data.Loadout then
		local killEffect = profile.Data.Loadout.KillEffect
		if type(killEffect) == "string" and killEffect ~= "" then
			return killEffect
		end
	end
	return ItemDefaults.ITEM_ID
end

local function _applyKillEffect(attackerUserId: number?, character: Model)
	local effectId = _getKillEffectIdForAttacker(attackerUserId)
	local ok, err = pcall(KillEffectsRegistry.apply, effectId, character)
	if not ok then
		warn("[MatchService] KillEffect error: " .. tostring(err))
	end
end

local function _registerDeathListener(player: Player, character: Model)
	_disconnectDeathConnection(player.UserId)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.BreakJointsOnDeath = false

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

		local deathRoot = character:FindFirstChild("HumanoidRootPart")
		if deathRoot and deathRoot:IsA("BasePart") then
			local nearestSpawn = _findNearestSpawnToPosition(deathRoot.Position)
			if nearestSpawn then
				_recentDeathBySpawn[nearestSpawn] = time()
			end
		end
		local attackerUserIdAttr = humanoid:GetAttribute("LastAttackerUserId")
		local attackerAtAttr = humanoid:GetAttribute("LastAttackerAt")
		local attackerWeaponIdAttr = humanoid:GetAttribute("LastAttackerWeaponId")
		local attackerHeadshotAttr = humanoid:GetAttribute("LastAttackerHeadshot")
		local attackerUserId = if type(attackerUserIdAttr) == "number" then attackerUserIdAttr else nil
		local attackerAt = if type(attackerAtAttr) == "number" then attackerAtAttr else 0
		local attackerWeaponId = if type(attackerWeaponIdAttr) == "string" then attackerWeaponIdAttr else ""
		local attackerWasHeadshot = attackerHeadshotAttr == true
		if attackerAt > 0 and time() - attackerAt > KILL_ATTRIBUTION_WINDOW then
			attackerUserId = nil
		end
		-- Atacante humano: descartar si no sigue in-match.
		if attackerUserId and attackerUserId > 0 and _isInMenuByUserId[attackerUserId] then
			attackerUserId = nil
		end
		local attackerPlayer = if attackerUserId then Players:GetPlayerByUserId(attackerUserId) else nil
		local killerName: string
		if attackerPlayer then
			killerName = attackerPlayer.Name
		elseif attackerUserId and attackerUserId < 0 then
			killerName = _resolveBotKillerName(attackerUserId)
		else
			killerName = ""
		end
		_registerKillEvent(player, attackerUserId, attackerWeaponId, attackerWasHeadshot)

		-- Aplicar kill effect del asesino (ragdoll visible para todos)
		_applyKillEffect(attackerUserId, character)

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
			local killerKills = if attackerUserId then (_matchKillsByUserId[attackerUserId] or 0) else 0
			local killerLevel = 0
			if attackerPlayer and _dataService and _dataService.GetProfile then
				local killerProfile = _dataService:GetProfile(attackerPlayer)
				if killerProfile and killerProfile.Data and killerProfile.Data.Stats then
					local lvl = killerProfile.Data.Stats.Level
					if type(lvl) == "number" then
						killerLevel = math.floor(lvl)
					end
				end
			end
			Network.Match.DeathScreenShow.SendTo({
				respawnCooldown = GameConfig.RespawnCooldown,
				killerUserId = if attackerUserId then tostring(attackerUserId) else "",
				killerName = killerName,
				killerKills = killerKills,
				killerLevel = killerLevel,
				weaponId = attackerWeaponId,
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

-- [Loadout functions extracted to LoadoutService.luau]

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

	local spawnPoints = _collectSharedSpawnPoints(_activeMapModel :: Instance)
	if #spawnPoints == 0 then
		return false
	end

	local mapDefinition = _getMapDefinitionByName(_activeMapName)
	local useIntelligentSpawning = mapDefinition ~= nil and mapDefinition.UseIntelligentSpawning == true
	local enemySide: "A" | "B" = if side == "A" then "B" else "A"
	local enemyPositions, enemyLookVectors = _collectCombatantDataForSide(enemySide, nil)
	local allyPositions, _allyLooks = _collectCombatantDataForSide(side, player)
	local chosenSpawn = SpawnSelector.select(spawnPoints, {
		enemyPositions = enemyPositions,
		enemyLookVectors = enemyLookVectors,
		allyPositions = allyPositions,
		recentDeaths = _recentDeathBySpawn,
		now = time(),
	}, useIntelligentSpawning)
	if not chosenSpawn then
		return false
	end

	local spawnedCharacter = _teleportCharacterToSpawn(player, chosenSpawn)
	if not spawnedCharacter then
		return false
	end

	-- Inmunidad al spawn: ForceField nativo bloquea Humanoid:TakeDamage (que es
	-- la ruta que usan WeaponsSystem y BotAI), así que no toca cambiar nada en
	-- el pipeline de daño. Duración configurada en GameConfig; el shield no se
	-- rompe al disparar — expira solo por tiempo vía Debris.
	if GameConfig.SpawnProtectionDuration > 0 then
		local forceField = Instance.new("ForceField")
		forceField.Visible = true
		forceField.Parent = spawnedCharacter
		Debris:AddItem(forceField, GameConfig.SpawnProtectionDuration)
	end

	LoadoutService.applyCosmetics(player, spawnedCharacter, _dataService)

	task.spawn(function()
		LoadoutService.grantWeaponsWithRetry(player, _dataService, 8)
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

-- Dedupe key del último broadcast de voto. Solo enviamos si cambió alguno
-- de los conteos o el segundo de timeLeft. Evita el spam de broadcasts cuando
-- jugadores spamean cambios de voto sin alterar el resultado.
local _lastVoteBroadcastKey: string? = nil

local function _broadcastVoteState(vote: ActiveVoteState)
	local timeLeft = math.ceil(math.max(0, vote.endAt - time()))
	local packet = _buildVoteStatePacket(vote, timeLeft)
	-- Key compuesta: name|votes|name|votes|name|votes|timeLeft.
	local key = string.format(
		"%s|%d|%s|%d|%s|%d|%d",
		tostring(packet.optionAName), packet.optionAVotes,
		tostring(packet.optionBName), packet.optionBVotes,
		tostring(packet.optionCName), packet.optionCVotes,
		packet.timeLeft
	)
	if key == _lastVoteBroadcastKey then
		return
	end
	_lastVoteBroadcastKey = key
	Network.Match.VoteState.SendToAll(packet)
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

	local isDone = false
	local cancelled = false
	local cloned: Instance? = nil
	local cloneError: string? = nil

	task.spawn(function()
		local ok, result = pcall(function()
			return mapTemplate:Clone()
		end)
		if not ok then
			cloneError = tostring(result)
			isDone = true
			return
		end

		if cancelled then
			(result :: Instance):Destroy()
			isDone = true
			return
		end

		cloned = result :: Instance
		isDone = true
	end)

	local startedAt = time()
	while not isDone do
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
	table.clear(_matchDeathsByUserId)
	table.clear(_killStreakByUserId)
	table.clear(_lastBroadcastStreakKeyByUserId)

	-- Clear all streak timeouts
	for userId, timeout in _killStreakTimeoutByUserId do
		if timeout then
			if type(task.cancel) == "function" then
				pcall(task.cancel, timeout)
			end
		end
	end
	table.clear(_killStreakTimeoutByUserId)

	_hasCompletedInitialVote = false
	_lastMapLoadStateBroadcastKey = nil
	_lastRoundStateBroadcastKey = nil
	_lastBotRosterJsonBroadcast = nil
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

	-- Despawnear bots inmediatamente al finalizar la ronda.
	if _AIService then
		_AIService:OnRoundEnd()
	end

	for _, player in Players:GetPlayers() do
		Network.Match.DeathScreenHide.SendTo({}, player)
	end
	_setPhase("RoundEnded", reason .. " | winner=" .. winnerTeam)
	for _, player in Players:GetPlayers() do
		Network.Match.RoundEnded.SendTo({
			winnerTeam = winnerTeam,
			scoreA = _roundScoreA,
			scoreB = _roundScoreB,
		}, player)
	end

	-- Daily task: WinMatches — solo jugadores elegibles (que jugaron la ronda)
	-- y que estaban en el equipo ganador. Empate ("Tie") no cuenta.
	-- Persistir Stats.MatchesPlayed para todos los elegibles + Wins/Losses
	-- para el equipo correspondiente.
	-- task.defer para que los N BatchUpdates no compitan por el mismo frame
	-- que el broadcast de RoundEnded; UX percibida más fluida en partidas
	-- llenas (16 BatchUpdates secuenciales = ~16 SetValues).
	local eligibleSnapshot: { number } = {}
	for userId in _roundEndEligibleByUserId do
		table.insert(eligibleSnapshot, userId)
	end
	local snapshotTeamByUserId: { [number]: string } = {}
	for _, userId in eligibleSnapshot do
		snapshotTeamByUserId[userId] = _teamByUserId[userId] or ""
	end

	task.defer(function()
		for _, userId in eligibleSnapshot do
			local player = Players:GetPlayerByUserId(userId)
			if not player then
				continue
			end

			local updates = {
				{ path = { "Stats", "MatchesPlayed" }, delta = 1 },
			}
			if winnerTeam == "A" or winnerTeam == "B" then
				if snapshotTeamByUserId[userId] == winnerTeam then
					table.insert(updates, { path = { "Stats", "Wins" }, delta = 1 })
					pcall(function()
						DailyTasksService:OnMatchWon(player)
					end)
				else
					table.insert(updates, { path = { "Stats", "Losses" }, delta = 1 })
				end
			end

			if _dataService then
				pcall(function()
					_dataService:BatchUpdate(player, updates)
				end)
			end
		end
	end)

	-- Devolver jugadores elegibles al menú inmediatamente.
	-- El cliente maneja la vuelta al menú al recibir RoundEnded.
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
			_sendMapLoadStateToPlayer(player)
		end
	end

	_endRoundAndRestartVoting(reason)
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
	_lastMapLoadStateBroadcastKey = nil
	_lastRoundStateBroadcastKey = nil
	_lastBotRosterJsonBroadcast = nil
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
	-- C3 fix: bumpear _roundId ANTES de cualquier task.spawn que lo capture.
	-- Si el AI service o cualquier callback dispara _finishRoundAndScheduleRestart
	-- en el mismo frame que iniciamos la ronda, la guard `roundId == _roundId`
	-- en _runRoundTimer previene timers huérfanos.
	_roundId += 1
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

	if _AIService then
		local sharedSpawnPoints = _collectSharedSpawnPoints(_activeMapModel :: Instance)
		_recentDeathBySpawn = {}
		local ok, err = pcall(function()
			_AIService:OnRoundStart({
				spawnPoints = sharedSpawnPoints,
				mapRoot = _activeMapModel,
				onBotDied = function(botTeam: string, _botName: string, botHumanoid: Humanoid, botFakeUserId: number)
					if not _isRoundActive then
						return
					end

					-- Credit the kill to whoever killed this bot
					local attackerUserIdAttr = botHumanoid:GetAttribute("LastAttackerUserId")
					local attackerAtAttr = botHumanoid:GetAttribute("LastAttackerAt")
					local attackerWeaponIdAttr = botHumanoid:GetAttribute("LastAttackerWeaponId")
					local attackerHeadshotAttr = botHumanoid:GetAttribute("LastAttackerHeadshot")
					local attackerUserId = if type(attackerUserIdAttr) == "number" then attackerUserIdAttr else nil
					local attackerAt = if type(attackerAtAttr) == "number" then attackerAtAttr else 0
					local attackerWeaponId = if type(attackerWeaponIdAttr) == "string" then attackerWeaponIdAttr else ""
					local attackerWasHeadshot = attackerHeadshotAttr == true
					if attackerAt > 0 and time() - attackerAt > KILL_ATTRIBUTION_WINDOW then
						attackerUserId = nil
					end
					-- H5 fix: NO descartamos por _isInMenuByUserId aquí. La
					-- ventana KILL_ATTRIBUTION_WINDOW (2s) ya filtra daño viejo
					-- de cuando el jugador estaba in-match. Si el daño es
					-- reciente y el bot muere justo cuando vuelve al menú,
					-- la kill es legítima — no robarla.

					if attackerUserId and attackerUserId ~= botFakeUserId then
						_matchKillsByUserId[attackerUserId] = (_matchKillsByUserId[attackerUserId] or 0) + 1
						-- Solo los jugadores humanos acumulan streak/timer/stats.
						if attackerUserId > 0 then
							local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
							if attackerPlayer then
								_killStreakByUserId[attackerUserId] = (_killStreakByUserId[attackerUserId] or 0) + 1
								_setupStreakTimeout(attackerUserId)
								_registerWeaponKillForAttacker(attackerUserId, attackerWeaponId)
								_grantActionRewardsToAttacker(attackerUserId, "Kill")
								if attackerWasHeadshot then
									_grantActionRewardsToAttacker(attackerUserId, "Headshot")
								end
								local newStreak = _killStreakByUserId[attackerUserId] or 0
								if newStreak == 3 then
									_grantActionRewardsToAttacker(attackerUserId, "Streak3")
								elseif newStreak == 5 then
									_grantActionRewardsToAttacker(attackerUserId, "Streak5")
								end
								-- C1 fix: persistir Stats.Kills/Headshots/KillStreakBest
								-- lifetime también para kills vs bots. Antes el path PvE
								-- solo actualizaba contadores en memoria.
								_persistAttackerKillStats(attackerPlayer, attackerWasHeadshot, newStreak)
							end
						end
						_sendPlayerStreakToAll(attackerUserId)
					end

						-- Los bots no usan streak: solo contabilizar kills/deaths para HUD.
					if _matchKillsByUserId[botFakeUserId] == nil then
						_matchKillsByUserId[botFakeUserId] = 0
					end
					_matchDeathsByUserId[botFakeUserId] = (_matchDeathsByUserId[botFakeUserId] or 0) + 1
					_sendPlayerStreakToAll(botFakeUserId)

					-- Sumar score al equipo contrario (igual que cuando muere un jugador)
					if botTeam == "A" then
						_roundScoreB += 1
					else
						_roundScoreA += 1
					end

					_broadcastRoundState()
					_rebalanceBotsForCurrentRound("bot death")
					_broadcastBotRoster()

					if _roundScoreA >= GameConfig.WinScoreLimit then
						_finishRoundAndScheduleRestart("win score limit reached", "A")
					elseif _roundScoreB >= GameConfig.WinScoreLimit then
						_finishRoundAndScheduleRestart("win score limit reached", "B")
					end
				end,
			})
		end)
		if not ok then
			warn("[MatchService] Failed to start AI round: " .. tostring(err))
		else
			_rebalanceBotsForCurrentRound("round start")
		end
	end

	-- _roundId ya bumpeado más arriba; aquí solo arrancamos el timer con el id actual.
	task.spawn(_runRoundTimer, _roundId)
end

local function _onRequestVoteSync(_: {}, player: Player)
	_log(string.format("Received RequestVoteSync from %s.", player.Name))
	_sendActiveVoteToPlayer(player)
	_sendMapLoadStateToPlayer(player)
	_sendRoundStateToPlayer(player)
	_sendAllPlayerStreaksToPlayer(player)
	_sendBotRosterToPlayer(player)
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
	-- Cap longitud antes de cualquier processing — protege contra payloads
	-- arbitrariamente grandes que harían trabajo en _isValidOption / format.
	if not NetGuards.validate(data, { mapName = NetGuards.MAX.MapName }) then
		return
	end

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
	-- Reset del dedupe key — el nuevo vote tiene otras opciones, debemos
	-- broadcastear el primer estado aunque numéricamente coincida con basura.
	_lastVoteBroadcastKey = nil
	-- Limpiar cooldowns viejos del voto anterior para que el primer voto del nuevo
	-- ciclo no quede bloqueado.
	table.clear(_voteCooldownsByUserId)
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

	local selectedSide = _pickBalancedTeam(player.UserId)
	if not selectedSide then
		_isInMenuByUserId[player.UserId] = true
		_pendingSpawnByUserId[player.UserId] = nil
		_joinDebounceByUserId[player.UserId] = nil
		_log(string.format("Ignored RequestJoinMatch from %s: both teams are full.", player.Name))
		return
	end

	_joinDebounceByUserId[player.UserId] = true
	_pendingSpawnByUserId[player.UserId] = true
	_isInMenuByUserId[player.UserId] = false
	_rebalanceBotsForCurrentRound("join request")
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

		-- Si la ronda terminó entre el RequestJoinMatch y este defer, abortamos
		-- para no spawnear al jugador en una ronda terminada (causa desync de phase).
		if not _isRoundActive then
			_isInMenuByUserId[player.UserId] = true
			_pendingSpawnByUserId[player.UserId] = nil
			_joinDebounceByUserId[player.UserId] = nil
			return
		end

		local team = if _teamByUserId[player.UserId] == "A" then _teamA else _teamB
		if not team then
			warn("[MatchService] Teams no inicializados.")
			_isInMenuByUserId[player.UserId] = true
			_pendingSpawnByUserId[player.UserId] = nil
			_joinDebounceByUserId[player.UserId] = nil
			_rebalanceBotsForCurrentRound("join aborted missing team")
			return
		end

		if not _spawnPlayerOnAssignedTeam(player) then
			warn("[MatchService] No fue posible spawnear al jugador en su equipo.")
			_isInMenuByUserId[player.UserId] = true
			_pendingSpawnByUserId[player.UserId] = nil
			_joinDebounceByUserId[player.UserId] = nil
			_rebalanceBotsForCurrentRound("join spawn failed")
			return
		end

		_pendingSpawnByUserId[player.UserId] = nil
		_joinDebounceByUserId[player.UserId] = nil
		_deathAtByUserId[player.UserId] = 0
		Network.Match.DeathScreenHide.SendTo({}, player)

		-- Daily task: PlayMatches (cuenta una vez por entrada al match).
		pcall(function()
			DailyTasksService:OnMatchPlayed(player)
		end)

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
	-- Minimum anti-spam cooldown (0.5s); the full respawn cooldown is enforced client-side via the death screen bar.
	if time() - deathAt < 0.5 then
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

-- HealthPickup logic extraída a HealthPickupService.luau (Sprint 4 P2 #17).
-- Se inicia desde MatchService:Start con predicates inyectados — ver allá.

local function _onRequestReturnToMenu(_: {}, player: Player)
	_isInMenuByUserId[player.UserId] = true
	_respawnDebounceByUserId[player.UserId] = nil
	_pendingSpawnByUserId[player.UserId] = nil
	_killStreakByUserId[player.UserId] = 0
	_resetStreakTimeout(player.UserId)
	_rebalanceBotsForCurrentRound("return to menu")
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

function MatchService:GetPlayerKillStreak(playerOrUserId: Player | number): number
	local userId = if typeof(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	return _killStreakByUserId[userId] or 0
end

function MatchService:Start(dataService: DataService): ()
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
		local aiFolder = serverRoot:FindFirstChild("AI")
		if aiFolder then
			-- Con Rojo, una carpeta con init.luau se compila directamente como ModuleScript.
			-- En ese caso aiFolder ya ES el módulo; si no, buscamos un hijo llamado init o AIService.
			local aiModule: ModuleScript?
			if aiFolder:IsA("ModuleScript") then
				aiModule = aiFolder :: ModuleScript
			else
				local child = aiFolder:FindFirstChild("init") or aiFolder:FindFirstChild("AIService")
				if child and child:IsA("ModuleScript") then
					aiModule = child :: ModuleScript
				end
			end

			if aiModule then
				local ok, result = pcall(require, aiModule)
				if ok then
					_AIService = result
					if _AIService.SetDataService then
						_AIService:SetDataService(_dataService)
					end
					_log("AIService loaded successfully.")
				else
					warn("[MatchService] Failed to load AIService: " .. tostring(result))
				end
			else
				_log("AIService module not found (init.luau or AIService.luau not in Server/AI)")
			end
		else
			_log("AI folder not found in Server (bots will not spawn)")
		end
	end

	-- C2: flush de acciones diferidas cuando el profile termine de cargar.
	-- Hooks compatibles tanto con Signal-style (ProfileLoaded) como con
	-- BindableEvent.Event. Si DataService no expone la signal, se ignora —
	-- el código sigue funcionando con la pérdida silenciosa preexistente.
	if _dataService and _dataService.ProfileLoaded then
		_dataService.ProfileLoaded:Connect(function(player: Player)
			local queue = _pendingProfileActionsByUserId[player.UserId]
			if not queue then return end
			_pendingProfileActionsByUserId[player.UserId] = nil
			for _, fn in queue do
				local ok, err = pcall(fn)
				if not ok then
					warn("[MatchService] Pending profile action error:", err)
				end
			end
		end)
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
		local wasActiveReal = _isInMenuByUserId[player.UserId] == false
		local wasPendingSpawn = _pendingSpawnByUserId[player.UserId] == true
		_voteCooldownsByUserId[player.UserId] = nil
		_isInMenuByUserId[player.UserId] = nil
		_deathAtByUserId[player.UserId] = nil
		_respawnDebounceByUserId[player.UserId] = nil
		_matchKillsByUserId[player.UserId] = nil
		_matchDeathsByUserId[player.UserId] = nil
		_killStreakByUserId[player.UserId] = nil
		_lastBroadcastStreakKeyByUserId[player.UserId] = nil
		_pendingProfileActionsByUserId[player.UserId] = nil
		_roundEndEligibleByUserId[player.UserId] = nil
		_resetStreakTimeout(player.UserId)
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
			_pendingSpawnByUserId[player.UserId] = nil
			_log(string.format("Released team assignment for %s (left before spawn).", player.Name))
		end

		_teamByUserId[player.UserId] = nil

		if _isRoundActive and (wasActiveReal or wasPendingSpawn) then
			_rebalanceBotsForCurrentRound("player leaving")
		end
	end)

	Network.Match.CastVote.Listen(_onCastVote)
	Network.Match.RequestVoteSync.Listen(_onRequestVoteSync)
	Network.Match.RequestJoinMatch.Listen(_onRequestJoinMatch)
	Network.Match.RequestRespawn.Listen(_onRequestRespawn)
	Network.Match.RequestReturnToMenu.Listen(_onRequestReturnToMenu)

	-- HealthPickup extraído (Sprint 4 P2 #17). Inyectamos predicates para
	-- que el service no se acople a state interno de MatchService.
	HealthPickupService:Start({
		isRoundActive = function() return _isRoundActive end,
		isPlayerInMenu = function(userId: number): boolean
			return _isInMenuByUserId[userId] == true
		end,
	})

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
