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
local MatchSnapshot = require(Shared:WaitForChild("MatchSnapshot"))
local Network = require(Shared.networking.Network)
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
-- Cooldown duro contra spam de remotes expensive (MatchSync envía streaks +
-- roster; ReturnToMenu hace LoadCharacter).
local REMOTE_RATE_LIMIT_SECONDS = 0.5

-- Forward-declaración: el listener de muerte (_registerDeathListener) llama a este
-- helper, que se define más abajo (depende de _findLobbySpawn/_teleportCharacterToSpawn).
-- Declararlo aquí permite capturarlo como upvalue en el closure de Died.
local _spawnPlayerAtLobby: (player: Player) -> ()

-- Tras morir, el cuerpo del jugador se reubica en el LobbySpawn pasado este margen
-- (deja que el kill effect / ragdoll cosmético se vea un momento). Poner a 0 para
-- reubicar de inmediato (perdería el ragdoll visible).
local DEATH_BODY_TO_LOBBY_DELAY = 3
-- Debounce mínimo entre reapariciones de lobby por jugador (anti-bucle infinito si
-- una muerte en lobby vuelve a disparar el respawn de lobby de inmediato).
local LOBBY_RESPAWN_DEBOUNCE = 2
local MULTIKILL_WINDOW = 4
local PICKUP_ELIGIBILITY_WINDOW = 15
local PICKUP_ELIGIBILITY_MAX_QUEUED = 8

local _activeMapName = ""
local _activeMapContainer: BasePart? = nil
local _activeMapModel: Instance? = nil
-- Caches por-round del mapa activo. Los spawn points y la carpeta de bots no
-- cambian durante un round, así evitamos escanear `_activeMapModel:GetDescendants()`
-- (potencialmente miles de instances) en cada respawn/spawn.
local _cachedSpawnPoints: { BasePart }? = nil
local _cachedBotsFolder: Instance? = nil
local _lastBotRosterJsonBroadcast: string? = nil

local _teamA: Team? = nil
local _teamB: Team? = nil
local _AIService: any = nil
local _dataService: DataService = nil :: any

-- ── PlayerSession ────────────────────────────────────────────
-- TODO el estado por-jugador vive en un único registro por userId: se crea en
-- PlayerAdded, se destruye atómicamente en PlayerRemoving (sin checklist de
-- tablas paralelas que limpiar). Los campos de scope RONDA se resetean en
-- bloque al desmontar la ronda (_resetSessionRoundState); el resto persiste
-- toda la sesión.
type PlayerSession = {
	-- ── scope ronda ──
	team: ("A" | "B")?,
	inMenu: boolean,
	-- Join request en vuelo (de RequestJoinMatch hasta spawn/abort). Hace
	-- también de debounce del handler — el viejo _joinDebounceByUserId era un
	-- duplicado exacto de este flag.
	pendingSpawn: boolean,
	deathAt: number, -- 0 = vivo / sin muerte registrada
	respawnDebounce: boolean,
	-- ── scope sesión ──
	-- Respawn al mapa en curso (desde que se solicita hasta que termina). La
	-- reubicación al lobby por inactividad lo consulta para no pisar un respawn.
	respawning: boolean,
	-- Última reaparición de lobby, para debounce anti-bucle (si el lobby
	-- resultara letal, no encadenar Died→respawn→Died sin freno).
	lobbyRespawnAt: number,
	matchSyncCooldownAt: number,
	returnToMenuCooldownAt: number,
	-- C2: acciones de persistencia diferidas hasta que el profile cargue.
	pendingProfileActions: { () -> () },
	-- Connections del jugador. deathConn/charDescendantConn siguen al character
	-- vivo actual (se re-registran en cada CharacterAdded).
	deathConn: RBXScriptConnection?,
	characterConn: RBXScriptConnection?,
	charDescendantConn: RBXScriptConnection?,
}

local _sessions: { [number]: PlayerSession } = {}

local function _newSession(): PlayerSession
	return {
		team = nil,
		inMenu = true,
		pendingSpawn = false,
		deathAt = 0,
		respawnDebounce = false,
		respawning = false,
		lobbyRespawnAt = 0,
		matchSyncCooldownAt = 0,
		returnToMenuCooldownAt = 0,
		pendingProfileActions = {},
		deathConn = nil,
		characterConn = nil,
		charDescendantConn = nil,
	}
end

-- Resetea los campos de scope ronda de una sesión (parte por-jugador del
-- desmontaje de ronda). Los campos de scope sesión no se tocan.
local function _resetSessionRoundState(session: PlayerSession)
	session.team = nil
	session.inMenu = true
	session.pendingSpawn = false
	session.deathAt = 0
	session.respawnDebounce = false
end

-- true si el jugador está en el menú. Sin sesión (desconectado) cuenta como
-- en-menú: ningún flujo de combate debe actuar sobre él.
local function _isPlayerInMenu(userId: number): boolean
	local session = _sessions[userId]
	return session == nil or session.inMenu
end

-- ── Round ────────────────────────────────────────────────────
-- TODO el estado con scope ronda vive en un objeto creado en _enterInRound y
-- tirado entero al desmontar (_enterResults). No hay "reset" de tablas de
-- ronda: la ronda nueva nace limpia por construcción.
-- Las stats se indexan por userId e INCLUYEN bots (fakeUserIds negativos).
type CombatStats = {
	kills: number,
	deaths: number,
	assists: number,
}

type Round = {
	scoreA: number,
	scoreB: number,
	statsByUserId: { [number]: CombatStats },
	-- Cash/XP concedidos esta ronda (caps por moneda independientes — L14).
	cashEarnedByUserId: { [number]: number },
	xpEarnedByUserId: { [number]: number },
	-- Timestamps de kills recientes (ventana de multikill).
	recentKillTimestampsByUserId: { [number]: { number } },
	-- S2: elegibilidad server-side para health pickups. Los pickups son
	-- puramente client-visuales (PickupDropEffect.luau spawnea el orbe en el
	-- cliente y manda RequestPickup al recogerlo); no hay entidad server que
	-- validar. Para evitar god-mode (spam de RequestPickup → +30 HP cada
	-- 0.2s) registramos una cola de timestamps de kills NO reclamadas: cada
	-- kill humana empuja un timestamp y cada RequestPickup válida consume el
	-- más antiguo dentro de la ventana — nadie se cura más veces de las que
	-- mata. GAP RESIDUAL (documentado): sin entidad server no se puede
	-- verificar que el orbe existió ni la proximidad; el exploit queda
	-- recortado de "ilimitado" a "1 heal por kill real".
	pickupCreditsByUserId: { [number]: { number } },
	-- Última muerte registrada cerca de cada spawn point; SpawnSelector lo usa
	-- para penalizar respawnear donde alguien acaba de morir (anti spawn-trap).
	-- Weak keys: si un spawn point se destruye, el GC libera la entry solo.
	recentDeathBySpawn: { [BasePart]: number },
}

