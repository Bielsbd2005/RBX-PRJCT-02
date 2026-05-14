--!strict

-- Top-level tabs del Locker. Cada tab agrupa varias nav-items (ver LockerConfig.NavItems).

local LockerMainCategory = {}

LockerMainCategory.STYLE = "Style"
LockerMainCategory.ARSENAL = "Arsenal"
LockerMainCategory.EFFECTS = "Effects"

LockerMainCategory.ALL = {
	LockerMainCategory.STYLE,
	LockerMainCategory.ARSENAL,
	LockerMainCategory.EFFECTS,
}

export type LockerMainCategory = "Style" | "Arsenal" | "Effects"

function LockerMainCategory.isValid(value: any): boolean
	return value == LockerMainCategory.STYLE
		or value == LockerMainCategory.ARSENAL
		or value == LockerMainCategory.EFFECTS
end

return LockerMainCategory
