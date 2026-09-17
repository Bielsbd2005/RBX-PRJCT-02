--!strict
--[[
	Única fuente de verdad de cómo se lee la posesión en `profile.Data`.
	El arma y el wrap "Default" cuentan como poseídos: vienen en el DataTemplate.
	NO valida que `profileData` no sea nil: el caller debe comprobar GetProfile antes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WeaponCategoryMod = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("WeaponCategory"))
local ItemDefaults = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemDefaults"))

local InventoryRepository = {}

export type WeaponCategory = WeaponCategoryMod.WeaponCategory

function InventoryRepository.ownsItem(profileData: any, category: string, itemId: string): boolean
	local categoryInv = if profileData.Inventory then profileData.Inventory[category] else nil
	if type(categoryInv) ~= "table" then
		return false
	end
	return categoryInv[itemId] == true
end

function InventoryRepository.ownsWeapon(profileData: any, category: WeaponCategory, weaponId: string): boolean
	if weaponId == ItemDefaults.ITEM_ID then
		return true
	end
	return InventoryRepository.ownsItem(profileData, category, weaponId)
end

-- Los wraps pueden guardarse como { [wrapId] = true } o { [wrapId] = count }.
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

return InventoryRepository