local _round: Round? = nil

local function _newRound(): Round
	return {
		scoreA = 0,
		scoreB = 0,
		statsByUserId = {},
		cashEarnedByUserId = {},
		xpEarnedByUserId = {},
		recentKillTimestampsByUserId = {},
		pickupCreditsByUserId = {},
		recentDeathBySpawn = setmetatable({}, { __mode = "k" }) :: any,
	}
end

-- Stats de combate de `userId` en la ronda activa, creadas lazy. nil si no hay
-- ronda en curso (el caller decide si el path debe no-op).
local function _roundStats(userId: number): CombatStats?
	local round = _round
	if not round then
		return nil
	end
	local stats = round.statsByUserId[userId]
	if not stats then
		stats = { kills = 0, deaths = 0, assists = 0 }
		round.statsByUserId[userId] = stats
	end
	return stats
end

-- Acumula lo concedido esta ronda para los caps por moneda.
local function _trackRoundEarnings(userId: number, cashGranted: number, xpGranted: number)
	local round = _round
	if not round then
		return
	end
	round.cashEarnedByUserId[userId] = (round.cashEarnedByUserId[userId] or 0) + cashGranted
	round.xpEarnedByUserId[userId] = (round.xpEarnedByUserId[userId] or 0) + xpGranted
end

-- Empuja una kill como crédito de pickup consumible. Llamado en ambos paths de
-- kill (PvP y vs bot) sólo para jugadores humanos in-match.
local function _recordPickupEligibility(userId: number)
	local round = _round
	if not round or userId <= 0 then
		return
	end
	local queue = round.pickupCreditsByUserId[userId]
	if not queue then
		queue = {}
		round.pickupCreditsByUserId[userId] = queue
	end
	table.insert(queue, time())
	-- Cap defensivo: nunca acumular más de N créditos pendientes (evita que un
	-- jugador que nunca se cura "ahorre" curaciones para más tarde).
	while #queue > PICKUP_ELIGIBILITY_MAX_QUEUED do
		table.remove(queue, 1)
	end
end

-- Consume (de existir) un crédito de pickup reciente. Devuelve true si había uno
-- dentro de la ventana. Poda timestamps caducados antes de decidir.
local function _consumePickupEligibility(userId: number): boolean
	local round = _round
	local queue = if round then round.pickupCreditsByUserId[userId] else nil
	if not queue then
		return false
	end
	local now = time()
	while #queue > 0 and (now - queue[1]) > PICKUP_ELIGIBILITY_WINDOW do
		table.remove(queue, 1)
	end
	if #queue == 0 then
		return false
	end
	table.remove(queue, 1)
	return true
end

-- ── Máquina de fases ─────────────────────────────────────────
-- Única fuente de verdad del flujo de partida:
--   Idle → Voting → Loading → InRound → Results → Idle
-- `_phase` SOLO muta dentro de las transiciones (_enter*); el resto del código
-- la lee. Los viejos flags sueltos (_isMapLoading / _isPlayEnabled /
-- _isRoundActive) son derivados de la fase.
type Phase = "Idle" | "Voting" | "Loading" | "InRound" | "Results"
local _phase: Phase = "Idle"
-- Bumpeada en cada transición. Los timers de fase (round timer, ventana de
-- Results) la capturan y abortan si hubo una transición debajo (sustituye al
-- viejo _roundId).
local _phaseGeneration = 0

local function _isRoundActive(): boolean
	return _phase == "InRound"
end

-- Forward-decl: el listener de muerte y el round timer disparan el fin de
-- ronda antes de que la transición esté definida (cierra el ciclo del flujo).
local _enterResults: (winnerTeam: string) -> ()

local function _enterIdle()
	_phase = "Idle"
	_phaseGeneration += 1
	MatchSnapshot.set({ MapName = "", PhaseEndsAt = 0, Phase = "Idle" })
end

local function _enterVoting()
	_phase = "Voting"
	_phaseGeneration += 1
	-- StartVote escribe las opciones/votos en el snapshot ANTES de que aquí se
	-- publique la fase — los clientes ven "Voting" con las opciones ya legibles.
	if not VotingService:StartVote() then
		-- Solo pasa con <3 mapas configurados (StartVote ya lo warnea).
		_enterIdle()
		return
	end
	MatchSnapshot.set({
		PhaseEndsAt = MatchSnapshot.now() + GameConfig.VoteDuration,
		Phase = "Voting",
	})
end

-- Idle → Voting. Único punto de arranque de la votación; cualquier disparador
-- (PlayerAdded, RequestMatchSync, fin de la ventana de Results, map-load fail)
-- pasa por aquí y solo actúa en fase Idle.
local function _tryStartVoting()
	if _phase ~= "Idle" then
		return
	end
	if #Players:GetPlayers() < GameConfig.MinPlayersToStart then
		return
	end
	_enterVoting()
end

-- Publica el score actual en el snapshot (los clientes derivan el countdown
-- de PhaseEndsAt localmente — el score es lo único que cambia por kill).
local function _publishScore()
	local round = _round
	if not round then
		return
	end
	MatchSnapshot.set({ ScoreA = round.scoreA, ScoreB = round.scoreB })
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
	local session = _sessions[player.UserId]
	local side = if session then session.team else nil
	if not side or not _dataService then
		return
	end
	local list = {}
	for _, other in Players:GetPlayers() do
		local otherSession = _sessions[other.UserId]
		if other ~= player and otherSession and otherSession.team == side then
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
		local session = _sessions[player.UserId]
		if session and session.team == side then
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
	Cola de acciones diferidas (session.pendingProfileActions) a la espera de
	que el profile cargue. C2: Sin esto, kills/deaths/XP en la window inicial
	(antes de que el profile esté listo) se pierden silenciosamente —
	_dataService:GetProfile() devuelve nil y :Increment/:AddXP/:BatchUpdate
	retornan early.

	Cualquier helper de persistencia llama a _deferUntilProfile(player, fn) si
	el profile aún no está. ProfileLoaded handler hace flush en orden FIFO.
]]
-- Audit mobile: cap por jugador para evitar acumulación si el profile nunca
-- carga (backend caído). El cap drop-oldest mantiene los últimos N, que es lo
-- que más probablemente importa cuando el profile finalmente cargue.
local PROFILE_ACTION_QUEUE_CAP = 50

