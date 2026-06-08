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

local ActionRewards = require(Shared:WaitForChild("constants"):WaitForChild("ActionRewards"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local SpawnSelector = require(script.Parent:WaitForChild("SpawnSelector"))
local LoadoutService = require(script.Parent:WaitForChild("LoadoutService"))
local HealthPickupService = require(script.Parent:WaitForChild("HealthPickupService"))
local TeamAssignmentService = require(script.Parent:WaitForChild("TeamAssignmentService"))
local VotingService = require(script.Parent:WaitForChild("VotingService"))
local KillAttributionService = require(script.Parent:WaitForChild("KillAttributionService"))
local MatchResultsService = require(script.Parent:WaitForChild("MatchResultsService"))
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local CollisionGroups = require(Shared.CollisionGroups)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local WeaponCategory = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local DailyTasksService = require(script.Parent.Parent.dailyTasks.DailyTasksService)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
local RewardService = require(script.Parent.Parent.Parent.core.RewardService)
local EconomyAnalytics = require(script.Parent.Parent.Parent.core.EconomyAnalytics)
local LastAttackerStore = require(ReplicatedStorage:WaitForChild("WeaponsSystem"):WaitForChild("Libraries"):WaitForChild("LastAttackerStore"))
type DataService = DataServiceMod.DataServiceModule

type MapDefinition = {
	Name: string,
	Modes: { string },
	PlaceholderImage: string,
	UseIntelligentSpawning: boolean?,
}

local MatchService = {}
MatchService.__index = MatchService

-- Onboarding callbacks — set by ServerBootstrap, fire-and-forget.
MatchService.OnPlayerJoinedMatch = nil :: ((Player) -> ())?
MatchService.OnPlayerFirstKill = nil :: ((Player) -> ())?
MatchService.OnPlayerMatchCompleted = nil :: ((Player) -> ())?
MatchService.OnPlayerReturnedToLobby = nil :: ((Player) -> ())?

local _started = false
-- Rate limit por-userId para RemoteEvents de match (vote sync / return to menu).
-- El `_joinDebounceByUserId` y `_respawnDebounceByUserId` ya tenían debounce de
-- estado; estos timestamps añaden un cooldown duro contra spam de eventos
-- expensive (VoteSync hace 5 SendTo a un solo player, ReturnToMenu hace LoadCharacter).
local REMOTE_RATE_LIMIT_SECONDS = 0.5
local _voteSyncCooldownByUserId: { [number]: number } = {}
local _returnToMenuCooldownByUserId: { [number]: number } = {}
local _phase = "Idle"

local _isMapLoading = false
local _isPlayEnabled = false
local _activeMapName = ""
local _activeMapContainer: BasePart? = nil
local _activeMapModel: Instance? = nil
-- Caches por-round del mapa activo. Los spawn points y la carpeta de bots no
-- cambian durante un round, así evitamos escanear `_activeMapModel:GetDescendants()`
-- (potencialmente miles de instances) en cada respawn/spawn.
local _cachedSpawnPoints: { BasePart }? = nil
local _cachedBotsFolder: Instance? = nil
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
-- Connection a character.DescendantAdded del character vivo actual del jugador.
-- Se desconecta al respawn (CharacterAdded vuelve a disparar), al morir, y al
-- salirse del juego — evita acumular listeners en characters viejos que pueden
-- seguir parented (ragdoll/kill effects) hasta que el GC los barra.
local _charDescendantConnectionsByUserId: { [number]: RBXScriptConnection } = {}
local _deathAtByUserId: { [number]: number } = {}
local _respawnDebounceByUserId: { [number]: boolean } = {}
local _matchKillsByUserId: { [number]: number } = {}
-- _killStreakByUserId, _killStreakTimeoutByUserId, _lastBroadcastStreakKeyByUserId
-- viven en KillAttributionService. Acá quedan kills/deaths que son
-- accesados ampliamente (HUD broadcast, score updates).
local _matchDeathsByUserId: { [number]: number } = {}
-- Asistencias de la partida actual (incrementadas en GrantCombatReward "Assist").
-- Se difunden en PlayerStreakState para la pantalla de Resultados.
local _matchAssistsByUserId: { [number]: number } = {}
local _matchCashEarnedByUserId: { [number]: number } = {}
local _matchXPEarnedByUserId: { [number]: number } = {}
local _recentKillTimestamps: { [number]: { number } } = {}
local MULTIKILL_WINDOW = 4
local _lastMapLoadStateBroadcastKey: string? = nil
local _lastRoundStateBroadcastKey: string? = nil
local _lastBotRosterJsonBroadcast: string? = nil
-- Timestamp de la última muerte registrada en cada spawn point. Usado por
-- SpawnSelector para penalizar respawnear donde alguien acaba de morir y evitar
-- spawn-trap loops. Se limpia en cada round restart.
-- Audit mobile: weak keys → si un spawn point se destruye (cambio de mapa
-- mid-round, race con vote.onVoteFinished), el GC libera la entry sola en
-- vez de mantener un BasePart huérfano referenciado para siempre.
local _recentDeathBySpawn: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any

local _teamA: Team? = nil
local _teamB: Team? = nil
local _finishRoundAndScheduleRestart: any = nil
-- Forward-decl: _endRoundAndRestartVoting + el path de map load fail llaman a
-- _startVoteIfPossible antes de que su implementación (delegate a VotingService)
-- esté declarada más abajo. Mantenemos el patrón que ya usa _finishRoundAndScheduleRestart.
local _startVoteIfPossible: any = nil
local _AIService: any = nil
local _dataService: DataService = nil :: any


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
	local isVoting = VotingService:HasActiveVote()
	local key = string.format(
		"%s|%s|%s|%s",
		tostring(_isMapLoading), tostring(_isPlayEnabled), _activeMapName, tostring(isVoting)
	)
	if _lastMapLoadStateBroadcastKey == key then
		return
	end
	_lastMapLoadStateBroadcastKey = key

	Network.Match.MapLoadState.SendToAll({
		isLoading = _isMapLoading,
		playEnabled = _isPlayEnabled,
		mapName = _activeMapName,
		isVoting = isVoting,
	})
end

local function _sendMapLoadStateToPlayer(player: Player)
	local ok, err = pcall(function()
		Network.Match.MapLoadState.SendTo({
			isLoading = _isMapLoading,
			playEnabled = _isPlayEnabled,
			mapName = _activeMapName,
			isVoting = VotingService:HasActiveVote(),
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

-- Wrappers que delegan al KillAttributionService. Mantienen los call sites
-- existentes inmutables — el service owns _killStreakByUserId, los timeouts y
-- el dedupe del broadcast.
local function _sendPlayerStreakToAll(userId: number)
	KillAttributionService:SendStreakBroadcast(userId)
end

local function _sendAllPlayerStreaksToPlayer(player: Player)
	KillAttributionService:SendAllStreaksTo(player)
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
	local json = _lastBotRosterJsonBroadcast
	if not json then
		local roster = _AIService:GetBotRoster()
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, roster)
		if not ok then return end
		json = encoded
		_lastBotRosterJsonBroadcast = json
	end
	pcall(function()
		Network.Match.BotRoster.SendTo({ json = json }, player)
	end)
end

-- Envía a `player` los cosméticos (outfit/face/hat) de sus compañeros REALES, para
-- reconstruir sus réplicas en Resultados. Solo su propio equipo, y solo otros
-- jugadores (los bots ya van en el BotRoster; el jugador local usa su loadout).
local function _sendTeamCosmeticsTo(player: Player)
	local side = _teamByUserId[player.UserId]
	if not side or not _dataService then
		return
	end
	local list = {}
	for _, other in Players:GetPlayers() do
		if other ~= player and _teamByUserId[other.UserId] == side then
			local profile = _dataService:GetProfile(other)
			local loadout = profile and profile.Data and profile.Data.Loadout
			if type(loadout) == "table" then
				table.insert(list, {
					userId = other.UserId,
					outfitId = if type(loadout.Outfit) == "string" then loadout.Outfit else "",
					faceId = if type(loadout.Face) == "string" then loadout.Face else "",
					hatId = if type(loadout.Hat) == "string" then loadout.Hat else "",
				})
			end
		end
	end
	if #list == 0 then
		return
	end
	local ok, json = pcall(HttpService.JSONEncode, HttpService, list)
	if ok then
		pcall(function()
			Network.Match.TeamCosmetics.SendTo({ json = json }, player)
		end)
	end
end

-- Refresca los cosméticos de equipo de todos los jugadores reales de `side`
-- (cada uno recibe la lista actualizada de sus compañeros).
local function _refreshTeamCosmetics(side: string?)
	if not side then
		return
	end
	for _, player in Players:GetPlayers() do
		if _teamByUserId[player.UserId] == side then
			_sendTeamCosmeticsTo(player)
		end
	end
end

local function _resolveBotKillerName(attackerUserId: number): string
	if _AIService and _AIService.GetBotDisplayName then
		return _AIService:GetBotDisplayName(attackerUserId) or ""
	end
	return ""
end

-- Helper consolidado: limpia todas las tablas con "scope match" (state
-- por-jugador y por-round) en un orden documentado. Llamado por:
--   * `_endRoundAndRestartVoting`: cleanup final tras un round.
--   * `_startMapLoadFlow`: slate limpio antes del siguiente round.
-- Cualquier tabla nueva con scope match debe agregarse acá — esta es la
-- fuente de verdad y previene drift entre los dos call sites.
-- NO toca:
--   * Vote cooldowns (viven en VotingService).
--   * `_voteSyncCooldownByUserId` y `_returnToMenuCooldownByUserId` (scope
--     sesión, no round — limpian en PlayerRemoving).
--   * Broadcast key caches (`_lastMapLoadStateBroadcastKey`, etc.) — se
--     manejan al lado de los broadcasts.
local function _resetMatchScopedState()
	-- Asignación + spawn flow
	table.clear(_teamByUserId)
	table.clear(_isInMenuByUserId)
	table.clear(_pendingSpawnByUserId)
	table.clear(_joinDebounceByUserId)
	table.clear(_deathAtByUserId)
	table.clear(_respawnDebounceByUserId)
	table.clear(_roundEndEligibleByUserId)
	-- Kill/death/assist tracking
	table.clear(_matchKillsByUserId)
	table.clear(_matchDeathsByUserId)
	table.clear(_matchAssistsByUserId)
	table.clear(_matchCashEarnedByUserId)
	table.clear(_matchXPEarnedByUserId)
	table.clear(_recentKillTimestamps)
	-- Streak state (counts + timeouts + broadcast keys) vive en KillAttributionService.
	KillAttributionService:Clear()
	-- Recent deaths por spawn point (audit fix: antes solo se limpiaba en
	-- _startMapLoadFlow, no en _endRoundAndRestartVoting → references a
	-- BaseParts destruidos del round anterior podían quedar como keys).
	-- table.clear preserva la metatable de weak keys.
	table.clear(_recentDeathBySpawn)
	-- Snapshots de inicio de partida (nivel/tier BP) para los items de Resultados.
	MatchResultsService:ClearSnapshots()
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

-- Audit mobile: cap por jugador para evitar acumulación si el profile nunca
-- carga (backend caído). Con 50 kills/min × 5 min de round = 250 closures por
-- jugador retenidas. Si 16 jugadores caen así, son 4000 closures vivos. El
-- cap drop-oldest mantiene los últimos N que es lo que más probablemente
-- importa cuando el profile finalmente cargue.
local PROFILE_ACTION_QUEUE_CAP = 50

local function _deferUntilProfile(player: Player, fn: () -> ()): ()
	local userId = player.UserId
	local queue = _pendingProfileActionsByUserId[userId]
	if not queue then
		queue = {}
		_pendingProfileActionsByUserId[userId] = queue
	end
	if #queue >= PROFILE_ACTION_QUEUE_CAP then
		-- Drop oldest (FIFO): table.remove(queue, 1) es O(n) pero N <= cap.
		table.remove(queue, 1)
	end
	table.insert(queue, fn)
end

local function _hasProfile(player: Player): boolean
	return _dataService ~= nil and _dataService:GetProfile(player) ~= nil
end

-- Audit mobile: signature acepta Player directo en lugar de userId. Antes el
-- kill chain (línea ~519+) ya tenía `attacker` resuelto y la función hacía
-- GetPlayerByUserId redundante por cada call (4 calls por kill: Kill +
-- Headshot? + Streak3? + Streak5?). Ahora 1 lookup en el caller, 4 reuses.
local function _isMatchCapReached(userId: number): boolean
	return (_matchCashEarnedByUserId[userId] or 0) >= GameConfig.MatchCashCap
		and (_matchXPEarnedByUserId[userId] or 0) >= GameConfig.MatchXPCap
end

local function _grantActionRewardsToAttacker(attacker: Player?, action: string, weaponId: string?)
	if not _dataService or not attacker then
		return
	end

	if _isMatchCapReached(attacker.UserId) then
		return
	end

	if not _hasProfile(attacker) then
		_deferUntilProfile(attacker, function()
			_grantActionRewardsToAttacker(attacker, action, weaponId)
		end)
		return
	end

	local ok, xpGranted, cashGranted = RewardService.Award(attacker, action, nil, weaponId)
	if ok then
		_matchCashEarnedByUserId[attacker.UserId] = (_matchCashEarnedByUserId[attacker.UserId] or 0) + cashGranted
		_matchXPEarnedByUserId[attacker.UserId] = (_matchXPEarnedByUserId[attacker.UserId] or 0) + xpGranted
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

	local profile = _dataService:GetProfile(player)
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
			local challenge = definition.KillChallenge
			local kills: number? = nil
			if challenge then
				kills = tonumber(challenge.Kills)
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
		return
	end

	for _, update in updates do
		local wrapKey = update.path[5]
		if type(wrapKey) == "string" then
			EconomyAnalytics.ItemSource(player, "MasteryWrap", weaponCategory .. "::" .. weaponId .. "::" .. wrapKey)
		end
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

	local ok, success, newCount = pcall(_dataService.IncrementWeaponKills, _dataService, attackerPlayer, weaponCategory, resolvedWeaponId, 1)
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

local function _resolveKillerName(attackerUserId: number?): string
	if not attackerUserId then
		return ""
	end
	if attackerUserId > 0 then
		local player = Players:GetPlayerByUserId(attackerUserId)
		return if player then player.Name else ""
	else
		return _resolveBotKillerName(attackerUserId)
	end
end

local function _registerKillEvent(deadPlayer: Player, attackerUserId: number?, attackerWeaponId: string?, attackerWasHeadshot: boolean?)
	local killerName = _resolveKillerName(attackerUserId)
	pcall(function()
		Network.Combat.KillFeed.SendToAll({
			killerName = killerName,
			victimName = deadPlayer.Name,
			weaponId = attackerWeaponId or "",
		})
	end)

	KillAttributionService:ResetStreak(deadPlayer.UserId)
	if _matchKillsByUserId[deadPlayer.UserId] == nil then
		_matchKillsByUserId[deadPlayer.UserId] = 0
	end
	_matchDeathsByUserId[deadPlayer.UserId] = (_matchDeathsByUserId[deadPlayer.UserId] or 0) + 1
	KillAttributionService:SendStreakBroadcast(deadPlayer.UserId)

	-- Persistir Stats.Deaths lifetime del que muere (siempre que sea jugador).
	-- C2: si el profile aún no cargó, encolar para flush en ProfileLoaded.
	if _dataService then
		if _hasProfile(deadPlayer) then
			pcall(_dataService.Increment, _dataService, deadPlayer, { "Stats", "Deaths" }, 1)
		else
			_deferUntilProfile(deadPlayer, function()
				pcall(_dataService.Increment, _dataService, deadPlayer, { "Stats", "Deaths" }, 1)
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

	local prevKills = _matchKillsByUserId[attackerUserId] or 0
	_matchKillsByUserId[attackerUserId] = prevKills + 1

	if prevKills == 0 and MatchService.OnPlayerFirstKill then
		pcall(MatchService.OnPlayerFirstKill, attacker)
	end

	local newStreak = KillAttributionService:RecordKill(attackerUserId)
	KillAttributionService:SendStreakBroadcast(attackerUserId)
	_registerWeaponKillForAttacker(attackerUserId, attackerWeaponId)
	_grantActionRewardsToAttacker(attacker, "Kill", attackerWeaponId)
	if attackerWasHeadshot then
		_grantActionRewardsToAttacker(attacker, "Headshot", attackerWeaponId)
	end
	if newStreak == 3 then
		_grantActionRewardsToAttacker(attacker, "Streak3", attackerWeaponId)
	elseif newStreak == 5 then
		_grantActionRewardsToAttacker(attacker, "Streak5", attackerWeaponId)
	end

	_persistAttackerKillStats(attacker, attackerWasHeadshot == true, newStreak)

	local now = time()
	local timestamps = _recentKillTimestamps[attackerUserId]
	if not timestamps then
		timestamps = {}
		_recentKillTimestamps[attackerUserId] = timestamps
	end
	table.insert(timestamps, now)
	while #timestamps > 0 and (now - timestamps[1]) > MULTIKILL_WINDOW do
		table.remove(timestamps, 1)
	end
	if _dataService and _hasProfile(attacker) then
		local killsInWindow = #timestamps
		if killsInWindow == 2 then
			pcall(_dataService.Increment, _dataService, attacker, { "Stats", "DoubleKills" }, 1)
		elseif killsInWindow == 3 then
			pcall(_dataService.Increment, _dataService, attacker, { "Stats", "TripleKills" }, 1)
		end
	end
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

-- _countActiveRealAssignments / _pickBalancedTeam / tie-break extraídos a
-- TeamAssignmentService. Aquí solo delegamos para mantener call sites estables.
local function _countActiveRealAssignments(): (number, number)
	return TeamAssignmentService:CountActiveRealAssignments()
end

local function _pickBalancedTeam(userId: number): ("A" | "B")?
	return TeamAssignmentService:PickBalancedTeam(userId)
end

-- Audit mobile: coalescer múltiples calls a rebalance al mismo frame.
-- Con kill chains rápidas (3-5/s) y joins/leaves simultáneos, el camino sin
-- debounce hacía SetBotTargets + scan completo + JSONEncode roster por cada
-- evento. El dedupe interno de _broadcastBotRoster cubre el broadcast pero
-- no el SetBotTargets ni el _refreshAliveLists.
local _rebalancePending = false
local _rebalanceLastReason: string? = nil

local function _doRebalanceNow(reason: string)
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

	_broadcastBotRoster()
end

local function _rebalanceBotsForCurrentRound(reason: string)
	if _rebalancePending then
		_rebalanceLastReason = reason
		return
	end
	_rebalancePending = true
	_rebalanceLastReason = reason
	task.defer(function()
		local reasonNow = _rebalanceLastReason or reason
		_rebalancePending = false
		_rebalanceLastReason = nil
		_doRebalanceNow(reasonNow)
	end)
end

local function _collectSharedSpawnPoints(activeMapRoot: Instance): { BasePart }
	-- Cache lazy: el primer call por round paga el escaneo, el resto reusa.
	-- Se invalida en _clearActiveMap() cuando termina el round.
	if _cachedSpawnPoints then
		return _cachedSpawnPoints
	end

	local spawnsRoot = activeMapRoot:FindFirstChild("Spawns", true)
	if not spawnsRoot then
		_cachedSpawnPoints = {}
		return _cachedSpawnPoints
	end

	local points = {} :: { BasePart }
	for _, node in spawnsRoot:GetDescendants() do
		if node:IsA("BasePart") then
			table.insert(points, node)
		end
	end

	_cachedSpawnPoints = points
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

local TeamUtils = require(Shared.utils.TeamUtils)

local function _resolveNpcSide(character: Model): "A" | "B"?
	return TeamUtils.getSide(character) :: any
end

-- Recolecta posiciones + lookVectors de combatientes vivos en un lado determinado
-- (excluyendo opcionalmente al jugador que pide el respawn). Combina jugadores
-- humanos y NPCs en una sola pasada por el mapa.
-- Audit mobile: single-pass por lado. Antes se llamaba 2 veces por respawn
-- (una por enemySide + una por allySide), cada una iterando Players +
-- botsFolder. Una sola pasada reduce las ~128 lookups del path crítico a 64.
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

		local candidateSide = _teamByUserId[candidatePlayer.UserId]
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

	if not _activeMapModel then
		return positionsBySide, lookVectorsBySide
	end

	-- Iteramos solo `mapRoot.Bots` (top-level): los bots de IA se parentan ahí
	-- (ver AIService:_registerBot). Antes era `mapRoot:GetDescendants()` que
	-- recorría miles de instances del mapa por cada respawn × cada lado (×2).
	-- Cache lazy del folder, invalidado en _clearActiveMap.
	if _cachedBotsFolder == nil or _cachedBotsFolder.Parent == nil then
		_cachedBotsFolder = (_activeMapModel :: Instance):FindFirstChild("Bots")
	end
	local botsFolder = _cachedBotsFolder
	if botsFolder then
		for _, node in botsFolder:GetChildren() do
			if not node:IsA("Model") then
				continue
			end

			-- Ignorar NPCs muertos/ragdollados — no son amenaza, no deben influir en la
			-- elección de spawn point.
			local npcSide = _resolveNpcSide(node)
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
		local lastAttacker = LastAttackerStore.get(humanoid)
		local attackerUserId = if lastAttacker then lastAttacker.UserId else nil
		local attackerAt = if lastAttacker then lastAttacker.At else 0
		local attackerWeaponId = if lastAttacker then lastAttacker.WeaponId else ""
		local attackerWasHeadshot = if lastAttacker then lastAttacker.Headshot else false
		if attackerAt > 0 and time() - attackerAt > GameConfig.KillAttributionWindow then
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

			-- Killer es bot: sustituir stats por las fingidas de la identidad
			-- (level + historicalKills del tier de personalidad). Mantiene la
			-- ilusión de que el bot tiene "carrera" propia. Para players reales
			-- el branch anterior ya cubrió los stats.
			if attackerUserId and attackerUserId < 0 and _AIService and _AIService.GetBotIdentity then
				local botIdentity = _AIService:GetBotIdentity(attackerUserId)
				if botIdentity then
					killerLevel = botIdentity.level
					killerKills = botIdentity.historicalKills
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

	LoadoutService.loadCharacterWithBody(player, _dataService)
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
	-- Single-pass sobre Players + botsFolder, devuelve datos de ambos lados.
	-- excludePlayer omite al jugador respawnando de su propio side (allies).
	-- En el lado enemigo nunca aparecería de todas formas porque su team es
	-- `side`, así que el efecto neto coincide con el viejo
	-- `_collectCombatantDataForSide(enemySide, nil)` + `(side, player)`.
	local positionsBySide, lookVectorsBySide = _collectAllCombatantData(player)
	local enemyPositions = positionsBySide[enemySide]
	local enemyLookVectors = lookVectorsBySide[enemySide]
	local allyPositions = positionsBySide[side]
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
	-- Audit mobile: stampear attribute SpawnProtectedUntil = expiry timestamp.
	-- BotAI lo lee en _getBestTarget en lugar de FindFirstChildOfClass("ForceField")
	-- por candidato (~2.5K lookups/seg con 16 bots × 16 candidates × 10Hz).
	if GameConfig.SpawnProtectionDuration > 0 then
		local forceField = Instance.new("ForceField")
		forceField.Visible = true
		forceField.Parent = spawnedCharacter
		Debris:AddItem(forceField, GameConfig.SpawnProtectionDuration)
		spawnedCharacter:SetAttribute("SpawnProtectedUntil", time() + GameConfig.SpawnProtectionDuration)
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
	_cachedSpawnPoints = nil
	_cachedBotsFolder = nil
end

-- Voting helpers (_buildVoteStatePacket / _broadcastVoteState /
-- _sendActiveVoteToPlayer / _collectCompatibleMaps / _pickRandomMapOptions)
-- viven en VotingService. Aquí solo wireamos el callback `onVoteFinished` y
-- delegamos snapshots vía `VotingService:SendSnapshotTo(player)`.

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
	_resetMatchScopedState()

	VotingService:ResetCompletedFlag()
	_lastMapLoadStateBroadcastKey = nil
	_lastRoundStateBroadcastKey = nil
	_lastBotRosterJsonBroadcast = nil
	_setPhase("Idle", "round cleaned; vote after Results window")

	-- La votación no arranca hasta que termina la pantalla de Resultados
	-- (EndResultsDuration). El hold bloquea cualquier disparador anticipado
	-- (RequestVoteSync, PlayerAdded), y el task.delay la lanza al expirar.
	VotingService:HoldVotingFor(GameConfig.EndResultsDuration)
	task.delay(GameConfig.EndResultsDuration, function()
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

	-- ── Recompensas de fin de partida ────────────────────────
	-- MVP = jugador(es) con más kills de SU equipo (kills > 0). Solo players reales.
	local teamMaxKills = { A = 0, B = 0 }
	for userId in _roundEndEligibleByUserId do
		if userId > 0 then
			local side = _teamByUserId[userId]
			if side == "A" or side == "B" then
				local kills = _matchKillsByUserId[userId] or 0
				if kills > teamMaxKills[side] then
					teamMaxKills[side] = kills
				end
			end
		end
	end

	-- Computar + ENVIAR las recompensas a cada elegible ANTES de RoundEnded (el
	-- cliente debe tenerlas al mostrar la pantalla). El cash se concede más abajo
	-- (task.defer) — server-authoritative, independiente de que se vea o no.
	local resultsByUserId: { [number]: any } = {}
	local winnerIsTeam = winnerTeam == "A" or winnerTeam == "B"
	for userId in _roundEndEligibleByUserId do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end
		local side = _teamByUserId[userId]
		local won = winnerIsTeam and side == winnerTeam
		local maxForSide = if side == "A" or side == "B" then teamMaxKills[side] else 0
		local context = {
			won = won,
			lost = not won, -- perder o empatar cuentan como "Defeat"
			isMVP = maxForSide > 0 and (_matchKillsByUserId[userId] or 0) == maxForSide,
			isVIP = MatchResultsService:IsVIPCached(player),
		}
		local results = MatchResultsService:BuildResults(player, context)
		resultsByUserId[userId] = results
		-- Solo el payload de display viaja al cliente (no `cash`, que lleva id interno).
		local payload = { outcome = results.outcome, rewards = results.rewards }
		local ok, json = pcall(HttpService.JSONEncode, HttpService, payload)
		if ok then
			pcall(function()
				Network.Match.MatchResults.SendTo({ json = json }, player)
			end)
		end
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

			-- Conceder el cash de fin de partida (no bloqueado). Se otorga aunque el
			-- jugador no vea la pantalla de Resultados (esté en el menú u otra pantalla).
			local results = resultsByUserId[userId]
			if results then
				MatchResultsService:GrantCash(player, results.cash)
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

		if MatchService.OnPlayerMatchCompleted then
			pcall(MatchService.OnPlayerMatchCompleted, player)
		end

		if lobbySpawn then
			_teleportCharacterToSpawn(player, lobbySpawn)
		else
			LoadoutService.loadCharacterWithBody(player, _dataService)
		end

		if player.Parent == Players then
			_sendMapLoadStateToPlayer(player)

			if MatchService.OnPlayerReturnedToLobby then
				pcall(MatchService.OnPlayerReturnedToLobby, player)
			end
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

-- Handler de muerte de un bot de IA. Extraído del callback inline en
-- _AIService:OnRoundStart para que la lógica de kill attribution / score / win
-- check no esté embebida dentro del round-start flow. Llamado por AIService
-- cuando un bot muere — toca state interno de MatchService (scoreA/B, streaks,
-- match kills/deaths) y dispara broadcasts.
local function _handleBotDied(botTeam: string, _botName: string, botHumanoid: Humanoid, botFakeUserId: number)
	if not _isRoundActive then
		return
	end

	-- Credit the kill to whoever killed this bot
	local lastAttacker = LastAttackerStore.get(botHumanoid)
	local attackerUserId = if lastAttacker then lastAttacker.UserId else nil
	local attackerAt = if lastAttacker then lastAttacker.At else 0
	local attackerWeaponId = if lastAttacker then lastAttacker.WeaponId else ""
	local attackerWasHeadshot = if lastAttacker then lastAttacker.Headshot else false
	if attackerAt > 0 and time() - attackerAt > GameConfig.KillAttributionWindow then
		attackerUserId = nil
	end
	-- H5 fix: NO descartamos por _isInMenuByUserId aquí. La ventana
	-- KillAttributionWindow (2s) ya filtra daño viejo de cuando el jugador
	-- estaba in-match. Si el daño es reciente y el bot muere justo cuando
	-- vuelve al menú, la kill es legítima — no robarla.

	local killerName = _resolveKillerName(attackerUserId)
	pcall(function()
		Network.Combat.KillFeed.SendToAll({
			killerName = killerName,
			victimName = _botName,
			weaponId = attackerWeaponId or "",
		})
	end)

	if attackerUserId and attackerUserId ~= botFakeUserId then
		_matchKillsByUserId[attackerUserId] = (_matchKillsByUserId[attackerUserId] or 0) + 1
		-- Solo los jugadores humanos acumulan streak/timer/stats.
		if attackerUserId > 0 then
			local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
			if attackerPlayer then
				local newStreak = KillAttributionService:RecordKill(attackerUserId)
				_registerWeaponKillForAttacker(attackerUserId, attackerWeaponId)
				_grantActionRewardsToAttacker(attackerPlayer, "Kill", attackerWeaponId)
				if attackerWasHeadshot then
					_grantActionRewardsToAttacker(attackerPlayer, "Headshot", attackerWeaponId)
				end
				if newStreak == 3 then
					_grantActionRewardsToAttacker(attackerPlayer, "Streak3", attackerWeaponId)
				elseif newStreak == 5 then
					_grantActionRewardsToAttacker(attackerPlayer, "Streak5", attackerWeaponId)
				end
				-- C1 fix: persistir Stats.Kills/Headshots/KillStreakBest lifetime
				-- también para kills vs bots. Antes el path PvE solo
				-- actualizaba contadores en memoria.
				_persistAttackerKillStats(attackerPlayer, attackerWasHeadshot, newStreak)
			end
		end
		KillAttributionService:SendStreakBroadcast(attackerUserId)
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

	if _roundScoreA >= GameConfig.WinScoreLimit then
		_finishRoundAndScheduleRestart("win score limit reached", "A")
	elseif _roundScoreB >= GameConfig.WinScoreLimit then
		_finishRoundAndScheduleRestart("win score limit reached", "B")
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

		VotingService:ResetCompletedFlag()
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
	_resetMatchScopedState()
	-- Tras el clear, re-inicializar kill/death/streak a 0 para los players
	-- actuales y broadcastear (UI sync); marcar a todos como en-menú (el
	-- siguiente RequestJoinMatch los moverá a in-round).
	for _, player in Players:GetPlayers() do
		_matchKillsByUserId[player.UserId] = 0
		KillAttributionService:InitStreak(player.UserId)
		_matchDeathsByUserId[player.UserId] = 0
		KillAttributionService:SendStreakBroadcast(player.UserId)
		_isInMenuByUserId[player.UserId] = true
	end
	_setPhase("PregameReady", "map loaded; play enabled")
	_sendMapLoadStateToAll()
	_broadcastRoundState()

	if _AIService then
		local sharedSpawnPoints = _collectSharedSpawnPoints(_activeMapModel :: Instance)
		-- _recentDeathBySpawn ya quedó limpio por `_resetMatchScopedState()` arriba.
		local ok, err = pcall(function()
			_AIService:OnRoundStart({
				spawnPoints = sharedSpawnPoints,
				mapRoot = _activeMapModel,
				onBotDied = _handleBotDied,
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

-- Handler de sync general (vote + map + round + streaks + roster). El bit de
-- vote lo delega VotingService:SendSnapshotTo; el resto vive aquí.
local function _onRequestVoteSync(_: {}, player: Player)
	local now = time()
	local last = _voteSyncCooldownByUserId[player.UserId] or 0
	if now - last < REMOTE_RATE_LIMIT_SECONDS then
		return
	end
	_voteSyncCooldownByUserId[player.UserId] = now

	_log(string.format("Received RequestVoteSync from %s.", player.Name))
	_startVoteIfPossible()
	VotingService:SendSnapshotTo(player)
	_sendMapLoadStateToPlayer(player)
	_sendRoundStateToPlayer(player)
	_sendAllPlayerStreaksToPlayer(player)
	_sendBotRosterToPlayer(player)
end

-- Implementación del forward-decl: delega al VotingService.
_startVoteIfPossible = function()
	VotingService:StartVoteIfPossible()
end

local function _onCharacterAdded(player: Player, character: Model)
	-- Asignar al grupo CHARACTERS para que jugadores vivos no colisionen con
	-- cadáveres (ragdolls están en RAGDOLL via los kill effects). Snapshot
	-- inmediato + DescendantAdded por si accesorios/tools cargan tarde.
	-- Trackeamos la connection por userId para desconectarla en el siguiente
	-- respawn / muerte / salida — el character viejo puede seguir parented por
	-- ragdoll/kill effects hasta el GC, lo que acumularía listeners.
	CollisionGroups.setGroupForCharacter(character, CollisionGroups.CHARACTERS)
	local prev = _charDescendantConnectionsByUserId[player.UserId]
	if prev then
		prev:Disconnect()
	end
	_charDescendantConnectionsByUserId[player.UserId] = character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			-- Si el char ya ragdollizó cuando llega una part nueva (VFX del
			-- kill effect, p.ej.), tomar el grupo coherente con su estado.
			descendant.CollisionGroup = CollisionGroups.groupForNewPart(character)
		end
	end)
	_registerDeathListener(player, character)
end

local function _bindCharacterTracking(player: Player)
	local old = _characterConnectionsByUserId[player.UserId]
	if old then
		old:Disconnect()
		_characterConnectionsByUserId[player.UserId] = nil
	end

	_characterConnectionsByUserId[player.UserId] = player.CharacterAdded:Connect(function(character)
		_onCharacterAdded(player, character)
	end)

	if player.Character then
		_onCharacterAdded(player, player.Character)
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
	KillAttributionService:EnsureStreakInitialized(player.UserId)
	KillAttributionService:SendStreakBroadcast(player.UserId)

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

			-- Cosméticos de equipo para Resultados: el recién llegado recibe a sus
			-- compañeros y los compañeros se actualizan para incluirlo a él.
			_refreshTeamCosmetics(_teamByUserId[player.UserId])

			-- Snapshot de nivel/tier de BP al entrar (set-if-absent) para computar
			-- los items desbloqueados durante la partida en la pantalla de Resultados.
			MatchResultsService:CaptureMatchStart(player)

			if MatchService.OnPlayerJoinedMatch then
				pcall(MatchService.OnPlayerJoinedMatch, player)
			end
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
	-- Cooldown duro: ReturnToMenu llama LoadCharacter (expensive) + teleport +
	-- rebalance de bots. Sin cap un cliente podría spamearlo entre frames.
	local now = time()
	local last = _returnToMenuCooldownByUserId[player.UserId] or 0
	if now - last < REMOTE_RATE_LIMIT_SECONDS then
		return
	end
	_returnToMenuCooldownByUserId[player.UserId] = now

	_isInMenuByUserId[player.UserId] = true
	_respawnDebounceByUserId[player.UserId] = nil
	_pendingSpawnByUserId[player.UserId] = nil
	KillAttributionService:ResetStreak(player.UserId)
	_rebalanceBotsForCurrentRound("return to menu")
	if _matchKillsByUserId[player.UserId] == nil then
		_matchKillsByUserId[player.UserId] = 0
	end
	KillAttributionService:SendStreakBroadcast(player.UserId)

	local lobbySpawn = _findLobbySpawn()
	if lobbySpawn then
		_teleportCharacterToSpawn(player, lobbySpawn)
	else
		LoadoutService.loadCharacterWithBody(player, _dataService)
	end

	if player.Parent == Players then
		Network.Match.DeathScreenHide.SendTo({}, player)
		Network.Match.ReturnToMenuDone.SendTo({}, player)
		_sendMapLoadStateToPlayer(player)
		_sendRoundStateToPlayer(player)
	end
end

function MatchService:GrantCombatReward(player: Player, actionKey: string, extraUpdates: any?, itemSku: string?)
	if _isMatchCapReached(player.UserId) then
		return false, 0, 0
	end

	local ok, xpGranted, cashGranted = RewardService.Award(player, actionKey, extraUpdates, itemSku)
	if ok then
		_matchCashEarnedByUserId[player.UserId] = (_matchCashEarnedByUserId[player.UserId] or 0) + cashGranted
		_matchXPEarnedByUserId[player.UserId] = (_matchXPEarnedByUserId[player.UserId] or 0) + xpGranted

		-- Asistencias de la partida: las difundimos vía streak para Resultados.
		if actionKey == "Assist" then
			_matchAssistsByUserId[player.UserId] = (_matchAssistsByUserId[player.UserId] or 0) + 1
			KillAttributionService:SendStreakBroadcast(player.UserId)
		end
	end
	return ok, xpGranted, cashGranted
end

function MatchService:GetPlayerKillStreak(playerOrUserId: Player | number): number
	local userId = if typeof(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	return KillAttributionService:GetStreak(userId)
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
		KillAttributionService:InitStreak(player.UserId)
		KillAttributionService:SendStreakBroadcast(player.UserId)
		_bindCharacterTracking(player)
		-- Intentar iniciar votación cuando un nuevo jugador llega (cubre el
		-- caso de servidor vacío donde Start() se ejecutó con 0 players).
		-- task.defer para que el jugador ya esté en Players:GetPlayers().
		task.defer(_startVoteIfPossible)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local wasActiveReal = _isInMenuByUserId[player.UserId] == false
		local wasPendingSpawn = _pendingSpawnByUserId[player.UserId] == true
		-- _voteCooldownsByUserId vive en VotingService:DisconnectPlayer (más abajo).
		_voteSyncCooldownByUserId[player.UserId] = nil
		_returnToMenuCooldownByUserId[player.UserId] = nil
		_isInMenuByUserId[player.UserId] = nil
		_deathAtByUserId[player.UserId] = nil
		_respawnDebounceByUserId[player.UserId] = nil
		_matchKillsByUserId[player.UserId] = nil
		_matchDeathsByUserId[player.UserId] = nil
		_matchAssistsByUserId[player.UserId] = nil
		_recentKillTimestamps[player.UserId] = nil
		KillAttributionService:OnPlayerRemoving(player.UserId)
		_pendingProfileActionsByUserId[player.UserId] = nil
		_roundEndEligibleByUserId[player.UserId] = nil
		_log(string.format("Player removing: %s (%d).", player.Name, player.UserId))
		VotingService:DisconnectPlayer(player.UserId)
		_joinDebounceByUserId[player.UserId] = nil
		_disconnectDeathConnection(player.UserId)

		local charConn = _characterConnectionsByUserId[player.UserId]
		if charConn then
			charConn:Disconnect()
			_characterConnectionsByUserId[player.UserId] = nil
		end

		local charDescConn = _charDescendantConnectionsByUserId[player.UserId]
		if charDescConn then
			charDescConn:Disconnect()
			_charDescendantConnectionsByUserId[player.UserId] = nil
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

	Network.Match.RequestVoteSync.Listen(_onRequestVoteSync)
	Network.Match.RequestJoinMatch.Listen(_onRequestJoinMatch)
	Network.Match.RequestRespawn.Listen(_onRequestRespawn)
	Network.Match.RequestReturnToMenu.Listen(_onRequestReturnToMenu)

	-- KillAttributionService: owns _killStreakByUserId, timeouts, broadcast keys.
	-- Necesita refs a kills/deaths para componer el packet del broadcast.
	KillAttributionService:Start({
		matchKillsByUserId = _matchKillsByUserId,
		matchDeathsByUserId = _matchDeathsByUserId,
		matchAssistsByUserId = _matchAssistsByUserId,
	})

	-- MatchResultsService: VIP cache + snapshots de inicio + recompensas de
	-- fin de partida (cash configurable + items desbloqueados, display-only).
	MatchResultsService:Start({ dataService = _dataService })

	-- VotingService: owns _activeVote, vote cooldowns, vote timer, CastVote
	-- handler. Wire callback `onVoteFinished` que dispara mapload.
	VotingService:Start({
		log = _log,
		setPhase = function(phase: string, reason: string)
			_setPhase(phase, reason)
		end,
		getIsMapLoading = function() return _isMapLoading end,
		getIsPlayEnabled = function() return _isPlayEnabled end,
		onVoteFinished = function(winnerMapName: string)
			_startMapLoadFlow(winnerMapName)
		end,
	})

	-- HealthPickup extraído (Sprint 4 P2 #17). Inyectamos predicates para
	-- que el service no se acople a state interno de MatchService.
	HealthPickupService:Start({
		isRoundActive = function() return _isRoundActive end,
		isPlayerInMenu = function(userId: number): boolean
			return _isInMenuByUserId[userId] == true
		end,
	})

	-- TeamAssignment: pasamos tabla `_teamByUserId` por referencia (el service
	-- escribe asignaciones ahí) y predicates de estado leído.
	TeamAssignmentService:Start({
		teamByUserId = _teamByUserId,
		isInMenuByUserId = _isInMenuByUserId,
		pendingSpawnByUserId = _pendingSpawnByUserId,
		getRoundScoreA = function() return _roundScoreA end,
		getRoundScoreB = function() return _roundScoreB end,
		teamSizeTarget = GameConfig.TeamSizeTarget,
	})

	for _, player in Players:GetPlayers() do
		_isInMenuByUserId[player.UserId] = true
		_deathAtByUserId[player.UserId] = 0
		_matchKillsByUserId[player.UserId] = 0
		KillAttributionService:InitStreak(player.UserId)
		_bindCharacterTracking(player)
	end

	_startVoteIfPossible()
end

return MatchService
