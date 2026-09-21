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
	AnimationId: string?,   -- Emotes: animación R15 que reproduce EmotePlayer.
	Looped: boolean?,       -- Emotes: true = se repite hasta que el jugador se mueva.
}

export type ItemCategory = { [string]: ItemConfig }

export type ItemsConfigType = {
	Main: ItemCategory,
	Special: ItemCategory,
	WeaponWraps: ItemCategory,
	KillEffects: ItemCategory,
	Emotes: ItemCategory,
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
    AK      = { Name = "AK",      Price = 2000,  LevelRequired = 13,  Rarity = "Rare",    Image = asset(85172441741101), CanPurchase = true },
    Groza   = { Name = "Groza",   Price = 300,   LevelRequired = 0,  Rarity = "Common",  Image = asset(73116397796109), CanPurchase = true },
    Tommy   = { Name = "Tommy",   Price = 5000,  LevelRequired = 23,  Rarity = "Rare",      Image = asset(116729825128346), CanPurchase = true },
    Sniper  = { Name = "Sniper",  Price = 20000, LevelRequired = 50,  Rarity = "Epic",      Image = asset(71831101535350),  CanPurchase = true },
    Large   = { Name = "Large",   Price = 65000, LevelRequired = 93,  Rarity = "Legendary",      Image = asset(120566462075583),  CanPurchase = true },
    -- RESERVADO: la definición (Definitions/<Category>/<Id>.luau) ya existe; falta el Tool ServerStorage.WeaponTools.<Category>.<Id>.
    -- Descomentar con la Image real cuando esté el Tool (sin él se compraría y no haría nada); precio, nivel y rareza ya son los de la escalera.
    -- LMG = { Name = "LMG", Price = 50000, LevelRequired = 82, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
},

Special = {
    -- Default: misma convención que Main.Default.
    Default = { Name = "Default", Price = 0,   LevelRequired = 0,  Rarity = "Common",        CanPurchase = false, Image = "rbxassetid://129951224466693" },
    Short   = { Name = "Short",   Price = 2500, LevelRequired = 15,  Rarity = "Rare",        Image = asset(126259419984088), CanPurchase = true },
    UZI     = { Name = "UZI",     Price = 300, LevelRequired = 0,  Rarity = "Common",         Image = asset(73440329120716), CanPurchase = true },
    Laser   = { Name = "Laser",   Price = 40000, LevelRequired = 73,  Rarity = "Epic",      Image = asset(104390588207353),  CanPurchase = true },
    RPG     = { Name = "RPG",     Price = 100000, LevelRequired = 117,  Rarity = "Legendary",      Image = asset(135425656083964), CanPurchase = true },
    -- RESERVADO: la definición (Definitions/<Category>/<Id>.luau) ya existe; falta el Tool ServerStorage.WeaponTools.<Category>.<Id>.
    -- Descomentar con la Image real cuando esté el Tool (sin él se compraría y no haría nada); precio, nivel y rareza ya son los de la escalera.
    -- Revolver = { Name = "Revolver", Price = 6500, LevelRequired = 27, Rarity = "Rare", Image = "rbxassetid://0", CanPurchase = true },
    -- Burst = { Name = "Burst", Price = 12500, LevelRequired = 39, Rarity = "Epic", Image = "rbxassetid://0", CanPurchase = true },
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
		-- Los wraps NO se venden: sólo se consiguen por maestría (KillChallenge) o en el pase.
		-- En reserva para un pase futuro (sólo datos):
		-- Wrap_White  = { Name = "Arctic",       Rarity = "Common",    BaseColor = Color3.fromRGB(235, 240, 245) },
		-- Wrap_Blue   = { Name = "Blue Wrap",    Rarity = "Common",    BaseColor = Color3.fromRGB(57, 110, 207) },
		-- Wrap_Green  = { Name = "Forest",       Rarity = "Common",    BaseColor = Color3.fromRGB(70, 150, 80) },
		-- Wrap_Coral  = { Name = "Coral",        Rarity = "Rare",      BaseColor = Color3.fromRGB(255, 120, 90) },
		-- Wrap_Purple = { Name = "Royal Purple", Rarity = "Rare",      BaseColor = Color3.fromRGB(130, 70, 200) },
		-- Wrap_Red    = { Name = "Crimson Flow", Rarity = "Epic",      TextureID = asset(86966645142772), isAnimated = true, ScrollSpeedU = 1, ScrollSpeedV = 0 },
		-- Wrap_Neon   = { Name = "Neon Surge",   Rarity = "Epic",      BaseColor = Color3.fromRGB(0, 255, 170), Material = Enum.Material.Neon },
		-- Wrap_Gold   = { Name = "Gold Wrap",    Rarity = "Legendary", BaseColor = Color3.fromRGB(214, 170, 55) },
		Mastery_Bronze = {
			Name = "Bronze Mastery",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(176, 110, 60),
			isAnimated = false,
			StudsPerTile = 3,
			KillChallenge = { Kills = 500 },
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
			KillChallenge = { Kills = 2500 },
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
			KillChallenge = { Kills = 10000 },
		},
	},

	KillEffects = {
		-- TODO: todos comparten el icono genérico; subir iconos propios cuando haya arte.
		Default   = { Name = "Default Kill",   Price = 0,   LevelRequired = 1, Rarity = "Common", Image = "rbxassetid://130437553674754", CanPurchase = false },
		Gravity   = { Name = "Gravity Kill",   Price = 0, LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://130437553674754", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 8 },
		-- Arte en ReplicatedStorage.Templates.Lapida. Precio y nivel PROVISIONALES.
		Tombstone = { Name = "Tombstone Kill", Price = 5000, LevelRequired = 11, Rarity = "Rare",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- Precio y nivel PROVISIONALES.
		Balloons  = { Name = "Up, Up & Away", Price = 50000, LevelRequired = 41, Rarity = "Legendary",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- Arte en ReplicatedStorage.Burning. Precio y nivel PROVISIONALES.
		Burning   = { Name = "Burning Kill",  Price = 10000, LevelRequired = 17, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- Arte OPCIONAL en ReplicatedStorage.Templates.UFO (sin él, OVNI procedural).
		Abduction = { Name = "UFO Abduction", Price = 0, LevelRequired = 0, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 31 },
		-- Sonido OPCIONAL en ReplicatedStorage.Templates.Disassemble. Precio y nivel PROVISIONALES.
		Disassemble = { Name = "Piece by Piece", Price = 125000, LevelRequired = 65, Rarity = "Legendary", Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- Orbes sólo cosméticos (no dan XP). Arte OPCIONAL en ReplicatedStorage.Xp o
		-- Templates.Xp (con Xp.BillboardGui.Image). Precio y nivel PROVISIONALES.
		XpOrbs    = { Name = "XP Drop",       Price = 25000, LevelRequired = 28, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- PROVISIONALES: entradas reales con nombre e Image de relleno; sustituir por el efecto
		-- definitivo (mismo precio, nivel y rareza). Sin módulo en KillEffectsRegistry cae al
		-- Default. KE_P01 es el suelo de la categoría (sin nivel); KE_P12, su trofeo.
		KE_P01   = { Name = "Kill P01",  Price = 2500,   LevelRequired = 0,   Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P02   = { Name = "Kill P02",  Price = 4000,   LevelRequired = 10,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P03   = { Name = "Kill P03",  Price = 5000,   LevelRequired = 11,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P04   = { Name = "Kill P04",  Price = 6500,   LevelRequired = 13,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P05   = { Name = "Kill P05",  Price = 10000,  LevelRequired = 17,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P06   = { Name = "Kill P06",  Price = 12500,  LevelRequired = 19,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P07   = { Name = "Kill P07",  Price = 20000,  LevelRequired = 25,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P08   = { Name = "Kill P08",  Price = 25000,  LevelRequired = 28,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P09   = { Name = "Kill P09",  Price = 40000,  LevelRequired = 36,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		KE_P10   = { Name = "Kill P10",  Price = 65000,  LevelRequired = 46,  Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
		KE_P11   = { Name = "Kill P11",  Price = 100000, LevelRequired = 58, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
		KE_P12   = { Name = "Kill P12",  Price = 300000, LevelRequired = 102, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
	},

	Emotes = {
		-- Animaciones stock de Roblox (R15, públicas: sirven en cualquier juego).
		-- Se reproducen en partida con la tecla E. Sin Image: el Locker cae en su
		-- thumbnail por defecto hasta que haya iconos propios.
		Default = { Name = "Wave",    Price = 0,    LevelRequired = 0,  Rarity = "Common",   CanPurchase = false, AnimationId = asset(507770239) },
		Point   = { Name = "Point",   Price = 65,   LevelRequired = 1,  Rarity = "Common",   CanPurchase = true,  AnimationId = asset(507770453) },
		Cheer   = { Name = "Cheer",   Price = 200,  LevelRequired = 3,  Rarity = "Common",   CanPurchase = true,  AnimationId = asset(507770677) },
		Laugh   = { Name = "Laugh",   Price = 250,  LevelRequired = 4,  Rarity = "Common",   CanPurchase = true,  AnimationId = asset(507770818) },
		Dance   = { Name = "Dance",   Price = 400,  LevelRequired = 6,  Rarity = "Rare",     CanPurchase = true,  AnimationId = asset(507771019), Looped = true },
		Groove  = { Name = "Groove",  Price = 1000, LevelRequired = 10, Rarity = "Epic",     CanPurchase = true,  AnimationId = asset(507776043), Looped = true },
		Shuffle = { Name = "Shuffle", Price = 2000, LevelRequired = 16, Rarity = "Epic",     CanPurchase = true,  AnimationId = asset(507777268), Looped = true },
	},

	Faces = {
		-- "Default" DEBE existir con esta clave: DataTemplate la da poseída y equipada
		-- (Faces.Default, Loadout.Face).
		Default = { Name = "Smile",          Price = 0,  LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://79175047578893", CanPurchase = false },
		Sigh       = { Name = "Sigh",       Price = 300,  LevelRequired = 0,  Rarity = "Common",    Image = "rbxassetid://77502892766951", CanPurchase = true },
		Meh        = { Name = "Meh",        Price = 400,   LevelRequired = 2,  Rarity = "Common",    Image = "rbxassetid://17848141083", CanPurchase = true },
		Pout       = { Name = "Pout",       Price = 500,   LevelRequired = 2,  Rarity = "Common",    Image = "rbxassetid://97580829209799", CanPurchase = true },
		Purr       = { Name = "Purr",       Price = 650,   LevelRequired = 3,  Rarity = "Common",    Image = "rbxassetid://73793991067813", CanPurchase = true },
		Unbothered = { Name = "Unbothered", Price = 1000,  LevelRequired = 4,  Rarity = "Common",    Image = "rbxassetid://112917697570516", CanPurchase = true },
		Smirk      = { Name = "Smirk",      Price = 1250,  LevelRequired = 5,  Rarity = "Common",    Image = "rbxassetid://113957522330582", CanPurchase = true },
		KO         = { Name = "K.O.",       Price = 4000,  LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://94201211759991", CanPurchase = true },
		Goofy      = { Name = "Goofy",      Price = 10000, LevelRequired = 17, Rarity = "Epic",      Image = "rbxassetid://17373537487", CanPurchase = true },
		Joy        = { Name = "Joy",        Price = 12500, LevelRequired = 19, Rarity = "Epic",      Image = "rbxassetid://18571318923", CanPurchase = true },
		Sly        = { Name = "Sly",        Price = 25000, LevelRequired = 28, Rarity = "Epic",      Image = "rbxassetid://138957466964629", CanPurchase = true },
		Chomper    = { Name = "Chomper",    Price = 200000, LevelRequired = 83, Rarity = "Legendary", Image = "rbxassetid://139252772271446", CanPurchase = true },
		-- PROVISIONALES: entradas reales con nombre e Image de relleno; sustituir por el ítem
		-- definitivo (mismo precio, nivel y rareza). Con Image 0 la cara se aplica en blanco.
		Face_P01 = { Name = "Face P01",  Price = 500,    LevelRequired = 2,   Rarity = "Common",    Image = "rbxassetid://0", CanPurchase = true },
		Face_P02 = { Name = "Face P02",  Price = 1000,   LevelRequired = 4,   Rarity = "Common",    Image = "rbxassetid://0", CanPurchase = true },
		Face_P03 = { Name = "Face P03",  Price = 2000,   LevelRequired = 6,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Face_P04 = { Name = "Face P04",  Price = 2500,   LevelRequired = 7,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Face_P05 = { Name = "Face P05",  Price = 4000,   LevelRequired = 10,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Face_P06 = { Name = "Face P06",  Price = 5000,   LevelRequired = 11,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Face_P07 = { Name = "Face P07",  Price = 6500,   LevelRequired = 13,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Face_P08 = { Name = "Face P08",  Price = 12500,  LevelRequired = 19,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Face_P09 = { Name = "Face P09",  Price = 20000,  LevelRequired = 25,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Face_P10 = { Name = "Face P10",  Price = 40000,  LevelRequired = 36,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Face_P11 = { Name = "Face P11",  Price = 65000,  LevelRequired = 46,  Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
		Face_P12 = { Name = "Face P12",  Price = 100000, LevelRequired = 58, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
		Face_P13 = { Name = "Face P13",  Price = 125000, LevelRequired = 65, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
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
		Hair4 = { Name = "#04", Price = 400, LevelRequired = 2, Rarity = "Common", Image = "rbxassetid://74260766660298", CanPurchase = true },
		Hair5 = { Name = "#05", Price = 400, LevelRequired = 2, Rarity = "Common", Image = "rbxassetid://115168351479536", CanPurchase = true },
		Hair6 = { Name = "#06", Price = 650, LevelRequired = 3, Rarity = "Common", Image = "rbxassetid://114132003042993", CanPurchase = true },
		Hair7 = { Name = "#07", Price = 650, LevelRequired = 3, Rarity = "Common", Image = "rbxassetid://77981161617693", CanPurchase = true },
		Hair8 = { Name = "#08", Price = 2000, LevelRequired = 6, Rarity = "Rare", Image = "rbxassetid://107460104584128", CanPurchase = true },
		Hair9 = { Name = "#09", Price = 2500, LevelRequired = 7, Rarity = "Rare", Image = "rbxassetid://92825188822719", CanPurchase = true },
		Hair10 = { Name = "#10", Price = 5000, LevelRequired = 11, Rarity = "Rare", Image = "rbxassetid://118499969525309", CanPurchase = true },

		Pan      = { Name = "Pan",      Price = 1000,  LevelRequired = 4,  Rarity = "Common",  Image = "rbxassetid://98264698156738",  CanPurchase = true },
		Football = { Name = "Football", Price = 4000,  LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://98792972052226",  CanPurchase = true },
		Unicorn  = { Name = "Unicorn",  Price = 6500,  LevelRequired = 13, Rarity = "Rare",      Image = "rbxassetid://124436692128195", CanPurchase = true },
		Captain  = { Name = "Captain",  Price = 40000, LevelRequired = 36, Rarity = "Epic",      Image = "rbxassetid://130137968102712", CanPurchase = true },
		-- Techo del catálogo: precio y nivel fijados a mano (la serie del dashboard no llega).
		Racing   = { Name = "Racing",   Price = 400000, LevelRequired = 119, Rarity = "Legendary", Image = "rbxassetid://82112635387141",  CanPurchase = true },
		-- PROVISIONALES: entradas reales con nombre e Image de relleno; sustituir por el ítem
		-- definitivo (mismo precio, nivel y rareza). Sin Accessory en Shared/Locker/Hats el
		-- sombrero se equipa en datos pero no se dibuja.
		Hat_P01  = { Name = "Hat P01",   Price = 1250,   LevelRequired = 5,   Rarity = "Common",    Image = "rbxassetid://0", CanPurchase = true },
		Hat_P02  = { Name = "Hat P02",   Price = 2000,   LevelRequired = 6,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P03  = { Name = "Hat P03",   Price = 4000,   LevelRequired = 10,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P04  = { Name = "Hat P04",   Price = 6500,   LevelRequired = 13,  Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P05  = { Name = "Hat P05",   Price = 10000,  LevelRequired = 17,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P06  = { Name = "Hat P06",   Price = 12500,  LevelRequired = 19,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P07  = { Name = "Hat P07",   Price = 12500,  LevelRequired = 19,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P08  = { Name = "Hat P08",   Price = 20000,  LevelRequired = 25,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P09  = { Name = "Hat P09",   Price = 25000,  LevelRequired = 28,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P10  = { Name = "Hat P10",   Price = 25000,  LevelRequired = 28,  Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Hat_P11  = { Name = "Hat P11",   Price = 65000,  LevelRequired = 46,  Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
		Hat_P12  = { Name = "Hat P12",   Price = 100000, LevelRequired = 58, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
		Hat_P13  = { Name = "Hat P13",   Price = 125000, LevelRequired = 65, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },

		Cone      = { Name = "Cone",      Price = 0, LevelRequired = 0, Rarity = "Rare",  Image = "rbxassetid://87414125761780",  CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 10 },
		Squid     = { Name = "Squid",     Price = 0, LevelRequired = 0, Rarity = "Rare",      Image = "rbxassetid://134763444804317", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 15 },
		Raccoon   = { Name = "Raccoon",   Price = 0, LevelRequired = 0, Rarity = "Epic",      Image = "rbxassetid://97532336058006",  CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 24 },
		Shark     = { Name = "Shark",     Price = 0, LevelRequired = 0, Rarity = "Rare",  Image = "rbxassetid://134534862804519", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 29 },
		Adventure = { Name = "Adventure", Price = 0, LevelRequired = 0, Rarity = "Epic",      Image = "rbxassetid://128435788752887", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 30 },
		Bunny     = { Name = "Bunny",     Price = 0, LevelRequired = 0, Rarity = "Common",    Image = "rbxassetid://134209005674999", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 3 },
		Crown     = { Name = "Crown",     Price = 0, LevelRequired = 0, Rarity = "Legendary", Image = "rbxassetid://138029493389714", CanPurchase = false, isVIPExclusive = true },
	},

	Outfits = {
		Default = { Name = "Dusty", Price = 0,    LevelRequired = 1,  Rarity = "Common",   Image = "rbxassetid://113812840207293", CanPurchase = false },
		Ducky   = { Name = "Ducky",          Price = 0, LevelRequired = 0, Rarity = "Legendary",     Image = "rbxassetid://131931384520146", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 40 },
		Tourist = { Name = "Tourist",        Price = 100,  LevelRequired = 0,  Rarity = "Common", Image = "rbxassetid://120382636547205", CanPurchase = true, Currency = "Gems" },
		Casual  = { Name = "Casual Dad",         Price = 1000, LevelRequired = 0, Rarity = "Epic",     Image = "rbxassetid://138309329239258", CanPurchase = true, Currency = "Gems" },
		Jungle  = { Name = "Jorge",         Price = 2500, LevelRequired = 0, Rarity = "Legendary",     Image = "rbxassetid://137785541624765", CanPurchase = true, Currency = "Gems" },
		Agent  = { Name = "007",         Price = 2500, LevelRequired = 0, Rarity = "Legendary",     Image = "rbxassetid://81380638175638", CanPurchase = true, Currency = "Gems" },
		Armored  = { Name = "Fridge",         Price = 2500, LevelRequired = 0, Rarity = "Legendary",     Image = "rbxassetid://130012491007709", CanPurchase = true, Currency = "Gems" },
		-- PROVISIONAL: el Rare de Gems que faltaba entre Tourist (100) y Casual Dad (1.000): a él apuntan las 300 Gems
		-- del pase o el pack de 250 más el pase. Sin modelo de cuerpo en Shared se equipa en datos y viste el Default.
		Outfit_P01 = { Name = "Outfit P01", Price = 400, LevelRequired = 0, Rarity = "Rare", Image = "rbxassetid://0", CanPurchase = true, Currency = "Gems" },
	},

	Banners = {
		-- Fondo de DeathScreen.Card que ve quien muere a manos del portador (Loadout.Banner).
		-- Solo vía pase: reward `{ Kind = "Item", Category = "Banners", ItemId = ... }` desde
		-- el dashboard, con Season/SeasonTier aquí. La Image de Studio se pisa: todos llevan
		-- Image, y Default es el fallback de la tarjeta.
		Default = { Name = "Default", Price = 0, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://74350418219200", CanPurchase = false },
		-- De PRUEBA: sin reward en el pase aún (en Studio, comando /banners).
		Banner1 = { Name = "Banner 1", Price = 0, LevelRequired = 0, Rarity = "Rare", Image = "rbxassetid://71273279440699", CanPurchase = false, isBPExclusive = true, Season = "S1", SeasonTier = 18 },
		Banner2 = { Name = "Banner 2", Price = 0, LevelRequired = 0, Rarity = "Epic", Image = "rbxassetid://132619218310875", CanPurchase = false, isBPExclusive = true },
	},
}

return table.freeze(ItemsConfig)



