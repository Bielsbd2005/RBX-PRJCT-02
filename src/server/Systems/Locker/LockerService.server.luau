--[[
    ShopService Optimizado
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local DataManager = require(ServerScriptService.Server.Systems.Data.DataManager)
local ItemsData = require(ReplicatedStorage.Shared.Systems.Locker.Data.ItemsData)

local ShopService = {}

----- Tipos -----
type ItemStats = {
	Price: number,
	Level: number?,
	Name: string,
	[string]: any
}

----- Configuración -----
local COOLDOWN_TIME = 0.3

----- Inicialización -----
local shopFolder = ReplicatedStorage:FindFirstChild("Shop") or Instance.new("Folder")
shopFolder.Name = "Shop"
shopFolder.Parent = ReplicatedStorage

local function GetRemote(name: string): RemoteFunction
	local remote = shopFolder:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = shopFolder
	end
	return remote :: RemoteFunction
end

local equipItemRF = GetRemote("EquipItem")
local buyItemRF = GetRemote("BuyItem")

----- Caché O(1) -----
local ItemCache: { [string]: ItemStats } = {}

-- Pre-calculamos las keys una sola vez al inicio del servidor
for tabName, categories in pairs(ItemsData) do
	for categoryName, items in pairs(categories) do
		for _, item in ipairs(items) do
			-- Usamos separador para garantizar unicidad
			ItemCache[tabName .. "|" .. categoryName .. "|" .. item.Name] = item
		end
	end
end

----- Cooldowns -----
local playerCooldowns: { [Player]: number } = {}

local function CheckCooldown(player: Player): boolean
	local now = os.clock()
	local last = playerCooldowns[player] or 0
	if (now - last) < COOLDOWN_TIME then return true end
	playerCooldowns[player] = now
	return false
end

----- Utilidad Privada -----
-- Asegura que el path al inventario exista para evitar errores en jugadores nuevos
local function _ensureInventoryTable(player: Player, data: any, category: string): {string}
	if not data.inventory then
		-- Si no existe inventario, lo creamos en el DataManager
		DataManager:Update(player, "inventory", {})
		data.inventory = {}
	end
	return data.inventory[category] or {}
end

--------------------------------------------------------------------------------
-- Logic: Equip Item
--------------------------------------------------------------------------------
equipItemRF.OnServerInvoke = function(player: Player, category: any, itemName: any)
	if CheckCooldown(player) then return false, "Espera..." end

	if type(category) ~= "string" or type(itemName) ~= "string" then
		return false, "Datos inválidos"
	end

	local data = DataManager:Get(player)
	if not data then return false, "Cargando..." end

	-- Validar posesión
	if itemName ~= "Default" then
		local invCategory = data.inventory and data.inventory[category]
		if not invCategory or not table.find(invCategory, itemName) then
			return false, "No posees este ítem"
		end
	end

	-- Guardado directo
	-- Asumimos que la estructura 'equipped' existe en el DataTemplate.
	-- Si no, deberías hacer un check similar al de _ensureInventoryTable
	local success = DataManager:Update(player, "equipped." .. category, itemName)

	return success, success and "Equipado" or "Error al equipar"
end

--------------------------------------------------------------------------------
-- Logic: Buy Item
--------------------------------------------------------------------------------
buyItemRF.OnServerInvoke = function(player: Player, tab: any, category: any, itemName: any)
	if CheckCooldown(player) then return false, "Procesando..." end

	-- 1. Validación de Tipos
	if type(tab) ~= "string" or type(category) ~= "string" or type(itemName) ~= "string" then
		return false, "Argumentos inválidos"
	end

	-- 2. Lookup O(1) en Caché
	local itemStats = ItemCache[tab .. "|" .. category .. "|" .. itemName]
	if not itemStats then return false, "Item no disponible" end

	-- 3. Obtención de Datos
	local data = DataManager:Get(player)
	if not data then return false, "Error de datos" end

	-- 4. Validaciones de Estado
	-- Usamos la función helper para obtener el array limpio sin errores
	local currentInventory = _ensureInventoryTable(player, data, category)

	if table.find(currentInventory, itemName) then
		return false, "Ya tienes este ítem"
	end

	local price = itemStats.Price or 0
	if (data.cash or 0) < price then return false, "Dinero insuficiente" end
	if (data.level or 0) < (itemStats.Level or 0) then return false, "Nivel bajo" end

	-- 5. Preparación de Datos (Batch)
	local newInventory = table.clone(currentInventory)
	table.insert(newInventory, itemName)

	local updates = {
		["cash"] = data.cash - price,
		["inventory." .. category] = newInventory,
		["equipped." .. category] = itemName
	}

	-- 6. Ejecución Atómica (BatchUpdate)
	local success = DataManager:BatchUpdate(player, updates)

	if success then
		-- Opcional: Log de compra
		-- print(`[Shop] ${player.Name} compró ${itemName} por ${price}`)
		return true, "¡Compra realizada!"
	else
		return false, "Error en la transacción"
	end
end

-- Limpieza
Players.PlayerRemoving:Connect(function(player)
	playerCooldowns[player] = nil
end)

return ShopService
