--!strict
--[[
	Peticiones del Locker a ShopService: equipar y comprar, y la respuesta de cada una.

	Equipar es local: DataController muestra ya el loadout nuevo (override) y el envío al
	servidor espera a cambiar de categoría, cerrar o EQUIP_IDLE_FLUSH sin más clics
	(flushEquips). Por slot solo viaja el último elegido. Comprar es inmediato y bloquea la interacción hasta la respuesta o
	SHOP_REQUEST_TIMEOUT.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Client = script.Parent.Parent.Parent
local Network = require(Shared.networking.Network)
local LockerCategory = require(Shared.constants.LockerCategory)
local LockerConfig = require(Shared.constants.LockerConfig)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local CurrencyMod = require(Shared.constants.Currency)
local StoreProducts = require(Shared.constants.StoreProducts)
local DataController = require(Client.core.data.DataController)
local UIUtils = require(Client.core.ui.UIUtils)
local Notify = require(Client.core.ui.NotificationController)
local LockerCatalog = require(script.Parent.LockerCatalog)
local LockerInventoryState = require(script.Parent.LockerInventoryState)

type LockerCatalogItem = LockerCatalog.LockerCatalogItem

local SHOP_REQUEST_TIMEOUT = 5
-- Separación mínima entre equips del mismo slot: por encima del cooldown de
-- ShopService (por slot) para no recibir "Too many requests".
local EQUIP_SEND_SPACING = 0.35
-- Envío sin cambiar de pestaña: si no, salir del juego con el Locker abierto perdería
-- lo equipado.
local EQUIP_IDLE_FLUSH = 1

local CATEGORY_TO_LOADOUT_SLOT = LockerConfig.CategoryToLoadoutSlot :: { [string]: string }

-- equipPath: slot que el servidor equipa al comprar (nil si la categoría no se equipa).
type PendingPurchase = { item: LockerCatalogItem, equipPath: { string }? }

type UnsentEquip = {
	path: { string },
	category: string,
	itemId: string,
	weaponCategory: string,
	weaponId: string,
}

-- Shop.Response no dice a qué petición responde; llegan en orden de envío.
type ExpectedShopResponse = { kind: "buy" } | { kind: "equip", path: { string } }

export type Deps = {
	inventory: LockerInventoryState.LockerInventoryState,
	-- Categoría y nav abiertas ahora (nil con el locker cerrado).
	getNav: () -> (string?, string?),
	-- Repuebla una vista seleccionando `qualifiedId` (tras un fallo o timeout de compra).
	repopulate: (category: string, navKey: string, qualifiedId: string) -> (),
	refreshSelection: () -> (),
	onPurchased: () -> (),
}

export type LockerShopRequests = {
	isBusy: (self: LockerShopRequests) -> boolean,
	requestEquip: (self: LockerShopRequests, item: LockerCatalogItem) -> (),
	flushEquips: (self: LockerShopRequests) -> (),
	purchase: (self: LockerShopRequests, item: LockerCatalogItem) -> (),
	Destroy: (self: LockerShopRequests) -> (),
}

type Internal = LockerShopRequests & {
	_deps: Deps,
	_alive: boolean,
	_pendingPurchase: PendingPurchase?,
	_unsentEquips: { [string]: UnsentEquip },
	_lastEquipSentAt: { [string]: number },
	_expectedResponses: { ExpectedShopResponse },
	_idleFlushThread: thread?,
	_disconnectResponse: () -> (),
}

local LockerShopRequests = {}
LockerShopRequests.__index = LockerShopRequests

-- ¿Queda otro equip de este slot por enviar o por responder? Entonces el override es
-- suyo y un fallo anterior no debe quitarlo.
local function hasNewerEquipFor(self: Internal, path: { string }): boolean
	local key = table.concat(path, "/")
	if self._unsentEquips[key] then
		return true
	end
	for _, expected in self._expectedResponses do
		if expected.kind == "equip" and table.concat(expected.path, "/") == key then
			return true
		end
	end
	return false
end

local function onResponse(self: Internal, response: { success: boolean, message: string })
	local expected = table.remove(self._expectedResponses, 1)
	if expected and expected.kind == "equip" then
		if not response.success then
			Notify.warning(if response.message ~= "" then response.message else "Couldn't equip that.")
			if not hasNewerEquipFor(self, expected.path) then
				DataController:clearLoadoutOverride(expected.path)
			end
		end
		return
	end

	local purchase = self._pendingPurchase
	self._pendingPurchase = nil

	if response.success then
		if purchase then
			-- El servidor ya equipó lo comprado: un equip pendiente u override del mismo
			-- slot lo pisaría (en pantalla ahora, en el servidor al siguiente flush).
			local path = purchase.equipPath
			if path then
				self._unsentEquips[table.concat(path, "/")] = nil
				DataController:clearLoadoutOverride(path)
			end
			self._deps.onPurchased()
		end
		return
	end

	Notify.warning(if response.message ~= "" then response.message else "That purchase couldn't be completed.")
	task.defer(function()
		local category, navKey = self._deps.getNav()
		if purchase and category and navKey then
			self._deps.repopulate(category, navKey, purchase.item.qualifiedId)
		else
			self._deps.refreshSelection()
		end
	end)
end

function LockerShopRequests.new(deps: Deps): LockerShopRequests
	local self = setmetatable({
		_deps = deps,
		_alive = true,
		_pendingPurchase = nil,
		_unsentEquips = {},
		_lastEquipSentAt = {},
		_expectedResponses = {},
		_idleFlushThread = nil,
	}, LockerShopRequests) :: any
	self._disconnectResponse = Network.Shop.Response.Listen(function(response)
		onResponse(self, response)
	end)
	return self
end

-- Con una compra en vuelo la grid no acepta clics.
function LockerShopRequests.isBusy(self: Internal): boolean
	return self._pendingPurchase ~= nil
end

-- Path del Loadout que ocupa `item` (el mismo que escribe ShopService), o nil si su
-- categoría no se equipa.
local function loadoutPathFor(item: LockerCatalogItem, weaponCategory: string, weaponId: string): { string }?
	if item.Category == LockerCategory.WEAPON_WRAPS then
		local wrapsKey = if weaponCategory == WeaponCategoryMod.MAIN then "MainWeaponWraps" else "SpecialWeaponWraps"
		return { wrapsKey, weaponId }
	end
	local slot = CATEGORY_TO_LOADOUT_SLOT[item.Category]
	return if slot then { slot } else nil
end

function LockerShopRequests.requestEquip(self: Internal, item: LockerCatalogItem)
	local weaponCategory, weaponId = self._deps.inventory:getWrapRequestContext(item.Category)
	local path = loadoutPathFor(item, weaponCategory, weaponId)
	if not path then
		return
	end

	self._unsentEquips[table.concat(path, "/")] = {
		path = path,
		category = item.Category,
		itemId = item.id,
		weaponCategory = weaponCategory,
		weaponId = weaponId,
	}
	DataController:setLoadoutOverride(path, item.id)

	-- Cada clic reinicia la espera: el spam de clics se sigue agrupando en un envío.
	if self._idleFlushThread then
		task.cancel(self._idleFlushThread)
	end
	self._idleFlushThread = task.delay(EQUIP_IDLE_FLUSH, function()
		self._idleFlushThread = nil
		self:flushEquips()
	end)
end

function LockerShopRequests.flushEquips(self: Internal)
	local idleFlush = self._idleFlushThread
	if idleFlush and idleFlush ~= coroutine.running() then
		task.cancel(idleFlush)
	end
	self._idleFlushThread = nil
	for key, equip in self._unsentEquips do
		self._unsentEquips[key] = nil
		local function send()
			self._lastEquipSentAt[key] = os.clock()
			table.insert(self._expectedResponses, { kind = "equip", path = equip.path })
			Network.Shop.EquipItem.Send({
				category = equip.category,
				itemId = equip.itemId,
				weaponCategory = equip.weaponCategory,
				weaponId = equip.weaponId,
			})
		end
		local wait = (self._lastEquipSentAt[key] or -math.huge) + EQUIP_SEND_SPACING - os.clock()
		if wait > 0 then
			task.delay(wait, send)
		else
			send()
		end
	end
end

-- Saldo del jugador en la moneda del ítem (Cash por defecto). El server cobra de este
-- mismo stat (ShopService + Shared.constants.Currency).
local function getBalanceFor(self: Internal, item: LockerCatalogItem): number
	local stats = self._deps.inventory:getStats()
	if CurrencyMod.resolve(item.Currency) == CurrencyMod.GEMS then
		-- `or 0` cubre el perfil que aún no pasó por Reconcile.
		return stats.Gems or 0
	end
	return stats.Cash
end

local function promptBestFitPack(self: Internal, item: LockerCatalogItem)
	local isGems = CurrencyMod.resolve(item.Currency) == CurrencyMod.GEMS
	local deficit = item.Price - getBalanceFor(self, item)
	local packs: { any } = if isGems then StoreProducts.Gems.InOrder else StoreProducts.Cash.InOrder

	local bestPack: any = nil
	for _, pack in packs do
		local amount = if isGems then pack.GemAmount else pack.CashAmount
		if amount >= deficit and pack.ProductId > 0 then
			bestPack = pack
			break
		end
	end
	if not bestPack then
		local largest = packs[#packs]
		if largest and largest.ProductId > 0 then
			bestPack = largest
		end
	end

	if bestPack then
		MarketplaceService:PromptProductPurchase(Players.LocalPlayer, bestPack.ProductId)
	end
end

-- Si falta saldo se ofrece el pack que mejor encaja. Cada rechazo avisa por toast: el
-- botón sigue visible con el ítem bloqueado y si no el clic no da feedback.
local function canPurchase(self: Internal, item: LockerCatalogItem): boolean
	if self._pendingPurchase then
		return false
	end
	local inventory = self._deps.inventory
	if inventory:getLevel() < item.LevelRequired then
		Notify.warning(`You need level {item.LevelRequired} to buy this item.`)
		return false
	end
	if inventory:isItemOwned(item) then
		Notify.warning("You already own this item.")
		return false
	end
	if item.KillGoal ~= nil and item.KillGoal > 0 then
		Notify.warning(`Unlock this wrap with {item.KillGoal} kills.`)
		return false
	end
	if item.MasteryScope then
		Notify.warning("Unlock this wrap through weapon mastery.")
		return false
	end
	if getBalanceFor(self, item) < item.Price then
		local currencyName = if CurrencyMod.resolve(item.Currency) == CurrencyMod.GEMS then "Gems" else "Cash"
		Notify.warning(`Not enough {currencyName}. You need {UIUtils.formatCashAmount(item.Price)}.`)
		promptBestFitPack(self, item)
		return false
	end
	return true
end

function LockerShopRequests.purchase(self: Internal, item: LockerCatalogItem)
	if not canPurchase(self, item) then
		return
	end

	local weaponCategory, weaponId = self._deps.inventory:getWrapRequestContext(item.Category)
	local purchase: PendingPurchase = { item = item, equipPath = loadoutPathFor(item, weaponCategory, weaponId) }
	self._pendingPurchase = purchase
	table.insert(self._expectedResponses, { kind = "buy" })
	-- Snapshot de categoría/nav: si el usuario navega durante el timeout, no se
	-- repuebla la vista nueva con un qualifiedId que no es suyo.
	local buyCategory, buyNavKey = self._deps.getNav()
	task.delay(SHOP_REQUEST_TIMEOUT, function()
		if not self._alive or self._pendingPurchase ~= purchase then
			return
		end
		self._pendingPurchase = nil
		local category, navKey = self._deps.getNav()
		if buyCategory and buyNavKey and category == buyCategory and navKey == buyNavKey then
			self._deps.repopulate(buyCategory, buyNavKey, item.qualifiedId)
		end
	end)

	Network.Shop.BuyItem.Send({
		itemId = item.id,
		category = item.Category,
		weaponCategory = weaponCategory,
		weaponId = weaponId,
	})
end

function LockerShopRequests.Destroy(self: Internal)
	self._alive = false
	self._disconnectResponse()
end

return LockerShopRequests
