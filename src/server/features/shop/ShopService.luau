--!strict
--[[
	Transacciones de la tienda vía ByteNet.

	Flujo de una compra (BuyItem):
	  1. Cliente envía Network.Shop.BuyItem
	  2. ShopService valida: cooldown → ítem existe → nivel suficiente → saldo suficiente → no poseído
	  3. DataService:BatchUpdate aplica la transacción atómica (saldo − precio, ítem = true, auto-equip si aplica)
	  4. Network.Shop.Response confirma al cliente

	Flujo de equip (EquipItem):
	  1. Cliente envía Network.Shop.EquipItem
	  2. ShopService valida: cooldown → ítem existe → jugador lo posee
	  3. DataService:SetValue actualiza el Loadout
	  4. Network.Shop.Response confirma al cliente

	_itemCache se indexa category → itemId para evitar colisiones entre IDs
	repetidos de categorías distintas.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared   = ReplicatedStorage:WaitForChild("Shared")

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)
type DataService = DataServiceMod.DataServiceModule

local Network     = require(Shared.networking.Network)
local NetGuards   = require(Shared.networking.NetGuards)
local RateLimiter = require(script.Parent.Parent.Parent.utils.RateLimiter)
local InventoryRepository = require(Shared.data.InventoryRepository)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local Currency = require(Shared.constants.Currency)
local LockerConfig = require(Shared.constants.LockerConfig)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local WeaponCategory = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local LockerCategory = require(Shared.constants.LockerCategory)

local M = NetGuards.MAX

local CATEGORY_TO_LOADOUT_SLOT = LockerConfig.CategoryToLoadoutSlot :: { [string]: string }
local WEAPON_WRAPS_PATH_BY_CATEGORY = {
	Main = { "Loadout", "MainWeaponWraps" },
	Special = { "Loadout", "SpecialWeaponWraps" },
} :: { [string]: { string } }

local function _resolveWeaponCategory(value: string?): string?
	if WeaponCategory.isValid(value) then
		return value
	end

	return nil
end

local function _resolveWeaponId(rawWeaponId: string?, fallbackWeaponId: string?): string
	if type(rawWeaponId) == "string" and rawWeaponId ~= "" then
		return rawWeaponId
	end

	if type(fallbackWeaponId) == "string" and fallbackWeaponId ~= "" then
		return fallbackWeaponId
	end

	return ItemDefaults.ITEM_ID
end

local function _ownsTargetWeapon(profileData: any, weaponCategory: string, weaponId: string): boolean
	if not WeaponCategory.isValid(weaponCategory) then
		return false
	end
	return InventoryRepository.ownsWeapon(profileData, weaponCategory :: WeaponCategory.WeaponCategory, weaponId)
end

local function _getOwnedWeaponWrap(profileData: any, weaponCategory: string, weaponId: string, wrapId: string): boolean
	if not WeaponCategory.isValid(weaponCategory) then
		return false
	end
	return InventoryRepository.ownsWeaponWrap(profileData, weaponCategory :: WeaponCategory.WeaponCategory, weaponId, wrapId)
end

-- Segundos entre dos acciones del mismo tipo por jugador.
local COOLDOWN = 0.3

-- Frases enteras por moneda (el %d es el precio) para poder ajustarlas por moneda.
local INSUFFICIENT_FUNDS_MESSAGE: { [string]: string } = {
	[Currency.CASH] = "Not enough Cash. You need %d.",
	[Currency.GEMS] = "Not enough Gems. You need %d.",
}

local _itemCache: { [string]: { [string]: any } } = {}

-- Se marca solo tras un éxito real: una compra rechazada no castiga al jugador.
local _limiter = RateLimiter.new(COOLDOWN)

-- nil hasta Start(); los call sites siempre corren después (Start es la primera
-- llamada del bootstrap).
local _dataService: DataService = nil :: any
local _started = false

local function _getPath(data: any, path: { string }): any
	local pointer: any = data
	for _, key in path do
		if type(pointer) ~= "table" then
			return nil
		end
		pointer = pointer[key]
	end
	return pointer
end

local function _onBuyItem(data: Network.ShopItemPayload, player: Player): ()
	-- ByteNet no impone maxLength en strings: se rechazan payloads largos antes de
	-- gsub/concat/lookup (DoS asimétrico).
	if not NetGuards.validate(data, {
		itemId         = M.Id,
		category       = M.Category,
		weaponCategory = M.Category,
		weaponId       = M.Id,
	}) or data.itemId == "" then
		Network.Shop.Response.SendTo({ success = false, message = "Invalid request." }, player)
		return
	end

	-- Cooldown sin marcar: se marca tras éxito real.
	if not _limiter:isReady(player, "buy") then
		Network.Shop.Response.SendTo({ success = false, message = "Too many requests. Slow down." }, player)
		return
	end

	-- Solo claves de _itemCache son válidas: la categoría queda whitelisted.
	local categoryCache = _itemCache[data.category]
	local itemConfig = categoryCache and categoryCache[data.itemId]
	if not itemConfig then
		Network.Shop.Response.SendTo({ success = false, message = "That item doesn't exist." }, player)
		return
	end

	if itemConfig.CanPurchase ~= true then
		Network.Shop.Response.SendTo({
			success = false,
			message = "That item isn't available for purchase.",
		}, player)
		return
	end

	if itemConfig.isBPExclusive == true or BattlePassConfig.IsBPExclusive(data.category, data.itemId) then
		Network.Shop.Response.SendTo({
			success = false,
			message = "That item is only available in the Battle Pass.",
		}, player)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		Network.Shop.Response.SendTo({ success = false, message = "Your data isn't loaded yet." }, player)
		return
	end

	local weaponCategoryForWraps: string? = nil
	local weaponIdForWraps: string? = nil

	if data.category == LockerCategory.WEAPON_WRAPS then
		weaponCategoryForWraps = _resolveWeaponCategory(data.weaponCategory)
		if not weaponCategoryForWraps then
			Network.Shop.Response.SendTo({ success = false, message = "Invalid weapon category for wraps." }, player)
			return
		end

		local weaponSlot = CATEGORY_TO_LOADOUT_SLOT[weaponCategoryForWraps]
		local equippedWeaponId = if weaponSlot then profile.Data.Loadout[weaponSlot] else nil
		weaponIdForWraps = _resolveWeaponId(data.weaponId, equippedWeaponId)

		if not _ownsTargetWeapon(profile.Data, weaponCategoryForWraps, weaponIdForWraps) then
			Network.Shop.Response.SendTo({ success = false, message = "You don't own that weapon." }, player)
			return
		end

		if _getOwnedWeaponWrap(profile.Data, weaponCategoryForWraps, weaponIdForWraps, data.itemId) then
			Network.Shop.Response.SendTo({ success = false, message = "You already own this wrap for that weapon." }, player)
			return
		end
	else
		local alreadyOwned = _getPath(profile.Data.Inventory, { data.category, data.itemId })
		if alreadyOwned then
			Network.Shop.Response.SendTo({ success = false, message = "You already own this item." }, player)
			return
		end
	end

	local playerLevel: number = profile.Data.Stats.Level or 0
	if playerLevel < (itemConfig.LevelRequired or 1) then
		Network.Shop.Response.SendTo({
			success = false,
			message = "You need level " .. tostring(itemConfig.LevelRequired) .. " to buy this item.",
		}, player)
		return
	end

	-- Saldo EN LA MONEDA DEL ÍTEM. `Currency` es opcional en ItemsConfig y resolve()
	-- cae a Cash con cualquier otro valor.
	local currency = Currency.resolve(itemConfig.Currency)
	local balancePath = Currency.balancePath(currency)
	local currentBalance: number = _getPath(profile.Data, balancePath) or 0
	local price: number = itemConfig.Price or 0
	if currentBalance < price then
		Network.Shop.Response.SendTo({
			success = false,
			message = INSUFFICIENT_FUNDS_MESSAGE[currency]:format(price),
		}, player)
		return
	end

	-- Si la categoría es equipable, el Loadout se actualiza en la misma operación.
	-- El saldo se descuenta con delta para evitar TOCTOU si otro flujo (kill, claim,
	-- otra compra) muta el stat entre la lectura y el write.
	local updates = {
		{ path = balancePath, delta = -price },
	}

	if data.category == LockerCategory.WEAPON_WRAPS then
		local resolvedWeaponCategory = weaponCategoryForWraps :: string
		local resolvedWeaponId = weaponIdForWraps :: string
		local wrapUpdates = _dataService:GrantWeaponWrapUpdates(data.itemId, {
			{ category = resolvedWeaponCategory, weaponId = resolvedWeaponId },
		}, "Shop")
		table.move(wrapUpdates, 1, #wrapUpdates, #updates + 1, updates)

		local wrapsRootPath = WEAPON_WRAPS_PATH_BY_CATEGORY[resolvedWeaponCategory]
		if wrapsRootPath then
			table.insert(updates, {
				path = { wrapsRootPath[1], wrapsRootPath[2], resolvedWeaponId },
				value = data.itemId,
			})
		end
	else
		table.insert(updates, { path = { "Inventory", data.category, data.itemId }, value = true })
		table.insert(updates, {
			path = { "InventoryMeta", data.category, data.itemId },
			value = { AcquiredAt = os.time(), Source = "Shop" },
		})
	end

	-- WeaponWraps NO está en CATEGORY_TO_LOADOUT_SLOT (el wrap equipado es
	-- por-arma vía MainWeaponWraps/SpecialWeaponWraps, ya gestionado arriba).
	local loadoutSlot = CATEGORY_TO_LOADOUT_SLOT[data.category]
	if loadoutSlot then
		table.insert(updates, { path = { "Loadout", loadoutSlot }, value = data.itemId })
	end

	if WeaponCategory.isValid(data.category) then
		table.insert(updates, {
			path = { "Inventory", "WeaponWrapsByWeapon", data.category, data.itemId, ItemDefaults.ITEM_ID },
			value = true,
		})
	end

	local success = _dataService:BatchUpdate(player, updates)

	if success then
		_limiter:mark(player, "buy")

		-- Forzar el guardado ANTES de registrar la compra: BatchUpdate solo escribe en
		-- memoria y el autosave de ProfileStore llega hasta 30 s después; si el server
		-- cae en esa ventana, la telemetría tendría un sink fantasma y un ítem vendido
		-- que nadie posee. Si el Save falla se registra igual y se avisa: el jugador ya
		-- tiene el ítem y el saldo descontado en memoria.
		if not _dataService:ForceSave(player) then
			warn(("[ShopService] compra de %s por %s registrada sin guardado confirmado"):format(
				tostring(data.itemId),
				player.Name
			))
		end

		-- `itemId` va como campo propio (no concatenado al transactionType): la vista
		-- de Shop desglosa por ítem sin parsear claves compuestas.
		TelemetryService.RecordFlow(player, "sink", "Shop::" .. data.category, price, data.itemId, currency)
		TelemetryService.RecordItem(player, "ShopItem::" .. data.category, data.itemId)
		-- Estado del jugador EN la compra (nivel, horas) para validar la escalera de
		-- precios; el acumulador de RecordFlow agrega por día y no lo conserva.
		TelemetryService.RecordItemPurchase(player, {
			userId = player.UserId,
			category = data.category,
			itemId = data.itemId,
			price = price,
			currency = currency,
			level = playerLevel,
			xp = profile.Data.Stats.XP or 0,
			timePlayedSeconds = profile.Data.Stats.TimePlayedSeconds or 0,
			balanceBefore = currentBalance,
			weaponCategory = weaponCategoryForWraps,
			weaponId = weaponIdForWraps,
		})

		Network.Shop.Response.SendTo({
			success = true,
			message = if data.category == LockerCategory.WEAPON_WRAPS
				then itemConfig.Name .. " purchased and equipped on the selected weapon."
				else if loadoutSlot
				then itemConfig.Name .. " purchased and equipped."
				else itemConfig.Name .. " purchased.",
		}, player)
	else
		Network.Shop.Response.SendTo({
			success = false,
			message = "Something went wrong. Try again.",
		}, player)
	end
end

local function _onEquipItem(data: Network.ShopItemPayload, player: Player): ()
	if not NetGuards.validate(data, {
		category       = M.Category,
		itemId         = M.Id,
		weaponCategory = M.Category,
		weaponId       = M.Id,
	}) or data.itemId == "" then
		Network.Shop.Response.SendTo({ success = false, message = "Invalid request." }, player)
		return
	end

	local categoryCache = _itemCache[data.category]
	local itemConfig = categoryCache and categoryCache[data.itemId]
	if not itemConfig then
		Network.Shop.Response.SendTo({ success = false, message = "That item doesn't exist." }, player)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		Network.Shop.Response.SendTo({ success = false, message = "Your data isn't loaded yet." }, player)
		return
	end

	-- Cooldown por slot: el Locker manda juntos los equips de varios slots. La clave sale
	-- del slot validado, nunca de strings del cliente: si no, variándolos se salta el
	-- cooldown y el mapa del limitador crece sin tope.
	local function isRateLimited(cooldownKey: string): boolean
		if _limiter:isReady(player, cooldownKey) then
			return false
		end
		Network.Shop.Response.SendTo({ success = false, message = "Too many requests. Slow down." }, player)
		return true
	end

	local ok = false
	local cooldownKey: string
	if data.category == LockerCategory.WEAPON_WRAPS then
		local weaponCategory = _resolveWeaponCategory(data.weaponCategory)
		if not weaponCategory then
			Network.Shop.Response.SendTo({ success = false, message = "Invalid target weapon for wraps." }, player)
			return
		end

		local wrapsRootPath = WEAPON_WRAPS_PATH_BY_CATEGORY[weaponCategory]
		if not wrapsRootPath then
			Network.Shop.Response.SendTo({ success = false, message = "Invalid target weapon for wraps." }, player)
			return
		end

		local weaponSlot = CATEGORY_TO_LOADOUT_SLOT[weaponCategory]
		if not weaponSlot then
			Network.Shop.Response.SendTo({ success = false, message = "Invalid weapon slot." }, player)
			return
		end

		local equippedWeaponId = profile.Data.Loadout[weaponSlot]
		local targetWeaponId = _resolveWeaponId(data.weaponId, equippedWeaponId)

		if not _ownsTargetWeapon(profile.Data, weaponCategory, targetWeaponId) then
			Network.Shop.Response.SendTo({ success = false, message = "You don't own that weapon." }, player)
			return
		end

		if not _getOwnedWeaponWrap(profile.Data, weaponCategory, targetWeaponId, data.itemId) then
			Network.Shop.Response.SendTo({ success = false, message = "You don't own this wrap for that weapon." }, player)
			return
		end

		cooldownKey = "equip:wrap:" .. weaponCategory
		if isRateLimited(cooldownKey) then
			return
		end
		ok = _dataService:SetValue(player, { wrapsRootPath[1], wrapsRootPath[2], targetWeaponId }, data.itemId)
	else
		local isOwned = _getPath(profile.Data.Inventory, { data.category, data.itemId })
		if not isOwned then
			Network.Shop.Response.SendTo({ success = false, message = "You don't own this item." }, player)
			return
		end

		local loadoutSlot = CATEGORY_TO_LOADOUT_SLOT[data.category]
		if not loadoutSlot then
			Network.Shop.Response.SendTo({ success = false, message = "That category can't be equipped." }, player)
			return
		end

		cooldownKey = "equip:" .. loadoutSlot
		if isRateLimited(cooldownKey) then
			return
		end
		ok = _dataService:SetValue(player, { "Loadout", loadoutSlot }, data.itemId)
	end

	if ok then
		_limiter:mark(player, cooldownKey)
		Network.Shop.Response.SendTo({
			success = true,
			message = itemConfig.Name .. " equipped.",
		}, player)
	else
		Network.Shop.Response.SendTo({
			success = false,
			message = "Couldn't equip that. Try again.",
		}, player)
	end
end

local ShopService = {}
ShopService.__index = ShopService

-- `dataService` se inyecta para evitar require circular entre servicios.
function ShopService:Start(dataService: DataService): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	for category, items in ItemsConfig do
		_itemCache[category] = {}
		for itemId, config in items do
			local entry = table.clone(config)
			entry.category = category
			_itemCache[category][itemId] = entry
		end
	end


	Network.Shop.BuyItem.Listen(_onBuyItem)
	Network.Shop.EquipItem.Listen(_onEquipItem)
end

return ShopService
