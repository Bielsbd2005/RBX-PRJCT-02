--!strict
--[[
	Qué wrap lleva un arma según el Loadout. La usan el server al dar las armas
	(LoadoutService) y el Locker para enseñar lo mismo que se verá en partida.

	El equip es por arma: `MainWeaponWraps.Default` es la slot del arma con id
	"Default", no un fallback. Un wrap global del pase da la posesión a todas las
	armas, pero se equipa arma a arma. El check de posesión cubre un Loadout que
	apunte a un wrap que ya no se tiene.
]]

local constants = script.Parent.Parent.constants
local ItemDefaults = require(constants.ItemDefaults)
local WeaponCategory = require(constants.WeaponCategory)
local WrapMastery = require(script.Parent.WrapMastery)

local LoadoutWraps = {}

function LoadoutWraps.resolveEquipped(loadout: any, weaponCategory: string, weaponId: string?, owns: WrapMastery.Owns): string
	local normalizedWeaponId = if type(weaponId) == "string" and weaponId ~= "" then weaponId else ItemDefaults.ITEM_ID
	local wrapsTableKey = if weaponCategory == WeaponCategory.MAIN then "MainWeaponWraps" else "SpecialWeaponWraps"
	local wrapsTable = if type(loadout) == "table" then loadout[wrapsTableKey] else nil
	if type(wrapsTable) ~= "table" then
		return ItemDefaults.ITEM_ID
	end

	local equipped = wrapsTable[normalizedWeaponId]
	if type(equipped) == "string" and equipped ~= "" and owns(weaponCategory, normalizedWeaponId, equipped) then
		return equipped
	end
	return ItemDefaults.ITEM_ID
end

return LoadoutWraps
