--!strict
--[[
	ShopService.luau  (Server)
	Gestiona las transacciones de la tienda usando ByteNet para comunicación
	de baja latencia (reemplaza RemoteFunction/RemoteEvent clásicos).

	Flujo de una compra (BuyItem):
	  1. Cliente envía Network.Shop.BuyItem via ByteNet
	  2. ShopService valida: cooldown → ítem existe → nivel suficiente → cash suficiente → no poseído
	  3. DataService:BatchUpdate aplica la transacción atómica (cash − precio, ítem = true, auto-equip si aplica)
	  4. Network.Shop.Response confirma al cliente

	Flujo de equip (EquipItem):
	  1. Cliente envía Network.Shop.EquipItem via ByteNet
	  2. ShopService valida: cooldown → ítem existe → jugador lo posee
	  3. DataService:SetValue actualiza el Loadout
	  4. Network.Shop.Response confirma al cliente

	Cache O(1):
	  En Start(), se construye _itemCache: category → itemId → { config + category }.
	  El lookup evita colisiones entre IDs repetidos de categorías distintas.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared   = ReplicatedStorage:WaitForChild("Shared")

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local Sift = require(Packages.sift) :: any

local Network     = require(Shared.networking.Network)
local NetGuards   = require(Shared.networking.NetGuards)
local InventoryRepository = require(Shared.data.InventoryRepository)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
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

-- Helpers de ownership delegan a InventoryRepository (single source of truth).
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

-- Cooldown por acción (segundos)
local COOLDOWN = 0.3

-- ────────────────────────────────────────────────────────────
-- ESTADO DEL MÓDULO
-- ────────────────────────────────────────────────────────────

-- Cache por categoría → itemId → config.
local _itemCache: { [string]: { [string]: any } } = {}

-- Cooldowns agrupados por jugador.
local _cooldowns: { [number]: { [string]: number } } = {}

-- DataService inyectado en Start() — typed para que :GetProfile/:BatchUpdate
-- etc. se chequeen en compile-time (el `:: any` previo perdía toda la safety).
-- Cast a `any` al init: en runtime es nil hasta Start(), pero los call sites
-- siempre corren después (Start es la primera llamada del bootstrap).
local _dataService: DataService = nil :: any
local _started = false

-- ────────────────────────────────────────────────────────────
-- HELPERS
-- ────────────────────────────────────────────────────────────

-- Devuelve true si la acción está fuera de cooldown (no muta state).
local function _isCooldownReady(player: Player, action: string): boolean
	local playerCooldowns = _cooldowns[player.UserId]
	if not playerCooldowns then
		return true
	end
	local last = playerCooldowns[action] or 0
	return time() - last >= COOLDOWN
end

-- Marca el cooldown como activo. Llamar tras validación exitosa.
local function _markCooldown(player: Player, action: string)
	local playerCooldowns = _cooldowns[player.UserId]
	if not playerCooldowns then
		playerCooldowns = {}
		_cooldowns[player.UserId] = playerCooldowns
	end
	playerCooldowns[action] = time()
end

--[[
	Navega profile.Data con una ruta de claves.
	Devuelve el valor en la hoja, o nil si algún nivel es nil.
]]
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

-- ────────────────────────────────────────────────────────────
-- HANDLERS
-- ────────────────────────────────────────────────────────────

local function _onBuyItem(data: { itemId: string, category: string, weaponCategory: string, weaponId: string }, player: Player): ()
	-- Validación 0: tipos + caps de longitud. ByteNet no impone maxLength en
	-- strings, así que rechazamos payloads con strings excesivos antes de hacer
	-- gsub/concat/lookup (DoS asimétrico — cliente paga poco, server paga O(n)).
	if not NetGuards.validate(data, {
		itemId         = M.Id,
		category       = M.Category,
		weaponCategory = M.Category,
		weaponId       = M.Id,
	}) or data.itemId == "" then
		Network.Shop.Response.SendTo({ success = false, message = "Payload inválido." }, player)
		return
	end

	-- Validación 1: cooldown (sin marcar; se marca tras éxito real)
	if not _isCooldownReady(player, "buy") then
		Network.Shop.Response.SendTo({ success = false, message = "Demasiadas peticiones." }, player)
		return
	end

	-- Validación 2: ítem existe en cache (la categoría queda implícitamente
	-- whitelisted: solo claves de _itemCache son válidas).
	local categoryCache = _itemCache[data.category]
	local itemConfig = categoryCache and categoryCache[data.itemId]
	if not itemConfig then
		Network.Shop.Response.SendTo({ success = false, message = "Ítem no encontrado." }, player)
		return
	end

	-- Validación 2.5: items exclusivos del Battle Pass no se venden.
	-- Defense in depth: el Locker ya los oculta a quien no los posee, pero un
	-- cliente malicioso podría reconstruir el packet con el itemId conocido.
	-- BP-exclusive si lo flagea ItemsConfig manualmente O si aparece como
	-- reward en cualquier season del BattlePass (single source of truth).
	if itemConfig.isBPExclusive == true or BattlePassConfig.IsBPExclusive(data.category, data.itemId) then
		Network.Shop.Response.SendTo({
			success = false,
			message = "Este ítem solo se obtiene en el Battle Pass.",
		}, player)
		return
	end

	-- Validación 3: perfil cargado
	local profile = _dataService:GetProfile(player)
	if not profile then
		Network.Shop.Response.SendTo({ success = false, message = "Perfil no disponible." }, player)
		return
	end

	local weaponCategoryForWraps: string? = nil
	local weaponIdForWraps: string? = nil

	-- Validación 4: ítem no poseído ya
	if data.category == LockerCategory.WEAPON_WRAPS then
		weaponCategoryForWraps = _resolveWeaponCategory(data.weaponCategory)
		if not weaponCategoryForWraps then
			Network.Shop.Response.SendTo({ success = false, message = "Categoría de arma inválida para wraps." }, player)
			return
		end

		local weaponSlot = CATEGORY_TO_LOADOUT_SLOT[weaponCategoryForWraps]
		local equippedWeaponId = if weaponSlot then profile.Data.Loadout[weaponSlot] else nil
		weaponIdForWraps = _resolveWeaponId(data.weaponId, equippedWeaponId)

		-- Bloquea comprar wraps para armas que el jugador no posee.
		if not _ownsTargetWeapon(profile.Data, weaponCategoryForWraps, weaponIdForWraps) then
			Network.Shop.Response.SendTo({ success = false, message = "No posees el arma objetivo." }, player)
			return
		end

		if _getOwnedWeaponWrap(profile.Data, weaponCategoryForWraps, weaponIdForWraps, data.itemId) then
			Network.Shop.Response.SendTo({ success = false, message = "Ya posees este wrap para esa arma." }, player)
			return
		end
	else
		local alreadyOwned = _getPath(profile.Data.Inventory, { data.category, data.itemId })
		if alreadyOwned then
			Network.Shop.Response.SendTo({ success = false, message = "Ya posees este ítem." }, player)
			return
		end
	end

	-- Validación 5: nivel suficiente
	local playerLevel: number = profile.Data.Stats.Level or 1
	if playerLevel < (itemConfig.LevelRequired or 1) then
		Network.Shop.Response.SendTo({
			success = false,
			message = "Necesitas el nivel " .. tostring(itemConfig.LevelRequired) .. ".",
		}, player)
		return
	end

	-- Validación 6: cash suficiente
	local currentCash: number = profile.Data.Stats.Cash or 0
	local price: number = itemConfig.Price or 0
	if currentCash < price then
		Network.Shop.Response.SendTo({
			success = false,
			message = "Cash insuficiente. Necesitas " .. tostring(price) .. ".",
		}, player)
		return
	end

	-- ── Transacción atómica ──────────────────────────────────
	-- Si la categoría es equipable, la compra actualiza también el Loadout
	-- en la misma operación para evitar un segundo request del cliente.
	-- Cash se descuenta con delta para evitar TOCTOU si otro flujo (kill,
	-- claim, otra compra) muta Stats.Cash entre la lectura y el write.
	local updates = {
		{ path = { "Stats", "Cash" }, delta = -price },
	}

	if data.category == LockerCategory.WEAPON_WRAPS then
		local resolvedWeaponCategory = weaponCategoryForWraps :: string
		local resolvedWeaponId = weaponIdForWraps :: string
		table.insert(updates, {
			path = { "Inventory", "WeaponWrapsByWeapon", resolvedWeaponCategory, resolvedWeaponId, data.itemId },
			value = true,
		})
		-- Marcar metadata + NEW! flag para el wrap.
		table.insert(updates, {
			path = { "InventoryMeta", "WeaponWraps", data.itemId },
			value = { AcquiredAt = os.time(), Source = "Shop" },
		})
		table.insert(updates, {
			path = { "NewItemFlags", "WeaponWraps", data.itemId },
			value = true,
		})

		local wrapsRootPath = WEAPON_WRAPS_PATH_BY_CATEGORY[resolvedWeaponCategory]
		if wrapsRootPath then
			table.insert(updates, {
				path = { wrapsRootPath[1], wrapsRootPath[2], resolvedWeaponId },
				value = data.itemId,
			})
		end
	else
		-- Categoría estándar: Inventory + InventoryMeta + NewItemFlags atómicos.
		table.insert(updates, { path = { "Inventory", data.category, data.itemId }, value = true })
		table.insert(updates, {
			path = { "InventoryMeta", data.category, data.itemId },
			value = { AcquiredAt = os.time(), Source = "Shop" },
		})
		table.insert(updates, {
			path = { "NewItemFlags", data.category, data.itemId },
			value = true,
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
		_markCooldown(player, "buy")
		Network.Shop.Response.SendTo({
			success = true,
			message = if data.category == LockerCategory.WEAPON_WRAPS
				then itemConfig.Name .. " comprado y equipado para el arma seleccionada."
				else if loadoutSlot
				then itemConfig.Name .. " comprado y equipado."
				else itemConfig.Name .. " comprado correctamente.",
		}, player)
	else
		Network.Shop.Response.SendTo({
			success = false,
			message = "Error interno. Inténtalo de nuevo.",
		}, player)
	end
end

local function _onEquipItem(data: { category: string, itemId: string, weaponCategory: string, weaponId: string }, player: Player): ()
	-- Validación 0: tipos + caps de longitud (ver _onBuyItem).
	if not NetGuards.validate(data, {
		category       = M.Category,
		itemId         = M.Id,
		weaponCategory = M.Category,
		weaponId       = M.Id,
	}) or data.itemId == "" then
		Network.Shop.Response.SendTo({ success = false, message = "Payload inválido." }, player)
		return
	end

	-- Validación 1: cooldown (sin marcar; se marca tras éxito real)
	if not _isCooldownReady(player, "equip") then
		Network.Shop.Response.SendTo({ success = false, message = "Demasiadas peticiones." }, player)
		return
	end

	-- Validación 2: ítem existe en cache (whitelist implícita de category).
	local categoryCache = _itemCache[data.category]
	local itemConfig = categoryCache and categoryCache[data.itemId]
	if not itemConfig then
		Network.Shop.Response.SendTo({ success = false, message = "Ítem no encontrado." }, player)
		return
	end

	-- Validación 3: perfil cargado
	local profile = _dataService:GetProfile(player)
	if not profile then
		Network.Shop.Response.SendTo({ success = false, message = "Perfil no disponible." }, player)
		return
	end

	local ok = false
	if data.category == LockerCategory.WEAPON_WRAPS then
		local weaponCategory = _resolveWeaponCategory(data.weaponCategory)
		if not weaponCategory then
			Network.Shop.Response.SendTo({ success = false, message = "Arma objetivo inválida para wraps." }, player)
			return
		end

		local wrapsRootPath = WEAPON_WRAPS_PATH_BY_CATEGORY[weaponCategory]
		if not wrapsRootPath then
			Network.Shop.Response.SendTo({ success = false, message = "Arma objetivo inválida para wraps." }, player)
			return
		end

		local weaponSlot = CATEGORY_TO_LOADOUT_SLOT[weaponCategory]
		if not weaponSlot then
			Network.Shop.Response.SendTo({ success = false, message = "Slot de arma inválido." }, player)
			return
		end

		local equippedWeaponId = profile.Data.Loadout[weaponSlot]
		local targetWeaponId = _resolveWeaponId(data.weaponId, equippedWeaponId)

		-- Re-validar ownership del arma objetivo y del wrap.
		if not _ownsTargetWeapon(profile.Data, weaponCategory, targetWeaponId) then
			Network.Shop.Response.SendTo({ success = false, message = "No posees el arma objetivo." }, player)
			return
		end

		if not _getOwnedWeaponWrap(profile.Data, weaponCategory, targetWeaponId, data.itemId) then
			Network.Shop.Response.SendTo({ success = false, message = "No posees este wrap para esa arma." }, player)
			return
		end

		ok = _dataService:SetValue(player, { wrapsRootPath[1], wrapsRootPath[2], targetWeaponId }, data.itemId)
	else
		-- Validación 4: el jugador posee el ítem
		local isOwned = _getPath(profile.Data.Inventory, { data.category, data.itemId })
		if not isOwned then
			Network.Shop.Response.SendTo({ success = false, message = "No posees este ítem." }, player)
			return
		end

		-- Validación 5: categoría tiene un slot de Loadout válido
		local loadoutSlot = CATEGORY_TO_LOADOUT_SLOT[data.category]
		if not loadoutSlot then
			Network.Shop.Response.SendTo({ success = false, message = "Categoría no equipable." }, player)
			return
		end

		-- ── Actualizar Loadout ───────────────────────────────────
		ok = _dataService:SetValue(player, { "Loadout", loadoutSlot }, data.itemId)
	end

	if ok then
		_markCooldown(player, "equip")
		Network.Shop.Response.SendTo({
			success = true,
			message = itemConfig.Name .. " equipado.",
		}, player)
	else
		Network.Shop.Response.SendTo({
			success = false,
			message = "Error al equipar. Inténtalo de nuevo.",
		}, player)
	end
end

-- ────────────────────────────────────────────────────────────
-- MÓDULO PRINCIPAL
-- ────────────────────────────────────────────────────────────

local ShopService = {}
ShopService.__index = ShopService

--[[
	Inicia el servicio.
	  dataService  — instancia de DataService (inyección de dependencia,
	                 evita require circular entre servicios)
]]
function ShopService:Start(dataService: DataService): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	-- ── Construir cache O(1) ──────────────────────────────────
	-- Itera ItemsConfig una vez y crea lookup por categoría + itemId.
	for category, items in ItemsConfig do
		_itemCache[category] = {}
		for itemId, config in items do
			_itemCache[category][itemId] = Sift.Dictionary.merge(config, { category = category })
		end
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
	end)

	-- ── Registrar listeners de ByteNet ────────────────────────
	Network.Shop.BuyItem.Listen(_onBuyItem)
	Network.Shop.EquipItem.Listen(_onEquipItem)
end

return ShopService
