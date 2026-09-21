--!strict

export type ItemConfig = {
	Name: string,
	Price: number,          -- En la moneda de `Currency`, sin conversión
	Currency: string?,      -- "Cash" (por defecto) | "Gems": ShopService descuenta de esa
	                        -- moneda (Shared.constants.Currency)
	LevelRequired: number,  -- Nivel mínimo para comprar
	Rarity: string,         -- "Common" | "Rare" | "Epic" | "Legendary"
	Image: string?,
	CanPurchase: boolean?,
	isBPExclusive: boolean?,  -- Sólo vía Battle Pass: oculto en Locker hasta poseerse y rechazado por Shop.
	isVIPExclusive: boolean?, -- Lo concede el gamepass VIP (VIPItemsService); oculto en Locker hasta poseerse.
	TextureID: string?,
	BaseColor: Color3?,
	Material: Enum.Material?,  -- De la parte principal del arma; nil conserva el original.
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
	Banners: ItemCategory,
}

-- Precios y niveles se calibran en el dashboard. El nivel se deriva del precio (se
-- desbloquea cuando ya se podía pagar). NADA de lo que regala el pase se vende aquí
-- (isBPExclusive = true, precio 0). Algunos ítems de tienda son aún PROVISIONALES
-- (nombre e Image de relleno).

local function asset(assetId: number): string
	return "rbxassetid://" .. tostring(assetId)
end

