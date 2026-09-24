--!strict

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
local SpawnService = require(script.Parent:WaitForChild("SpawnService"))
local HealthPickupService = require(script.Parent:WaitForChild("HealthPickupService"))
local TeamAssignmentService = require(script.Parent:WaitForChild("TeamAssignmentService"))
local VotingService = require(script.Parent:WaitForChild("VotingService"))
local KillAttributionService = require(script.Parent:WaitForChild("KillAttributionService"))
local KillRewardsService = require(script.Parent:WaitForChild("KillRewardsService"))
local MatchResultsService = require(script.Parent:WaitForChild("MatchResultsService"))
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local CollisionGroups = require(Shared.CollisionGroups)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local InventoryRepository = require(Shared.data.InventoryRepository)
local ClientBootStage = require(Shared.constants.ClientBootStage)
local DailyTasksService = require(script.Parent.Parent.dailyTasks.DailyTasksService)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
local RewardService = require(script.Parent.Parent.Parent.core.RewardService)
local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)
type DataService = DataServiceMod.DataServiceModule

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

-- Tras morir, el cuerpo se reubica en el LobbySpawn pasado este margen para que el
-- kill effect / ragdoll se vea completo. Solo si no respawnea antes (guard de deathStamp).
local DEATH_BODY_TO_LOBBY_DELAY = 4.5
-- Debounce mínimo entre reapariciones de lobby por jugador (anti-bucle infinito si
-- una muerte en lobby vuelve a disparar el respawn de lobby de inmediato).
local LOBBY_RESPAWN_DEBOUNCE = 2
-- Espera a Died tras Health = 0 antes de contar la muerte igualmente. El estado Dead lo
-- decide el cliente dueño del personaje (llega ~1 ping tarde) y uno que lo desactiva
-- no dispararía Died nunca: ni kill para el asesino ni punto para el rival.
local DIED_FALLBACK_GRACE = 1.5
-- Part de Workspace donde aparecen TODOS los mapas: el pivot del modelo del mapa
-- se coloca en su CFrame al cargar. Sin ella, el mapa se queda donde se autoró.
local MAP_ANCHOR_NAME = "MapAnchor"

local _activeMapName = ""
local _activeMapContainer: BasePart? = nil
local _activeMapModel: Instance? = nil
local _lastBotRosterJsonBroadcast: string? = nil

local _teamA: Team? = nil
local _teamB: Team? = nil
local _AIService: any = nil
local _dataService: DataService = nil :: any

-- Estado por-jugador: un único registro por userId, creado en PlayerAdded y destruido
-- atómicamente en PlayerRemoving. Los campos de scope RONDA se resetean en bloque al
-- desmontar la ronda (_resetSessionRoundState); el resto persiste toda la sesión.
type DeathListener = { Disconnect: (self: DeathListener) -> () }

