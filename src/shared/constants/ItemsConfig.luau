--!strict
--[[
	ItemsConfig.luau
	Base de datos estática e inmutable de todos los ítems del juego.
	ShopService construye un cache O(1) a partir de este módulo en Start().

	Estructura:
	  ItemsConfig[category][itemId] = ItemConfig

	Categorías válidas: "Weapons", "WeaponSkins", "KillEffects",
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
}

export type ItemCategory = { [string]: ItemConfig }

export type ItemsConfigType = {
	Weapons: ItemCategory,
	WeaponSkins: ItemCategory,
	KillEffects: ItemCategory,
	Faces: ItemCategory,
	Hats: ItemCategory,
	Outfits: ItemCategory,
}

-- ────────────────────────────────────────────────────────────
-- DATOS
-- ────────────────────────────────────────────────────────────

local ItemsConfig: ItemsConfigType = {

	Weapons = {
		Default   = { Name = "Default Weapon",  Price = 0,    LevelRequired = 1,  Rarity = "Common"    },
		Weapon2   = { Name = "Weapon 2",         Price = 500,  LevelRequired = 5,  Rarity = "Uncommon"  },
		Weapon3   = { Name = "Weapon 3",         Price = 1000, LevelRequired = 10, Rarity = "Rare"      },
		Weapon4   = { Name = "Weapon 4",         Price = 2000, LevelRequired = 15, Rarity = "Epic"      },
		Weapon5   = { Name = "Weapon 5",         Price = 3500, LevelRequired = 20, Rarity = "Epic"      },
		Weapon6   = { Name = "Weapon 6",         Price = 5000, LevelRequired = 25, Rarity = "Legendary" },
	},

	WeaponSkins = {
		Default   = { Name = "Default Skin",    Price = 0,    LevelRequired = 1,  Rarity = "Common"    },
		Skin_Red  = { Name = "Red Skin",        Price = 300,  LevelRequired = 1,  Rarity = "Common"    },
		Skin_Blue = { Name = "Blue Skin",       Price = 300,  LevelRequired = 1,  Rarity = "Common"    },
		Skin_Gold = { Name = "Gold Skin",       Price = 2500, LevelRequired = 15, Rarity = "Legendary" },
	},

	KillEffects = {
		Default = { Name = "Default Kill",   Price = 0,    LevelRequired = 1,  Rarity = "Common" },
		Gravity = { Name = "Gravity Kill",   Price = 1500, LevelRequired = 10, Rarity = "Rare"   },
	},

	Faces = {
		Default = { Name = "Default Face",   Price = 0,   LevelRequired = 1,  Rarity = "Common"   },
		Face1   = { Name = "Happy Face",     Price = 200, LevelRequired = 1,  Rarity = "Common"   },
		Face2   = { Name = "Cool Face",      Price = 500, LevelRequired = 5,  Rarity = "Uncommon" },
	},

	Hats = {
		Hat1 = { Name = "Cap",          Price = 400,  LevelRequired = 3,  Rarity = "Common"    },
		Hat2 = { Name = "Top Hat",      Price = 1200, LevelRequired = 10, Rarity = "Rare"      },
		Hat3 = { Name = "Crown",        Price = 4000, LevelRequired = 20, Rarity = "Legendary" },
	},

	Outfits = {
		Default = { Name = "Default Outfit", Price = 0,    LevelRequired = 1,  Rarity = "Common"   },
		Outfit1 = { Name = "Battle Suit",    Price = 800,  LevelRequired = 8,  Rarity = "Uncommon" },
	},
}

return table.freeze(ItemsConfig)
