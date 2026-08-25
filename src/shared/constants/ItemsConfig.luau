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
	isBPExclusive: boolean?,  -- Si true, sólo se obtiene vía Battle Pass; oculto en Locker hasta poseerse y rechazado por Shop.
	TextureID: string?,
	BaseColor: Color3?,
	Material: Enum.Material?,  -- Material de la parte principal del arma (Neon, Metal, etc.). Si es nil se conserva el original.
	isAnimated: boolean?,
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
    AK      = { Name = "AK",      Price = 65,    LevelRequired = 0,  Rarity = "Common",    Image = asset(100246140710694), CanPurchase = false },
    Groza   = { Name = "Groza",   Price = 125,    LevelRequired = 1,  Rarity = "Common",  Image = asset(133051760713810), CanPurchase = true },
    Default = { Name = "Default", Price = 400, LevelRequired = 4,  Rarity = "Rare",      Image = asset(115787466520426), CanPurchase = true },
    Tommy   = { Name = "Tommy",   Price = 800, LevelRequired = 7,  Rarity = "Epic",      Image = asset(111814750317784), CanPurchase = true },
    Sniper  = { Name = "Sniper",  Price = 2500, LevelRequired = 15,  Rarity = "Legendary",      Image = asset(86261275288637),  CanPurchase = true },
    Large   = { Name = "Large",   Price = 5000, LevelRequired = 23,  Rarity = "Legendary",      Image = asset(90736156284730),  CanPurchase = true },
},

