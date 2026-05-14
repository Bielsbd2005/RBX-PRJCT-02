--!strict

local WeaponCategory = {}

WeaponCategory.MAIN = "Main"
WeaponCategory.SPECIAL = "Special"
WeaponCategory.ALL = { WeaponCategory.MAIN, WeaponCategory.SPECIAL }

export type WeaponCategory = "Main" | "Special"

function WeaponCategory.isValid(value: any): boolean
	return value == WeaponCategory.MAIN or value == WeaponCategory.SPECIAL
end

return WeaponCategory
