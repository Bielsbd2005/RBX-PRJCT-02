--!strict

-- Categorías del Locker que no son armas (Main/Special: WeaponCategory).
-- Deben coincidir con las keys top-level de ItemsConfig.

local LockerCategory = {}

LockerCategory.WEAPON_WRAPS = "WeaponWraps"
LockerCategory.KILL_EFFECTS = "KillEffects"
LockerCategory.EMOTES = "Emotes"
LockerCategory.FACES = "Faces"
LockerCategory.HATS = "Hats"
LockerCategory.OUTFITS = "Outfits"
LockerCategory.BANNERS = "Banners"

LockerCategory.ALL = {
	LockerCategory.WEAPON_WRAPS,
	LockerCategory.KILL_EFFECTS,
	LockerCategory.EMOTES,
	LockerCategory.FACES,
	LockerCategory.HATS,
	LockerCategory.OUTFITS,
	LockerCategory.BANNERS,
}

export type LockerCategory =
	"WeaponWraps"
	| "KillEffects"
	| "Emotes"
	| "Faces"
	| "Hats"
	| "Outfits"
	| "Banners"

function LockerCategory.isValid(value: any): boolean
	for _, c in LockerCategory.ALL do
		if c == value then return true end
	end
	return false
end

return LockerCategory