Special = {
    -- Secondary/Special (corto rango o alto impacto)
    Short   = { Name = "Short",   Price = 250, LevelRequired = 3,  Rarity = "Rare",      Image = asset(118462878872416), CanPurchase = true },
    UZI     = { Name = "UZI",     Price = 65, LevelRequired = 0,  Rarity = "Common",         Image = asset(109948875778066), CanPurchase = true },
    Laser   = { Name = "Laser",   Price = 1250, LevelRequired = 10,  Rarity = "Epic",      Image = asset(80482264427643),  CanPurchase = true },
    RPG     = { Name = "RPG",     Price = 5000, LevelRequired = 23,  Rarity = "Legendary",      Image = asset(139650368086109), CanPurchase = true },
},


	WeaponWraps = {
		Default   = {
			Name = "Default",
			Price = 0,
			LevelRequired = 1,
			Rarity = "Common",
			Image = asset(109044845487335),
			CanPurchase = false,
			BaseColor = Color3.fromRGB(255, 255, 255),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Pink = {
			Name = "Pink Wrap",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Epic",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(255, 105, 180),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Red  = {
			Name = "SK_0020",
			Price = 300,
			LevelRequired = 1,
			Rarity = "Epic",
			CanPurchase = true,
			TextureID = asset(86966645142772),
			isAnimated = true,
			StudsPerTile = 3,
			ScrollSpeedU = 1,
			ScrollSpeedV = 0,
		},
		-- Skin de prueba para el soporte de Material: color verde brillante +
		-- Material.Neon (debe verse "encendida"/glow). Gratis y comprable para
		-- poder probarla rápido desde la tienda.
		Wrap_Neon_Test = {
			Name = "Neon Test",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Legendary",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(0, 255, 170),
			Material = Enum.Material.Neon,
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Blue = {
			Name = "Blue Wrap",
			Price = 300,
			LevelRequired = 1,
			Rarity = "Common",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(57, 110, 207),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_RPG_Blue = {
			Name = "RPG Blue",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(30, 120, 255),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Gold = {
			Name = "Gold Wrap",
			Price = 2500,
			LevelRequired = 15,
			Rarity = "Legendary",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(214, 170, 55),
			isAnimated = false,
			StudsPerTile = 3,
		},
		-- Cash wrap de prueba: irá a la tienda de rotación (pendiente); mientras,
		-- excluido de Collection por CanPurchase+Price.
		Test_Cash_Coral = {
			Name = "Coral",
			Price = 750,
			LevelRequired = 0,
			Rarity = "Uncommon",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(255, 120, 90),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Mastery_Bronze = {
			Name = "Bronze Mastery",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(176, 110, 60),
			isAnimated = false,
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
			isAnimated = false,
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
			isAnimated = false,
			StudsPerTile = 3,
			KillChallenge = { Kills = 1500 },
		},
	},

	KillEffects = {
		Default   = { Name = "Default Kill",   Price = 0,   LevelRequired = 1, Rarity = "Common", Image = "rbxassetid://130437553674754", CanPurchase = false },
		Gravity   = { Name = "Gravity Kill",   Price = 200, LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://130437553674754", CanPurchase = false, isBPExclusive = true },
		Explosion = { Name = "Explosion Kill", Price = 800, LevelRequired = 7, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
	},

	Faces = {
		-- "Default" = la cara base del rig (no es un decal de catálogo). Todo jugador
		-- la posee y equipa por DataTemplate, así que DEBE existir en el catálogo o
		-- el Locker no puede mostrar la cara equipada y applyFaceToHead no-opea.
		-- Usamos la textura built-in del engine (rbxasset://, no un assetId de catálogo
		-- desconocido) para que el catálogo renderice algo seguro y aplicarla restaure
		-- la cara base del head. No comprable, precio 0.
		Default = { Name = "Default",        Price = 0,  LevelRequired = 0, Rarity = "Common", Image = "rbxasset://textures/face.png", CanPurchase = false },
		Face1   = { Name = "Default Face",   Price = 100,  LevelRequired = 1, Rarity = "Common",   Image = "rbxassetid://79175047578893",  CanPurchase = true },
		Face2   = { Name = "Face2",          Price = 200,  LevelRequired = 2, Rarity = "Uncommon",   Image = "rbxassetid://18571318923",    CanPurchase = false },
		Face3   = { Name = "Face3",          Price = 125,  LevelRequired = 1, Rarity = "Common",   Image = "rbxassetid://97580829209799", CanPurchase = true },
		Face4   = { Name = "Face4",          Price = 2500,  LevelRequired = 15, Rarity = "Legendary",   Image = "rbxassetid://94789972115859", CanPurchase = true },
		Face5   = { Name = "Face5",          Price = 250,  LevelRequired = 3, Rarity = "Rare",   Image = "rbxassetid://17285554126",    CanPurchase = false },
		Face6   = { Name = "Face6",          Price = 4000,  LevelRequired = 20, Rarity = "Legendary",   Image = "rbxassetid://70391209868621", CanPurchase = true },
		Face7   = { Name = "Face7",          Price = 5000,  LevelRequired = 23, Rarity = "Legendary",   Image = "rbxassetid://18626918162",    CanPurchase = true },
		Face8   = { Name = "Face8",          Price = 65,  LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://17373537487",    CanPurchase = true },
		Face9   = { Name = "Face9",          Price = 400,  LevelRequired = 4, Rarity = "Rare",   Image = "rbxassetid://118980363558612", CanPurchase = false },
		Face10  = { Name = "Face10",         Price = 800, LevelRequired = 7, Rarity = "Epic",   Image = "rbxassetid://18870092964",    CanPurchase = true },
		Face11  = { Name = "Face11",         Price = 1000, LevelRequired = 8, Rarity = "Epic",   Image = "rbxassetid://101878427779141", CanPurchase = true },
		Face12  = { Name = "Face12",         Price = 1250, LevelRequired = 10, Rarity = "Epic",   Image = "rbxassetid://112166980943980", CanPurchase = true },

	},

	Hats = {
		Hat1 = { Name = "Bunny",          Price = 65,  LevelRequired = 0,  Rarity = "Common",    Image = "rbxassetid://117004939623250", CanPurchase = true },
		Hat2 = { Name = "Cone",      Price = 1200, LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://138341632720877", CanPurchase = false, isBPExclusive = true },
		Hat3 = { Name = "Crown",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://119183410438332", CanPurchase = false, isBPExclusive = true },
		Hat4 = { Name = "Squid",        Price = 800, LevelRequired = 7, Rarity = "Epic", Image = "rbxassetid://74317816532636", CanPurchase = true },
		Hat5 = { Name = "Alaska",        Price = 1000, LevelRequired = 8, Rarity = "Epic", Image = "rbxassetid://83643028468192", CanPurchase = true },
		Hat6 = { Name = "Drink",        Price = 1250, LevelRequired = 10, Rarity = "Epic", Image = "rbxassetid://130927276777389", CanPurchase = true },
		Hat7 = { Name = "IceCream",        Price = 2500, LevelRequired = 15, Rarity = "Legendary", Image = "rbxassetid://89103967355981", CanPurchase = true },
		Hat8 = { Name = "Spartan",        Price = 4000, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://89103967355981", CanPurchase = true },
		Hat9 = { Name = "RaceHelmet",        Price = 5000, LevelRequired = 23, Rarity = "Legendary", Image = "rbxassetid://84090421736652", CanPurchase = true },
		Hat10 = { Name = "Pan",        Price = 100, LevelRequired = 1, Rarity = "Common", Image = "rbxassetid://97418970357486", CanPurchase = true },
		Hat11 = { Name = "Football",        Price = 125, LevelRequired = 1, Rarity = "Common", Image = "rbxassetid://86457108228550", CanPurchase = true },
		Hat12 = { Name = "Mexican",        Price = 200, LevelRequired = 2, Rarity = "Uncommon", Image = "rbxassetid://79179819137524", CanPurchase = true },
		Hat13 = { Name = "Shark",        Price = 250, LevelRequired = 3, Rarity = "Rare", Image = "rbxassetid://72319063957484", CanPurchase = true },
		Hat14 = { Name = "Unicorn",        Price = 400, LevelRequired = 4, Rarity = "Rare", Image = "rbxassetid://112312308063894", CanPurchase = true },


	},

	Outfits = {
		-- Las claves coinciden con los .rbxm en Shared.Bodies (outfitId = clave = nombre del modelo).
		-- Image = thumbnail 2D de la tarjeta del locker. Placeholder rbxassetid://0 → reemplazar por el ID real.
		Default = { Name = "Default Outfit", Price = 0,    LevelRequired = 1,  Rarity = "Common",   Image = "rbxassetid://107928751959121", CanPurchase = false },
		Tourist = { Name = "Tourist",        Price = 65,  LevelRequired = 0,  Rarity = "Common", Image = "rbxassetid://119849081428861", CanPurchase = true },
		Ducky   = { Name = "Ducky",          Price = 250, LevelRequired = 3, Rarity = "Rare",     Image = "rbxassetid://137997678899031", CanPurchase = true },
		Inmate  = { Name = "Inmate",         Price = 1250, LevelRequired = 10, Rarity = "Epic",     Image = "rbxassetid://75053707941889", CanPurchase = true },
		Jungle  = { Name = "Jungle",         Price = 5000, LevelRequired = 23, Rarity = "Legendary",     Image = "rbxassetid://109406925958012", CanPurchase = true },
	},
}

return table.freeze(ItemsConfig)