type PlayerSession = {
	-- Scope ronda (hasta respawnDebounce, lo resetea _resetSessionRoundState).
	team: ("A" | "B")?,
	inMenu: boolean,
	-- Join request en vuelo (de RequestJoinMatch hasta spawn/abort); también hace
	-- de debounce del handler.
	pendingSpawn: boolean,
	deathAt: number, -- 0 = vivo / sin muerte registrada
	respawnDebounce: boolean,
	-- Scope sesión desde aquí.
	-- Respawn al mapa en curso (desde que se solicita hasta que termina). La
	-- reubicación al lobby por inactividad lo consulta para no pisar un respawn.
	respawning: boolean,
	-- Última reaparición de lobby, para debounce anti-bucle (si el lobby
	-- resultara letal, no encadenar Died→respawn→Died sin freno).
	lobbyRespawnAt: number,
	matchSyncCooldownAt: number,
	returnToMenuCooldownAt: number,
	-- Handshake de join (informativo, no gatea el spawn): true cuando llegó el
	-- primer ClientReady. joinedAt (time()) mide cuánto tardó el cliente.
	clientReady: boolean,
	joinedAt: number,
	-- Acciones de persistencia diferidas hasta que el profile cargue.
	pendingProfileActions: { () -> () },
	-- Connections del jugador. deathConn/charDescendantConn siguen al character
	-- vivo actual (se re-registran en cada CharacterAdded).
	deathConn: DeathListener?,
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
		clientReady = false,
		joinedAt = time(),
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

-- Estado de ronda: objeto creado en _enterInRound y tirado entero al desmontar
-- (_enterResults); la ronda nueva nace limpia por construcción.
-- Las stats se indexan por userId e INCLUYEN bots (fakeUserIds negativos).
type CombatStats = KillRewardsService.CombatStats

type Round = {
	-- Id de la partida, compartido por todas las series que la describen: MATCH_END,
	-- la votación que eligió su mapa y los bonus de fin de partida.
	matchId: string,
	-- os.time() del arranque. Solo telemetría: distinguir fin por marcador de fin
	-- por MaxRoundDuration.
	startedAt: number,
	scoreA: number,
	scoreB: number,
	statsByUserId: { [number]: CombatStats },
	-- Cash/XP concedidos esta ronda (caps por moneda independientes). PlayerRemoving NO
	-- los borra: salir y volver a entrar reiniciaría el cap.
	cashEarnedByUserId: { [number]: number },
	xpEarnedByUserId: { [number]: number },
	-- XP de PASE concedido esta ronda. Cupo aparte del de cuenta: headshots y asistencias
	-- llenan el de cuenta antes y, compartido, recortarían el pase a quien mejor apunta.
	bpXpEarnedByUserId: { [number]: number },
	-- os.time() de la PRIMERA entrada de cada jugador a esta ronda (set-if-absent): de
	-- aquí arranca su cap, para que quien entra tarde no herede el cupo acumulado.
	-- Tampoco se borra en PlayerRemoving.
	firstJoinAtByUserId: { [number]: number },
	-- Segundos EN PARTIDA (fuera del menú) ya acumulados y, mientras está dentro, desde
	-- cuándo. Gatean y escalan los bonus de fin de partida.
	inMatchSecondsByUserId: { [number]: number },
	inMatchSinceByUserId: { [number]: number },
	-- Tramos abiertos por jugador esta ronda (1 = entró y se quedó). Solo telemetría:
	-- la alerta de reentradas del ingest salta por encima de dos.
	entriesByUserId: { [number]: number },
	-- Timestamps de kills recientes (ventana de multikill).
	recentKillTimestampsByUserId: { [number]: { number } },
	-- Elegibilidad server-side de health pickups. Los pickups son solo visuales en el
	-- cliente (PickupDropEffect manda RequestPickup), sin entidad server: cada kill
	-- humana encola un timestamp y cada RequestPickup válida consume el más antiguo
	-- dentro de la ventana, así nadie se cura más veces de las que mata. No se puede
	-- verificar que el orbe existiera ni la proximidad.
	pickupCreditsByUserId: { [number]: { number } },
	-- Última muerte registrada cerca de cada spawn point; SpawnSelector lo usa
	-- para penalizar respawnear donde alguien acaba de morir (anti spawn-trap).
	-- Weak keys: si un spawn point se destruye, el GC libera la entry solo.
	recentDeathBySpawn: { [BasePart]: number },
}

local _round: Round? = nil

--[[
	El matchId se acuña al abrir la votación, no al crear la ronda: el MAP_VOTE
	tiene que llevar el mismo id que el MATCH_END que llegará después.
]]
local _pendingMatchId = ""

local function _newMatchId(): string
	local ok, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	return if ok and type(guid) == "string" then guid else tostring(os.clock())
end

local function _newRound(): Round
	local matchId = if _pendingMatchId ~= "" then _pendingMatchId else _newMatchId()
	_pendingMatchId = ""
	return {
		matchId = matchId,
		startedAt = os.time(),
		scoreA = 0,
		scoreB = 0,
		statsByUserId = {},
		cashEarnedByUserId = {},
		xpEarnedByUserId = {},
		bpXpEarnedByUserId = {},
		firstJoinAtByUserId = {},
		inMatchSecondsByUserId = {},
		inMatchSinceByUserId = {},
		entriesByUserId = {},
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

-- Entrada del jugador a la partida dentro de la ronda activa (spawn conseguido). La
-- primera fija el arranque de su cap; todas abren un tramo de tiempo en partida.
local function _markEnteredMatch(userId: number)
	local round = _round
	if not round then
		return
	end
	local now = os.time()
	if round.firstJoinAtByUserId[userId] == nil then
		round.firstJoinAtByUserId[userId] = now
	end
	if round.inMatchSinceByUserId[userId] == nil then
		round.inMatchSinceByUserId[userId] = now
		round.entriesByUserId[userId] = (round.entriesByUserId[userId] or 0) + 1
	end
end

-- Contrato con MatchHud (cliente): atributo de Player "MatchSide" = bando mientras el
-- jugador está EN PARTIDA, aunque esté muerto y con Team=nil (SpawnAtLobby). No usar
-- "TeamName": TeamUtils.getSide lo lee y los bots apuntarían al cuerpo del lobby.
local function _setMatchSide(player: Player, side: ("A" | "B")?)
	player:SetAttribute("MatchSide", side)
end

-- Salida de la partida (vuelta al menú o desconexión): cierra el tramo abierto.
local function _markLeftMatch(userId: number)
	local round = _round
	if not round then
		return
	end
	local since = round.inMatchSinceByUserId[userId]
	if since then
		round.inMatchSecondsByUserId[userId] = (round.inMatchSecondsByUserId[userId] or 0) + math.max(0, os.time() - since)
		round.inMatchSinceByUserId[userId] = nil
	end
end

-- Segundos que el jugador lleva EN PARTIDA esta ronda, con el tramo abierto incluido.
local function _inMatchSeconds(round: Round, userId: number): number
	local since = round.inMatchSinceByUserId[userId]
	local open = if since then math.max(0, os.time() - since) else 0
	return (round.inMatchSecondsByUserId[userId] or 0) + open
end

-- Máquina de fases, única fuente de verdad del flujo de partida:
--   Idle → Voting → Loading → InRound → Results → Idle
-- `_phase` SOLO muta dentro de las transiciones (_enter*); el resto la lee.
type Phase = "Idle" | "Voting" | "Loading" | "InRound" | "Results"
local _phase: Phase = "Idle"
-- Bumpeada en cada transición. Los timers de fase (round timer, ventana de
-- Results) la capturan y abortan si hubo una transición debajo.
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
	-- La partida empieza aquí a efectos de telemetría: el MAP_VOTE que sale de
	-- esta votación y el MATCH_END de la ronda que decida llevan este mismo id.
	_pendingMatchId = _newMatchId()
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

	-- Precalentar los pools de rigs de bots durante la votación (~1 clone/frame),
	-- para que el spawn de inicio de ronda no pague clones síncronos.
	if _AIService and _AIService.PrewarmRigPools then
		pcall(function()
			_AIService:PrewarmRigPools()
		end)
	end
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

-- Delegan en KillAttributionService (broadcast de stats de combate con dedupe). El
-- packet se llama "Streak" pero lleva stats de combate, no rachas.
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

--[[
	Acciones diferidas (session.pendingProfileActions) hasta que cargue el profile:
	sin esto, kills/deaths/XP antes de que esté listo se perderían (GetProfile
	devuelve nil). ProfileLoaded hace flush FIFO. Cap por jugador (drop-oldest)
	por si el profile no carga nunca.
]]
local PROFILE_ACTION_QUEUE_CAP = 50

local function _deferUntilProfile(player: Player, fn: () -> ()): ()
	local session = _sessions[player.UserId]
	if not session then
		return
	end
	local queue = session.pendingProfileActions
	if #queue >= PROFILE_ACTION_QUEUE_CAP then
		table.remove(queue, 1)
	end
	table.insert(queue, fn)
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

-- Coalesce los rebalanceos del mismo frame: kill chains y joins/leaves simultáneos
-- harían SetBotTargets + roster por evento.
local _rebalancePending = false
local _rebalanceLastReason: string? = nil

local function _doRebalanceNow(reason: string)
	if not _isRoundActive() or not _AIService then
		return
	end

	local realA, realB = TeamAssignmentService:CountActiveRealAssignments()
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

-- Banner que pinta la tarjeta de muerte de quien cae a manos de este perfil. Se
-- revalida catálogo y posesión: un Loadout.Banner que ya no existe (ítem retirado)
-- o que no se posee cae al Default en vez de mandar un id que el cliente no sabe
-- pintar.
local function _resolveEquippedBanner(profileData: any): string
	local loadout = if type(profileData) == "table" then profileData.Loadout else nil
	local bannerId = if type(loadout) == "table" then loadout.Banner else nil
	if type(bannerId) ~= "string" or bannerId == "" or bannerId == ItemDefaults.ITEM_ID then
		return ItemDefaults.ITEM_ID
	end
	local banners = ItemsConfig.Banners
	if type(banners) ~= "table" or banners[bannerId] == nil then
		return ItemDefaults.ITEM_ID
	end
	if not InventoryRepository.ownsItem(profileData, "Banners", bannerId) then
		return ItemDefaults.ITEM_ID
	end
	return bannerId
end

local function _applyKillEffect(attackerUserId: number?, character: Model)
	local effectId = _getKillEffectIdForAttacker(attackerUserId)
	local ok, err = pcall(KillEffectsRegistry.apply, effectId, character)
	if not ok then
		warn("[MatchService] KillEffect error: " .. tostring(err))
	end
end

type InRoundDeath = {
	attackerUserId: number?,
	attackerPlayer: Player?,
	attackerWeaponId: string,
	killerName: string,
}

--[[
	Contabiliza una muerte en ronda: kill y recompensas del atacante, stats de la víctima
	y punto para el rival. La comparten el Died de ronda y el Reset estando vivo
	(_onRequestReturnToMenu). Devuelve (nil, false) si el jugador no tiene equipo, y
	roundEnded=true si esta muerte cerró la ronda (_enterResults ya corrió).
]]
local function _scoreInRoundDeath(
	player: Player,
	session: PlayerSession,
	character: Model,
	humanoid: Humanoid,
	withKillEffect: boolean
): (InRoundDeath?, boolean)
	local deadSide = session.team
	local round = _round
	if deadSide == nil or not round then
		return nil, false
	end

	session.deathAt = time()
	session.respawnDebounce = false

	local deathRoot = character:FindFirstChild("HumanoidRootPart")
	if deathRoot and deathRoot:IsA("BasePart") then
		local nearestSpawn = SpawnService.FindNearestSpawn(deathRoot.Position)
		if nearestSpawn then
			round.recentDeathBySpawn[nearestSpawn] = time()
		end
	end
	local attackerUserId, attackerWeaponId, attackerWasHeadshot, attackerWeaponCategory = KillRewardsService:ResolveKillAttacker(humanoid)
	local attackerPlayer = if attackerUserId then Players:GetPlayerByUserId(attackerUserId) else nil
	local killerName: string
	if attackerPlayer then
		killerName = attackerPlayer.Name
	elseif attackerUserId and attackerUserId < 0 then
		killerName = _resolveBotKillerName(attackerUserId)
	else
		killerName = ""
	end
	KillRewardsService:RegisterPlayerDeath(player, attackerUserId, attackerWeaponId, attackerWasHeadshot, attackerWeaponCategory)

	-- Ragdoll visible para todos.
	if withKillEffect then
		_applyKillEffect(attackerUserId, character)
	end

	if deadSide == "A" then
		round.scoreB += 1
	else
		round.scoreA += 1
	end

	_publishScore()

	local death: InRoundDeath = {
		attackerUserId = attackerUserId,
		attackerPlayer = attackerPlayer,
		attackerWeaponId = attackerWeaponId,
		killerName = killerName,
	}
	if round.scoreA >= GameConfig.WinScoreLimit then
		_enterResults("A")
		return death, true
	elseif round.scoreB >= GameConfig.WinScoreLimit then
		_enterResults("B")
		return death, true
	end
	return death, false
end

-- Saca al jugador de la partida y lo deja en el menú del lobby. El cliente cierra la
-- partida con ReturnToMenuDone (desde cualquier fase de juego).
local function _sendToMenu(player: Player, session: PlayerSession, reason: string)
	_markLeftMatch(player.UserId)
	_setMatchSide(player, nil)
	DailyTasksService:ResetStreak(player)
	session.inMenu = true
	session.respawnDebounce = false
	session.pendingSpawn = false
	_rebalanceBotsForCurrentRound(reason)
	KillAttributionService:SendStreakBroadcast(player.UserId)

	SpawnService.SpawnAtLobby(player)

	if player.Parent == Players then
		Network.Match.DeathScreenHide.SendTo({}, player)
		Network.Match.ReturnToMenuDone.SendTo({}, player)
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

	-- Una sola vez por character: la dispara Died o, si no llega, el fallback de Health.
	local listening = true
	local function onDeath()
		if not listening then
			return
		end
		listening = false

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
				SpawnService.SpawnAtLobby(player)
			end)
			return
		end

		local death, roundEnded = _scoreInRoundDeath(player, session, character, humanoid, true)
		if not death or roundEnded then
			return
		end
		local attackerUserId = death.attackerUserId
		local attackerPlayer = death.attackerPlayer
		local killerName = death.killerName
		local attackerWeaponId = death.attackerWeaponId

		-- Muerte sin asesino (vacío, entorno): la muerte cuenta igual (arriba), pero no hay
		-- pantalla de muerte ni respawn: directo al menú.
		if attackerUserId == nil then
			if player.Parent == Players then
				_sendToMenu(player, session, "death without killer")
			end
			return
		end

		if player.Parent == Players then
			-- La tarjeta de muerte enseña quién mató, su nivel y su banner equipado.
			local killerLevel = 0
			local killerBanner = ItemDefaults.ITEM_ID
			if attackerPlayer and _dataService and _dataService.GetProfile then
				local killerProfile = _dataService:GetProfile(attackerPlayer)
				if killerProfile and killerProfile.Data then
					local stats = killerProfile.Data.Stats
					local lvl = if stats then stats.Level else nil
					if type(lvl) == "number" then
						killerLevel = math.floor(lvl)
					end
					killerBanner = _resolveEquippedBanner(killerProfile.Data)
				end
			end

			-- Killer bot: nivel y banner salen de su identidad (los bots no tienen perfil).
			if attackerUserId and attackerUserId < 0 and _AIService and _AIService.GetBotIdentity then
				local botIdentity = _AIService:GetBotIdentity(attackerUserId)
				if botIdentity then
					killerLevel = botIdentity.level
					if botIdentity.appearance then
						killerBanner = botIdentity.appearance.bannerId
					end
				end
			end

			Network.Match.DeathScreenShow.SendTo({
				respawnCooldown = GameConfig.RespawnCooldown,
				killerUserId = if attackerUserId then tostring(attackerUserId) else "",
				killerName = killerName,
				killerLevel = killerLevel,
				killerBanner = killerBanner,
				weaponId = attackerWeaponId,
			}, player)
		end

		-- El cuerpo se reubica al LobbySpawn tras un margen; el jugador solo vuelve a
		-- partida pulsando spawn (RequestRespawn). Se cancela si respawneó o murió de
		-- nuevo (deathAt cambia), hay un respawn en curso, se fue al menú, salió o
		-- terminó la ronda.
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
			SpawnService.SpawnAtLobby(player)
		end)
	end

	local diedConn = humanoid.Died:Connect(onDeath)
	local healthConn = humanoid.HealthChanged:Connect(function(health: number)
		if health > 0 or not listening then
			return
		end
		task.delay(DIED_FALLBACK_GRACE, function()
			if humanoid.Health <= 0 then
				onDeath()
			end
		end)
	end)
	session.deathConn = {
		Disconnect = function(_self: DeathListener)
			listening = false
			diedConn:Disconnect()
			healthConn:Disconnect()
		end,
	}
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

