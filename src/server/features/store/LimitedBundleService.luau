--!strict
--[[
	Bundles limitados (StoreProducts.Bundles): unidades contadas entre todos los
	servidores y un número de serie por compra.

	Contador: una clave por bundle en el DataStore LIMITED_STORE_NAME con
	{ Sold, Recent }. `UpdateAsync` es atómico entre servidores, así que dos compras
	nunca reciben el mismo número. `Recent` guarda los últimos PurchaseId con su número:
	un receipt reintentado recupera el suyo en vez de gastar otro. Se acota para que la
	clave siga pequeña; un reintento más viejo que eso deja un hueco en la numeración,
	nunca un número repetido.

	Agotado: la venta se cierra en `SellableUnits`, por debajo de `MaxUnits`. Lo que
	se cuele entre servidores después del cierre se entrega igual (un developer product
	no se devuelve) y cae en ese hueco.

	La compra propia pasa por BuyBundle: el servidor comprueba stock y posesión y lanza
	él el prompt. El regalo lo gestiona GiftingService con las funciones de aquí.
]]

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local StoreProducts = require(Shared.constants.StoreProducts)
local LimitedBundles = require(Shared.data.LimitedBundles)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)
local RateLimiter = require(script.Parent.Parent.Parent.utils.RateLimiter)
type DataService = DataServiceMod.DataServiceModule
type BundleDefinition = StoreProducts.BundleDefinition

-- Studio usa otro DataStore: probar no debe gastar números reales.
local LIMITED_STORE_NAME = if RunService:IsStudio() then "LimitedBundles_Studio" else "LimitedBundles"
local RECENT_MAX = 100
-- Lectura del contador para el stock que ve la tienda. Una GetAsync por bundle y
-- servidor: muy lejos del presupuesto de DataStore.
local STOCK_POLL_SECONDS = 60
local BUY_COOLDOWN = 1
-- Bloqueo mientras el prompt está abierto o su receipt en camino: un segundo prompt
-- cobraría un bundle que el jugador ya va a tener.
local PROMPT_LOCK_SECONDS = 30

local LimitedBundleService = {}

local _dataService: DataService = nil :: any
local _started = false
local _store: DataStore? = nil
local _buyLimiter = RateLimiter.new(BUY_COOLDOWN)
local _promptLockUntil: { [number]: number } = {}

local function _getStore(): DataStore?
	if not _store then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(LIMITED_STORE_NAME)
		end)
		if not ok then
			warn(`[LimitedBundleService] DataStore no disponible: {result}`)
			return nil
		end
		_store = result
	end
	return _store
end

-- Nunca baja (salvo ResetForTesting): una lectura vieja (caché de GetAsync) no debe
-- reabrir la venta.
local function _publishSold(bundle: BundleDefinition, sold: number)
	local current = LimitedBundles.getSold(bundle)
	if current and current >= sold then
		return
	end
	ReplicatedStorage:SetAttribute(LimitedBundles.soldAttributeName(bundle), sold)
end

local function _refreshStock(bundle: BundleDefinition)
	local store = _getStore()
	if not store then
		return
	end
	local ok, result = pcall(function()
		return store:GetAsync(bundle.Name)
	end)
	if not ok then
		warn(`[LimitedBundleService] No se pudo leer el stock de {bundle.Name}: {result}`)
		return
	end
	local sold = if type(result) == "table" then tonumber(result.Sold) else nil
	_publishSold(bundle, sold or 0)
end

