--!strict
--[[
	GiftingService.luau  (Server)

	Envío, entrega y claim de regalos (packs de cash comprados con Robux).

	Envío (SendGift):
	  1. Valida producto (StoreProducts), receptor ≠ uno mismo y que el receptor
	     acepta regalos (Settings.GiftsEnabled): si está online en este server se
	     lee su perfil en memoria; si no, un snapshot read-only del DataStore.
	     El check offline es best-effort: solo bloquea un `false` leído con
	     éxito — una API caída no frena el regalo (el default es aceptar).
	  2. Persiste la INTENCIÓN en el perfil del comprador (GiftIntent). Al
	     vivir en el perfil y no en memoria, sobrevive reintentos del receipt
	     aunque lleguen en otro servidor.
	  3. Responde SendResponse y lanza el prompt de compra del developer product.

	Entrega (ProcessReceipt — delegado desde ServerBootstrap ANTES del grant de
	cash normal; devolver nil aquí = "no es un regalo, sigue el flujo normal"):
	  • Idempotencia PRIMERO: un receipt ya en ProcessedReceipts se concede sin
	    re-entregar, aunque la intención haya expirado o se haya limpiado entre
	    reintentos (con el orden inverso, un reintento tardío caía al handler de
	    cash y una compra pagaba dos veces).
	  • Con GiftIntent activa para ese ProductId, el cash NO va al comprador:
	    - receptor en este server → _depositGift a su PendingGifts (+ForceSave);
	    - offline / otro server / cola llena → ProfileStore MessageAsync
	      (persistente; lo consume el MessageHandler al cargar su perfil).
	  • Toda entrega pasa por _depositGift: dedup por PurchaseId + ledger
	    ClaimedGifts (un regalo YA reclamado jamás se re-deposita — cierra el
	    doble-claim cuando un receipt/message se re-entrega tras un crash) +
	    cap MAX_PENDING_GIFTS.
	  • Prompt cancelado (PromptProductPurchaseFinished purchased=false) limpia
	    la intención para que una compra normal posterior del mismo pack no se
	    desvíe como regalo.

	Claim (ClaimGift, desde el GiftAlert del cliente):
	  Borra PendingGifts[giftId], concede el cash y apunta el giftId en
	  ClaimedGifts atómicamente (sin yields entre lectura y borrado ⇒ sin
	  doble-claim por spam). PendingGifts se replica por ReplicaService — no
	  existe packet de "tienes un regalo": el cliente observa.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local StoreProducts = require(Shared.constants.StoreProducts)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
local EconomyAnalytics = require(script.Parent.Parent.Parent.core.EconomyAnalytics)
type DataService = DataServiceMod.DataServiceModule

local M = NetGuards.MAX

-- SendGift hace web-calls (view de perfil offline); Claim es barato pero
-- igualmente spameable. Cooldowns separados por acción.
local SEND_COOLDOWN = 1
local CLAIM_COOLDOWN = 0.3
-- TTL de una intención persistida. Pasado esto, un receipt del mismo producto
-- se trata como compra normal — protege contra intents huérfanas de prompts
-- que nunca se resolvieron (crash antes de PromptProductPurchaseFinished).
local INTENT_TTL = 600
-- Cap de regalos pendientes por perfil. Con la cola llena, los messages de
-- ProfileStore quedan sin procesar (se reintentan al reclamar hueco / recargar).
local MAX_PENDING_GIFTS = 50

-- Cache corto de checks de receptor OFFLINE (GetAsync cuesta presupuesto de
-- DataStore compartido con la carga de perfiles; los reintentos y el spam no
-- deben quemarlo). Las lecturas de receptores online son gratis y no se cachean.
local RECEIVER_CHECK_TTL = 60
local RECEIVER_CHECK_CACHE_MAX = 256

local GiftingService = {}

local _dataService: DataService = nil :: any
local _started = false
local _sendCooldowns: { [number]: number } = {}
local _claimCooldowns: { [number]: number } = {}
local _receiverChecks: { [number]: { at: number, accepts: boolean, reason: string } } = {}

-- ────────────────────────────────────────────────────────────
-- HELPERS
-- ────────────────────────────────────────────────────────────

local function _checkCooldown(map: { [number]: number }, player: Player, cooldown: number): boolean
	local last = map[player.UserId] or 0
	if time() - last < cooldown then
		return false
	end
	map[player.UserId] = time()
	return true
end

local function _respondSend(player: Player, success: boolean, message: string): ()
	Network.Gifting.SendResponse.SendTo({
		success = success,
		message = message,
	}, player)
end

local function _respondClaim(player: Player, success: boolean, giftId: string, message: string, cashAmount: number): ()
	Network.Gifting.ClaimResponse.SendTo({
		success = success,
		giftId = giftId,
		message = message,
		cashAmount = cashAmount,
	}, player)
end

-- Entradas de BatchUpdate que dejan GiftIntent en "sin intención". Única
-- fuente del campo: las usan _clearIntent y el bookkeeping de ProcessReceipt.
local function _intentClearEntries(): { { path: { string }, value: any } }
	return {
		{ path = { "GiftIntent", "ReceiverUserId" }, value = 0 },
		{ path = { "GiftIntent", "ProductId" }, value = 0 },
		{ path = { "GiftIntent", "CreatedAt" }, value = 0 },
	}
end

local function _clearIntent(player: Player): boolean
	return _dataService:BatchUpdate(player, _intentClearEntries())
end

-- Payload del message de ProfileStore para entregas offline/cola llena.
local function _giftMessagePayload(giftId: string, gift: any): any
	return {
		Type = "Gift",
		Id = giftId,
		SenderUserId = gift.SenderUserId,
		SenderName = gift.SenderName,
		CashAmount = gift.CashAmount,
		ProductId = gift.ProductId,
		SentAt = gift.SentAt,
	}
end

--[[
	¿El receptor puede recibir regalos? Devuelve (accepts, reason).

	Online en este server → perfil en memoria (gratis, fresco). Si no →
	snapshot read-only cacheado RECEIVER_CHECK_TTL. La vista de un perfil que
	NUNCA existió llega con SessionLoadCount == 0 — ese regalo sería imposible
	de entregar jamás, así que se corta ANTES de cobrar Robux. Con la API caída
	(apiOk=false) se falla abierto: solo un "no" leído con éxito bloquea.

	Nota TOCTOU asumida: esto se comprueba al ENVIAR; si el receptor desactiva
	los regalos entre el prompt y el receipt, la entrega sigue (el Robux ya se
	pagó y el opt-out es anti-spam, no una barrera dura).
]]
local function _receiverAcceptsGifts(receiverUserId: number): (boolean, string)
	local receiver = Players:GetPlayerByUserId(receiverUserId)
	if receiver then
		local profile = _dataService:GetProfile(receiver)
		if profile then
			if (profile.Data.Settings :: any).GiftsEnabled == false then
				return false, "That player has gifts disabled."
			end
			return true, ""
		end
	end

	local cached = _receiverChecks[receiverUserId]
	if cached and os.clock() - cached.at < RECEIVER_CHECK_TTL then
		return cached.accepts, cached.reason
	end

	local view, apiOk = _dataService:ViewProfileAsync(receiverUserId)
	local accepts, reason = true, ""
	if apiOk and view ~= nil then
		if (tonumber(view.SessionLoadCount) or 0) <= 0 then
			accepts, reason = false, "That player hasn't played this game yet."
		else
			local settings = view.Data and view.Data.Settings
			if type(settings) == "table" and settings.GiftsEnabled == false then
				accepts, reason = false, "That player has gifts disabled."
			end
		end
	end

	if apiOk then
		-- Purga tosca para acotar el mapa (256 receptores distintos por minuto
		-- ya es un patrón de abuso, no de juego).
		local count = 0
		for _ in _receiverChecks do
			count += 1
		end
		if count >= RECEIVER_CHECK_CACHE_MAX then
			table.clear(_receiverChecks)
		end
		_receiverChecks[receiverUserId] = { at = os.clock(), accepts = accepts, reason = reason }
	end
	return accepts, reason
end

-- ────────────────────────────────────────────────────────────
-- ENVÍO
-- ────────────────────────────────────────────────────────────

-- Corre en thread propio (yielda: view offline).
function GiftingService:_handleSendGift(player: Player, data: { receiverUserId: string, productId: number }): ()
	local product = StoreProducts.ProductsByProductId[data.productId]
	if not product or product.ProductId <= 0 then
		_respondSend(player, false, "That item can't be gifted.")
		return
	end

	local receiverUserId = tonumber(data.receiverUserId)
	if not receiverUserId or receiverUserId <= 0 or receiverUserId % 1 ~= 0 then
		_respondSend(player, false, "Select a player to send the gift to.")
		return
	end
	if receiverUserId == player.UserId then
		_respondSend(player, false, "You can't gift yourself.")
		return
	end

	local accepts, reason = _receiverAcceptsGifts(receiverUserId)
	if not accepts then
		_respondSend(player, false, reason)
		return
	end

	-- El jugador pudo irse durante el yield de arriba.
	if player.Parent ~= Players then
		return
	end

	-- Persistir la intención ANTES del prompt: si este write falla NO lanzamos
	-- la compra — sin intención, el receipt concedería el cash al comprador en
	-- vez de convertirse en regalo.
	local ok = _dataService:BatchUpdate(player, {
		{ path = { "GiftIntent", "ReceiverUserId" }, value = receiverUserId },
		{ path = { "GiftIntent", "ProductId" }, value = product.ProductId },
		{ path = { "GiftIntent", "CreatedAt" }, value = os.time() },
	})
	if not ok then
		_respondSend(player, false, "Something went wrong. Try again.")
		return
	end

	_respondSend(player, true, "")
	MarketplaceService:PromptProductPurchase(player, product.ProductId)
end

-- ────────────────────────────────────────────────────────────
-- ENTREGA
-- ────────────────────────────────────────────────────────────

--[[
	Deposita un regalo en PendingGifts del receptor. ÚNICA puerta de entrada —
	la usan la entrega online de ProcessReceipt y el consumo de messages — para
	que dedup, ledger y cap se apliquen igual en ambos caminos. Devuelve:
	  "deposited" — escrito (nuevo).
	  "duplicate" — ya estaba pendiente (re-entrega idempotente).
	  "claimed"   — ya fue reclamado (ledger ClaimedGifts): NUNCA re-depositar.
	  "full"      — PendingGifts al cap; el caller decide encolar.
	  "error"     — perfil no cargado o write fallido.
]]
function GiftingService:_depositGift(player: Player, giftId: string, gift: any): string
	local profile = _dataService:GetProfile(player)
	if not profile then
		return "error"
	end
	local data = profile.Data :: any

	local claimed = data.ClaimedGifts
	if type(claimed) == "table" and claimed[giftId] ~= nil then
		return "claimed"
	end

	local pending = data.PendingGifts
	if type(pending) == "table" then
		if pending[giftId] ~= nil then
			return "duplicate"
		end
		local count = 0
		for _ in pending do
			count += 1
		end
		if count >= MAX_PENDING_GIFTS then
			return "full"
		end
	end

	return if _dataService:SetValue(player, { "PendingGifts", giftId }, gift) then "deposited" else "error"
end

--[[
	Delegado del dispatcher central (ServerBootstrap) ANTES del grant de cash.
	Devuelve nil si el receipt no corresponde a un regalo, para que el handler
	de compra normal lo procese.
]]
function GiftingService:ProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision?
	local product = StoreProducts.ProductsByProductId[receiptInfo.ProductId]
	if not product then
		return nil
	end

	local buyer = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not buyer then
		return nil
	end
	local profile = _dataService:GetProfile(buyer)
	if not profile then
		return nil
	end

	-- Idempotencia ANTES de mirar la intención: un receipt ya procesado (como
	-- regalo o como compra normal) jamás re-entrega ni re-concede — ni siquiera
	-- si la intención expiró o se limpió entre reintentos. Con el orden inverso
	-- un reintento tardío caía al handler de cash del bootstrap y una sola
	-- compra pagaba dos veces (regalo entregado + cash al comprador).
	local purchaseId = tostring(receiptInfo.PurchaseId)
	if _dataService:IsReceiptProcessed(buyer, purchaseId) then
		if _dataService:ForceSave(buyer) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local intent = (profile.Data :: any).GiftIntent
	local hasIntent = type(intent) == "table" and (tonumber(intent.ReceiverUserId) or 0) > 0
	if not hasIntent
		or intent.ProductId ~= receiptInfo.ProductId
		or os.time() - (tonumber(intent.CreatedAt) or 0) > INTENT_TTL
	then
		-- Diagnóstico: si HABÍA intención para ESTE producto pero caducó, el
		-- regalo se convierte en compra normal (cash al comprador). No es lo
		-- normal — merece un warn para no perder un regalo en silencio.
		if hasIntent and intent.ProductId == receiptInfo.ProductId then
			warn(("[GiftingService] Intent de regalo para product %s caducó (edad %ds > %ds); receipt tratado como compra normal.")
				:format(tostring(receiptInfo.ProductId), os.time() - (tonumber(intent.CreatedAt) or 0), INTENT_TTL))
		end
		-- Sin intención activa: compra normal de cash. Trade-off asumido: si la
		-- ENTREGA de un regalo fallara en bucle durante más de INTENT_TTL, el
		-- receipt acaba aquí y el comprador recibe el cash él mismo (valor no
		-- perdido, regalo no entregado) — preferible a una intención eterna que
		-- desvíe compras normales futuras del mismo pack.
		return nil
	end

	local receiverUserId = math.floor(tonumber(intent.ReceiverUserId) :: number)
	local gift = {
		SenderUserId = buyer.UserId,
		SenderName = buyer.Name,
		CashAmount = product.CashAmount,
		ProductId = product.ProductId,
		SentAt = os.time(),
	}

	-- Entrega vía _depositGift (dedup + ledger + cap). "claimed"/"duplicate"
	-- cuentan como entregadas: son reintentos de un receipt cuyo regalo ya
	-- llegó. Cola llena u offline → message persistente (acotado: durante un
	-- outage devuelve false y Roblox reintenta, en vez de colgar el receipt).
	local delivered = false
	local receiver = Players:GetPlayerByUserId(receiverUserId)
	if receiver and _dataService:GetProfile(receiver) then
		local status = self:_depositGift(receiver, purchaseId, gift)
		if status == "full" then
			delivered = _dataService:MessageProfile(receiverUserId, _giftMessagePayload(purchaseId, gift))
		else
			delivered = status ~= "error"
			if status == "deposited" then
				-- Adelanta el write del receptor (Save es fire-and-forget; el
				-- autosave de ≤30s es la red de seguridad real).
				_dataService:ForceSave(receiver)
			end
		end
	else
		delivered = _dataService:MessageProfile(receiverUserId, _giftMessagePayload(purchaseId, gift))
	end

	if not delivered then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- Roblox reintenta
	end

	-- Bookkeeping del comprador: receipt + Robux gastados + intención consumida,
	-- atómico y con save adelantado ANTES de conceder (Roblox consume el receipt
	-- al devolver PurchaseGranted). Si aun así el server muriera antes de
	-- persistir, el reintento re-entrega — y el ledger ClaimedGifts del receptor
	-- evita que ese regalo se cobre dos veces.
	local updates: { any } = {
		{ path = { "Stats", "TotalRobuxSpent" }, delta = product.RobuxPrice },
		{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
	}
	for _, entry in _intentClearEntries() do
		table.insert(updates, entry)
	end
	local ok = _dataService:BatchUpdate(buyer, updates)
	if not ok or not _dataService:ForceSave(buyer) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	Network.Gifting.GiftDelivered.SendTo({
		receiverUserId = tostring(receiverUserId),
	}, buyer)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ────────────────────────────────────────────────────────────
-- RECEPCIÓN
-- ────────────────────────────────────────────────────────────

-- Consume un message "Gift" de ProfileStore → _depositGift. Llamar a
-- `processed()` borra el message de la cola persistente; NO llamarlo lo deja
-- pendiente — OJO: ProfileStore no re-dispatcha messages no procesados dentro
-- de la misma sesión, así que "sin processed()" significa "reintento en la
-- PRÓXIMA sesión del jugador", no en unos segundos.
function GiftingService:_ingestGiftMessage(player: Player, message: any, processed: () -> ()): ()
	local giftId = tostring(message.Id or "")
	local cashAmount = math.floor(tonumber(message.CashAmount) or 0)
	if giftId == "" or #giftId > M.GiftId or cashAmount <= 0 then
		processed() -- malformado: descartar para no crecer la cola
		return
	end

	local gift = {
		SenderUserId = math.floor(tonumber(message.SenderUserId) or 0),
		SenderName = tostring(message.SenderName or "???"),
		CashAmount = cashAmount,
		ProductId = math.floor(tonumber(message.ProductId) or 0),
		SentAt = math.floor(tonumber(message.SentAt) or os.time()),
	}

	local status = GiftingService:_depositGift(player, giftId, gift)
	if status == "deposited" or status == "duplicate" or status == "claimed" then
		processed()
	end
	-- "full"  → sin processed(): se re-entrega la próxima sesión, cuando el
	--           jugador haya reclamado hueco.
	-- "error" → sin processed(): perfil descargándose o write fallido.
end

-- Síncrono de punta a punta (sin yields entre leer y borrar el regalo) — el
-- dispatcher de ByteNet procesa un packet a la vez, así que no hay doble-claim.
function GiftingService:_handleClaimGift(player: Player, giftId: string): ()
	local profile = _dataService:GetProfile(player)
	if not profile then
		_respondClaim(player, false, giftId, "Your data isn't loaded yet.", 0)
		return
	end

	local pending = (profile.Data :: any).PendingGifts
	local gift = if type(pending) == "table" then pending[giftId] else nil
	if type(gift) ~= "table" then
		_respondClaim(player, false, giftId, "That gift is no longer available.", 0)
		return
	end

	local amount = math.max(0, math.floor(tonumber(gift.CashAmount) or 0))

	-- Borrar ANTES de conceder: si algo falla a medias preferimos restaurar el
	-- regalo (abajo) a arriesgar un doble-grant.
	if not _dataService:SetValue(player, { "PendingGifts", giftId }, nil) then
		_respondClaim(player, false, giftId, "Something went wrong. Try again.", 0)
		return
	end

	local ok = _dataService:BatchUpdate(player, {
		{ path = { "Stats", "Cash" }, delta = amount },
		{ path = { "Stats", "TotalCashEarned" }, delta = amount },
		-- Ledger anti doble-claim: si este giftId (PurchaseId) volviera a
		-- entregarse (receipt/message re-entregado tras un crash), _depositGift
		-- lo rechaza. DataService lo poda por edad al cargar el perfil.
		{ path = { "ClaimedGifts", giftId }, value = os.time() },
	})
	if not ok then
		_dataService:SetValue(player, { "PendingGifts", giftId }, gift)
		_respondClaim(player, false, giftId, "Something went wrong. Try again.", 0)
		return
	end

	local balance = profile.Data.Stats.Cash or 0
	EconomyAnalytics.Source(player, amount, balance, "Gift", tostring(gift.ProductId))
	_respondClaim(player, true, giftId, "", amount)
end

-- ────────────────────────────────────────────────────────────
-- START
-- ────────────────────────────────────────────────────────────

function GiftingService:Start(dataService: DataService): ()
	if _started then
		return
	end
	_started = true
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player: Player)
		_sendCooldowns[player.UserId] = nil
		_claimCooldowns[player.UserId] = nil
	end)

	-- Consumidor de messages de ProfileStore: regalos enviados mientras el
	-- receptor estaba offline o en otro servidor. Se registra por sesión; los
	-- messages encolados se entregan al cargar y los nuevos van llegando en
	-- caliente (los recoge el ciclo de autosave de ProfileStore).
	dataService.ProfileLoaded:Connect(function(player: Player)
		local profile: any = dataService:GetProfile(player)
		if not profile or type(profile.MessageHandler) ~= "function" then
			return
		end
		profile:MessageHandler(function(message: any, processed: () -> ())
			if type(message) ~= "table" or message.Type ~= "Gift" then
				processed() -- message desconocido: descartar para no crecer la cola
				return
			end
			GiftingService:_ingestGiftMessage(player, message, processed)
		end)
	end)

	Network.Gifting.SendGift.Listen(function(data: any, player: Player)
		if not NetGuards.validate(data, {
			receiverUserId = M.UserIdString,
			productId = { kind = "number", integer = true, min = 1 },
		}) then
			return
		end
		if not _checkCooldown(_sendCooldowns, player, SEND_COOLDOWN) then
			return
		end
		-- Yielda (view offline): thread aparte para no congelar el dispatcher de ByteNet.
		task.spawn(function()
			GiftingService:_handleSendGift(player, data)
		end)
	end)

	Network.Gifting.ClaimGift.Listen(function(data: any, player: Player)
		if not NetGuards.validate(data, { giftId = M.GiftId }) then
			return
		end
		if not _checkCooldown(_claimCooldowns, player, CLAIM_COOLDOWN) then
			return
		end
		GiftingService:_handleClaimGift(player, data.giftId)
	end)

	-- Prompt cancelado → limpiar la intención para que una compra normal
	-- posterior del mismo pack no se desvíe como regalo. En purchased=true NO
	-- se toca nada: la consume ProcessReceipt al entregar (limpiar aquí
	-- perdería la carrera contra el receipt). Residual asumido: si un regalo
	-- YA COMPRADO sigue con el receipt reintentando (entrega fallando) y el
	-- jugador cancela un prompt normal del mismo pack, esta limpieza convierte
	-- ese receipt en compra normal — el cash va al comprador (valor no perdido).
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, purchased: boolean)
		if purchased then
			return
		end
		local buyer = Players:GetPlayerByUserId(userId)
		if not buyer then
			return
		end
		local profile = _dataService:GetProfile(buyer)
		local intent = profile and (profile.Data :: any).GiftIntent
		if type(intent) == "table"
			and (tonumber(intent.ReceiverUserId) or 0) > 0
			and intent.ProductId == productId
		then
			_clearIntent(buyer)
		end
	end)
end

return GiftingService