-- Cuenta las claves de un map. Los de esta ronda son por participante, así
-- que nunca son grandes; sólo alimentan el diagnóstico del MATCH_END.
local function _countKeys(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

--[[
	Congela los equipos de los bots mientras el roster todavía existe.
	HAY QUE LLAMARLA ANTES DE `_AIService:OnRoundEnd()`: ese despawn vacía las
	tablas de identidad y equipo (AI/init.luau) y `GetBotRoster()` devuelve `{}`;
	sin equipo, los bots se caerían del MATCH_END.
]]
local function _captureBotTeams(): { [number]: string }
	local botTeams: { [number]: string } = {}
	if not _AIService then
		return botTeams
	end

	local ok, roster = pcall(function()
		return _AIService:GetBotRoster()
	end)
	if ok and type(roster) == "table" then
		for _, bot in roster do
			botTeams[bot.fakeUserId] = bot.team
		end
	end
	return botTeams
end

--[[
	Emite MATCH_END: una fila por ronda y una por participante. Se llama ANTES de
	_round = nil, última ventana con marcador y stats de ronda vivos.

	Bots incluidos (fakeUserId negativo): el backend guarda `is_bot` como dimensión.
	El loadout sale del perfil (Loadout.MainWeapon/SpecialWeapon) para no tocar la
	ruta crítica de spawn; cruzado con el resultado da el win rate por arma.
]]
local function _emitMatchEndTelemetry(botTeams: { [number]: string }): string?
	local round = _round
	if not round then
		return "sin ronda activa"
	end
	if _activeMapName == "" then
		return "sin mapa activo"
	end

	local winningTeam = if round.scoreA > round.scoreB
		then "A"
		elseif round.scoreB > round.scoreA then "B"
		else ""

	local reachedLimit = round.scoreA >= GameConfig.WinScoreLimit or round.scoreB >= GameConfig.WinScoreLimit

	-- Los equipos de los bots llegan congelados desde antes del despawn: el
	-- roster ya no existe a estas alturas (ver `_captureBotTeams`).
	local players = {}
	for participantId, stats in round.statsByUserId do
		local isBot = participantId < 0
		local team: string? = if isBot then botTeams[participantId] else nil
		local mainWeapon, specialWeapon = "", ""

		if not isBot then
			local session = _sessions[participantId]
			team = if session then session.team else nil

			local player = Players:GetPlayerByUserId(participantId)
			if player and _dataService then
				local profile = _dataService:GetProfile(player)
				local loadout = if profile and profile.Data then profile.Data.Loadout else nil
				if loadout then
					mainWeapon = loadout.MainWeapon or ""
					specialWeapon = loadout.SpecialWeapon or ""
				end
			end
		end

		-- Sin equipo no hay resultado que calcular, así que la fila no aporta.
		if team == "A" or team == "B" then
			table.insert(players, {
				participantId = participantId,
				isBot = isBot,
				team = team,
				kills = stats.kills,
				deaths = stats.deaths,
				assists = stats.assists,
				mainWeapon = mainWeapon,
				specialWeapon = specialWeapon,
			})
		end
	end

	if #players == 0 then
		return ("ningún participante con equipo (%d en el marcador, %d bots congelados)"):format(
			_countKeys(round.statsByUserId),
			_countKeys(botTeams)
		)
	end

	-- Aparte del roster a propósito: `players` pierde a quien salió o acabó en el menú,
	-- que es justo quien entra y sale para exprimir la ronda.
	local entries = {}
	for userId, count in round.entriesByUserId do
		table.insert(entries, {
			userId = userId,
			entries = count,
			inMatchSeconds = _inMatchSeconds(round, userId),
		})
	end

	TelemetryService.Enqueue("MATCH_END", {
		matchId = round.matchId,
		mapName = _activeMapName,
		durationSeconds = math.max(0, os.time() - round.startedAt),
		scoreA = round.scoreA,
		scoreB = round.scoreB,
		winningTeam = winningTeam,
		endReason = if reachedLimit then "score" else "timeout",
		-- El límite que produjo ese endReason. Sin su valor, una ronda de hace
		-- tres meses y una de hoy no son comparables si alguien tocó la config.
		winScoreLimit = GameConfig.WinScoreLimit,
		-- Participantes bot, para separar rondas de relleno de rondas reales.
		botCount = _countKeys(botTeams),
		players = players,
		entries = entries,
	})

	return nil
end

local function _clearActiveMap()
	if _activeMapContainer and _activeMapContainer.Parent then
		_activeMapContainer:Destroy()
	end
	_activeMapContainer = nil
	_activeMapModel = nil
	_activeMapName = ""
	SpawnService.InvalidateMapCache()
end

-- Clone() no hace yield: la carga es síncrona, sin timeout.
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

	-- Se mueve ANTES de parentar a Workspace: así el mapa replica ya en su sitio
	-- y nada (spawns, RoamGraph, bots) llega a leer la posición autorada.
	local anchor = Workspace:FindFirstChild(MAP_ANCHOR_NAME)
	if not anchor or not anchor:IsA("BasePart") then
		warn(string.format("[MatchService] Workspace.%s no existe; el mapa '%s' se queda en su posición autorada.", MAP_ANCHOR_NAME, mapName))
	elseif not result:IsA("Model") then
		warn(string.format("[MatchService] ServerStorage/Maps/%s no es un Model; no se puede mover a Workspace.%s.", mapName, MAP_ANCHOR_NAME))
	else
		result:PivotTo(anchor.CFrame)
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
-- desmonta la ronda (bots, listeners, sesiones, Round). El MAPA se queda hasta que
-- expira la ventana de Resultados, porque la pantalla se rueda dentro de él (podio
-- Results.Player1..4 + Results.Camera del propio mapa); luego Idle y nueva votación.
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

	-- El despawn de abajo vacía el roster de bots, que la telemetría necesita.
	local botTeams = _captureBotTeams()

	-- Se copia porque el reparto de recompensas corre en `task.defer`, después
	-- de que el desmontaje ponga `_round = nil`.
	local matchId = round.matchId

	if _AIService then
		_AIService:OnRoundEnd()
	end

	Network.Match.DeathScreenHide.SendToAll({})

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

	-- Enviar recompensas antes de RoundEnded NO garantiza que lleguen antes: van por la
	-- cola POR-JUGADOR de ByteNet y RoundEnded por la de BROADCAST, que se vacía antes.
	-- El cliente las pinta al llegar (ResultsView:applyRewards). El cash se concede
	-- abajo (task.defer), server-authoritative.
	local resultsByUserId: { [number]: any } = {}
	-- Participación: los bonus (y la daily de victorias) piden un mínimo de tiempo EN
	-- PARTIDA y de kills + asistencias; estar dentro al sonar el final no basta.
	local participatedByUserId: { [number]: boolean } = {}
	local winnerIsTeam = winnerTeam == "A" or winnerTeam == "B"
	for userId in eligibleByUserId do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end
		local stats = round.statsByUserId[userId]
		local contribution = if stats then stats.kills + stats.assists else 0
		local secondsInMatch = _inMatchSeconds(round, userId)
		local participated = secondsInMatch >= GameConfig.MatchEndMinSeconds
			and contribution >= GameConfig.MatchEndMinContribution
		participatedByUserId[userId] = participated
		-- Proporcional al tiempo en partida, igual que devenga el cap de combate.
		-- El techo diario entra aquí y no al conceder: lo pintado debe ser lo cobrado.
		local bonusScale = if participated
			then math.clamp(secondsInMatch / math.max(1, GameConfig.MaxRoundDuration), 0, 1)
				* RewardService.PlayedCashFactor(player)
			else 0
		local side = teamOf(userId)
		local won = winnerIsTeam and side == winnerTeam
		local maxForSide = if side then teamMaxKills[side] else 0
		local context = {
			won = won,
			lost = not won, -- perder o empatar cuentan como "Defeat"
			isMVP = maxForSide > 0 and killsOf(userId) == maxForSide,
			isVIP = MatchResultsService:IsVIPCached(player),
		}
		local results = MatchResultsService:BuildResults(player, context, bonusScale)
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

	local rosterParts: { string } = {}
	for userId in eligibleByUserId do
		local side = teamOf(userId)
		if userId > 0 and side then
			table.insert(rosterParts, `{userId}:{side}`)
		end
	end
	Network.Match.RoundEnded.SendToAll({
		winnerTeam = winnerTeam,
		scoreA = round.scoreA,
		scoreB = round.scoreB,
		roster = table.concat(rosterParts, ","),
	})

	-- Stats.MatchesPlayed para los elegibles + Wins/Losses y la daily WinMatches (el
	-- empate no cuenta). task.defer para no competir con el broadcast de RoundEnded.
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
					-- La daily paga Cash: misma exigencia de participación que los bonus.
					if participatedByUserId[userId] then
						pcall(function()
							DailyTasksService:OnMatchWon(player)
						end)
					end
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
				MatchResultsService:GrantCash(player, results.cash, matchId)
			end
		end
	end)

	-- Devolver jugadores elegibles al menú inmediatamente.
	-- El cliente maneja la vuelta al menú al recibir RoundEnded.
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

		SpawnService.SpawnAtLobby(player)

		if player.Parent == Players and MatchService.OnPlayerReturnedToLobby then
			pcall(MatchService.OnPlayerReturnedToLobby, player)
		end
	end

	-- Telemetría ANTES de desmontar: última ventana con mapa, marcador y stats de
	-- ronda. El pcall no es mudo a propósito: un MATCH_END que no sale debe avisar.
	local emitOk, emitResult = pcall(_emitMatchEndTelemetry, botTeams)
	if not emitOk then
		warn(("[MatchService] MATCH_END no se emitió (error): %s"):format(tostring(emitResult)))
	elseif emitResult ~= nil then
		warn(("[MatchService] MATCH_END no se emitió: %s"):format(tostring(emitResult)))
	end

	-- Desmontar la ronda: listeners de muerte, campos de scope ronda de las sesiones y
	-- el objeto Round. El mapa NO: los clientes ven Resultados sobre su podio.
	for _, session in _sessions do
		if session.deathConn then
			session.deathConn:Disconnect()
			session.deathConn = nil
		end
		_resetSessionRoundState(session)
	end
	for _, player in Players:GetPlayers() do
		_setMatchSide(player, nil)
	end
	_round = nil
	-- Dedupe del broadcast de stats vive en KillAttributionService.
	KillAttributionService:Clear()
	DailyTasksService:ResetAllStreaks()
	-- Snapshots de inicio de partida (nivel/tier BP) para los items de Resultados.
	MatchResultsService:ClearSnapshots()
	_lastBotRosterJsonBroadcast = nil

	-- La votación no arranca hasta que termina la pantalla de Resultados. Es
	-- también cuando se desmonta el mapa: hasta aquí es el escenario de la
	-- pantalla. (Si otra transición ganase la carrera, _loadMapClone vacía el
	-- contenedor ActiveMap al cargar el siguiente, así que no queda basura.)
	task.delay(GameConfig.EndResultsDuration, function()
		if _phaseGeneration ~= generation then
			return
		end
		_clearActiveMap()
		_enterIdle()
		_tryStartVoting()
	end)