local function _deferUntilProfile(player: Player, fn: () -> ()): ()
	local session = _sessions[player.UserId]
	if not session then
		return
	end
	local queue = session.pendingProfileActions
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
-- L14 fix: el cap de cash y el de XP son INDEPENDIENTES. Antes esto era un
-- AND-gate (`_isMatchCapReached` exigía AMBOS capados para frenar cualquier
-- grant), así que un jugador capado en una moneda seguía ganando la otra hasta
-- llegar al tope de ambas — y además, una vez capada una, seguía sumando la
-- otra sin límite por moneda. Ahora cada moneda se frena en cuanto ESA llega a
-- su cap; usamos opts.skipCash/skipXP en RewardService.Award para suprimir sólo
-- la moneda capada y dejar pasar la otra.
local function _isCashCapReached(userId: number): boolean
	local round = _round
	local earned = if round then round.cashEarnedByUserId[userId] or 0 else 0
	return earned >= GameConfig.MatchCashCap
end

local function _isXPCapReached(userId: number): boolean
	local round = _round
	local earned = if round then round.xpEarnedByUserId[userId] or 0 else 0
	return earned >= GameConfig.MatchXPCap
end

local function _grantActionRewardsToAttacker(attacker: Player?, action: string, weaponId: string?)
	if not _dataService or not attacker then
		return
	end

	local skipCash = _isCashCapReached(attacker.UserId)
	local skipXP = _isXPCapReached(attacker.UserId)
	-- Si ambas monedas ya están capadas no hay nada que conceder.
	if skipCash and skipXP then
		return
	end

	if not _hasProfile(attacker) then
		_deferUntilProfile(attacker, function()
			_grantActionRewardsToAttacker(attacker, action, weaponId)
		end)
		return
	end

	local ok, xpGranted, cashGranted =
		RewardService.Award(attacker, action, nil, weaponId, { skipCash = skipCash, skipXP = skipXP })
	if ok then
		_trackRoundEarnings(attacker.UserId, cashGranted, xpGranted)
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
	local deadStats = _roundStats(deadPlayer.UserId)
	if deadStats then
		deadStats.deaths += 1
	end
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

	if _isPlayerInMenu(attackerUserId) then
		return
	end

	local attackerStats = _roundStats(attackerUserId)
	if not attackerStats then
		return
	end
	attackerStats.kills += 1

	if attackerStats.kills == 1 and MatchService.OnPlayerFirstKill then
		pcall(MatchService.OnPlayerFirstKill, attacker)
	end

	local newStreak = KillAttributionService:RecordKill(attackerUserId)
	KillAttributionService:SendStreakBroadcast(attackerUserId)
	_registerWeaponKillForAttacker(attackerUserId, attackerWeaponId)
	-- S2: una kill PvP dropea un health pickup client-side; registramos el crédito
	-- para que el RequestPickup correspondiente pueda validarse server-side.
	_recordPickupEligibility(attackerUserId)
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

	local round = _round
	if not round then
		return
	end
	local now = time()
	local timestamps = round.recentKillTimestampsByUserId[attackerUserId]
	if not timestamps then
		timestamps = {}
		round.recentKillTimestampsByUserId[attackerUserId] = timestamps
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
	if not _isRoundActive() or not _AIService then
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

		local candidateSession = _sessions[candidatePlayer.UserId]
		local candidateSide = if candidateSession then candidateSession.team else nil
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
	local session = _sessions[userId]
	if session and session.deathConn then
		session.deathConn:Disconnect()
		session.deathConn = nil
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

	local session = _sessions[player.UserId]
	if not session then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.BreakJointsOnDeath = false

	session.deathConn = humanoid.Died:Connect(function()
		-- Muerte fuera de partida (lobby/menú): el motor no auto-respawnea
		-- (CharacterAutoLoads off), así que devolvemos el cuerpo al LobbySpawn para
		-- que no quede muerto/sin cuerpo. Con debounce: si el lobby resultara letal
		-- o el spawn fallara, no encadenamos Died→respawn→Died sin freno.
		if not _isRoundActive() or session.inMenu then
			task.defer(function()
				if player.Parent ~= Players then
					return
				end
				if not (not _isRoundActive() or session.inMenu) then
					return
				end
				if time() - session.lobbyRespawnAt < LOBBY_RESPAWN_DEBOUNCE then
					return
				end
				session.lobbyRespawnAt = time()
				_spawnPlayerAtLobby(player)
			end)
			return
		end

		local deadSide = session.team
		local round = _round
		if deadSide == nil or not round then
			return
		end

		session.deathAt = time()
		session.respawnDebounce = false

		local deathRoot = character:FindFirstChild("HumanoidRootPart")
		if deathRoot and deathRoot:IsA("BasePart") then
			local nearestSpawn = _findNearestSpawnToPosition(deathRoot.Position)
			if nearestSpawn then
				round.recentDeathBySpawn[nearestSpawn] = time()
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
		if attackerUserId and attackerUserId > 0 and _isPlayerInMenu(attackerUserId) then
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
			round.scoreB += 1
		else
			round.scoreA += 1
		end

		_publishScore()

		if round.scoreA >= GameConfig.WinScoreLimit then
			_enterResults("A")
			return
		elseif round.scoreB >= GameConfig.WinScoreLimit then
			_enterResults("B")
			return
		end

		if player.Parent == Players then
			local killerStats = if attackerUserId then round.statsByUserId[attackerUserId] else nil
			local killerKills = if killerStats then killerStats.kills else 0
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

		-- El cuerpo se reubica al LobbySpawn tras un margen (deja ver el ragdoll del
		-- kill effect). El jugador solo vuelve a partida pulsando spawn (RequestRespawn).
		-- Guardas: cancelar si ya respawneó (deathAt vuelve a 0), murió de nuevo
		-- (deathAt cambia), hay un respawn al mapa en curso, se fue al menú, salió, o
		-- la ronda terminó.
		local deathStamp = session.deathAt
		task.delay(DEATH_BODY_TO_LOBBY_DELAY, function()
			if player.Parent ~= Players or not _isRoundActive() then
				return
			end
			if session.inMenu or session.respawning then
				return
			end
			if session.deathAt ~= deathStamp then
				return
			end
			_spawnPlayerAtLobby(player)
		end)
	end)
