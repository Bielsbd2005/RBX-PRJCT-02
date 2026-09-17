--!strict

export type LockerCategoryKey = "Style" | "Arsenal" | "Effects"

export type LockerNavItemDefinition = {
	key: string,
	title: string,
	thumbnail: string,
}

local STYLE_NAV_ITEMS = table.freeze({
	{ key = "Body", title = "Body", thumbnail = "rbxassetid://137817236260095" },
	{ key = "Faces", title = "Faces", thumbnail = "rbxassetid://130328966728722" },
	{ key = "Hats", title = "Hats", thumbnail = "rbxassetid://126122024454210" },
})

local ARSENAL_NAV_ITEMS = table.freeze({
	{ key = "Main", title = "Main", thumbnail = "rbxassetid://99665561004765" },
	{ key = "Special", title = "Special", thumbnail = "rbxassetid://94351975111962" },
})

local EFFECTS_NAV_ITEMS = table.freeze({
	{ key = "KillEffects", title = "Kill Effects", thumbnail = "rbxassetid://130437553674754" },
})

local NAV_ITEMS = table.freeze({
	Style = STYLE_NAV_ITEMS,
	Arsenal = ARSENAL_NAV_ITEMS,
	Effects = EFFECTS_NAV_ITEMS,
})

-- Nav-key → categoría del catálogo. La única traducción no-identidad es Body→Outfits.
local ITEMS_CONFIG_BY_NAV = table.freeze({
	Style = table.freeze({
		Body = "Outfits",
		Faces = "Faces",
		Hats = "Hats",
	}),
	Arsenal = table.freeze({
		Main = "Main",
		Special = "Special",
		WeaponWraps = "WeaponWraps",
	}),
	Effects = table.freeze({
		KillEffects = "KillEffects",
	}),
})

local CATEGORY_TO_LOADOUT_SLOT = table.freeze({
	Main = "MainWeapon",
	Special = "SpecialWeapon",
	-- WeaponWraps no se mapea: el wrap equipado es por arma (MainWeaponWraps[weaponId] /
	-- SpecialWeaponWraps[weaponId]); sus call-sites (ShopService, locker/init) tienen ramas explícitas.
	KillEffects = "KillEffect",
	Faces = "Face",
	Hats = "Hat",
	Outfits = "Outfit",
})

local RARITY_RANK = table.freeze({
	Common = 1,
	Rare = 2,
	Epic = 3,
	Legendary = 4,
	Mythic = 5,
})

local function makeQualifiedId(category: string, id: string): string
	return category .. "." .. id
end

local LockerConfig = {
	NavItems = NAV_ITEMS,
	ItemsConfigByNav = ITEMS_CONFIG_BY_NAV,
	CategoryToLoadoutSlot = CATEGORY_TO_LOADOUT_SLOT,
	RarityRank = RARITY_RANK,
	makeQualifiedId = makeQualifiedId,
}

return table.freeze(LockerConfig)
