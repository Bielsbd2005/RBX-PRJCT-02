--!strict
--[[
	InventoryRepository.luau
	Lecturas de ownership / loadout sobre `profile.Data`. Single source of
	truth de cómo está estructurado el inventario en el schema actual.

	Por qué existe: ShopService, CasesService, LoadoutService y BattlePassService
	tenían cada uno su propia versión de "¿el jugador posee X?". Cuando el
	schema cambie (e.g. WeaponWrapsByWeapon migra a otra rama), todos esos
	helpers tendrían que actualizarse en sincronía. Aquí está la lógica una vez.

	Convención: `weaponId == "Default"` siempre se considera poseído porque
	viene en el DataTemplate inicial. `wrapId == "Default"` también.

	NO valida que `profileData` no sea nil — los callers deben verificar
	`dataService:GetProfile(player)` antes de llamar a este módulo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WeaponCategoryMod = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("WeaponCategory"))
local ItemDefaults = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemDefaults"))

local InventoryRepository = {}

export type WeaponCategory = WeaponCategoryMod.WeaponCategory

export type OwnedWeapon = {
	category: WeaponCategory,
	weaponId: string,
}


-- True si el jugador posee el ítem en `profileData.Inventory[category][itemId]`.
function InventoryRepository.ownsItem(profileData: any, category: string, itemId: string): boolean
	local categoryInv = if profileData.Inventory then profileData.Inventory[category] else nil
	if type(categoryInv) ~= "table" then
		return false
	end
	return categoryInv[itemId] == true
end

-- True si el jugador posee el arma. "Default" siempre es true.
function InventoryRepository.ownsWeapon(profileData: any, category: WeaponCategory, weaponId: string): boolean
	if weaponId == ItemDefaults.ITEM_ID then
		return true
	end
	return InventoryRepository.ownsItem(profileData, category, weaponId)
end

-- True si el jugador posee el wrap específico para esa arma.
-- "Default" wrap siempre es true.
-- Soporta dos shapes: { [wrapId] = true } o { [wrapId] = count }.
function InventoryRepository.ownsWeaponWrap(profileData: any, category: WeaponCategory, weaponId: string, wrapId: string): boolean
	if wrapId == ItemDefaults.ITEM_ID then
		return true
	end
	local wraps = if profileData.Inventory then profileData.Inventory.WeaponWrapsByWeapon else nil
	if type(wraps) ~= "table" then
		return false
	end
	local catWraps = wraps[category]
	if type(catWraps) ~= "table" then
		return false
	end
	local weaponWraps = catWraps[weaponId]
	if type(weaponWraps) ~= "table" then
		return false
	end
	local isOwned = weaponWraps[wrapId]
	if isOwned == true then
		return true
	end
	return type(isOwned) == "number" and isOwned > 0
end

-- Lista todas las armas Main + Special poseídas. Si no hay ninguna,
-- devuelve `{ { category = "Main", weaponId = "Default" } }` para que los
-- callers (e.g. random weapon picker en cajas) tengan siempre algo.
function InventoryRepository.listOwnedWeapons(profileData: any): { OwnedWeapon }
	local ownedWeapons = {} :: { OwnedWeapon }
	local inventory = profileData.Inventory
	if type(inventory) ~= "table" then
		return { { category = WeaponCategoryMod.MAIN, weaponId = ItemDefaults.ITEM_ID } }
	end

	for _, categoryName in WeaponCategoryMod.ALL do
		local categoryInventory = inventory[categoryName]
		if type(categoryInventory) == "table" then
			for weaponId, isOwned in categoryInventory do
				if isOwned == true and type(weaponId) == "string" and weaponId ~= "" then
					table.insert(ownedWeapons, {
						category = categoryName :: WeaponCategory,
						weaponId = weaponId,
					})
				end
			end
		end
	end

	if #ownedWeapons == 0 then
		table.insert(ownedWeapons, { category = WeaponCategoryMod.MAIN, weaponId = ItemDefaults.ITEM_ID })
	end

	return ownedWeapons
end

return InventoryRepository