--[[
	Número de serie para `purchaseId`, o nil si el DataStore falla (el receipt queda sin
	procesar y Roblox lo reintenta). Yielda. Idempotente por purchaseId mientras siga
	en `Recent`.
]]
function LimitedBundleService.ReserveSerial(bundle: BundleDefinition, purchaseId: string): number?
	local store = _getStore()
	if not store then
		return nil
	end

	local serial: number? = nil
	local sold = 0
	local ok, err = pcall(function()
		-- La transformación se repite si otro servidor escribe a la vez: `serial` y `sold`
		-- quedan con los de la última pasada, que es la que se guarda.
		store:UpdateAsync(bundle.Name, function(current: any)
			local state = if type(current) == "table" then current else {}
			local recent = if type(state.Recent) == "table" then state.Recent else {}
			sold = math.max(0, math.floor(tonumber(state.Sold) or 0))

			for _, entry in recent do
				if type(entry) == "table" and entry.Id == purchaseId then
					serial = tonumber(entry.Serial)
					return nil
				end
			end

			sold += 1
			serial = sold
			table.insert(recent, { Id = purchaseId, Serial = sold })
			while #recent > RECENT_MAX do
				table.remove(recent, 1)
			end
			return { Sold = sold, Recent = recent }
		end)
	end)
	if not ok or not serial then
		warn(`[LimitedBundleService] No se pudo reservar número de {bundle.Name} para {purchaseId}: {err}`)
		return nil
	end

	_publishSold(bundle, sold)
	if (serial :: number) > bundle.MaxUnits then
		warn(`[LimitedBundleService] {bundle.Name} entregó el #{serial}, por encima de MaxUnits {bundle.MaxUnits}`)
	end
	return serial
end

-- Motivo por el que el bundle no se vende ahora mismo, o nil.
function LimitedBundleService.SaleRejection(bundle: BundleDefinition): string?
	local sold = LimitedBundles.getSold(bundle)
	if sold == nil then
		return "The store isn't ready yet. Try again in a moment."
	end
	return if LimitedBundles.isSaleOpen(bundle, sold) then nil else "This bundle is sold out."
end

-- Motivo por el que este perfil no puede recibir el bundle, o nil.
function LimitedBundleService.OwnershipRejection(profileData: any, bundle: BundleDefinition, isSelf: boolean): string?
	if LimitedBundles.ownsBundle(profileData, bundle) then
		return if isSelf then "You already own this bundle." else "That player already owns this bundle."
	end
	local pending = profileData.PendingGifts
	if type(pending) == "table" then
		for _, gift in pending do
			if type(gift) == "table" and gift.BundleName == bundle.Name then
				return if isSelf
					then "You have this bundle waiting as a gift."
					else "That player already has this bundle waiting as a gift."
			end
		end
	end
	return nil
end

-- Mismas entradas que DataService:GrantWeaponWrapUpdates, con el número en el meta.
function LimitedBundleService.GrantUpdates(bundle: BundleDefinition, serial: number, source: string): { any }
	local updates: { any } = {}
	local now = os.time()
	for _, wrap in bundle.Wraps do
		table.insert(updates, {
			path = { "Inventory", "WeaponWrapsByWeapon", wrap.Category, wrap.WeaponId, wrap.WrapId },
			value = true,
		})
		table.insert(updates, {
			path = { "InventoryMeta", "WeaponWraps", wrap.WrapId },
			value = { AcquiredAt = now, Source = source, Serial = serial },
		})
	end
	return updates
end

local function _reject(player: Player, message: string)
	Network.Store.BundleRejected.SendTo({ message = message }, player)
end

function LimitedBundleService._handleBuyBundle(player: Player, bundleName: string)
	local bundle = StoreProducts.Bundles.ByName[bundleName]
	if not bundle or bundle.ProductId <= 0 then
		_reject(player, "This bundle isn't available.")
		return
	end
	local profile = _dataService:GetProfile(player)
	if not profile then
		_reject(player, "Your data isn't loaded yet.")
		return
	end
	if (_promptLockUntil[player.UserId] or 0) > os.clock() then
		_reject(player, "Your purchase is still being processed.")
		return
	end
	local saleRejection = LimitedBundleService.SaleRejection(bundle)
	if saleRejection then
		_reject(player, saleRejection)
		return
	end
	local rejection = LimitedBundleService.OwnershipRejection(profile.Data, bundle, true)
	if rejection then
		_reject(player, rejection)
		return
	end

	_promptLockUntil[player.UserId] = os.clock() + PROMPT_LOCK_SECONDS
	MarketplaceService:PromptProductPurchase(player, bundle.ProductId)
end

