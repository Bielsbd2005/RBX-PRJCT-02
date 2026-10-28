--!strict
--[[
	Única fuente de verdad de cómo se lee la posesión en `profile.Data`.
	El arma y el wrap "Default" cuentan como poseídos: vienen en el DataTemplate.
	NO valida que `profileData` no sea nil: el caller debe comprobar GetProfile antes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponCategoryMod = require(Shared:WaitForChild("constants"):WaitForChild("WeaponCategory"))
local ItemDefaults = require(Shared:WaitForChild("constants"):WaitForChild("ItemDefaults"))
local LockerConfig = require(Shared:WaitForChild("constants"):WaitForChild("LockerConfig"))
local LockerCategory = require(Shared:WaitForChild("constants"):WaitForChild("LockerCategory"))
local BorderLevels = require(script.Parent.BorderLevels)

local InventoryRepository = {}

export type WeaponCategory = WeaponCategoryMod.WeaponCategory

-- Lee la posesión física guardada en profileData.Inventory sin aplicar flags de depuración.
function InventoryRepository.rawOwnsItem(profileData: any, category: string, itemId: string): boolean
	local categoryInv = if profileData.Inventory then profileData.Inventory[category] else nil
	if type(categoryInv) ~= "table" then
		return false
	end
	return categoryInv[itemId] == true
end

-- Los wraps pueden guardarse como { [wrapId] = true } o { [wrapId] = count }.
function InventoryRepository.rawOwnsWeaponWrap(
	profileData: any,
	category: WeaponCategory,
	weaponId: string,
	wrapId: string
): boolean
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

function InventoryRepository.ownsItem(
	profileData: any,
	category: string,
	itemId: string,
	playerOrUserId: (Player | number)?
): boolean
	if LockerConfig.isUnlockAllActive(playerOrUserId) then
		return true
	end
	if category == LockerCategory.BORDERS then
		local stats = profileData.Stats
		local level = if type(stats) == "table" then tonumber(stats.Level) else nil
		return BorderLevels.isUnlocked(itemId, level or 0)
	end
	return InventoryRepository.rawOwnsItem(profileData, category, itemId)
end

function InventoryRepository.ownsWeapon(
	profileData: any,
	category: WeaponCategory,
	weaponId: string,
	playerOrUserId: (Player | number)?
): boolean
	if LockerConfig.isUnlockAllActive(playerOrUserId) then
		return true
	end
	if weaponId == ItemDefaults.ITEM_ID then
		return true
	end
	return InventoryRepository.rawOwnsItem(profileData, category, weaponId)
end

function InventoryRepository.ownsWeaponWrap(
	profileData: any,
	category: WeaponCategory,
	weaponId: string,
	wrapId: string,
	playerOrUserId: (Player | number)?
): boolean
	if LockerConfig.isUnlockAllActive(playerOrUserId) then
		return true
	end
	return InventoryRepository.rawOwnsWeaponWrap(profileData, category, weaponId, wrapId)
end

return InventoryRepository