end

local function _teleportCharacterToSpawn(player: Player, spawnPoint: BasePart)
	if player.Parent ~= Players then
		return nil
	end

	LoadoutService.loadCharacterWithBody(player, _dataService)
	local character = player.Character or player.CharacterAdded:Wait()
	if player.Parent ~= Players or not character or not character.Parent then
		return nil
	end

	-- player:LoadCharacter() coloca el cuerpo en el spawn por defecto (lobby/origen)
	-- y NOSOTROS lo reposicionamos al mapa. El bug del "vacío": tras un body-swap el
	-- rig puede tardar un instante en estar completo, y leer HumanoidRootPart con
	-- FindFirstChild demasiado pronto devolvía nil → la línea de reposición se
	-- saltaba → el cuerpo se quedaba en el lobby y caía al vacío. WaitForChild con
	-- timeout corto evita esa carrera; si aun así no aparece, el spawn falla limpio.
	local rootInstance = character:FindFirstChild("HumanoidRootPart")
		or character:WaitForChild("HumanoidRootPart", 3)
	if not rootInstance or not rootInstance:IsA("BasePart") then
		return nil
	end
	local root = rootInstance :: BasePart

	-- Anclar mientras reposicionamos para que la física NO arrastre el cuerpo al
	-- vacío durante el/los frames en que todavía está en el spawn por defecto.
	-- Se suelta al final del frame, ya colocado sobre el mapa.
	root.Anchored = true
	root.CFrame = spawnPoint.CFrame + Vector3.new(0, 4, 0)
	task.defer(function()
		if root.Parent then
			root.Anchored = false
		end
	end)

	return character
end

-- [Loadout functions extracted to LoadoutService.luau]

-- LobbySpawn vive directamente bajo Workspace.
local function _findLobbySpawn(): BasePart?
	local direct = Workspace:FindFirstChild("LobbySpawn")
	if direct and direct:IsA("BasePart") then
		return direct
	end

	return nil
end

-- Garantiza un SpawnLocation Neutral+Enabled en el lobby.
--
-- El bug del "vacío al morir": en partida el jugador está en Team A/B
-- (_spawnPlayerOnAssignedTeam hace player.Team = team). Al morir, el auto-respawn
-- del MOTOR busca un SpawnLocation de SU equipo; los spawns del mapa son Part
-- normales (no SpawnLocation) y el del lobby no sirve para Team A/B, así que el
-- motor no encuentra punto válido y aparece en el origen (0,0,0) → el vacío.
--
-- Un SpawnLocation Neutral sirve para CUALQUIER equipo, así que el auto-respawn cae
-- en el lobby en lugar del vacío. Invisible y no-colisionable para no estorbar.
local function _ensureLobbySpawnLocation()
	local lobby = _findLobbySpawn()
	if not lobby then
		warn("[MatchService] Workspace.LobbySpawn no encontrado; el auto-respawn del motor caería al vacío.")
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

-- Coloca al jugador en el lobby de forma controlada: carga su cuerpo y lo teleporta
-- a Workspace.LobbySpawn (sin armas). Con CharacterAutoLoads desactivado, TODO spawn
-- fuera de partida pasa por aquí (join, muerte→lobby, vuelta a menú); el motor nunca
-- respawnea solo, así que nunca cae al vacío. Asigna a la forward-declaración de arriba.
function _spawnPlayerAtLobby(player: Player)
	if player.Parent ~= Players then
		return
	end
	-- En el lobby el jugador es neutral (sin equipo de combate).
	player.Neutral = true
	local lobbySpawn = _findLobbySpawn()
	if lobbySpawn then
		_teleportCharacterToSpawn(player, lobbySpawn)
	else
		LoadoutService.loadCharacterWithBody(player, _dataService)
	end
end

