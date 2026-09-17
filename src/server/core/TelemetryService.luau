--!strict
--[[
	Única salida de analítica del juego: HTTP al backend de GUNNERS Analytics (el
	AnalyticsService de Roblox no se usa porque no se puede leer).

	Contrato: nunca lanza (todo en pcall), nunca bloquea al caller (Record* solo
	mutan memoria; el IO va en loops propios) y la cola está acotada.

	Eventos propios: SESSION_END, ROBUX_PURCHASE, SERVER_FLUSH, FUNNEL_STEP,
	ITEM_PURCHASE, LEVEL_UP, ASSET_MANIFEST; las features añaden los suyos con
	Enqueue (MATCH_END, MAP_VOTE). Tiempos: server/core/TelemetryConfig.luau.

	Los flujos se acumulan por jugador y los drena SERVER_FLUSH o SESSION_END;
	drenar resetea, así que el backend puede sumar sin doble conteo.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

-- En server/core y no en shared: no debe replicarse al cliente.
local TelemetryConfig = require(script.Parent.TelemetryConfig)

local DataServiceMod = require(script.Parent.data.DataService)
type DataService = DataServiceMod.DataServiceModule

export type FlowDirection = "source" | "sink"
-- Dimensión, no etiqueta: mezclar Gems con Cash invalida el ratio Faucet/Sink.
export type Currency = "Cash" | "Gems"
export type PurchaseKind = "CashPack" | "GemPack" | "BattlePassPremium" | "SkipTier" | "Gift" | "GamePass"

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
	Compra de tienda con el estado del jugador en ese instante (el acumulador solo
	dice qué se vendió, no cuándo). timePlayedSeconds lo completa RecordItemPurchase:
	Stats.TimePlayedSeconds solo se incrementa al cerrar sesión.
]]
export type ItemPurchasePayload = {
	userId: number,
	category: string,
	itemId: string,
	price: number,
	currency: Currency,
	level: number,
	xp: number,
	timePlayedSeconds: number,
	balanceBefore: number,
	weaponCategory: string?,
	weaponId: string?,
}

--[[
	Claves cortas porque viajan miles por batch: t = transactionType, i = itemId/sku
	opcional, c = moneda o pseudo-moneda, a = importe acumulado, n = nº de transacciones.
]]
type FlowEntry = { t: string, i: string?, c: string, a: number, n: number }
type Accumulator = {
	faucets: { [string]: FlowEntry },
	sinks: { [string]: FlowEntry },
	startedAt: number,
	any: boolean,
}

--[[
	cat = "Main" | "Special", w = weaponId de ItemsConfig, v = "human" | "bot",
	k = kills, h = subconjunto de k con headshot.
	No se deriva del acumulador de economía: RewardService solo registra kills que
	dan recompensa, y MatchCashCap/MatchXPCap las cortan a mitad de partida.
]]
type CombatEntry = { cat: string, w: string, v: string, k: number, h: number }
type CombatAccumulator = { [string]: CombatEntry }

local TelemetryService = {}

local _started = false
local _shuttingDown = false
local _dataService: DataService = nil :: any
local _botCountProvider: (() -> number)? = nil

local _queue: { any } = {}
local _droppedEvents = 0
local _droppedCritical = 0
local _accumulators: { [number]: Accumulator } = {}
local _combatAccumulators: { [number]: CombatAccumulator } = {}

local _sending = false
local _consecutiveFailures = 0
local _circuitOpenUntil = 0
local _authHeader: any = nil
local _serverStartClock = os.clock()

local INGEST_PATH = "/api/v1/telemetry/batch"

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
	return tostring(game.JobId) .. "-" .. tostring(os.clock())
end