local ItemsConfig: ItemsConfigType = {

Main = {
    -- "Default" = arma de inicio: InventoryRepository.ownsWeapon la da siempre por
    -- poseída y es el fallback de LoadoutService/ShopService (ItemDefaults.ITEM_ID).
    Default = { Name = "Default", Price = 0,    LevelRequired = 0,  Rarity = "Common",    Image = asset(83154611597881), CanPurchase = false },
    AK      = { Name = "AK",      Price = 500,  LevelRequired = 5,  Rarity = "Common",    Image = asset(85172441741101), CanPurchase = true },
    Groza   = { Name = "Groza",   Price = 150,   LevelRequired = 0,  Rarity = "Common",  Image = asset(73116397796109), CanPurchase = true },
    Tommy   = { Name = "Tommy",   Price = 5000,  LevelRequired = 21,  Rarity = "Rare",      Image = asset(116729825128346), CanPurchase = true },
    Sniper  = { Name = "Sniper",  Price = 12500, LevelRequired = 36,  Rarity = "Epic",      Image = asset(71831101535350),  CanPurchase = true },
    Large   = { Name = "Large",   Price = 50000, LevelRequired = 75,  Rarity = "Legendary",      Image = asset(120566462075583),  CanPurchase = true },
},

Special = {
    -- Default: misma convención que Main.Default.
    Default = { Name = "Default", Price = 0,   LevelRequired = 0,  Rarity = "Common",        CanPurchase = false, Image = "rbxassetid://129951224466693" },
    Short   = { Name = "Short",   Price = 1000, LevelRequired = 8,  Rarity = "Common",        Image = asset(126259419984088), CanPurchase = true },
    UZI     = { Name = "UZI",     Price = 300, LevelRequired = 0,  Rarity = "Common",         Image = asset(73440329120716), CanPurchase = true },
    Laser   = { Name = "Laser",   Price = 12500, LevelRequired = 36,  Rarity = "Epic",      Image = asset(104390588207353),  CanPurchase = true },
    RPG     = { Name = "RPG",     Price = 50000, LevelRequired = 75,  Rarity = "Legendary",      Image = asset(135425656083964), CanPurchase = true },
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
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(255, 105, 180),
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
			Season = "S1",
			SeasonTier = 19,
		},
		-- Wraps del pase S1: nombre y color PROVISIONALES; la rareza sigue al tier.
		-- TODO: cuando haya arte, darle a Wrap_S1_Prism TextureID animada como Wrap_Red.
		Wrap_S1_Ember = {
			Name = "Ember",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Common",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(230, 90, 40),
			isAnimated = false,
			StudsPerTile = 3,
			Season = "S1",
			SeasonTier = 4,
		},
		Wrap_S1_Tide = {
			Name = "Tide",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(40, 160, 200),
			isAnimated = false,
			StudsPerTile = 3,
			Season = "S1",
			SeasonTier = 7,
		},
		Wrap_S1_Magma = {
			Name = "Magma",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(200, 50, 30),
			isAnimated = false,
			StudsPerTile = 3,
			Season = "S1",
			SeasonTier = 14,
		},
		Wrap_S1_Volt = {
			Name = "Volt",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(255, 230, 0),
			Material = Enum.Material.Neon,
			isAnimated = false,
			StudsPerTile = 3,
			Season = "S1",
			SeasonTier = 22,
		},
		Wrap_S1_Frost = {
			Name = "Frost",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Epic",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(180, 230, 255),
			isAnimated = false,
			StudsPerTile = 3,
			Season = "S1",
			SeasonTier = 26,
		},
		Wrap_S1_Shadow = {
			Name = "Shadow",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Epic",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(40, 40, 50),
			isAnimated = false,
			StudsPerTile = 3,
			Season = "S1",
			SeasonTier = 36,
		},
		Wrap_S1_Prism = {
			Name = "Prism",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Legendary",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(200, 120, 255),
			Material = Enum.Material.Neon,
			isAnimated = false,
			StudsPerTile = 3,
			Season = "S1",
			SeasonTier = 32,
		},
		-- Wraps de tienda: se compran POR ARMA (WeaponWrapsByWeapon), así que su banda de
		-- precio es ≈⅓ de la de su rareza; la rareza marca el tier de la skin, no el precio.
		Wrap_White = {
			Name = "Arctic",
			Price = 100,
			LevelRequired = 0,
			Rarity = "Common",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(235, 240, 245),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Blue = {
			Name = "Blue Wrap",
			Price = 150,
			LevelRequired = 2,
			Rarity = "Common",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(57, 110, 207),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Green = {
			Name = "Forest",
			Price = 400,
			LevelRequired = 4,
			Rarity = "Common",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(70, 150, 80),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Coral = {
			Name = "Coral",
			Price = 1000,
			LevelRequired = 8,
			Rarity = "Rare",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(255, 120, 90),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Purple = {
			Name = "Royal Purple",
			Price = 1500,
			LevelRequired = 10,
			Rarity = "Rare",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(130, 70, 200),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Red  = {
			Name = "Crimson Flow",
			Price = 4000,
			LevelRequired = 19,
			Rarity = "Epic",
			CanPurchase = true,
			TextureID = asset(86966645142772),
			isAnimated = true,
			StudsPerTile = 3,
			ScrollSpeedU = 1,
			ScrollSpeedV = 0,
		},
		Wrap_Neon = {
			Name = "Neon Surge",
			Price = 6500,
			LevelRequired = 25,
			Rarity = "Epic",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(0, 255, 170),
			Material = Enum.Material.Neon,
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Gold = {
			Name = "Gold Wrap",
			Price = 12500,
			LevelRequired = 36,
			Rarity = "Legendary",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(214, 170, 55),
			isAnimated = false,
			StudsPerTile = 3,
		},
		-- Los wraps son SIEMPRE de Cash: las Gems solo compran pase, skips y outfits.
		Mastery_Bronze = {
			Name = "Bronze Mastery",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(176, 110, 60),
			isAnimated = false,
			StudsPerTile = 3,
			KillChallenge = { Kills = 200 },
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
			KillChallenge = { Kills = 1000 },
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
			KillChallenge = { Kills = 3000 },
		},
	},

	KillEffects = {
		-- TODO: todos comparten el icono genérico; subir iconos propios cuando haya arte.
		Default   = { Name = "Default Kill",   Price = 0,   LevelRequired = 1, Rarity = "Common", Image = "rbxassetid://130437553674754", CanPurchase = false },
		Gravity   = { Name = "Gravity Kill",   Price = 0, LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://130437553674754", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 8 },
		-- Arte en ReplicatedStorage.Templates.Lapida. Precio y nivel PROVISIONALES.
		Tombstone = { Name = "Tombstone Kill", Price = 20000, LevelRequired = 46, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- Precio y nivel PROVISIONALES.
		Balloons  = { Name = "Up, Up & Away", Price = 20000, LevelRequired = 46, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- Arte en ReplicatedStorage.Burning. Precio y nivel PROVISIONALES.
		Burning   = { Name = "Burning Kill",  Price = 20000, LevelRequired = 46, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- Arte OPCIONAL en ReplicatedStorage.Templates.UFO (sin él, OVNI procedural).
		Abduction = { Name = "UFO Abduction", Price = 0, LevelRequired = 0, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 31 },
		-- Sonido OPCIONAL en ReplicatedStorage.Templates.Disassemble. Precio y nivel PROVISIONALES.
		Disassemble = { Name = "Piece by Piece", Price = 20000, LevelRequired = 46, Rarity = "Epic", Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- Orbes sólo cosméticos (no dan XP). Arte OPCIONAL en ReplicatedStorage.Xp o
		-- Templates.Xp (con Xp.BillboardGui.Image). Precio y nivel PROVISIONALES.
		XpOrbs    = { Name = "XP Drop",       Price = 20000, LevelRequired = 46, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
	},

	Faces = {
		-- "Default" DEBE existir con esta clave: DataTemplate la da poseída y equipada
		-- (Faces.Default, Loadout.Face).
		Default = { Name = "Smile",          Price = 0,  LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://79175047578893", CanPurchase = false },
		Sigh       = { Name = "Sigh",       Price = 300,  LevelRequired = 0,  Rarity = "Common",    Image = "rbxassetid://77502892766951", CanPurchase = true },
		Meh        = { Name = "Meh",        Price = 400,   LevelRequired = 4,  Rarity = "Common",    Image = "rbxassetid://17848141083", CanPurchase = true },
		Pout       = { Name = "Pout",       Price = 500,   LevelRequired = 5,  Rarity = "Common",    Image = "rbxassetid://97580829209799", CanPurchase = true },
		Purr       = { Name = "Purr",       Price = 650,   LevelRequired = 6,  Rarity = "Common",    Image = "rbxassetid://73793991067813", CanPurchase = true },
		Unbothered = { Name = "Unbothered", Price = 1000,  LevelRequired = 8,  Rarity = "Common",    Image = "rbxassetid://112917697570516", CanPurchase = true },
		Smirk      = { Name = "Smirk",      Price = 1250,  LevelRequired = 9,  Rarity = "Common",    Image = "rbxassetid://113957522330582", CanPurchase = true },
		KO         = { Name = "K.O.",       Price = 4000,  LevelRequired = 19, Rarity = "Rare",      Image = "rbxassetid://94201211759991", CanPurchase = true },
		Goofy      = { Name = "Goofy",      Price = 10000, LevelRequired = 31, Rarity = "Epic",      Image = "rbxassetid://17373537487", CanPurchase = true },
		Joy        = { Name = "Joy",        Price = 12500, LevelRequired = 36, Rarity = "Epic",      Image = "rbxassetid://18571318923", CanPurchase = true },
		Sly        = { Name = "Sly",        Price = 20000, LevelRequired = 46, Rarity = "Epic",      Image = "rbxassetid://138957466964629", CanPurchase = true },
		Chomper    = { Name = "Chomper",    Price = 65000, LevelRequired = 86, Rarity = "Legendary", Image = "rbxassetid://139252772271446", CanPurchase = true },
		Cutie      = { Name = "Cutie",      Price = 0, LevelRequired = 0, Rarity = "Rare",      Image = "rbxassetid://113135767356440", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 1 },
		Worried    = { Name = "Worried",    Price = 0, LevelRequired = 0, Rarity = "Rare",      Image = "rbxassetid://89277236777187", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 6 },
		Exhausted  = { Name = "Exhausted",  Price = 0, LevelRequired = 0, Rarity = "Rare",      Image = "rbxassetid://118367363713874", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 11 },
		Blep       = { Name = "Blep",       Price = 0, LevelRequired = 0, Rarity = "Epic",      Image = "rbxassetid://122618931216206", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 16 },
		Angry      = { Name = "Angry",      Price = 0, LevelRequired = 0, Rarity = "Rare",      Image = "rbxassetid://101878427779141", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 23 },
		Derp       = { Name = "Derp",       Price = 0, LevelRequired = 0, Rarity = "Legendary", Image = "rbxassetid://134592485348307", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 34 },
		Scream     = { Name = "Scream",     Price = 0, LevelRequired = 0, Rarity = "Legendary", Image = "rbxassetid://17278359754", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 39 },
	},

	Hats = {
		-- CosmeticsTemplates.findHatTemplate busca el Accessory en Shared/Locker/Hats por
		-- Name y luego por clave. Los Hair* el Locker los pinta con ItemHair.
		Hair1 = { Name = "#01", Price = 300, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://83980144647844", CanPurchase = true },
		Hair2 = { Name = "#02", Price = 300, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://109302398273420", CanPurchase = true },
		Hair3 = { Name = "#03", Price = 300, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://76394833926082", CanPurchase = true },
		Hair4 = { Name = "#04", Price = 400, LevelRequired = 4, Rarity = "Common", Image = "rbxassetid://74260766660298", CanPurchase = true },
		Hair5 = { Name = "#05", Price = 400, LevelRequired = 4, Rarity = "Common", Image = "rbxassetid://115168351479536", CanPurchase = true },
		Hair6 = { Name = "#06", Price = 650, LevelRequired = 6, Rarity = "Common", Image = "rbxassetid://114132003042993", CanPurchase = true },
		Hair7 = { Name = "#07", Price = 650, LevelRequired = 6, Rarity = "Common", Image = "rbxassetid://77981161617693", CanPurchase = true },
		-- En reserva (arte listo) para una rotación o S2:
		-- Hair8  = { Name = "#08", Image = "rbxassetid://107460104584128" },
		-- Hair9  = { Name = "#09", Image = "rbxassetid://92825188822719" },
		-- Hair10 = { Name = "#10", Image = "rbxassetid://118499969525309" },

		Pan      = { Name = "Pan",      Price = 1000,  LevelRequired = 8,  Rarity = "Common",  Image = "rbxassetid://98264698156738",  CanPurchase = true },
		Football = { Name = "Football", Price = 4000,  LevelRequired = 19, Rarity = "Rare",      Image = "rbxassetid://98792972052226",  CanPurchase = true },
		Captain  = { Name = "Captain",  Price = 25000, LevelRequired = 52, Rarity = "Epic",      Image = "rbxassetid://130137968102712", CanPurchase = true },
		-- Techo del catálogo: precio y nivel fijados a mano (la serie del dashboard no llega).
		Racing   = { Name = "Racing",   Price = 80000, LevelRequired = 96, Rarity = "Legendary", Image = "rbxassetid://82112635387141",  CanPurchase = true },

		Cone      = { Name = "Cone",      Price = 0, LevelRequired = 0, Rarity = "Rare",  Image = "rbxassetid://87414125761780",  CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 10 },
		Squid     = { Name = "Squid",     Price = 0, LevelRequired = 0, Rarity = "Rare",      Image = "rbxassetid://134763444804317", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 15 },
		Unicorn   = { Name = "Unicorn",   Price = 0, LevelRequired = 0, Rarity = "Rare",      Image = "rbxassetid://124436692128195", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 18 },
		Raccoon   = { Name = "Raccoon",   Price = 0, LevelRequired = 0, Rarity = "Epic",      Image = "rbxassetid://97532336058006",  CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 24 },
		Shark     = { Name = "Shark",     Price = 0, LevelRequired = 0, Rarity = "Rare",  Image = "rbxassetid://134534862804519", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 29 },
		Adventure = { Name = "Adventure", Price = 0, LevelRequired = 0, Rarity = "Epic",      Image = "rbxassetid://128435788752887", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 30 },
		Bunny     = { Name = "Bunny",     Price = 0, LevelRequired = 0, Rarity = "Common",    Image = "rbxassetid://134209005674999", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 35 },
		Crown     = { Name = "Crown",     Price = 0, LevelRequired = 0, Rarity = "Legendary", Image = "rbxassetid://138029493389714", CanPurchase = false, isVIPExclusive = true },
	},

	Outfits = {
		Default = { Name = "Dusty", Price = 0,    LevelRequired = 1,  Rarity = "Common",   Image = "rbxassetid://113812840207293", CanPurchase = false },
		Ducky   = { Name = "Ducky",          Price = 0, LevelRequired = 0, Rarity = "Rare",     Image = "rbxassetid://131931384520146", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 40 },
		Tourist = { Name = "Tourist",        Price = 100,  LevelRequired = 0,  Rarity = "Common", Image = "rbxassetid://120382636547205", CanPurchase = true, Currency = "Gems" },
		Casual  = { Name = "Casual Dad",         Price = 1000, LevelRequired = 5, Rarity = "Epic",     Image = "rbxassetid://138309329239258", CanPurchase = true, Currency = "Gems" },
		Jungle  = { Name = "Jorge",         Price = 2500, LevelRequired = 10, Rarity = "Legendary",     Image = "rbxassetid://137785541624765", CanPurchase = true, Currency = "Gems" },
		Agent  = { Name = "007",         Price = 2500, LevelRequired = 10, Rarity = "Legendary",     Image = "rbxassetid://81380638175638", CanPurchase = true, Currency = "Gems" },
		Armored  = { Name = "Fridge",         Price = 2500, LevelRequired = 10, Rarity = "Legendary",     Image = "rbxassetid://130012491007709", CanPurchase = true, Currency = "Gems" },
	},

	Banners = {
		-- Fondo de DeathScreen.Card que ve quien muere a manos del portador (Loadout.Banner).
		-- Solo vía pase: reward `{ Kind = "Item", Category = "Banners", ItemId = ... }` desde
		-- el dashboard, con Season/SeasonTier aquí. La Image de Studio se pisa: todos llevan
		-- Image, y Default es el fallback de la tarjeta.
		Default = { Name = "Default", Price = 0, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://74350418219200", CanPurchase = false },
		-- De PRUEBA: sin reward en el pase aún (en Studio, comando /banners).
		Banner1 = { Name = "Banner 1", Price = 0, LevelRequired = 0, Rarity = "Rare", Image = "rbxassetid://71273279440699", CanPurchase = false, isBPExclusive = true },
		Banner2 = { Name = "Banner 2", Price = 0, LevelRequired = 0, Rarity = "Epic", Image = "rbxassetid://132619218310875", CanPurchase = false, isBPExclusive = true },
	},
}

return table.freeze(ItemsConfig)