--[[
	Compra propia. nil si el ProductId no es de un bundle. Va detrás de GiftingService en
	el dispatcher: un receipt con intención de regalo nunca llega aquí.
	Mismo contrato de durabilidad que los packs (ServerBootstrap): idempotencia por
	PurchaseId y SaveReceipt confirmado antes de devolver PurchaseGranted.
]]
function LimitedBundleService.ProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision?
	local bundle = StoreProducts.Bundles.ByProductId[receiptInfo.ProductId]
	if not bundle then
		return nil
	end

	local buyer = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = buyer and _dataService:GetProfile(buyer)
	if not buyer or not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = tostring(receiptInfo.PurchaseId)
	if _dataService:IsReceiptProcessed(buyer, purchaseId) then
		if _dataService:SaveReceipt(buyer, purchaseId) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local updates: { any } = {
		{ path = { "Stats", "TotalRobuxSpent" }, delta = bundle.RobuxPrice },
		{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
	}

	-- Solo llega aquí saltándose BuyBundle (prompt lanzado desde el cliente). Sin número
	-- nuevo: el bundle ya lo tiene y gastarlo dejaría un hueco.
	local alreadyOwned = LimitedBundles.ownsBundle(profile.Data, bundle)
	local serial: number? = nil
	if alreadyOwned then
		warn(`[LimitedBundleService] {buyer.UserId} pagó {bundle.Name} ya poseyéndolo (receipt {purchaseId}): sin entrega.`)
	else
		serial = LimitedBundleService.ReserveSerial(bundle, purchaseId)
		if not serial then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		for _, entry in LimitedBundleService.GrantUpdates(bundle, serial :: number, "Bundle") do
			table.insert(updates, entry)
		end
	end

	if not _dataService:BatchUpdate(buyer, updates) or not _dataService:SaveReceipt(buyer, purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	_promptLockUntil[buyer.UserId] = nil

	TelemetryService.RecordPurchase({
		userId = buyer.UserId,
		purchaseId = purchaseId,
		productId = receiptInfo.ProductId,
		sku = bundle.Name,
		robuxPrice = bundle.RobuxPrice,
		cashGranted = 0,
		kind = "Bundle",
	})
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--[[
	Borra los contadores de todos los bundles, para /ResetData. Solo en Studio: fuera
	reiniciaría la numeración real y repetiría números que ya tienen los jugadores.
	Las GetAsync de otros servidores de prueba pueden seguir viendo el valor viejo unos
	segundos (caché de Roblox). Devuelve si se borraron todos.
]]
function LimitedBundleService.ResetForTesting(): boolean
	if not RunService:IsStudio() then
		return false
	end
	local store = _getStore()
	if not store then
		return false
	end

	local allOk = true
	for _, bundle in StoreProducts.Bundles.InOrder do
		local ok, err = pcall(function()
			store:RemoveAsync(bundle.Name)
		end)
		if ok then
			ReplicatedStorage:SetAttribute(LimitedBundles.soldAttributeName(bundle), 0)
		else
			allOk = false
			warn(`[LimitedBundleService] No se pudo reiniciar el contador de {bundle.Name}: {err}`)
		end
	end
	table.clear(_promptLockUntil)
	return allOk
end

function LimitedBundleService.Start(dataService: DataService): ()
	if _started then
		return
	end
	_started = true
	_dataService = dataService

	task.spawn(function()
		while true do
			for _, bundle in StoreProducts.Bundles.InOrder do
				if bundle.ProductId > 0 then
					_refreshStock(bundle)
				end
			end
			task.wait(STOCK_POLL_SECONDS)
		end
	end)

	Network.Store.BuyBundle.Listen(function(data: Network.BuyBundlePayload, player: Player)
		if not NetGuards.validate(data, { bundleName = NetGuards.MAX.Id }) then
			return
		end
		if not _buyLimiter:tryConsume(player) then
			return
		end
		LimitedBundleService._handleBuyBundle(player, data.bundleName)
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, purchased: boolean)
		if not purchased and StoreProducts.Bundles.ByProductId[productId] then
			_promptLockUntil[userId] = nil
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		_promptLockUntil[player.UserId] = nil
	end)
end

return LimitedBundleService
