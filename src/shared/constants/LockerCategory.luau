--!strict

-- Catalog categories del Locker que NO son armas. Para Main/Special ver WeaponCategory.
-- Coinciden con las keys top-level de ItemsConfig (excluyendo Main/Special).

local LockerCategory = {}

LockerCategory.WEAPON_WRAPS = "WeaponWraps"
LockerCategory.KILL_EFFECTS = "KillEffects"
LockerCategory.FACES = "Faces"
LockerCategory.HATS = "Hats"
LockerCategory.OUTFITS = "Outfits"

LockerCategory.ALL = {
	LockerCategory.WEAPON_WRAPS,
	LockerCategory.KILL_EFFECTS,
	LockerCategory.FACES,
	LockerCategory.HATS,
	LockerCategory.OUTFITS,
}

export type LockerCategory =
	"WeaponWraps"
	| "KillEffects"
	| "Faces"
	| "Hats"
	| "Outfits"

function LockerCategory.isValid(value: any): boolean
	for _, c in LockerCategory.ALL do
		if c == value then return true end
	end
	return false
end

return LockerCategory
