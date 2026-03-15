--[[
	ItemsDataUtils
	Utility functions for querying ItemsData and player data.
	Consolidates ownership checks, level-lock checks, and item lookups
	previously duplicated 4× across LockerUI.

	Ruta: ReplicatedStorage.Shared.ItemsDataUtils
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemsDataUtils = {}

----- Tipos -----
export type ItemData = {
	Name: string,
	Level: number?,
	Price: number?,
	[string]: any
}

export type PlayerData = {
	inventory: { [string]: {string} }?, -- Asumiendo que inventario es array de strings
	level: number?,
	[string]: any
}

----- Estado Interno (Lazy Loading + Caching) -----
local _itemsData = nil
-- Cache estructura: [Category][Section][ItemName] = ItemData
local _lookupCache: { [string]: { [string]: { [string]: ItemData } } } = {}

-- Carga e indexa los datos una sola vez
local function ensureDataLoaded()
	if _itemsData then return end

	_itemsData = require(ReplicatedStorage.Shared.Systems.Locker.Data.ItemsData)

	-- Construimos el caché de búsqueda inversa para O(1)
	-- Esto evita recorrer arrays cada vez que buscamos un item por nombre
	for categoryName, sections in pairs(_itemsData) do
		_lookupCache[categoryName] = {}
		for sectionName, itemsList in pairs(sections) do
			_lookupCache[categoryName][sectionName] = {}
			for _, item in ipairs(itemsList) do
				if item.Name then
					_lookupCache[categoryName][sectionName][item.Name] = item
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Find an item by name within a category/section (Optimized O(1))
--------------------------------------------------------------------------------
function ItemsDataUtils.findByName(category: string, section: string, name: string): ItemData?
	if not name or name == "" then return nil end

	ensureDataLoaded()

	-- Búsqueda directa por Hash Map (Instantánea)
	local catCache = _lookupCache[category]
	local secCache = catCache and catCache[section]

	return secCache and secCache[name]
end

--------------------------------------------------------------------------------
-- Check if a player owns an item (Optimized table.find)
--------------------------------------------------------------------------------
function ItemsDataUtils.isItemOwned(playerData: PlayerData, section: string, itemName: string): boolean
	if itemName == "Default" then return true end
	if not playerData or not playerData.inventory then return false end

	local categoryInv = playerData.inventory[section]
	if not categoryInv then return false end

	-- OPTIMIZACIÓN: table.find es nativo (C++) y más rápido que un bucle for en Lua
	return table.find(categoryInv, itemName) ~= nil
end

--------------------------------------------------------------------------------
-- Check if an item is locked by level requirement
--------------------------------------------------------------------------------
function ItemsDataUtils.isLevelLocked(item: ItemData, playerData: PlayerData): boolean
	if not item then return false end -- Safety check

	local requiredLevel = item.Level or 0
	-- Si el nivel requerido es 0, no está bloqueado
	if requiredLevel <= 0 then return false end

	local playerLevel = (playerData and playerData.level) or 0

	return playerLevel < requiredLevel
end

--------------------------------------------------------------------------------
-- Utility: Get All Items in Section (Wrapper seguro)
--------------------------------------------------------------------------------
function ItemsDataUtils.getItemsInSection(category: string, section: string): {ItemData}
	ensureDataLoaded()
	if _itemsData and _itemsData[category] then
		return _itemsData[category][section] or {}
	end
	return {}
end

return ItemsDataUtils
