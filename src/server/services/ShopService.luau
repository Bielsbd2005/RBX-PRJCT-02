--!strict
--[[
	ShopService.luau  (Server)
	Gestiona las transacciones de la tienda usando ByteNet para comunicación
	de baja latencia (reemplaza RemoteFunction/RemoteEvent clásicos).

	Flujo de una compra (BuyItem):
	  1. Cliente envía Network.Shop.BuyItem via ByteNet
	  2. ShopService valida: cooldown → ítem existe → nivel suficiente → cash suficiente → no poseído
	  3. DataService:BatchUpdate aplica la transacción atómica (cash − precio, ítem = true)
	  4. Network.Shop.Response confirma al cliente

	Flujo de equip (EquipItem):
	  1. Cliente envía Network.Shop.EquipItem via ByteNet
	  2. ShopService valida: cooldown → ítem existe → jugador lo posee
	  3. DataService:SetValue actualiza el Loadout
	  4. Network.Shop.Response confirma al cliente

	Cache O(1):
	  En Start(), se construye _itemCache: un mapa plano itemId → { config + category }.
	  Lookup de validación en tiempo constante sin iterar ItemsConfig en cada request.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared   = ReplicatedStorage:WaitForChild("Shared")

local Sift = require(Packages.sift) :: any

local Network     = require(Shared.networking.Network)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any

-- Mapeo de categoría de ítem → clave de Loadout (para EquipItem)
local CATEGORY_TO_LOADOUT_SLOT: { [string]: string } = {
	Weapons     = "PrimaryWeapon",
	WeaponSkins = "ActiveSkin",
	KillEffects = "KillEffect",
	Faces       = "Face",
	Hats        = "Hat",
	Outfits     = "Outfit",
}

-- Cooldown por acción (segundos)
local COOLDOWN = 0.3

-- ────────────────────────────────────────────────────────────
-- ESTADO DEL MÓDULO
-- ────────────────────────────────────────────────────────────

-- Cache plano: itemId → { ...ItemConfig, category = string }
-- Construido en Start() con O(n) una sola vez.
local _itemCache: { [string]: any } = {}

-- Cooldowns: clave = tostring(userId) .. "_" .. action
local _cooldowns: { [string]: number } = {}

-- DataService inyectado en Start()
local _dataService: any = nil

-- ────────────────────────────────────────────────────────────
-- HELPERS
-- ────────────────────────────────────────────────────────────

local function _checkCooldown(player: Player, action: string): boolean
	local key = tostring(player.UserId) .. "_" .. action
	local last = _cooldowns[key] or 0
	if tick() - last < COOLDOWN then
		return false
	end
	_cooldowns[key] = tick()
	return true
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

local function _onBuyItem(data: { itemId: string, category: string }, player: Player): ()
	-- Validación 1: cooldown
	if not _checkCooldown(player, "buy") then
		Network.Shop.Response.SendTo({ success = false, message = "Demasiadas peticiones." }, player)
		return
	end

	-- Validación 2: ítem existe en cache
	local itemConfig = _itemCache[data.itemId]
	if not itemConfig then
		Network.Shop.Response.SendTo({ success = false, message = "Ítem no encontrado." }, player)
		return
	end

	-- Validación 3: categoría coincide
	if itemConfig.category ~= data.category then
		Network.Shop.Response.SendTo({ success = false, message = "Categoría inválida." }, player)
		return
	end

	-- Validación 4: perfil cargado
	local profile = _dataService:GetProfile(player)
	if not profile then
		Network.Shop.Response.SendTo({ success = false, message = "Perfil no disponible." }, player)
		return
	end

	-- Validación 5: ítem no poseído ya
	local alreadyOwned = _getPath(profile.Data.Inventory, { data.category, data.itemId })
	if alreadyOwned then
		Network.Shop.Response.SendTo({ success = false, message = "Ya posees este ítem." }, player)
		return
	end

	-- Validación 6: nivel suficiente
	local playerLevel: number = profile.Data.Stats.Level or 1
	if playerLevel < (itemConfig.LevelRequired or 1) then
		Network.Shop.Response.SendTo({
			success = false,
			message = "Necesitas el nivel " .. tostring(itemConfig.LevelRequired) .. ".",
		}, player)
		return
	end

	-- Validación 7: cash suficiente
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
	-- BatchUpdate aplica ambos cambios en una sola operación,
	-- generando exactamente 2 mensajes de red (uno por sección: Stats e Inventory).
	local success = _dataService:BatchUpdate(player, {
		{ path = { "Stats", "Cash" }, value = currentCash - price },
		{ path = { "Inventory", data.category, data.itemId }, value = true },
	})

	if success then
		Network.Shop.Response.SendTo({
			success = true,
			message = itemConfig.Name .. " comprado correctamente.",
		}, player)
	else
		Network.Shop.Response.SendTo({
			success = false,
			message = "Error interno. Inténtalo de nuevo.",
		}, player)
	end
end

local function _onEquipItem(data: { category: string, itemId: string }, player: Player): ()
	-- Validación 1: cooldown
	if not _checkCooldown(player, "equip") then
		Network.Shop.Response.SendTo({ success = false, message = "Demasiadas peticiones." }, player)
		return
	end

	-- Validación 2: ítem existe en cache
	local itemConfig = _itemCache[data.itemId]
	if not itemConfig or itemConfig.category ~= data.category then
		Network.Shop.Response.SendTo({ success = false, message = "Ítem no encontrado." }, player)
		return
	end

	-- Validación 3: perfil cargado
	local profile = _dataService:GetProfile(player)
	if not profile then
		Network.Shop.Response.SendTo({ success = false, message = "Perfil no disponible." }, player)
		return
	end

	-- Validación 4: el jugador posee el ítem
	local owned = _getPath(profile.Data.Inventory, { data.category, data.itemId })
	if not owned then
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
	local ok = _dataService:SetValue(player, { "Loadout", loadoutSlot }, data.itemId)

	if ok then
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
-- LIMPIEZA DE COOLDOWNS AL SALIR
-- ────────────────────────────────────────────────────────────

Players.PlayerRemoving:Connect(function(player: Player)
	local prefix = tostring(player.UserId) .. "_"
	-- Limpiar entradas de cooldown para liberar memoria
	for key in _cooldowns do
		if string.sub(key, 1, #prefix) == prefix then
			_cooldowns[key] = nil
		end
	end
end)

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
function ShopService:Start(dataService: any): ()
	_dataService = dataService

	-- ── Construir cache O(1) ──────────────────────────────────
	-- Itera ItemsConfig una vez para crear un mapa plano de búsqueda rápida.
	-- Sift.Dictionary.merge agrega la clave "category" al config sin mutar el original.
	for category, items in ItemsConfig do
		for itemId, config in items do
			_itemCache[itemId] = Sift.Dictionary.merge(config, { category = category })
		end
	end

	-- ── Registrar listeners de ByteNet ────────────────────────
	Network.Shop.BuyItem.Listen(_onBuyItem)
	Network.Shop.EquipItem.Listen(_onEquipItem)
end

return ShopService