local function _spawnPlayerOnAssignedTeam(player: Player): boolean
	if not _activeMapModel then
		return false
	end

	local session = _sessions[player.UserId]
	local side = if session then session.team else nil
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
	local round = _round
	local chosenSpawn = SpawnSelector.select(spawnPoints, {
		enemyPositions = enemyPositions,
		enemyLookVectors = enemyLookVectors,
		allyPositions = allyPositions,
		recentDeaths = if round then round.recentDeathBySpawn else {},
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

-- Los helpers de votación viven en VotingService; aquí solo wireamos el
-- callback `onVoteFinished`.

-- Clone() no hace yield, así que la carga es síncrona — no hay timeout que
-- aplicar (el viejo _loadMapCloneWithTimeout tenía un watcher de polling que
-- nunca llegaba a correr antes de que el clone terminara).
local function _loadMapClone(mapName: string): (boolean, string)
	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	if not mapsFolder then
		return false, "ServerStorage/Maps no existe"
	end

	local mapTemplate = mapsFolder:FindFirstChild(mapName)
	if not mapTemplate then
		return false, string.format("No existe ServerStorage/Maps/%s", mapName)
	end

	local ok, result = pcall(mapTemplate.Clone, mapTemplate)
	if not ok then
		return false, "Error clonando mapa: " .. tostring(result)
	end

	local container = _ensureActiveMapContainer()
	result.Parent = container
	_activeMapContainer = container
	_activeMapModel = result
	_activeMapName = mapName

	return true, "ok"
end

local function _resolveScoreWinner(): string
	local round = _round
	if not round then
		return "Tie"
	end
	if round.scoreA > round.scoreB then
		return "A"
	elseif round.scoreB > round.scoreA then
		return "B"
	end

	return "Tie"
end

-- Jugadores que estaban en la ronda al terminar (elegibles para recompensas y
-- vuelta al lobby). Devuelve un set local — solo lo consume _enterResults.
local function _captureRoundEndEligiblePlayers(): { [number]: true }
	local eligible: { [number]: true } = {}
	for _, player in Players:GetPlayers() do
		if not _isPlayerInMenu(player.UserId) then
			eligible[player.UserId] = true
		end
	end
	return eligible
end

-- InRound → Results. Reparte recompensas, devuelve a los elegibles al lobby y
-- desmonta la ronda; al expirar la ventana de Resultados pasa a Idle y relanza
-- la votación. La fase Results bloquea cualquier disparador anticipado de voto
-- (_tryStartVoting solo actúa en Idle).
function _enterResults(winnerTeam: string)
	if _phase ~= "InRound" then
		return
	end
	local round = _round
	if not round then
		return
	end
	_phase = "Results"
	_phaseGeneration += 1
	local generation = _phaseGeneration

	local eligibleByUserId = _captureRoundEndEligiblePlayers()
	MatchSnapshot.set({
		PhaseEndsAt = MatchSnapshot.now() + GameConfig.EndResultsDuration,
		Phase = "Results",
	})

	-- Despawnear bots inmediatamente al finalizar la ronda.
	if _AIService then
		_AIService:OnRoundEnd()
	end

	Network.Match.DeathScreenHide.SendToAll({})

	-- ── Recompensas de fin de partida ────────────────────────
	-- MVP = jugador(es) con más kills de SU equipo (kills > 0). Solo players reales.
	local function killsOf(userId: number): number
		local stats = round.statsByUserId[userId]
		return if stats then stats.kills else 0
	end
	local function teamOf(userId: number): ("A" | "B")?
		local session = _sessions[userId]
		return if session then session.team else nil
	end

	local teamMaxKills = { A = 0, B = 0 }
	for userId in eligibleByUserId do
		if userId > 0 then
			local side = teamOf(userId)
			if side then
				local kills = killsOf(userId)
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
	for userId in eligibleByUserId do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end
		local side = teamOf(userId)
		local won = winnerIsTeam and side == winnerTeam
		local maxForSide = if side then teamMaxKills[side] else 0
		local context = {
			won = won,
			lost = not won, -- perder o empatar cuentan como "Defeat"
			isMVP = maxForSide > 0 and killsOf(userId) == maxForSide,
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

	Network.Match.RoundEnded.SendToAll({
		winnerTeam = winnerTeam,
		scoreA = round.scoreA,
		scoreB = round.scoreB,
	})

	-- Daily task: WinMatches — solo jugadores elegibles (que jugaron la ronda)
	-- y que estaban en el equipo ganador. Empate ("Tie") no cuenta.
	-- Persistir Stats.MatchesPlayed para todos los elegibles + Wins/Losses
	-- para el equipo correspondiente.
	-- task.defer para que los N BatchUpdates no compitan por el mismo frame
	-- que el broadcast de RoundEnded; UX percibida más fluida en partidas
	-- llenas (16 BatchUpdates secuenciales = ~16 SetValues).
	local eligibleSnapshot: { number } = {}
	for userId in eligibleByUserId do
		table.insert(eligibleSnapshot, userId)
	end
	local snapshotTeamByUserId: { [number]: string } = {}
	for _, userId in eligibleSnapshot do
		snapshotTeamByUserId[userId] = teamOf(userId) or ""
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
		local session = _sessions[player.UserId]
		if not session or not eligibleByUserId[player.UserId] then
			continue
		end

		session.inMenu = true
		session.respawnDebounce = false
		session.pendingSpawn = false

		if MatchService.OnPlayerMatchCompleted then
			pcall(MatchService.OnPlayerMatchCompleted, player)
		end

		if lobbySpawn then
			_teleportCharacterToSpawn(player, lobbySpawn)
		else
			LoadoutService.loadCharacterWithBody(player, _dataService)
		end

		if player.Parent == Players and MatchService.OnPlayerReturnedToLobby then
			pcall(MatchService.OnPlayerReturnedToLobby, player)
		end
	end

	-- Desmontar la ronda: mapa, listeners de muerte, campos de scope ronda de
	-- las sesiones y el objeto Round entero (no hay tablas que "limpiar": la
	-- siguiente ronda nace en un objeto nuevo).
	_clearActiveMap()
	for _, session in _sessions do
		if session.deathConn then
			session.deathConn:Disconnect()
			session.deathConn = nil
		end
		_resetSessionRoundState(session)
	end
	_round = nil
	-- Streak state (counts + timeouts + dedupe keys) vive en KillAttributionService.
	KillAttributionService:Clear()
	-- Snapshots de inicio de partida (nivel/tier BP) para los items de Resultados.
	MatchResultsService:ClearSnapshots()
	_lastBotRosterJsonBroadcast = nil

	-- La votación no arranca hasta que termina la pantalla de Resultados.
	task.delay(GameConfig.EndResultsDuration, function()
		if _phaseGeneration ~= generation then
			return
		end
		_enterIdle()
		_tryStartVoting()
	end)
end

-- Handler de muerte de un bot de IA. Extraído del callback inline en
-- _AIService:OnRoundStart para que la lógica de kill attribution / score / win
-- check no esté embebida dentro del round-start flow. Llamado por AIService
-- cuando un bot muere — toca state interno de MatchService (scoreA/B, streaks,
-- match kills/deaths) y dispara broadcasts.
local function _handleBotDied(botTeam: string, _botName: string, botHumanoid: Humanoid, botFakeUserId: number)
	local round = _round
	if not _isRoundActive() or not round then
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
	-- H5 fix: NO descartamos al atacante por estar en el menú. La ventana
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
		local attackerStats = _roundStats(attackerUserId)
		if attackerStats then
			attackerStats.kills += 1
		end
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
				-- S2: una kill vs bot también dropea un health pickup client-side;
				-- registramos el crédito igual que en el path PvP para que el
				-- RequestPickup correspondiente pueda validarse server-side.
				_recordPickupEligibility(attackerUserId)
				-- C1 fix: persistir Stats.Kills/Headshots/KillStreakBest lifetime
				-- también para kills vs bots. Antes el path PvE solo
				-- actualizaba contadores en memoria.
				_persistAttackerKillStats(attackerPlayer, attackerWasHeadshot, newStreak)
			end
		end
		KillAttributionService:SendStreakBroadcast(attackerUserId)
	end

	-- Los bots no usan streak: solo contabilizar kills/deaths para HUD.
	local botStats = _roundStats(botFakeUserId)
	if botStats then
		botStats.deaths += 1
	end
	_sendPlayerStreakToAll(botFakeUserId)

	-- Sumar score al equipo contrario (igual que cuando muere un jugador)
	if botTeam == "A" then
		round.scoreB += 1
	else
		round.scoreA += 1
	end

	_publishScore()
	_rebalanceBotsForCurrentRound("bot death")

	if round.scoreA >= GameConfig.WinScoreLimit then
		_enterResults("A")
	elseif round.scoreB >= GameConfig.WinScoreLimit then
		_enterResults("B")
	end
end

-- Loading → InRound. Resetea el estado de ronda, arranca bots y el round timer.
-- La generación se bumpea ANTES de cualquier task.spawn que la capture: si un
-- callback termina la ronda en el mismo frame, el guard del timer lo detecta.
local function _enterInRound()
	-- El Round nuevo nace ANTES de publicar la fase: phase == "InRound" implica
	-- _round ~= nil para todo el código que corre debajo. Las sesiones ya están
	-- limpias (reset en el desmontaje de Results; los joiners nacen limpios).
	_round = _newRound()
	_phase = "InRound"
	_phaseGeneration += 1
	local generation = _phaseGeneration
	-- Streaks a 0 para los players actuales + broadcast (UI sync). Kills/deaths
	-- arrancan en 0 implícitamente (stats lazy del Round nuevo).
	for _, player in Players:GetPlayers() do
		KillAttributionService:InitStreak(player.UserId)
		KillAttributionService:SendStreakBroadcast(player.UserId)
	end
	MatchSnapshot.set({
		ScoreA = 0,
		ScoreB = 0,
		PhaseEndsAt = MatchSnapshot.now() + GameConfig.MaxRoundDuration,
		Phase = "InRound",
	})

	if _AIService then
		local sharedSpawnPoints = _collectSharedSpawnPoints(_activeMapModel :: Instance)
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

	-- Fin de ronda por tiempo: un único delay con guard de generación (el
	-- countdown visible lo computa cada cliente desde PhaseEndsAt).
	task.delay(GameConfig.MaxRoundDuration, function()
		if _phase == "InRound" and _phaseGeneration == generation then
			_enterResults(_resolveScoreWinner())
		end
	end)
end

-- Voting → Loading. Clona el mapa ganador; si falla vuelve a Idle y relanza
-- la votación.
local function _enterLoading(winnerMapName: string)
	_phase = "Loading"
	_phaseGeneration += 1
	_activeMapName = winnerMapName
	_lastBotRosterJsonBroadcast = nil
	MatchSnapshot.set({ MapName = winnerMapName, PhaseEndsAt = 0, Phase = "Loading" })

	local success, reason = _loadMapClone(winnerMapName)
	if not success then
		warn("[MatchService] Error loading map:", reason)
		_activeMapName = ""
		_enterIdle()
		_tryStartVoting()
		return
	end

	_enterInRound()
end

-- Sync inicial para un cliente recién cargado: estado event-driven (streaks de
-- todos + roster de bots). El estado ambiental (fase/voto/score) viaja por
-- MatchSnapshot y no necesita resync.
local function _onRequestMatchSync(_: {}, player: Player)
	local session = _sessions[player.UserId]
	if not session then
		return
	end
	local now = time()
	if now - session.matchSyncCooldownAt < REMOTE_RATE_LIMIT_SECONDS then
		return
	end
	session.matchSyncCooldownAt = now

	_tryStartVoting()
	_sendAllPlayerStreaksToPlayer(player)
	_sendBotRosterToPlayer(player)
end

local function _onCharacterAdded(player: Player, character: Model)
	-- Asignar al grupo CHARACTERS para que jugadores vivos no colisionen con
	-- cadáveres (ragdolls están en RAGDOLL via los kill effects). Snapshot
	-- inmediato + DescendantAdded por si accesorios/tools cargan tarde.
	-- Trackeamos la connection por userId para desconectarla en el siguiente
	-- respawn / muerte / salida — el character viejo puede seguir parented por
	-- ragdoll/kill effects hasta el GC, lo que acumularía listeners.
	CollisionGroups.setGroupForCharacter(character, CollisionGroups.CHARACTERS)
	local session = _sessions[player.UserId]
	if not session then
		return
	end
	if session.charDescendantConn then
		session.charDescendantConn:Disconnect()
	end
	session.charDescendantConn = character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			-- Si el char ya ragdollizó cuando llega una part nueva (VFX del
			-- kill effect, p.ej.), tomar el grupo coherente con su estado.
			descendant.CollisionGroup = CollisionGroups.groupForNewPart(character)
		end
	end)
	_registerDeathListener(player, character)
end

local function _bindCharacterTracking(player: Player)
	local session = _sessions[player.UserId]
	if not session then
		return
	end
	if session.characterConn then
		session.characterConn:Disconnect()
	end
	session.characterConn = player.CharacterAdded:Connect(function(character)
		_onCharacterAdded(player, character)
	end)

	if player.Character then
		_onCharacterAdded(player, player.Character)
	end
end

-- Crea la sesión del jugador al entrar (o al arrancar el servicio con jugadores
-- ya presentes) y wirea su tracking de character. ÚNICO punto de creación de
-- sesiones.
local function _initJoinedPlayerState(player: Player)
	_sessions[player.UserId] = _newSession()
	KillAttributionService:InitStreak(player.UserId)
	KillAttributionService:SendStreakBroadcast(player.UserId)
	_bindCharacterTracking(player)
end

local function _onRequestJoinMatch(_: {}, player: Player)
	if _phase ~= "InRound" or not _activeMapModel then
		return
	end

	local session = _sessions[player.UserId]
	if not session or session.pendingSpawn then
		return
	end

	local selectedSide = _pickBalancedTeam(player.UserId)
	if not selectedSide then
		session.inMenu = true
		return
	end

	session.pendingSpawn = true
	session.inMenu = false
	_rebalanceBotsForCurrentRound("join request")
	KillAttributionService:EnsureStreakInitialized(player.UserId)
	KillAttributionService:SendStreakBroadcast(player.UserId)

	task.defer(function()
		if player.Parent ~= Players then
			session.pendingSpawn = false
			return
		end

		-- Si la ronda terminó entre el RequestJoinMatch y este defer, abortamos
		-- para no spawnear al jugador en una ronda terminada (causa desync de phase).
		if not _isRoundActive() then
			session.inMenu = true
			session.pendingSpawn = false
			return
		end

		local team = if session.team == "A" then _teamA else _teamB
		if not team then
			warn("[MatchService] Teams no inicializados.")
			session.inMenu = true
			session.pendingSpawn = false
			_rebalanceBotsForCurrentRound("join aborted missing team")
			return
		end

		if not _spawnPlayerOnAssignedTeam(player) then
			warn("[MatchService] No fue posible spawnear al jugador en su equipo.")
			session.inMenu = true
			session.pendingSpawn = false
			_rebalanceBotsForCurrentRound("join spawn failed")
			return
		end

		session.pendingSpawn = false
		session.deathAt = 0
		Network.Match.DeathScreenHide.SendTo({}, player)

		-- Daily task: PlayMatches (cuenta una vez por entrada al match).
		pcall(function()
			DailyTasksService:OnMatchPlayed(player)
		end)

		if player.Parent == Players then
			Network.Match.JoinMatchSpawned.SendTo({}, player)

			-- Cosméticos de equipo para Resultados: el recién llegado recibe a sus
			-- compañeros y los compañeros se actualizan para incluirlo a él.
			_refreshTeamCosmetics(session.team)

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
	local session = _sessions[player.UserId]
	if not session or not _isRoundActive() or session.inMenu then
		return
	end

	if session.respawnDebounce then
		return
	end

	local deathAt = session.deathAt
	-- S5: enforce the full respawn cooldown server-side (was client-only via the
	-- death screen bar — a modified client could respawn every 0.5s). Si conocemos
	-- el momento de la muerte (deathAt > 0), exigimos GameConfig.RespawnCooldown
	-- completo. Si no lo conocemos (deathAt == 0: arranque, edge cases), caemos al
	-- floor anti-spam de 0.5s como fallback.
	if deathAt > 0 then
		if time() - deathAt < GameConfig.RespawnCooldown then
			return
		end
	elseif time() - deathAt < 0.5 then
		return
	end

	session.respawnDebounce = true
	-- Marcamos "respawn al mapa en curso" de forma SÍNCRONA (antes del defer), para
	-- que la reubicación al lobby por inactividad lo vea en cuanto se pulsa spawn y
	-- no mande al jugador al lobby en vez de a la partida (carrera #1).
	session.respawning = true
	task.defer(function()
		session.respawnDebounce = false

		-- Reintento defensivo: al acabar la votación, jugadores y bots respawnean
		-- a la vez y el body-swap puede fallar puntualmente (contención del lock,
		-- rig a medio construir). Sin reintento, un fallo dejaba al jugador muerto
		-- o cayendo al vacío. Reintentamos unas pocas veces con pausa corta.
		local spawned = false
		for _ = 1, 3 do
			if player.Parent ~= Players or not _isRoundActive() or session.inMenu then
				break
			end
			if _spawnPlayerOnAssignedTeam(player) then
				spawned = true
				break
			end
			task.wait(0.15)
		end

		session.respawning = false

		if spawned then
			session.deathAt = 0
			Network.Match.DeathScreenHide.SendTo({}, player)
		end
	end)
end

-- HealthPickup logic extraída a HealthPickupService.luau (Sprint 4 P2 #17).
-- Se inicia desde MatchService:Start con predicates inyectados — ver allá.

local function _onRequestReturnToMenu(_: {}, player: Player)
	local session = _sessions[player.UserId]
	if not session then
		return
	end
	-- Cooldown duro: ReturnToMenu llama LoadCharacter (expensive) + teleport +
	-- rebalance de bots. Sin cap un cliente podría spamearlo entre frames.
	local now = time()
	if now - session.returnToMenuCooldownAt < REMOTE_RATE_LIMIT_SECONDS then
		return
	end
	session.returnToMenuCooldownAt = now

	session.inMenu = true
	session.respawnDebounce = false
	session.pendingSpawn = false
	KillAttributionService:ResetStreak(player.UserId)
	_rebalanceBotsForCurrentRound("return to menu")
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
	end
end

function MatchService:GrantCombatReward(player: Player, actionKey: string, extraUpdates: any?, itemSku: string?)
	-- L14: cap por moneda independiente. Si ambas monedas están capadas pero NO
	-- hay extraUpdates (que deben aplicarse igualmente, p. ej. Stats.Assists),
	-- podemos cortar temprano. Si hay extraUpdates seguimos al Award con ambas
	-- monedas suprimidas para persistirlos.
	local skipCash = _isCashCapReached(player.UserId)
	local skipXP = _isXPCapReached(player.UserId)
	if skipCash and skipXP and extraUpdates == nil then
		return false, 0, 0
	end

	local ok, xpGranted, cashGranted =
		RewardService.Award(player, actionKey, extraUpdates, itemSku, { skipCash = skipCash, skipXP = skipXP })
	if ok then
		_trackRoundEarnings(player.UserId, cashGranted, xpGranted)

		-- Asistencias de la partida: las difundimos vía streak para Resultados.
		if actionKey == "Assist" then
			local stats = _roundStats(player.UserId)
			if stats then
				stats.assists += 1
				KillAttributionService:SendStreakBroadcast(player.UserId)
			end
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
		return
	end

	_dataService = dataService

	_started = true

	-- Crea el folder replicado del snapshot con su estado inicial (los clientes
	-- hacen WaitForChild sobre él al arrancar su feature de match).
	MatchSnapshot.set({ Phase = "Idle" })

	-- Control total del spawn: el motor NO auto-respawnea (ni en join ni al morir),
	-- así nunca suelta al jugador en el vacío. Todo spawn pasa por código:
	--  · join / vuelta a menú / muerte → _spawnPlayerAtLobby (LobbySpawn)
	--  · pulsar spawn en partida        → _spawnPlayerOnAssignedTeam (spawn del mapa)
	Players.CharacterAutoLoads = false

	_ensureTeams()
	-- Red de seguridad: SpawnLocation Neutral en el lobby por si algún LoadCharacter
	-- sin reposicionar (o un auto-respawn que se cuele antes de Start) necesita un
	-- punto válido — evita el origen (0,0,0).
	_ensureLobbySpawnLocation()

	-- Cargar AIService (require lazy para evitar dependencia circular).
	-- Con Rojo, la carpeta Server/AI (con su init.luau) se compila directamente
	-- como ModuleScript: Server.AI ES el módulo.
	local serverRoot = ServerScriptService:FindFirstChild("Server")
	local aiModule = if serverRoot then serverRoot:FindFirstChild("AI") else nil
	if aiModule and aiModule:IsA("ModuleScript") then
		local ok, result = pcall(require, aiModule)
		if ok then
			_AIService = result
			if _AIService.SetDataService then
				_AIService:SetDataService(_dataService)
			end
		else
			warn("[MatchService] Failed to load AIService: " .. tostring(result))
		end
	else
		warn("[MatchService] Server.AI module not found (bots will not spawn)")
	end

	-- C2: flush de acciones diferidas cuando el profile termine de cargar.
	-- Hooks compatibles tanto con Signal-style (ProfileLoaded) como con
	-- BindableEvent.Event. Si DataService no expone la signal, se ignora —
	-- el código sigue funcionando con la pérdida silenciosa preexistente.
	if _dataService and _dataService.ProfileLoaded then
		_dataService.ProfileLoaded:Connect(function(player: Player)
			local session = _sessions[player.UserId]
			if not session or #session.pendingProfileActions == 0 then
				return
			end
			local queue = session.pendingProfileActions
			session.pendingProfileActions = {}
			for _, fn in queue do
				local ok, err = pcall(fn)
				if not ok then
					warn("[MatchService] Pending profile action error:", err)
				end
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		local session = _sessions[userId]
		local wasActiveOrPending = session ~= nil
			and (session.inMenu == false or session.pendingSpawn)

		-- Destrucción atómica de la sesión (connections incluidas).
		if session then
			if session.deathConn then
				session.deathConn:Disconnect()
			end
			if session.characterConn then
				session.characterConn:Disconnect()
			end
			if session.charDescendantConn then
				session.charDescendantConn:Disconnect()
			end
		end
		_sessions[userId] = nil

		-- Entradas del jugador en la ronda activa (las de bots permanecen).
		local round = _round
		if round then
			round.statsByUserId[userId] = nil
			round.cashEarnedByUserId[userId] = nil
			round.xpEarnedByUserId[userId] = nil
			round.recentKillTimestampsByUserId[userId] = nil
			round.pickupCreditsByUserId[userId] = nil
		end

		KillAttributionService:OnPlayerRemoving(userId)
		VotingService:DisconnectPlayer(userId)

		if _isRoundActive() and wasActiveOrPending then
			_rebalanceBotsForCurrentRound("player leaving")
		end
	end)

	Network.Match.RequestMatchSync.Listen(_onRequestMatchSync)
	Network.Match.RequestJoinMatch.Listen(_onRequestJoinMatch)
	Network.Match.RequestRespawn.Listen(_onRequestRespawn)
	Network.Match.RequestReturnToMenu.Listen(_onRequestReturnToMenu)

	-- KillAttributionService: owns streaks, timeouts y dedupe keys. Lee los
	-- stats de combate de la ronda activa vía getters (0s entre rondas).
	KillAttributionService:Start({
		getCombatStats = function(userId: number): (number, number, number)
			local round = _round
			local stats = if round then round.statsByUserId[userId] else nil
			if not stats then
				return 0, 0, 0
			end
			return stats.kills, stats.deaths, stats.assists
		end,
		getActiveBotUserIds = function(): { number }
			local ids: { number } = {}
			local round = _round
			if round then
				for userId in round.statsByUserId do
					if userId < 0 then
						table.insert(ids, userId)
					end
				end
			end
			return ids
		end,
	})

	-- MatchResultsService: VIP cache + snapshots de inicio + recompensas de
	-- fin de partida (cash configurable + items desbloqueados, display-only).
	MatchResultsService:Start({ dataService = _dataService })

	-- VotingService: owns _activeVote, vote cooldowns, vote timer, CastVote
	-- handler. Al cerrar la votación transicionamos a Loading.
	VotingService:Start({
		onVoteFinished = function(winnerMapName: string)
			if _phase ~= "Voting" then
				return
			end
			_enterLoading(winnerMapName)
		end,
	})

	-- HealthPickup extraído (Sprint 4 P2 #17). Inyectamos predicates para
	-- que el service no se acople a state interno de MatchService.
	HealthPickupService:Start({
		isRoundActive = _isRoundActive,
		isPlayerInMenu = _isPlayerInMenu,
		-- S2: el service consume un crédito de kill reciente por heal — ver
		-- _consumePickupEligibility / _recordPickupEligibility.
		consumePickupEligibility = function(userId: number): boolean
			return _consumePickupEligibility(userId)
		end,
	})

	-- TeamAssignment: lee team/inMenu/pendingSpawn de las sesiones (y escribe
	-- `team` al asignar — es el dueño de la asignación). El cast evita la
	-- invarianza del diccionario: PlayerSession ⊃ SessionView estructuralmente.
	TeamAssignmentService:Start({
		sessions = _sessions :: any,
		getRoundScoreA = function()
			return if _round then _round.scoreA else 0
		end,
		getRoundScoreB = function()
			return if _round then _round.scoreB else 0
		end,
		teamSizeTarget = GameConfig.TeamSizeTarget,
	})

	-- Wiring de jugadores DESPUÉS de los Start de services: la creación de
	-- sesión hace broadcast de streaks, que necesita los deps ya inyectados.
	Players.PlayerAdded:Connect(function(player)
		_initJoinedPlayerState(player)
		-- Spawn inicial en el lobby por código (CharacterAutoLoads está desactivado,
		-- el motor no spawnea solo). task.defer para no bloquear el flujo de join.
		task.defer(function()
			_spawnPlayerAtLobby(player)
		end)
		-- Intentar iniciar votación cuando un nuevo jugador llega (cubre el
		-- caso de servidor vacío donde Start() se ejecutó con 0 players).
		-- task.defer para que el jugador ya esté en Players:GetPlayers().
		task.defer(_tryStartVoting)
	end)

	-- Jugadores ya presentes cuando arranca el servicio (Start tras un join):
	-- misma init que PlayerAdded + su cuerpo de lobby, ya que el motor no lo hará.
	for _, player in Players:GetPlayers() do
		_initJoinedPlayerState(player)
		task.defer(function()
			_spawnPlayerAtLobby(player)
		end)
	end

	_tryStartVoting()
end

return MatchService