--[[
	El Secret de GetSecret solo es usable dentro de una request. Sin secreto
	(Studio) se envía sin auth y en producción el backend responde 401.
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

--[[
	Eventos que no se pueden reconstruir si se pierden: acumuladores ya drenados
	(SESSION_END, SERVER_FLUSH) o hechos transaccionales. Son los últimos en descartarse.
]]
local IRREPLACEABLE_EVENTS: { [string]: boolean } = {
	SESSION_END = true,
	SERVER_FLUSH = true,
	ROBUX_PURCHASE = true,
	ITEM_PURCHASE = true,
	LEVEL_UP = true,
	MATCH_END = true,
	ASSET_MANIFEST = true,
}

--[[
	Al desbordar se descarta el reemplazable más viejo; solo si no queda ninguno cae
	uno irreemplazable, contado aparte en droppedCritical.
]]
local function _dropOne()
	for index = 1, #_queue do
		local event = _queue[index]
		if not IRREPLACEABLE_EVENTS[event.type] then
			table.remove(_queue, index)
			_droppedEvents += 1
			return
		end
	end

	table.remove(_queue, 1)
	_droppedEvents += 1
	_droppedCritical += 1
end

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
	-- gameVersion es una constante manual; placeVersion es la versión publicada real.
	payload.placeVersion = game.PlaceVersion

	table.insert(_queue, payload)

	while #_queue > TelemetryConfig.QueueMaxEvents do
		_dropOne()
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

local function _isCircuitOpen(): boolean
	return os.clock() < _circuitOpenUntil
end

-- El jitter evita que miles de servidores reintenten a la vez tras una caída.
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
	Como mucho una request en vuelo por servidor (mantiene el orden). Un batch que
	falla tras los reintentos se descarta a propósito: reencolarlo bloquearía los
	eventos nuevos durante una caída larga.
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

-- JSON convertiría el map en objeto con claves string; el backend quiere un array ordenado.
local function _sortedNumericKeys(t: any): { number }
	local keys: { number } = {}
	if type(t) ~= "table" then
		return keys
	end
	for key in t do
		local n = tonumber(key)
		if n then
			table.insert(keys, n)
		end
	end
	table.sort(keys)
	return keys
end

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
		-- placeVersion en Studio suele ser 0.
		isStudio = RunService:IsStudio(),
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
		payload.clientVersion = meta.LastClientVersion
		payload.firstSessionVersion = meta.FirstSessionVersion
		-- Momento del load, no de la salida.
		payload.lastSeen = meta.LastSeen
		payload.balances = { cash = stats.Cash, gems = stats.Gems or 0 }
		payload.lifetime = {
			totalCashEarned = stats.TotalCashEarned,
			-- `or 0`: el campo puede faltar hasta que Reconcile lo rellene en el siguiente load.
			totalCashPurchased = stats.TotalCashPurchased or 0,
			totalGemsEarned = stats.TotalGemsEarned or 0,
			totalRobuxSpent = stats.TotalRobuxSpent,
			level = stats.Level,
			kills = stats.Kills,
			deaths = stats.Deaths,
			matchesPlayed = stats.MatchesPlayed,
			wins = stats.Wins,
			-- Ya incluye esta sesión: DataService lo incrementa antes de ProfileUnloading.
			timePlayedSeconds = stats.TimePlayedSeconds,
			-- Headshots/Longshots/MeleeKills son subconjuntos de Kills.
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
			-- Denominador de `xp`, que es XP dentro del nivel actual, no acumulada.
			xpToNextLevel = stats.XPToNextLevel or 0,
		}

		-- De por vida (el backend resta sesiones consecutivas); sirve de control cruzado
		-- del acumulador de combate.
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
			-- Progreso dentro del tier actual.
			xp = bp.XP or 0,
			claimedTiers = _sortedNumericKeys(bp.Claimed),
			grantedSkips = _countKeys(bp.GrantedSkips),
		}

		local streak = data.LoginStreak
		if streak then
			payload.loginStreak = {
				current = streak.Current or 0,
				best = streak.Best or 0,
			}
		end

		local inventory = data.Inventory
		if inventory then
			local owned: { [string]: number } = {}
			for category, items in inventory do
				if type(items) == "table" then
					owned[category] = _countKeys(items)
				end
			end
			payload.inventoryCounts = owned
		end

		local loadout = data.Loadout
		if loadout then
			payload.loadout = {
				mainWeapon = loadout.MainWeapon or "",
				specialWeapon = loadout.SpecialWeapon or "",
			}
		end
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
			-- Clave string: JSONEncode convierte claves numéricas en arrays con huecos.
			economyByUser[tostring(userId)] = drained
			hasAny = true
		end
	end

	-- Drena también el combate de quien sigue en partida, por si el servidor cae.
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
	local droppedCritical = _droppedCritical
	_droppedCritical = 0

	return {
		uptimeSeconds = math.floor(os.clock() - _serverStartClock),
		playerCount = #Players:GetPlayers(),
		-- Para separar bots de humanos en las métricas de combate.
		botCount = botCount,
		droppedEvents = dropped,
		-- Descartes irreemplazables: > 0 es un agujero real en la contabilidad.
		droppedCritical = droppedCritical,
		queueSize = #_queue,
		consecutiveFailures = _consecutiveFailures,
		circuitOpen = _isCircuitOpen(),
		economyByUser = if hasAny then economyByUser else nil,
		combatByUser = if hasCombat then combatByUser else nil,
	}
end

-- Moneda como string: "Items" y "XP" no son monedas y no deben entrar en las firmas públicas.
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
	-- Validar en runtime: una dirección inválida tratada como faucet invertiría el balance.
	if direction ~= "source" and direction ~= "sink" then
		warn(
			("[Telemetry] dirección de flujo inválida %q en %q: el movimiento se descarta"):format(
				tostring(direction),
				transactionType
			)
		)
		return
	end

	local userId = player.UserId
	local acc = _accumulators[userId]
	if not acc then
		acc = _newAccumulator()
		_accumulators[userId] = acc
	end

	local bucket = if direction == "sink" then acc.sinks else acc.faucets
	-- La moneda entra en la clave: un mismo transactionType puede mover Cash y Gems.
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
	Solo muta memoria: apto para hot paths. `transactionType` es la etiqueta de
	faucet/sink del dashboard (p.ej. "Kill", "Shop::Hats", "MatchEnd::Victory").
	Pasar currency "Gems" en todo movimiento de moneda premium.
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
	Bien virtual adquirido: faucet de 1 bajo la pseudo-moneda "Items". Va por el
	acumulador porque un BatchUpdate de maestría puede desbloquear varios de golpe.
]]
function TelemetryService.RecordItem(player: Player, transactionType: string, itemId: string)
	if type(itemId) ~= "string" or itemId == "" then
		return
	end
	_recordFlow(player, "source", transactionType, 1, itemId, "Items")
