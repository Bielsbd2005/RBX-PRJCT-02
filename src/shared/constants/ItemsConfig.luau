--!strict
--[[
	ItemsConfig.luau
	Base de datos estática e inmutable de todos los ítems del juego.
	ShopService construye un cache O(1) a partir de este módulo en Start().

	Estructura:
	  ItemsConfig[category][itemId] = ItemConfig

	Categorías válidas: "Main", "Special", "WeaponWraps", "KillEffects",
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
	BPExclusive: boolean?,  -- Si true, sólo se obtiene vía Battle Pass; oculto en Locker hasta poseerse y rechazado por Shop.
	TextureID: string?,
	BaseColor: Color3?,
	Animated: boolean?,
	StudsPerTile: number?,
	ScrollSpeedU: number?,
	ScrollSpeedV: number?,
	KillChallenge: { Kills: number }?,
}

export type ItemCategory = { [string]: ItemConfig }

export type ItemsConfigType = {
	Main: ItemCategory,
	Special: ItemCategory,
	WeaponWraps: ItemCategory,
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

local ItemsConfig: ItemsConfigType = {

Main = {
    -- Primary (rango medio, daño sostenido)
    AK      = { Name = "AK",      Price = 0,    LevelRequired = 0,  Rarity = "Common",    Image = asset(100246140710694), CanPurchase = false },
    Groza   = { Name = "Groza",   Price = 2,    LevelRequired = 1,  Rarity = "Uncommon",  Image = asset(133051760713810), CanPurchase = false },
    Default = { Name = "Default", Price = 1000, LevelRequired = 0,  Rarity = "Rare",      Image = asset(115787466520426), CanPurchase = false },
    Tommy   = { Name = "Tommy",   Price = 1000, LevelRequired = 0,  Rarity = "Rare",      Image = asset(111814750317784), CanPurchase = false },
    Sniper  = { Name = "Sniper",  Price = 1000, LevelRequired = 0,  Rarity = "Rare",      Image = asset(86261275288637),  CanPurchase = false },
    Large   = { Name = "Large",   Price = 1000, LevelRequired = 0,  Rarity = "Rare",      Image = asset(90736156284730),  CanPurchase = false },
},

Special = {
    -- Secondary/Special (corto rango o alto impacto)
    Short   = { Name = "Short",   Price = 1000, LevelRequired = 0,  Rarity = "Rare",      Image = asset(118462878872416), CanPurchase = false },
    UZI     = { Name = "UZI",     Price = 1000, LevelRequired = 0,  Rarity = "Rare",      Image = asset(109948875778066), CanPurchase = false },
    Laser   = { Name = "Laser",   Price = 1000, LevelRequired = 0,  Rarity = "Rare",      Image = asset(80482264427643),  CanPurchase = false },
    RPG     = { Name = "RPG",     Price = 1000, LevelRequired = 0,  Rarity = "Rare",      Image = asset(139650368086109), CanPurchase = false },
},

	WeaponWraps = {
		Default   = {
			Name = "DefaulEt",
			Price = 0,
			LevelRequired = 1,
			Rarity = "Common",
			Image = asset(109044845487335),
			CanPurchase = false,
			BaseColor = Color3.fromRGB(255, 255, 255),
			Animated = false,
			StudsPerTile = 3,
		},
		Wrap_Red  = {
			Name = "SK_0020",
			Price = 300,
			LevelRequired = 1,
			Rarity = "Epic",
			CanPurchase = false,
			TextureID = asset(86966645142772),
			Animated = true,
			StudsPerTile = 3,
			ScrollSpeedU = 1,
			ScrollSpeedV = 0,
		},
		Wrap_Blue = {
			Name = "Blue Wrap",
			Price = 300,
			LevelRequired = 1,
			Rarity = "Common",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(57, 110, 207),
			Animated = false,
			StudsPerTile = 3,
		},
		Wrap_Gold = {
			Name = "Gold Wrap",
			Price = 2500,
			LevelRequired = 15,
			Rarity = "Legendary",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(214, 170, 55),
			Animated = false,
			StudsPerTile = 3,
		},
		Mastery_Bronze = {
			Name = "Bronze Mastery",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(176, 110, 60),
			Animated = false,
			StudsPerTile = 3,
			KillChallenge = { Kills = 4 },
		},
		Mastery_Silver = {
			Name = "Silver Mastery",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Epic",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(192, 192, 192),
			Animated = false,
			StudsPerTile = 3,
			KillChallenge = { Kills = 500 },
		},
		Mastery_Diamond = {
			Name = "Diamond Mastery",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Legendary",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(120, 220, 255),
			Animated = false,
			StudsPerTile = 3,
			KillChallenge = { Kills = 1500 },
		},
	},

	KillEffects = {
		Default = { Name = "Default Kill",   Price = 0,    LevelRequired = 1,  Rarity = "Common", Image = "rbxassetid://130437553674754", CanPurchase = false },
		Gravity = { Name = "Gravity Kill",   Price = 200, LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://130437553674754", CanPurchase = false },
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
		Hat1 = { Name = "Bunny",          Price = 12000,  LevelRequired = 0,  Rarity = "Common",    Image = "rbxassetid://117004939623250", CanPurchase = false },
		Hat2 = { Name = "Cone",      Price = 1200, LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://138341632720877", CanPurchase = false },
		Hat3 = { Name = "Crown",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://119183410438332", CanPurchase = false },
		Hat4 = { Name = "Squid",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://74317816532636", CanPurchase = false },
		Hat5 = { Name = "Alaska",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://83643028468192", CanPurchase = false },
		Hat6 = { Name = "Drink",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://130927276777389", CanPurchase = false },
		Hat7 = { Name = "IceCream",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://89103967355981", CanPurchase = false },
		Hat8 = { Name = "Spartan",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://89103967355981", CanPurchase = false },
		Hat9 = { Name = "RaceHelmet",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://84090421736652", CanPurchase = false },
		Hat10 = { Name = "Pan",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://97418970357486", CanPurchase = false },
		Hat11 = { Name = "Football",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://86457108228550", CanPurchase = false },
		Hat12 = { Name = "Mexican",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://79179819137524", CanPurchase = false },
		Hat13 = { Name = "Shark",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://72319063957484", CanPurchase = false },
		Hat14 = { Name = "Unicorn",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://112312308063894", CanPurchase = false },


	},

	Outfits = {
		Default = { Name = "Default Outfit", Price = 0,    LevelRequired = 1,  Rarity = "Common",   CanPurchase = false },
		Outfit1 = { Name = "Battle Suit",    Price = 800,  LevelRequired = 8,  Rarity = "Uncommon", CanPurchase = false },
	},
}

return table.freeze(ItemsConfig)
