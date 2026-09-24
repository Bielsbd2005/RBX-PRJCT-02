--!strict
--[[
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
	    re-entregar aunque la intención haya expirado o se haya limpiado entre
	    reintentos; si no, un reintento tardío caería al handler de cash y la compra
	    pagaría dos veces.
	  • Con GiftIntent activa para ese ProductId, el cash NO va al comprador. Antes de
	    entregar se persiste GiftDeliveries[PurchaseId]: los reintentos van al mismo
	    receptor aunque la intención caduque o cambie.
	    - receptor en este server → _depositGift a su PendingGifts (save confirmado);
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
local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)
local RateLimiter = require(script.Parent.Parent.Parent.utils.RateLimiter)
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
local _sendLimiter = RateLimiter.new(SEND_COOLDOWN)
local _claimLimiter = RateLimiter.new(CLAIM_COOLDOWN)
local _receiverChecks: { [number]: { at: number, accepts: boolean, reason: string } } = {}
-- Último SendGift por jugador: un envío que sale del yield ya superado no escribe su
-- intención (pisaría la del envío nuevo y el pago iría al receptor equivocado).
local _sendSeqByUserId: { [number]: number } = {}

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

	Online en este server → perfil en memoria (gratis). Si no → snapshot read-only
	cacheado RECEIVER_CHECK_TTL. Sin perfil (vista nil) o con uno que solo tiene
	messages (SessionLoadCount == 0) nunca ha jugado: se corta ANTES de cobrar Robux.
	Con la API caída (apiOk=false) se falla abierto.
	TOCTOU asumido: si el receptor desactiva los regalos entre el prompt y el receipt,
	la entrega sigue (el Robux ya se pagó y el opt-out es anti-spam, no una barrera).
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
	if apiOk then
		if view == nil or (tonumber(view.SessionLoadCount) or 0) <= 0 then
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

-- Corre en thread propio (yielda: view offline).
function GiftingService:_handleSendGift(player: Player, data: Network.SendGiftPayload): ()
	local seq = (_sendSeqByUserId[player.UserId] or 0) + 1
	_sendSeqByUserId[player.UserId] = seq

	local product = StoreProducts.Cash.ByProductId[data.productId]
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

	-- El jugador pudo irse, o mandar otro SendGift, durante el yield de arriba.
	if player.Parent ~= Players or _sendSeqByUserId[player.UserId] ~= seq then
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

function GiftingService:ProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision?
	local product = StoreProducts.Cash.ByProductId[receiptInfo.ProductId]
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

	-- Idempotencia ANTES de mirar la intención (ver cabecera): un receipt ya procesado
	-- jamás re-entrega ni re-concede.
	local purchaseId = tostring(receiptInfo.PurchaseId)
	if _dataService:IsReceiptProcessed(buyer, purchaseId) then
		if _dataService:SaveReceipt(buyer, purchaseId) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Un intento anterior ya empezó a entregar este receipt: se reentrega al MISMO
	-- receptor sin mirar GiftIntent. Si cayera a compra normal por TTL, el comprador
	-- cobraría el cash y el receptor también (el MessageAsync de ese intento completa tarde).
	local deliveries = (profile.Data :: any).GiftDeliveries
	local prior = if type(deliveries) == "table" then deliveries[purchaseId] else nil
	local receiverUserId: number
	if type(prior) == "table" and (tonumber(prior.ReceiverUserId) or 0) > 0 then
		receiverUserId = math.floor(tonumber(prior.ReceiverUserId) :: number)
	else
		local intent = (profile.Data :: any).GiftIntent
		local hasIntent = type(intent) == "table" and (tonumber(intent.ReceiverUserId) or 0) > 0
		if not hasIntent
			or intent.ProductId ~= receiptInfo.ProductId
			or os.time() - (tonumber(intent.CreatedAt) or 0) > INTENT_TTL
		then
			-- Intención para ESTE producto pero caducada: el regalo pasa a compra normal; warn
			-- para no perderlo en silencio.
			if hasIntent and intent.ProductId == receiptInfo.ProductId then
				warn(("[GiftingService] Intent de regalo para product %s caducó (edad %ds > %ds); receipt tratado como compra normal.")
					:format(tostring(receiptInfo.ProductId), os.time() - (tonumber(intent.CreatedAt) or 0), INTENT_TTL))
			end
			-- Sin intención activa y sin entrega intentada: compra normal. Trade-off asumido:
			-- preferible a una intención eterna que desvíe compras normales futuras del mismo pack.
			return nil
		end
		receiverUserId = math.floor(tonumber(intent.ReceiverUserId) :: number)
		if not _dataService:BatchUpdate(buyer, {
			{ path = { "GiftDeliveries", purchaseId }, value = {
				ReceiverUserId = receiverUserId,
				ProductId = product.ProductId,
				At = os.time(),
			} },
		}) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	-- La marca debe estar en disco antes del primer intento de entrega: si el server cae
	-- con la entrega hecha y la marca solo en memoria, el reintento no la vería.
	local markPersisted = _dataService:SaveAndConfirm(buyer, function(lastSaved: any): boolean
		local saved = lastSaved.GiftDeliveries
		return type(saved) == "table" and saved[purchaseId] ~= nil
	end)
	if not markPersisted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

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
		elseif status ~= "error" then
			-- En memoria no basta: el receipt del comprador se consume al conceder.
			delivered = _dataService:SaveAndConfirm(receiver, function(lastSaved: any): boolean
				local pending = lastSaved.PendingGifts
				local claimed = lastSaved.ClaimedGifts
				return (type(pending) == "table" and pending[purchaseId] ~= nil)
					or (type(claimed) == "table" and claimed[purchaseId] ~= nil)
			end)
		end
	else
		delivered = _dataService:MessageProfile(receiverUserId, _giftMessagePayload(purchaseId, gift))
	end

	if not delivered then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- Roblox reintenta
	end

	-- Bookkeeping del comprador: receipt + Robux gastados, atómico y confirmado en disco
	-- ANTES de conceder. Si el server muriera antes, el reintento re-entrega por
	-- GiftDeliveries y el ledger ClaimedGifts del receptor evita el doble cobro.
	local updates: { any } = {
		{ path = { "Stats", "TotalRobuxSpent" }, delta = product.RobuxPrice },
		{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
	}
	-- Solo si la intención sigue siendo la de este regalo: un SendGift posterior no se pisa.
	local currentIntent = (profile.Data :: any).GiftIntent
	if type(currentIntent) == "table"
		and currentIntent.ProductId == product.ProductId
		and tonumber(currentIntent.ReceiverUserId) == receiverUserId
	then
		for _, entry in _intentClearEntries() do
			table.insert(updates, entry)
		end
	end
	local ok = _dataService:BatchUpdate(buyer, updates)
	if not ok or not _dataService:SaveReceipt(buyer, purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	TelemetryService.RecordPurchase({
		userId = buyer.UserId,
		purchaseId = purchaseId,
		productId = product.ProductId,
		sku = product.ButtonName,
		robuxPrice = product.RobuxPrice,
		cashGranted = product.CashAmount,
		kind = "Gift",
		-- El par comprador→receptor es lo que hace medible el multiplicador
		-- social de la vista de Gifting.
		receiverUserId = receiverUserId,
	})

	Network.Gifting.GiftDelivered.SendTo({
		receiverUserId = tostring(receiverUserId),
	}, buyer)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

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

-- Sin yields entre leer y borrar el regalo: ByteNet corre cada packet en su propio
-- hilo, y un yield aquí dejaría que dos ClaimGift del mismo regalo cobraran ambos.
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
		-- El cash regalado lo compró el remitente con Robux: cuenta también en
		-- el contador de comprado, para que la telemetría pueda restar y medir
		-- el ritmo JUGADO sin regalos dentro.
		{ path = { "Stats", "TotalCashPurchased" }, delta = amount },
		-- Ledger anti doble-claim: si este giftId (PurchaseId) volviera a
		-- entregarse (receipt/message re-entregado tras un crash), _depositGift
		-- lo rechaza. DataService lo acota por número al cargar el perfil.
		{ path = { "ClaimedGifts", giftId }, value = os.time() },
	})
	if not ok then
		_dataService:SetValue(player, { "PendingGifts", giftId }, gift)
		_respondClaim(player, false, giftId, "Something went wrong. Try again.", 0)
		return
	end

	TelemetryService.RecordFlow(player, "source", "Gift", amount, tostring(gift.ProductId), "Cash")
	_respondClaim(player, true, giftId, "", amount)
end

function GiftingService:Start(dataService: DataService): ()
	if _started then
		return
	end
	_started = true
	_dataService = dataService

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

	Network.Gifting.SendGift.Listen(function(data: Network.SendGiftPayload, player: Player)
		if not NetGuards.validate(data, {
			receiverUserId = M.UserIdString,
			productId = { kind = "number", integer = true, min = 1 },
		}) then
			return
		end
		if not _sendLimiter:tryConsume(player) then
			return
		end
		task.spawn(function()
			GiftingService:_handleSendGift(player, data)
		end)
	end)

	Network.Gifting.ClaimGift.Listen(function(data: Network.ClaimGiftPayload, player: Player)
		if not NetGuards.validate(data, { giftId = M.GiftId }) then
			return
		end
		if not _claimLimiter:tryConsume(player) then
			return
		end
		GiftingService:_handleClaimGift(player, data.giftId)
	end)

	-- Prompt cancelado → limpiar la intención para que una compra normal posterior del
	-- mismo pack no se desvíe como regalo. Con purchased=true no se toca: la consume
	-- ProcessReceipt (limpiar aquí perdería la carrera contra el receipt). Residual
	-- asumido: si un regalo ya comprado sigue reintentando y el jugador cancela un prompt
	-- normal del mismo pack, ese receipt pasa a compra normal (cash al comprador).
	Players.PlayerRemoving:Connect(function(player: Player)
		_sendSeqByUserId[player.UserId] = nil
	end)

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