end

-- Pseudo-moneda "XP" en el acumulador: no se mezcla con los faucets de Cash.
function TelemetryService.RecordXP(player: Player, transactionType: string, amount: number, itemSku: string?)
	_recordFlow(player, "source", transactionType, amount, itemSku, "XP")
end

--[[
	Evento suelto (no acumulador): importa cuándo se cruza cada nivel.
	timePlayedSeconds suma la sesión en curso, igual que ITEM_PURCHASE.
]]
function TelemetryService.RecordLevelUp(
	player: Player,
	fromLevel: number,
	toLevel: number,
	xpGained: number,
	source: string?
)
	if not TelemetryConfig.Enabled or not _started then
		return
	end
	if not player or type(fromLevel) ~= "number" or type(toLevel) ~= "number" then
		return
	end

	local acc = _accumulators[player.UserId]
	local sessionSeconds = if acc then math.max(0, os.time() - acc.startedAt) else 0

	local timePlayed = 0
	local profile = _dataService and _dataService:GetProfile(player)
	local data = profile and (profile :: any).Data
	if data and data.Stats then
		timePlayed = data.Stats.TimePlayedSeconds or 0
	end

	_enqueue("LEVEL_UP", {
		userId = player.UserId,
		fromLevel = fromLevel,
		toLevel = toLevel,
		xpGained = xpGained,
		source = source,
		timePlayedSeconds = timePlayed + sessionSeconds,
		sessionSeconds = sessionSeconds,
	})
end

-- `sessionId` agrupa los pasos de un mismo intento; opcional en onboarding (un único intento por jugador).
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
	Hot path de combate: solo escribe en memoria. victimIsBot es dimensión, no
	filtro: el dashboard decide si mezclarlos.
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

-- Evento individual: `purchaseId` da idempotencia en el backend.
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

--[[
	Por _enqueue y no por el acumulador, que perdería el instante, nivel y tiempo
	jugado de cada compra. Sin purchaseId, la idempotencia es el eventId (PK en backend).
]]
function TelemetryService.RecordItemPurchase(player: Player, payload: ItemPurchasePayload)
	if not TelemetryConfig.Enabled or not _started then
		return
	end
	if type(payload) ~= "table" or not player then
		return
	end

	-- La sesión en curso aún no está sumada al perfil (se suma al salir).
	local acc = _accumulators[player.UserId]
	local sessionSeconds = if acc then math.max(0, os.time() - acc.startedAt) else 0

	_enqueue("ITEM_PURCHASE", {
		userId = player.UserId,
		category = payload.category,
		itemId = payload.itemId,
		price = payload.price,
		currency = payload.currency,
		level = payload.level,
		xp = payload.xp,
		timePlayedSeconds = (payload.timePlayedSeconds or 0) + sessionSeconds,
		sessionSeconds = sessionSeconds,
		balanceBefore = payload.balanceBefore,
		weaponCategory = payload.weaponCategory,
		weaponId = payload.weaponId,
	})
end

function TelemetryService.Enqueue(eventType: string, payload: any)
	if type(payload) == "table" then
		_enqueue(eventType, payload)
	end
end

--[[
	El saldo inicial de DataTemplate entra por Reconcile sin pasar por RewardService:
	se registra como faucet "NewPlayerGrant", leído del perfil (no de la plantilla).
	No se suma a TotalCashEarned: ese contador mide el ritmo de grind que calibra precios.
]]
local function _recordNewPlayerGrant(player: Player)
	local profile = _dataService and _dataService:GetProfile(player)
	local data = profile and (profile :: any).Data
	if not data or not data.Metadata or not data.Stats then
		return
	end
	-- JoinCount == 1 también tras un /resetdata, que reinyecta el grant.
	if data.Metadata.JoinCount ~= 1 then
		return
	end

	local cash = data.Stats.Cash
	if type(cash) == "number" and cash > 0 then
		_recordFlow(player, "source", "NewPlayerGrant", cash, nil, "Cash")
	end
	local gems = data.Stats.Gems
	if type(gems) == "number" and gems > 0 then
		_recordFlow(player, "source", "NewPlayerGrant", gems, nil, "Gems")
	end
