--!strict
--[[
	TelemetryService.luau
	Pipeline HTTP de telemetría hacia el backend de GUNNERS Analytics. Es la
	ÚNICA salida de analítica del juego.

	Hubo un `EconomyAnalytics.luau` que hacía dual-write al AnalyticsService de
	Roblox (Creator Hub). Se eliminó: ese destino es WRITE-ONLY —no hay API para
	leerlo— así que no podía alimentar el dashboard y sólo duplicaba las
	llamadas en cada call site. Lo que aportaba de propio (items y pasos de
	funnel) vive ahora aquí como `RecordItem` y `RecordFunnelStep`.

	CONTRATO — se cumple sin excepciones:
	  1. Nunca lanza. Todo va en pcall; un backend caído no rompe una compra.
	  2. Nunca bloquea al caller. `RecordFlow`/`RecordPurchase` sólo mutan tablas
	     en memoria; el IO vive en loops propios.
	  3. Nunca crece sin límite. Cola acotada con descarte del MÁS VIEJO.

	Eventos propios (ver `server/core/TelemetryConfig.luau` para los tiempos):
	  • SESSION_END   — uno por sesión de jugador, desde DataService.ProfileUnloading.
	  • ROBUX_PURCHASE— transaccional, desde los tres caminos de ProcessReceipt.
	  • SERVER_FLUSH  — agregado por servidor cada ServerFlushSeconds.
	  • FUNNEL_STEP   — un paso de embudo (onboarding, BP Premium).
	Las features encolan además los suyos vía `Enqueue` (MATCH_END, MAP_VOTE).

	ACUMULADOR: los flujos de cash no se envían uno a uno (serían miles). Se
	acumulan por jugador y los drena quien llegue antes — SERVER_FLUSH o
	SESSION_END. Drenar RESETEA, así que el backend puede sumar sin arriesgar
	doble conteo.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- TelemetryConfig vive en server/core (NO en shared/constants): nada del
-- cliente lo necesita, y así el nombre del secreto (SecretKey, no su valor)
-- ni el resto de la config interna se replican a ReplicatedStorage.
local TelemetryConfig = require(script.Parent.TelemetryConfig)

local DataServiceMod = require(script.Parent.data.DataService)
type DataService = DataServiceMod.DataServiceModule

-- ────────────────────────────────────────────────────────────
-- TIPOS
-- ────────────────────────────────────────────────────────────

export type FlowDirection = "source" | "sink"
--[[
	Moneda del movimiento. Es una DIMENSIÓN, no una etiqueta cosmética: sin
	ella, los Gems del Battle Pass se sumarían a los faucets de Coin y el
	Faucet/Sink ratio del dashboard —la métrica sobre la que se decide el
	balance económico— quedaría inservible.
]]
export type Currency = "Cash" | "Gems"
export type PurchaseKind = "CashPack" | "GemPack" | "BattlePassPremium" | "SkipTier" | "Gift"

export type PurchasePayload = {
	userId: number,
	purchaseId: string,
	productId: number,
	sku: string,
	robuxPrice: number,
	cashGranted: number,
	kind: PurchaseKind,
	receiverUserId: number?,
}

--[[
	Entrada del acumulador. Se guarda como tabla (y no como un simple número)
	para conservar las dos dimensiones que el dashboard necesita sin tener que
	parsear claves compuestas en el backend:
	  t = transactionType ("Kill", "Shop::Hats", "MatchEnd::Victory", ...)
	  i = itemId / sku opcional (weaponId de la kill, itemId comprado, ...)
	  c = moneda ("Cash" | "Gems" | "Items")
	  a = importe acumulado
	  n = nº de transacciones
]]
type FlowEntry = { t: string, i: string?, c: string, a: number, n: number }
type Accumulator = {
	faucets: { [string]: FlowEntry },
	sinks: { [string]: FlowEntry },
	startedAt: number,
	any: boolean,
}

--[[
	Entrada del acumulador de COMBATE. Claves cortas por la misma razón que en
	FlowEntry: viajan miles por batch y el nombre largo no aporta nada.
	  cat = categoría del arma ("Main" | "Special")
	  w   = weaponId tal y como aparece en ItemsConfig
	  v   = naturaleza de la víctima ("human" | "bot")
	  k   = kills acumuladas
	  h   = subconjunto de k que fueron headshot

	POR QUÉ NO SE DERIVA DE LA ECONOMÍA
	El acumulador de flujo ya recibe el weaponId como itemId en las kills, así
	que parece que estos datos ya existían. No sirven: RewardService sólo
	registra la kill si CONCEDE recompensa, y MatchCashCap/MatchXPCap la cortan
	a mitad de partida. El recuento se trunca justo para quien más mata — la
	población que decide el balance. El combate necesita su propio contador.
]]
type CombatEntry = { cat: string, w: string, v: string, k: number, h: number }
type CombatAccumulator = { [string]: CombatEntry }

local TelemetryService = {}

-- ────────────────────────────────────────────────────────────
-- ESTADO
-- ────────────────────────────────────────────────────────────

local _started = false
local _shuttingDown = false
local _dataService: DataService = nil :: any
local _botCountProvider: (() -> number)? = nil

local _queue: { any } = {}
local _droppedEvents = 0
local _accumulators: { [number]: Accumulator } = {}
local _combatAccumulators: { [number]: CombatAccumulator } = {}

local _sending = false
local _consecutiveFailures = 0
local _circuitOpenUntil = 0
local _authHeader: any = nil
local _serverStartClock = os.clock()

local INGEST_PATH = "/api/v1/telemetry/batch"

-- ────────────────────────────────────────────────────────────
-- UTILIDADES
-- ────────────────────────────────────────────────────────────

local function _debug(message: string)
	if TelemetryConfig.Debug then
		print("[Telemetry] " .. message)
	end
end

local function _newEventId(): string
	local ok, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if ok and type(guid) == "string" then
		return guid
	end
	-- Fallback: jobId + reloj monotónico. Sigue siendo único por servidor.
	return tostring(game.JobId) .. "-" .. tostring(os.clock())
end

--[[
	Cabecera de auth. `HttpService:GetSecret` devuelve un objeto Secret que sólo
	puede viajar dentro de una request — su valor nunca es legible desde Luau.
	Si el secreto no está configurado (Studio, primer arranque) seguimos sin
	auth: el backend en local lo acepta y en producción lo rechazará con 401,
	que es exactamente el comportamiento deseado.
]]
local function _resolveAuthHeader()
	local ok, secret = pcall(function()
		return HttpService:GetSecret(TelemetryConfig.SecretKey)
	end)
	if not ok or secret == nil then
		_debug("Secreto '" .. TelemetryConfig.SecretKey .. "' no disponible — enviando sin auth")
		return
	end

	local prefixed, result = pcall(function()
		return (secret :: any):AddPrefix("Bearer ")
	end)
	_authHeader = if prefixed then result else secret
end

local function _newAccumulator(): Accumulator
	return {
		faucets = {},
		sinks = {},
		startedAt = os.time(),
		any = false,
	}
end

--[[
	Drena el acumulador de un jugador y lo resetea. Devuelve nil si no había
	nada — así los payloads no se llenan de tablas vacías.
]]
--[[
	Drena el acumulador de combate de un jugador. Devuelve nil si no hay nada,
	para que el payload no cargue una tabla vacía en cada sesión sin kills.
]]
local function _drainCombatAccumulator(userId: number): CombatAccumulator?
	local acc = _combatAccumulators[userId]
	if not acc or next(acc) == nil then
		return nil
	end
	_combatAccumulators[userId] = {}
	return acc
end

local function _drainAccumulator(userId: number): { faucets: any, sinks: any }?
	local acc = _accumulators[userId]
	if not acc or not acc.any then
		return nil
	end

	local drained = { faucets = acc.faucets, sinks = acc.sinks }
	_accumulators[userId] = _newAccumulator()
	return drained
end

-- ────────────────────────────────────────────────────────────
-- COLA
-- ────────────────────────────────────────────────────────────

--[[
	Encola con tope duro. Al desbordar se descarta el evento MÁS VIEJO: ante
	saturación preferimos datos frescos a datos completos. Los descartes se
	cuentan y viajan en el siguiente SERVER_FLUSH para que el backend sepa que
	su serie tiene un hueco (un hueco conocido es infinitamente mejor que uno
	silencioso).
]]
local function _enqueue(eventType: string, payload: any)
	if not TelemetryConfig.Enabled then
		return
	end

	payload.eventId = payload.eventId or _newEventId()
	payload.type = eventType
	payload.ts = payload.ts or os.time()
	payload.placeId = game.PlaceId
	payload.jobId = game.JobId
	payload.gameVersion = TelemetryConfig.GameVersion

	table.insert(_queue, payload)

	while #_queue > TelemetryConfig.QueueMaxEvents do
		table.remove(_queue, 1)
		_droppedEvents += 1
	end
end

local function _takeBatch(): { any }
	local batch = {}
	local count = math.min(#_queue, TelemetryConfig.BatchMaxEvents)
	for _ = 1, count do
		table.insert(batch, table.remove(_queue, 1))
	end
	return batch
end

-- ────────────────────────────────────────────────────────────
-- ENVÍO
-- ────────────────────────────────────────────────────────────

local function _isCircuitOpen(): boolean
	return os.clock() < _circuitOpenUntil
end

--[[
	Backoff exponencial CON JITTER. El jitter no es cosmético: con ~6 jugadores
	por servidor, 12k CCU son ~2.000 servidores. Sin jitter, todos reintentarían
	en el mismo instante tras una caída y convertirían la recuperación del
	backend en un segundo incidente (efecto manada).
]]
local function _backoffSeconds(attempt: number): number
	local exponential = TelemetryConfig.BackoffBaseSeconds * (2 ^ (attempt - 1))
	local capped = math.min(exponential, TelemetryConfig.BackoffMaxSeconds)
	return capped * (0.5 + math.random())
end

local function _postBatch(batch: { any }, urgent: boolean): boolean
	local body
	local encoded = pcall(function()
		body = HttpService:JSONEncode({
			sentAt = os.time(),
			jobId = game.JobId,
			placeId = game.PlaceId,
			events = batch,
		})
	end)
	if not encoded or type(body) ~= "string" then
		_debug("JSONEncode falló — batch descartado")
		return false
	end

	local headers: { [string]: any } = { ["Content-Type"] = "application/json" }
	if _authHeader ~= nil then
		headers["Authorization"] = _authHeader
	end

	-- En apagado no hay tiempo para backoff: un intento y fuera.
	local maxAttempts = if urgent then 1 else TelemetryConfig.MaxRetries

	for attempt = 1, maxAttempts do
		local ok, response = pcall(function()
			return HttpService:RequestAsync({
				Url = TelemetryConfig.IngestUrl .. INGEST_PATH,
				Method = "POST",
				Headers = headers,
				Body = body,
			})
		end)

		if ok and type(response) == "table" and response.Success then
			_consecutiveFailures = 0
			_debug(("batch de %d eventos OK (%d)"):format(#batch, response.StatusCode))
			return true
		end

		-- 4xx (salvo 429) es un error nuestro: reintentar no lo arregla.
		if ok and type(response) == "table" then
			local status = tonumber(response.StatusCode) or 0
			if status >= 400 and status < 500 and status ~= 429 then
				_debug(("batch rechazado con %d — no se reintenta"):format(status))
				return false
			end
		end

		if attempt < maxAttempts then
			task.wait(_backoffSeconds(attempt))
		end
	end

	return false
end

--[[
	Un ciclo de envío. El guard `_sending` garantiza como mucho una request en
	vuelo por servidor: evita apilar peticiones contra un backend lento y
	mantiene el orden de los batches.

	Si el batch falla tras todos los reintentos se DESCARTA. Es deliberado:
	reencolarlo haría que una caída larga bloqueara los eventos nuevos detrás de
	los viejos, y en telemetría el dato fresco vale más. El circuit breaker
	evita seguir martilleando un backend caído.
]]
local function _flushOnce(urgent: boolean?)
	if _sending or #_queue == 0 or not TelemetryConfig.Enabled then
		return
	end
	if _isCircuitOpen() then
		return
	end

	_sending = true
	local batch = _takeBatch()

	local ok, sent = pcall(_postBatch, batch, urgent == true)
	if not ok or not sent then
		_consecutiveFailures += 1
		_droppedEvents += #batch
		if _consecutiveFailures >= TelemetryConfig.CircuitBreakerThreshold then
			_circuitOpenUntil = os.clock() + TelemetryConfig.CircuitBreakerCooldownSeconds
			_consecutiveFailures = 0
			warn(("[Telemetry] Circuito abierto %ds tras %d fallos consecutivos")
				:format(TelemetryConfig.CircuitBreakerCooldownSeconds, TelemetryConfig.CircuitBreakerThreshold))
		end
	end

	_sending = false
end

-- ────────────────────────────────────────────────────────────
-- CONSTRUCCIÓN DE EVENTOS
-- ────────────────────────────────────────────────────────────

local function _countKeys(t: any): number
	if type(t) ~= "table" then
		return 0
	end
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function _buildSessionEnd(player: Player): any?
	local userId = player.UserId
	local acc = _accumulators[userId]
	local sessionSeconds = if acc then math.max(0, os.time() - acc.startedAt) else 0
	local economy = _drainAccumulator(userId)

	local payload: any = {
		userId = userId,
		sessionSeconds = sessionSeconds,
		economy = economy,
		combat = _drainCombatAccumulator(userId),
	}

	local profile = _dataService and _dataService:GetProfile(player)
	local data = profile and (profile :: any).Data
	if data then
		local stats = data.Stats
		local meta = data.Metadata
		local bp = data.BattlePass

		payload.isNewPlayer = meta.JoinCount == 1
		payload.joinCount = meta.JoinCount
		payload.createdAt = meta.CreatedAt
		payload.country = meta.Country
		payload.balances = { cash = stats.Cash, gems = stats.Gems or 0 }
		payload.lifetime = {
			totalCashEarned = stats.TotalCashEarned,
			totalGemsEarned = stats.TotalGemsEarned or 0,
			totalRobuxSpent = stats.TotalRobuxSpent,
			level = stats.Level,
			kills = stats.Kills,
			deaths = stats.Deaths,
			matchesPlayed = stats.MatchesPlayed,
			wins = stats.Wins,
			-- Ya incluye ESTA sesión: DataService hace el Increment de
			-- TimePlayedSeconds ANTES de disparar ProfileUnloading.
			timePlayedSeconds = stats.TimePlayedSeconds,
			-- Combate y progresión. Estaban en el perfil desde el principio;
			-- simplemente no viajaban. Headshots/Longshots/MeleeKills son
			-- SUBSETS de Kills (ver DataTemplate), no se suman aparte.
			assists = stats.Assists or 0,
			headshots = stats.Headshots or 0,
			longshots = stats.Longshots or 0,
			meleeKills = stats.MeleeKills or 0,
			doubleKills = stats.DoubleKills or 0,
			tripleKills = stats.TripleKills or 0,
			killStreakBest = stats.KillStreakBest or 0,
			damageDealt = stats.DamageDealt or 0,
			shotsFired = stats.ShotsFired or 0,
			shotsHit = stats.ShotsHit or 0,
			losses = stats.Losses or 0,
			friendsInvited = stats.FriendsInvited or 0,
			xp = stats.XP or 0,
		}

		-- Kills acumuladas por arma (las que ya alimentan la maestría de wraps
		-- en el Locker). Son de POR VIDA: el backend saca el periodo restando
		-- sesiones consecutivas del mismo jugador. Sirven de control cruzado
		-- del acumulador de combate — si no cuadran, hay una ruta de kill sin
		-- instrumentar.
		local weaponKills = data.WeaponKills
		if weaponKills then
			payload.weaponKills = {
				main = weaponKills.Main,
				special = weaponKills.Special,
			}
		end
		payload.battlePass = {
			seasonId = bp.SeasonId,
			currentTier = bp.CurrentTier,
			totalXPEarned = bp.TotalXPEarned,
			premiumOwned = bp.PremiumOwned,
			claimedCount = _countKeys(bp.Claimed),
		}
	end

	_accumulators[userId] = nil
	_combatAccumulators[userId] = nil
	return payload
end

local function _buildServerFlush(): any
	local economyByUser: { [string]: any } = {}
	local hasAny = false

	for userId in _accumulators do
		local drained = _drainAccumulator(userId)
		if drained then
			-- Clave string: JSONEncode convierte las tablas con claves numéricas
			-- en arrays con huecos. El backend hace tonumber().
			economyByUser[tostring(userId)] = drained
			hasAny = true
		end
	end

	-- Combate huérfano: kills de jugadores que siguen en partida cuando vence
	-- el flush. Sin esto, una sesión larga acumularía todas sus kills en
	-- memoria hasta el SESSION_END y las perdería entera si el servidor cae.
	local combatByUser: { [string]: any } = {}
	local hasCombat = false
	for userId in _combatAccumulators do
		local drained = _drainCombatAccumulator(userId)
		if drained then
			combatByUser[tostring(userId)] = drained
			hasCombat = true
		end
	end

	local botCount = 0
	if _botCountProvider then
		local ok, count = pcall(_botCountProvider :: any)
		if ok and type(count) == "number" then
			botCount = count
		end
	end

	local dropped = _droppedEvents
	_droppedEvents = 0

	return {
		uptimeSeconds = math.floor(os.clock() - _serverStartClock),
		playerCount = #Players:GetPlayers(),
		-- Con RealPlayerCapPerServer=6 y TotalParticipantsTarget=8, ~25% de los
		-- participantes de combate son bots. Sin este campo el backend no puede
		-- separarlos y toda métrica de combate queda contaminada.
		botCount = botCount,
		droppedEvents = dropped,
		economyByUser = if hasAny then economyByUser else nil,
		combatByUser = if hasCombat then combatByUser else nil,
	}
end

-- ────────────────────────────────────────────────────────────
-- API PÚBLICA
-- ────────────────────────────────────────────────────────────

--[[
	Cuerpo compartido por `RecordFlow` y `RecordItem`. Toma la moneda como
	string suelto —y no como `Currency`— porque "Items" no es una moneda del
	juego y no debe colarse en las firmas públicas que sí lo son.
]]
local function _recordFlow(
	player: Player,
	direction: FlowDirection,
	transactionType: string,
	amount: number,
	itemId: string?,
	resolvedCurrency: string
)
	if not TelemetryConfig.Enabled or not _started then
		return
	end
	if not player or type(amount) ~= "number" or amount <= 0 then
		return
	end

	local userId = player.UserId
	local acc = _accumulators[userId]
	if not acc then
		acc = _newAccumulator()
		_accumulators[userId] = acc
	end

	local bucket = if direction == "sink" then acc.sinks else acc.faucets
	-- La moneda entra en la clave: el mismo transactionType puede mover Cash y
	-- Gems (p. ej. un tier del pase que da una u otra) y son series distintas.
	local key = resolvedCurrency .. "|" .. transactionType .. "|" .. (itemId or "")

	local entry = bucket[key]
	if entry then
		entry.a += amount
		entry.n += 1
	else
		bucket[key] = { t = transactionType, i = itemId, c = resolvedCurrency, a = amount, n = 1 }
	end

	acc.any = true
end

--[[
	RecordFlow: registra un movimiento de cash. Sólo muta memoria — sin IO, sin
	yields, sin errores. Se puede llamar desde cualquier hot path.

	`transactionType` es la taxonomía que verá el dashboard como faucet o sink.
	Etiquetas en uso: "Kill", "Shop::Hats", "MatchEnd::Victory",
	"BattlePassClaim", "Gift", "RobuxPurchase".

	`currency` por defecto es "Cash". Pasar "Gems" en todo movimiento de la
	moneda premium — omitirlo mezcla las dos economías en una sola serie.
]]
function TelemetryService.RecordFlow(
	player: Player,
	direction: FlowDirection,
	transactionType: string,
	amount: number,
	itemId: string?,
	currency: Currency?
)
	_recordFlow(player, direction, transactionType, amount, itemId, currency or "Cash")
end

--[[
	RecordItem: adquisición de un bien virtual (skin, wrap, sombrero). No mueve
	moneda, así que entra como un faucet de cantidad 1 bajo la pseudo-moneda
	"Items" — el mismo convenio que usaba el AnalyticsService de Roblox.

	Va por el acumulador y no por `_enqueue` a propósito: un solo BatchUpdate de
	maestría puede desbloquear varios wraps de golpe, y como eventos sueltos eso
	serían N requests para una información que se agrega igual de bien.

	Al viajar como moneda propia, los items NUNCA contaminan el Faucet/Sink
	ratio de Cash o Gems: `c` forma parte de la clave del acumulador.
]]
function TelemetryService.RecordItem(player: Player, transactionType: string, itemId: string)
	if type(itemId) ~= "string" or itemId == "" then
		return
	end
	_recordFlow(player, "source", transactionType, 1, itemId, "Items")
end

--[[
	RecordFunnelStep: un paso de embudo de conversión.

	`sessionId` agrupa los pasos de un MISMO intento: sin él no se puede
	distinguir "un jugador que lo intentó tres veces" de "tres jugadores que lo
	intentaron una". Es opcional porque el embudo de onboarding es único por
	jugador (sólo corre con JoinCount == 1) y ahí no hay nada que desambiguar.
]]
function TelemetryService.RecordFunnelStep(
	player: Player,
	funnel: string,
	step: number,
	stepName: string?,
	sessionId: string?
)
	if not player or type(funnel) ~= "string" or type(step) ~= "number" then
		return
	end

	_enqueue("FUNNEL_STEP", {
		userId = player.UserId,
		funnel = funnel,
		step = step,
		stepName = stepName,
		funnelSessionId = sessionId,
	})
end

--[[
	RecordCombat: una kill atribuida a un arma.

	Corre en la ruta caliente de combate (_creditKillToAttacker), así que es
	SOLO escritura en una tabla en memoria — igual que _enqueue, sin yields ni
	llamadas a servicios. El envío vive en el loop de flush.

	`victimIsBot` es una DIMENSIÓN, no un filtro. Con ~25% de bots entre los
	participantes, agregarlos con los humanos falsea cualquier K/D o win rate
	por arma; guardarlos por separado deja la decisión al dashboard y permite
	cambiar de criterio sin reinstrumentar el juego.
]]
function TelemetryService.RecordCombat(
	player: Player,
	weaponCategory: string,
	weaponId: string,
	victimIsBot: boolean,
	wasHeadshot: boolean
)
	if not TelemetryConfig.Enabled or not _started then
		return
	end
	if not player or type(weaponCategory) ~= "string" or type(weaponId) ~= "string" then
		return
	end
	if weaponCategory == "" or weaponId == "" then
		return
	end

	local userId = player.UserId
	local acc = _combatAccumulators[userId]
	if not acc then
		acc = {}
		_combatAccumulators[userId] = acc
	end

	local victimKind = if victimIsBot then "bot" else "human"
	local key = weaponCategory .. "|" .. weaponId .. "|" .. victimKind

	local entry = acc[key]
	if entry then
		entry.k += 1
		if wasHeadshot then
			entry.h += 1
		end
	else
		acc[key] = {
			cat = weaponCategory,
			w = weaponId,
			v = victimKind,
			k = 1,
			h = if wasHeadshot then 1 else 0,
		}
	end
end

--[[
	RecordPurchase: compra con Robux. No pasa por el acumulador — cada compra es
	un evento individual porque su valor unitario justifica el request y porque
	`purchaseId` da idempotencia natural en el backend (mismo criterio que
	`ProcessedReceipts` en DataTemplate).
]]
function TelemetryService.RecordPurchase(payload: PurchasePayload)
	if not TelemetryConfig.Enabled or not _started then
		return
	end
	if type(payload) ~= "table" or not payload.purchaseId then
		return
	end

	_enqueue("ROBUX_PURCHASE", {
		userId = payload.userId,
		purchaseId = payload.purchaseId,
		productId = payload.productId,
		sku = payload.sku,
		robuxPrice = payload.robuxPrice,
		cashGranted = payload.cashGranted,
		kind = payload.kind,
		receiverUserId = payload.receiverUserId,
	})
end

-- Escotilla genérica para eventos futuros sin tocar este módulo.
function TelemetryService.Enqueue(eventType: string, payload: any)
	if type(payload) == "table" then
		_enqueue(eventType, payload)
	end
end

--[[
	Start: arranca loops y suscripciones.

	`botCountProvider` se INYECTA (lo cablea ServerBootstrap con
	`AIService:GetBotRoster`) en vez de requerir AI desde aquí: `core` no debe
	depender de `features`. Mismo criterio que el resto de cross-cutting
	concerns del bootstrap.
]]
function TelemetryService.Start(dataService: DataService, botCountProvider: (() -> number)?)
	if _started or not TelemetryConfig.Enabled then
		return
	end
	_started = true
	_dataService = dataService
	_botCountProvider = botCountProvider

	_resolveAuthHeader()

	-- El acumulador nace en ProfileLoaded para que `startedAt` mida la sesión
	-- real y no el momento de la primera transacción.
	dataService.ProfileLoaded:Connect(function(player: Player)
		if not _accumulators[player.UserId] then
			_accumulators[player.UserId] = _newAccumulator()
		end
	end)

	-- ProfileUnloading dispara tanto en el unload normal como dentro del
	-- BindToClose de DataService, así que cubre ambos caminos de salida.
	dataService.ProfileUnloading:Connect(function(player: Player)
		local ok, payload = pcall(_buildSessionEnd, player)
		if ok and payload then
			_enqueue("SESSION_END", payload)
		end
	end)

	-- Loop de envío.
	task.spawn(function()
		while _started do
			task.wait(TelemetryConfig.FlushIntervalSeconds)
			if not _shuttingDown then
				pcall(_flushOnce, false)
			end
		end
	end)

	-- Loop de SERVER_FLUSH.
	task.spawn(function()
		while _started do
			task.wait(TelemetryConfig.ServerFlushSeconds)
			if not _shuttingDown then
				local ok, payload = pcall(_buildServerFlush)
				if ok and payload then
					_enqueue("SERVER_FLUSH", payload)
				end
			end
		end
	end)

	--[[
		Apagado. Roblox ejecuta los BindToClose EN PARALELO, así que este no se
		encola detrás de los 25s que consume el de DataService: corre a la vez y
		termina mucho antes.

		Sin este handler se pierde el último batch en CADA apagado de servidor —
		y no es pérdida aleatoria: sesga sistemáticamente contra las sesiones
		largas y contra los estados de fin de partida.
	]]
	game:BindToClose(function()
		if not TelemetryConfig.Enabled then
			return
		end
		_shuttingDown = true

		-- 1. Gracia: dar tiempo a que ProfileUnloading encole los SESSION_END.
		local graceDeadline = os.clock() + TelemetryConfig.ShutdownGraceSeconds
		while os.clock() < graceDeadline do
			task.wait(0.1)
		end

		-- 2. Recoger acumuladores huérfanos (jugadores sin SESSION_END emitido).
		local ok, payload = pcall(_buildServerFlush)
		if ok and payload and payload.economyByUser then
			_enqueue("SERVER_FLUSH", payload)
		end

		-- 3. Drenar con tope duro, en modo urgente (sin backoff).
		local deadline = os.clock() + TelemetryConfig.ShutdownDeadlineSeconds
		while (#_queue > 0 or _sending) and os.clock() < deadline do
			if not _sending then
				pcall(_flushOnce, true)
			end
			task.wait(0.1)
		end

		if #_queue > 0 then
			warn(("[Telemetry] BindToClose: %d eventos sin enviar"):format(#_queue))
		end
	end)

	_debug("iniciado → " .. TelemetryConfig.IngestUrl .. INGEST_PATH)
end

function TelemetryService.Destroy()
	_started = false
	_shuttingDown = false
	table.clear(_queue)
	table.clear(_accumulators)
end

return TelemetryService
