--!strict
--[[
	ItemsConfig.luau
	Base de datos estática e inmutable de todos los ítems del juego.
	ShopService construye un cache O(1) a partir de este módulo en Start().

	Estructura:
	  ItemsConfig[category][itemId] = ItemConfig

	Categorías válidas: "Main", "Special", "WeaponSkins", "KillEffects",
	                    "Faces", "Hats", "Outfits"
]]

-- ────────────────────────────────────────────────────────────
-- TIPOS
-- ────────────────────────────────────────────────────────────

export type ItemConfig = {
	Name: string,
	Price: number,          -- Precio en Cash
	LevelRequired: number,  -- Nivel mínimo para comprar
	Rarity: string,         -- "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary"
	Image: string?,         -- Thumbnail para UI (rbxassetid://...)
	CanPurchase: boolean?,  -- Flag para habilitar compra desde UI
	TextureID: string?,
	BaseColor: Color3?,
	Animated: boolean?,
	StudsPerTile: number?,
}

export type ItemCategory = { [string]: ItemConfig }

export type ItemsConfigType = {
	Main: ItemCategory,
	Special: ItemCategory,
	WeaponSkins: ItemCategory,
	KillEffects: ItemCategory,
	Faces: ItemCategory,
	Hats: ItemCategory,
	Outfits: ItemCategory,
}

-- ────────────────────────────────────────────────────────────
-- DATOS
-- ────────────────────────────────────────────────────────────

local function asset(assetId: number): string
	return "rbxassetid://" .. tostring(assetId)
end

local WEAPON_IMAGE_IDS = {
	Main = {
		Default = 136728627576131,
		Weapon2 = 122930463834964,
		Weapon3 = 114523558287606,
	},
	Special = {
		Default = 94351975111962,
		Weapon4 = 94351975111962,
		Weapon5 = 94351975111962,
	},
}

local ItemsConfig: ItemsConfigType = {

	Main = {
		Default   = { Name = "Default",  		 Price = 0,    LevelRequired = 1,  Rarity = "Common",    Image = asset(WEAPON_IMAGE_IDS.Main.Default), CanPurchase = false },
		Weapon2   = { Name = "Weapon1",         Price = 500,  LevelRequired = 5,  Rarity = "Uncommon",  Image = asset(WEAPON_IMAGE_IDS.Main.Weapon2), CanPurchase = false },
		Weapon3   = { Name = "Weapon2",         Price = 1000, LevelRequired = 10, Rarity = "Rare",      Image = asset(WEAPON_IMAGE_IDS.Main.Weapon3), CanPurchase = false },
	},

	Special = {
		Default   = { Name = "Default",  		 Price = 0,    LevelRequired = 1,  Rarity = "Common",    Image = asset(WEAPON_IMAGE_IDS.Special.Default), CanPurchase = false },
		Weapon4   = { Name = "Weapon1",         Price = 2000, LevelRequired = 15, Rarity = "Epic",      Image = asset(WEAPON_IMAGE_IDS.Special.Weapon4), CanPurchase = false },
		Weapon5   = { Name = "Weapon2",         Price = 3500, LevelRequired = 20, Rarity = "Epic",      Image = asset(WEAPON_IMAGE_IDS.Special.Weapon5), CanPurchase = false },
	},

	WeaponSkins = {
		Default   = {
			Name = "Default",
			Price = 0,
			LevelRequired = 1,
			Rarity = "Common",
			Image = asset(109044845487335),
			CanPurchase = false,
			BaseColor = Color3.fromRGB(255, 255, 255),
			Animated = false,
			StudsPerTile = 3,
		},
		Skin_Red  = {
			Name = "SK_0020",
			Price = 300,
			LevelRequired = 1,
			Rarity = "Epic",
			CanPurchase = false,
			TextureID = asset(86966645142772),
			Animated = true,
			StudsPerTile = 3,
		},
		Skin_Blue = {
			Name = "Blue Skin",
			Price = 300,
			LevelRequired = 1,
			Rarity = "Common",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(57, 110, 207),
			Animated = false,
			StudsPerTile = 3,
		},
		Skin_Gold = {
			Name = "Gold Skin",
			Price = 2500,
			LevelRequired = 15,
			Rarity = "Legendary",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(214, 170, 55),
			Animated = false,
			StudsPerTile = 3,
		},
	},

	KillEffects = {
		Default = { Name = "Default Kill",   Price = 0,    LevelRequired = 1,  Rarity = "Common", Image = "rbxassetid://130437553674754", CanPurchase = false },
		Gravity = { Name = "Gravity Kill",   Price = 1500, LevelRequired = 10, Rarity = "Rare",   Image = "rbxassetid://130437553674754", CanPurchase = false },
	},

	Faces = {
		Face1   = { Name = "Default Face",   Price = 1,  LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://79175047578893",  CanPurchase = false },
		Face2   = { Name = "Face2",          Price = 2,  LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://18571318923",    CanPurchase = false },
		Face3   = { Name = "Face3",          Price = 3,  LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://97580829209799", CanPurchase = false },
		Face4   = { Name = "Face4",          Price = 4,  LevelRequired = 1, Rarity = "Rare",   Image = "rbxassetid://94789972115859", CanPurchase = false },
		Face5   = { Name = "Face5",          Price = 5,  LevelRequired = 2, Rarity = "Rare",   Image = "rbxassetid://17285554126",    CanPurchase = false },
		Face6   = { Name = "Face6",          Price = 6,  LevelRequired = 3, Rarity = "Rare",   Image = "rbxassetid://70391209868621", CanPurchase = false },
		Face7   = { Name = "Face7",          Price = 8,  LevelRequired = 5, Rarity = "Rare",   Image = "rbxassetid://18626918162",    CanPurchase = false },
		Face8   = { Name = "Face8",          Price = 8,  LevelRequired = 4, Rarity = "Common", Image = "rbxassetid://17373537487",    CanPurchase = false },
		Face9   = { Name = "Face9",          Price = 9,  LevelRequired = 1, Rarity = "Rare",   Image = "rbxassetid://118980363558612", CanPurchase = false },
		Face10  = { Name = "Face10",         Price = 10, LevelRequired = 1, Rarity = "Rare",   Image = "rbxassetid://18870092964",    CanPurchase = false },
		Face11  = { Name = "Face11",         Price = 11, LevelRequired = 1, Rarity = "Rare",   Image = "rbxassetid://101878427779141", CanPurchase = false },
		Face12  = { Name = "Face12",         Price = 12, LevelRequired = 1, Rarity = "Rare",   Image = "rbxassetid://112166980943980", CanPurchase = false },

	},

	Hats = {
		Hat1 = { Name = "Hat1",          Price = 400,  LevelRequired = 3,  Rarity = "Common",    Image = "rbxassetid://97016006374032", CanPurchase = false },
		Hat2 = { Name = "Hat2",      Price = 1200, LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://94019428436806", CanPurchase = false },
		Hat3 = { Name = "Hat3",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://131331207733432", CanPurchase = false },
	},

	Outfits = {
		Default = { Name = "Default Outfit", Price = 0,    LevelRequired = 1,  Rarity = "Common",   CanPurchase = false },
		Outfit1 = { Name = "Battle Suit",    Price = 800,  LevelRequired = 8,  Rarity = "Uncommon", CanPurchase = false },
	},
}

return table.freeze(ItemsConfig)