end

local MANIFEST_MAX_NAMES = 500

local function _childNames(root: Instance?, ...: string): { string }
	local node: Instance? = root
	for _, childName in { ... } do
		if not node then
			break
		end
		node = node:FindFirstChild(childName)
	end
	local names: { string } = {}
	if not node then
		return names
	end
	for _, child in node:GetChildren() do
		if #names >= MANIFEST_MAX_NAMES then
			break
		end
		table.insert(names, child.Name)
	end
	table.sort(names)
	return names
end

local function _killEffectIds(): { string }
	local ok, ids = pcall(function()
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local locker = if shared then shared:FindFirstChild("Locker") else nil
		local killEffects = if locker then locker:FindFirstChild("killEffects") else nil
		local registryModule = if killEffects then killEffects:FindFirstChild("KillEffectsRegistry") else nil
		if not registryModule then
			return {}
		end
		local registry = require(registryModule) :: any
		return if type(registry.ids) == "function" then registry.ids() else {}
	end)
	if not ok or type(ids) ~= "table" then
		return {}
	end
	local out: { string } = {}
	for _, id in ids do
		if #out >= MANIFEST_MAX_NAMES then
			break
		end
		table.insert(out, tostring(id))
	end
	return out
end

--[[
	Hats, outfits, tools y displays viven solo en el place (Rojo no los sincroniza):
	el servidor los lista y el dashboard los cruza con ItemsConfig.
]]
local function _buildAssetManifest(): any
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	return {
		placeVersion = game.PlaceVersion,
		isStudio = RunService:IsStudio(),
		hats = _childNames(shared, "Locker", "Hats"),
		bodies = _childNames(shared, "Bodies"),
		weaponDisplays = {
			Main = _childNames(shared, "Locker", "weapons", "Main"),
			Special = _childNames(shared, "Locker", "weapons", "Special"),
		},
		weaponTools = {
			Main = _childNames(ServerStorage, "WeaponTools", "Main"),
			Special = _childNames(ServerStorage, "WeaponTools", "Special"),
		},
		killEffects = _killEffectIds(),
	}
end

-- botCountProvider se inyecta desde ServerBootstrap: core no debe depender de features.
function TelemetryService.Start(dataService: DataService, botCountProvider: (() -> number)?)
	if _started or not TelemetryConfig.Enabled then
		return
	end
	_started = true
	_dataService = dataService
	_botCountProvider = botCountProvider

	_resolveAuthHeader()

	-- Con retraso para que el place termine de cargar las carpetas de modelos.
	task.delay(5, function()
		if not _started then
			return
		end
		local ok, payload = pcall(_buildAssetManifest)
		if ok and payload then
			_enqueue("ASSET_MANIFEST", payload)
		else
			warn("[Telemetry] ASSET_MANIFEST no construido: " .. tostring(payload))
		end
	end)

	-- El acumulador nace en ProfileLoaded para que `startedAt` mida la sesión
	-- real y no el momento de la primera transacción.
	dataService.ProfileLoaded:Connect(function(player: Player)
		if not _accumulators[player.UserId] then
			_accumulators[player.UserId] = _newAccumulator()
		end
		_recordNewPlayerGrant(player)
	end)

	-- Por señal porque core.data no puede requerir este módulo (ciclo).
	dataService.LeveledUp:Connect(function(player: Player, fromLevel: number, toLevel: number, xpGained: number, source: string?)
		pcall(TelemetryService.RecordLevelUp, player, fromLevel, toLevel, xpGained, source)
	end)

	-- ProfileUnloading dispara tanto en el unload normal como dentro del
	-- BindToClose de DataService, así que cubre ambos caminos de salida.
	dataService.ProfileUnloading:Connect(function(player: Player)
		local ok, payload = pcall(_buildSessionEnd, player)
		if ok and payload then
			_enqueue("SESSION_END", payload)
		end
	end)

	task.spawn(function()
		while _started do
			task.wait(TelemetryConfig.FlushIntervalSeconds)
			if not _shuttingDown then
				pcall(_flushOnce, false)
			end
		end
	end)

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

	-- Los BindToClose corren en paralelo: este no espera al de DataService.
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

		-- 2. Se encola aunque no haya economía: es el único portador de droppedEvents.
		local ok, payload = pcall(_buildServerFlush)
		if ok and payload then
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
	table.clear(_combatAccumulators)
end

return TelemetryService