end

-- Muerte de un bot (lo llama AIService): atribución de kill, score y victoria.
local function _handleBotDied(botTeam: string, _botName: string, botHumanoid: Humanoid, botFakeUserId: number)
	local round = _round
	if not _isRoundActive() or not round then
		return
	end

	local attackerUserId, attackerWeaponId, attackerWasHeadshot, attackerWeaponCategory = KillRewardsService:ResolveKillAttacker(botHumanoid)

	local killerName = _resolveKillerName(attackerUserId)
	-- Nombre ficticio del bot víctima (no su nombre crudo "Bot_B_08"). Fallback al
	-- nombre crudo si la identidad ya no estuviera disponible.
	local victimName = _botName
	if _AIService and _AIService.GetBotDisplayName then
		victimName = _AIService:GetBotDisplayName(botFakeUserId) or _botName
	end
	pcall(function()
		Network.Combat.KillFeed.SendToAll({
			killerName = killerName,
			victimName = victimName,
			weaponId = attackerWeaponId or "",
		})
	end)

	if attackerUserId and attackerUserId ~= botFakeUserId then
		-- Víctima bot: PvE.
		KillRewardsService:CreditKill(attackerUserId, attackerWeaponId, attackerWasHeadshot, true, attackerWeaponCategory)
	end

	-- Los bots no usan streak: solo contabilizar kills/deaths para HUD.
	local botStats = _roundStats(botFakeUserId)
	if botStats then
		botStats.deaths += 1
	end
	_sendPlayerStreakToAll(botFakeUserId)

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
	-- Broadcast inicial de stats para los players actuales (UI sync). Kills/deaths
	-- arrancan en 0 implícitamente (stats lazy del Round nuevo).
	for _, player in Players:GetPlayers() do
		KillAttributionService:SendStreakBroadcast(player.UserId)
	end
	MatchSnapshot.set({
		ScoreA = 0,
		ScoreB = 0,
		PhaseEndsAt = MatchSnapshot.now() + GameConfig.MaxRoundDuration,
		Phase = "InRound",
	})

	if _AIService then
		local sharedSpawnPoints = SpawnService.GetSpawnPoints()
		local ok, err = pcall(function()
			_AIService:OnRoundStart({
				spawnPoints = sharedSpawnPoints,
				mapRoot = _activeMapModel,
				onBotDied = _handleBotDied,
				selectSpawnPoint = SpawnService.SelectBotSpawnPoint,
				-- Los spawns se escalonan entre frames: el roster emitido tras
				-- SetBotTargets no incluye los pendientes y el pump lo reenvía al acabar.
				onRosterChanged = _broadcastBotRoster,
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
local function _onRequestMatchSync(_: Network.Empty, player: Player)
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

-- Handshake de join: el cliente avisa de que fijó la cámara de lobby y construyó
-- el menú. NO gatea el spawn (con CharacterAutoLoads=false el primer spawn es
-- lo que copia StarterGui a PlayerGui, así que el menú no puede preceder al
-- cuerpo). Idempotente: el cliente reintenta hasta ver el ACK, que es el
-- atributo replicado Player.JoinState = "Ready". Sin sesión (jugador ya fuera)
-- se ignora.
local function _onClientReady(_: Network.Empty, player: Player)
	local session = _sessions[player.UserId]
	if not session or session.clientReady then
		return
	end
	session.clientReady = true
	player:SetAttribute(ClientBootStage.JOIN_STATE_ATTRIBUTE, ClientBootStage.JOIN_READY)
	-- Cuánto tardó el cliente en estar usable desde PlayerAdded: es la métrica
	-- que dice si el flujo de carga aguanta las conexiones reales.
	TelemetryService.Enqueue("CLIENT_READY", {
		userId = player.UserId,
		bootMs = math.floor((time() - session.joinedAt) * 1000),
	})
end

local function _onCharacterAdded(player: Player, character: Model)
	-- Grupo CHARACTERS para no colisionar con cadáveres (RAGDOLL). DescendantAdded por
	-- si accesorios/tools cargan tarde; la connection vive en la sesión porque el
	-- character viejo puede seguir parented por ragdoll y acumularía listeners.
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
			-- kill effect, p.ej.), nace con el grupo coherente con su estado y,
			-- si es cadáver, sin query ni touch (no para balas).
			CollisionGroups.applyToNewPart(character, descendant)
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
	-- Estado de join visible al cliente (replica); ClientReady lo pasa a Ready.
	player:SetAttribute(ClientBootStage.JOIN_STATE_ATTRIBUTE, ClientBootStage.JOIN_LOADING)
	KillAttributionService:SendStreakBroadcast(player.UserId)
	_bindCharacterTracking(player)
end

local function _onRequestJoinMatch(_: Network.Empty, player: Player)
	if _phase ~= "InRound" or not _activeMapModel then
		return
	end

	-- Solo desde el menú: estando en partida, un join sería un respawn con vida llena
	-- y ForceField a demanda.
	local session = _sessions[player.UserId]
	if not session or session.pendingSpawn or not session.inMenu then
		return
	end

	-- Sin perfil las armas no se pueden conceder (grantWeaponsWithRetry se rinde a los
	-- 8 s) y el jugador jugaría desarmado. Se rechaza: el cliente vuelve al lobby.
	if _dataService and not _dataService:GetProfile(player) then
		Network.Match.JoinRejected.SendTo({ reason = "DataNotLoaded" }, player)
		return
	end

	local selectedSide = TeamAssignmentService:PickBalancedTeam(player.UserId)
	if not selectedSide then
		Network.Match.JoinRejected.SendTo({ reason = "TeamsFull" }, player)
		return
	end

	session.pendingSpawn = true
	session.inMenu = false
	_rebalanceBotsForCurrentRound("join request")
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
			Network.Match.JoinRejected.SendTo({ reason = "SpawnFailed" }, player)
			return
		end

		-- Un ReturnToMenu del mismo frame (corre antes que este defer) ya lo mandó al lobby.
		if session.inMenu then
			return
		end

		if not SpawnService.SpawnOnAssignedTeam(player) then
			warn("[MatchService] No fue posible spawnear al jugador en su equipo.")
			session.inMenu = true
			session.pendingSpawn = false
			_rebalanceBotsForCurrentRound("join spawn failed")
			if player.Parent == Players then
				Network.Match.JoinRejected.SendTo({ reason = "SpawnFailed" }, player)
			end
			return
		end

		-- SpawnOnAssignedTeam yielda en el lock de body-swap: un ReturnToMenu o el fin de
		-- ronda pueden haber reubicado al jugador en el lobby ANTES de este LoadCharacter,
		-- que lo ha devuelto al mapa. Se le vuelve a mandar al lobby.
		if session.inMenu then
			SpawnService.SpawnAtLobby(player)
			return
		end

		session.pendingSpawn = false
		session.deathAt = 0
		_markEnteredMatch(player.UserId)
		_setMatchSide(player, session.team)
		Network.Match.DeathScreenHide.SendTo({}, player)

		if player.Parent == Players then
			Network.Match.JoinMatchSpawned.SendTo({}, player)

				-- Marcador completo para el que entra: el cliente vacía sus stats al recibir
				-- JoinMatchSpawned y luego solo recibe cambios. El broadcast de arriba solo
				-- lleva al propio jugador y se dedupea.
			KillAttributionService:SendAllStreaksTo(player)

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

local function _onRequestRespawn(_: Network.Empty, player: Player)
	local session = _sessions[player.UserId]
	if not session or not _isRoundActive() or session.inMenu then
		return
	end

	-- session.respawning cubre la ventana en la que respawnDebounce ya se limpió
	-- (al inicio del defer) pero el bucle de spawn sigue corriendo (~0.45s de
	-- yields). Sin este guard, un segundo RequestRespawn en esa ventana arranca un
	-- segundo LoadCharacter/loadout concurrente (doble spawn explotable).
	if session.respawnDebounce or session.respawning then
		return
	end

	-- Solo tras una muerte registrada y con el cooldown cumplido: con deathAt == 0 el
	-- jugador está vivo y un respawn le daría vida llena y ForceField sin morir. No se
	-- mira Humanoid.Health: tras DEATH_BODY_TO_LOBBY_DELAY el muerto tiene un cuerpo vivo
	-- en el lobby.
	local deathAt = session.deathAt
	if deathAt <= 0 or time() - deathAt < GameConfig.RespawnCooldown then
		return
	end

	session.respawnDebounce = true
	-- "Respawn al mapa en curso" de forma SÍNCRONA (antes del defer), para que la
	-- reubicación al lobby por inactividad lo vea y no mande al jugador al lobby.
	session.respawning = true
	task.defer(function()
		session.respawnDebounce = false

		-- Reintento: al acabar la votación jugadores y bots respawnean a la vez y el
		-- body-swap puede fallar puntualmente (contención del lock, rig a medio construir).
		local spawned = false
		for _ = 1, 3 do
			if player.Parent ~= Players or not _isRoundActive() or session.inMenu then
				break
			end
			if SpawnService.SpawnOnAssignedTeam(player) then
				spawned = true
				break
			end
			task.wait(0.15)
		end

		session.respawning = false

		-- Mismo caso que en el join: menú o fin de ronda durante el yield del spawn.
		if spawned and (session.inMenu or not _isRoundActive()) then
			if player.Parent == Players then
				SpawnService.SpawnAtLobby(player)
			end
			return
		end

		if spawned then
			session.deathAt = 0
			Network.Match.DeathScreenHide.SendTo({}, player)
		end
	end)
end

local function _onRequestReturnToMenu(_: Network.Empty, player: Player)
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

	-- Ya en el menú (p. ej. el fin de ronda lo mandó al lobby con la petición en vuelo):
	-- solo confirmar, sin otro LoadCharacter ni rebalanceo.
	if session.inMenu and not session.pendingSpawn and not session.respawning then
		Network.Match.DeathScreenHide.SendTo({}, player)
		Network.Match.ReturnToMenuDone.SendTo({}, player)
		return
	end

	-- Reset/Menú estando vivo con un atacante reciente cuenta como muerte: si no, escapar
	-- de una muerte segura negaría la kill y el punto al rival. Sin kill effect: el cuerpo
	-- se reemplaza ahora mismo por el del lobby.
	if _isRoundActive() and not session.inMenu and session.deathAt <= 0 then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and humanoid and humanoid.Health > 0 and KillRewardsService:ResolveKillAttacker(humanoid) ~= nil then
			-- El Died que pudiera llegar después no debe contarla otra vez.
			_disconnectDeathConnection(player.UserId)
			local _, roundEnded = _scoreInRoundDeath(player, session, character, humanoid, false)
			if roundEnded then
				-- _enterResults ya lo mandó al lobby; el cliente pasa a Resultados con RoundEnded.
				return
			end
		end
	end

	_sendToMenu(player, session, "return to menu")
end

--[[
	true si la kill ocurrió DENTRO de la partida: ronda activa, killer en partida y
	víctima bot de la ronda o jugador en partida. Lo usan las asistencias del
	WeaponsSystem, que ven morir cualquier humanoid a tiros, también un cuerpo del lobby.
]]
function MatchService:IsMatchKill(killer: Player, victimHumanoid: Humanoid): boolean
	if not _isRoundActive() or _isPlayerInMenu(killer.UserId) then
		return false
	end
	local victimCharacter = victimHumanoid.Parent
	if not victimCharacter then
		return false
	end
	local victimPlayer = Players:GetPlayerFromCharacter(victimCharacter)
	if victimPlayer then
		return not _isPlayerInMenu(victimPlayer.UserId)
	end
	-- Los bots sólo existen durante la ronda y AIService marca su modelo con BotTeam.
	return victimCharacter:GetAttribute("BotTeam") ~= nil
end

-- Punto de entrada de las asistencias (WeaponsSystem.flushAssists).
function MatchService:GrantCombatReward(player: Player, actionKey: string, extraUpdates: any?, itemSku: string?)
	return KillRewardsService:GrantCombatReward(player, actionKey, extraUpdates, itemSku)
end

function MatchService:Start(dataService: DataService): ()
	if _started then
		return
	end

	_dataService = dataService
	KillRewardsService:Start({
		dataService = dataService,
		getRound = function()
			return _round
		end,
		roundStats = _roundStats,
		isPlayerInMenu = _isPlayerInMenu,
		deferUntilProfile = _deferUntilProfile,
		resolveKillerName = _resolveKillerName,
		onFirstKill = function(player: Player)
			if MatchService.OnPlayerFirstKill then
				MatchService.OnPlayerFirstKill(player)
			end
		end,
	})

	_started = true

	-- Crea el folder replicado del snapshot con su estado inicial (los clientes
	-- hacen WaitForChild sobre él al arrancar su feature de match).
	MatchSnapshot.set({ Phase = "Idle" })

	-- Control total del spawn: el motor NO auto-respawnea (ni en join ni al morir),
	-- así nunca suelta al jugador en el vacío. Todo spawn pasa por SpawnService:
	--  · join / vuelta a menú / muerte → SpawnAtLobby (LobbySpawn)
	--  · pulsar spawn en partida        → SpawnOnAssignedTeam (spawn del mapa)
	Players.CharacterAutoLoads = false

	_ensureTeams()
	SpawnService.Start({
		dataService = _dataService,
		getActiveMapModel = function()
			return _activeMapModel
		end,
		getActiveMapName = function()
			return _activeMapName
		end,
		getPlayerSide = function(player: Player)
			local session = _sessions[player.UserId]
			return if session then session.team else nil
		end,
		getTeamInstance = function(side: "A" | "B")
			return if side == "A" then _teamA else _teamB
		end,
		getRecentDeathBySpawn = function()
			local round = _round
			return if round then round.recentDeathBySpawn else {}
		end,
	})
	-- Red de seguridad: SpawnLocation Neutral en el lobby por si algún LoadCharacter
	-- sin reposicionar (o un auto-respawn que se cuele antes de Start) necesita un
	-- punto válido — evita el origen (0,0,0).
	SpawnService.EnsureLobbySpawnLocation()

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

	-- Flush de acciones diferidas cuando el profile carga. Si DataService no expone
	-- ProfileLoaded, las acciones diferidas se pierden.
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

		-- Entradas del jugador en la ronda activa (las de bots permanecen). Lo ganado y
		-- su primera entrada se quedan: son el cap de quien sale y vuelve a entrar.
		_markLeftMatch(userId)
		local round = _round
		if round then
			round.statsByUserId[userId] = nil
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
	Network.Match.ClientReady.Listen(_onClientReady)
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
		-- El id lo acuña `_enterVoting`, así que para cuando la votación
		-- termina ya identifica a la ronda que va a arrancar.
		currentMatchId = function(): string
			return _pendingMatchId
		end,
	})

	-- Predicates inyectados para no acoplar el service al estado de MatchService.
	HealthPickupService:Start({
		isRoundActive = _isRoundActive,
		isPlayerInMenu = _isPlayerInMenu,
		-- Cada heal consume el crédito de una kill reciente (KillRewardsService).
		consumePickupEligibility = function(userId: number): boolean
			return KillRewardsService:ConsumePickupCredit(userId)
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
			SpawnService.SpawnAtLobby(player)
		end)
		-- Cubre el servidor vacío donde Start() corrió con 0 players; defer para que
		-- el jugador ya esté en Players:GetPlayers().
		task.defer(_tryStartVoting)
	end)

	-- Jugadores ya presentes cuando arranca el servicio (Start tras un join):
	-- misma init que PlayerAdded + su cuerpo de lobby, ya que el motor no lo hará.
	for _, player in Players:GetPlayers() do
		_initJoinedPlayerState(player)
		task.defer(function()
			SpawnService.SpawnAtLobby(player)
		end)
	end

	_tryStartVoting()
end

return MatchService
