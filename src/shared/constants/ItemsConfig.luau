--!strict

export type ItemConfig = {
	Name: string,
	Price: number,          -- En la moneda de `Currency`, sin conversión
	Currency: string?,      -- "Cash" (por defecto) | "Gems": ShopService descuenta de esa
	                        -- moneda (Shared.constants.Currency)
	LevelRequired: number,  -- Nivel mínimo para comprar
	Rarity: string,         -- "Common" | "Rare" | "Epic" | "Legendary" | "Mythic"
	Image: string?,
	CanPurchase: boolean?,
	isVIPExclusive: boolean?, -- Lo concede el gamepass VIP (VIPItemsService); oculto en Locker hasta poseerse.
	TextureID: string?,       -- Wraps: fija va en MeshPart.TextureID; con isAnimated, por caras con scroll (WeaponWrapPainter).
	BaseColor: Color3?,
	Material: Enum.Material?,  -- De la parte principal del arma; nil conserva el original.
	isAnimated: boolean?,
	StudsPerTile: number?,    -- Sólo texturas por caras.
	ScrollSpeedU: number?,
	ScrollSpeedV: number?,
	-- Maestría de wraps (Shared.data.WrapMastery). En WeaponWraps: Challenge
	-- (Stat = "Kills" | "Precision" | "Streaks", Goal para la clase Auto), Requires (otro
	-- wrap que el arma debe tener además) o MasteryScope ("Weapon" | "Category" | "All").
	Challenge: { Stat: string, Goal: number }?,
	Requires: string?,
	MasteryScope: string?,
	MasteryClass: string?,  -- Main/Special: clave de WeaponMasteryClasses.Classes (nil = DEFAULT).
	AnimationId: string?,   -- Emotes: animación R15 que reproduce EmotePlayer.
	Looped: boolean?,       -- Emotes: fuerza el loop del track (nil = el que traiga la animación).
	CatalogEmoteId: number?, -- Emotes: id del catálogo; la animación la resuelve EmoteAssetService.
	PreviewYaw: number?,    -- Rotación en Y (grados) para alinear la preview en el locker (override por código).
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
-- desbloquea cuando ya se podía pagar). Algunos ítems de tienda son aún PROVISIONALES
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
    Large   = { Name = "Large",   Price = 20000, LevelRequired = 50,  Rarity = "Epic",      Image = asset(120566462075583),  CanPurchase = true, MasteryClass = "Shotgun" },
    Marksman = { Name = "Marksman", Price = 65000, LevelRequired = 93, Rarity = "Legendary",      Image = asset(104747113234324), CanPurchase = true, MasteryClass = "Sniper" },
    -- RESERVADO: la definición (Definitions/<Category>/<Id>.luau) ya existe; falta el Tool ServerStorage.WeaponTools.<Category>.<Id>.
    -- Descomentar con la Image real cuando esté el Tool (sin él se compraría y no haría nada); precio, nivel y rareza ya son los de la escalera.
    -- LMG = { Name = "LMG", Price = 50000, LevelRequired = 82, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
},

Special = {
    -- Default: misma convención que Main.Default.
    Default = { Name = "Default", Price = 0,   LevelRequired = 0,  Rarity = "Common",        CanPurchase = false, Image = "rbxassetid://129951224466693", MasteryClass = "Pistol" },
    Short   = { Name = "Short",   Price = 2500, LevelRequired = 15,  Rarity = "Rare",        Image = asset(126259419984088), CanPurchase = true, MasteryClass = "Shotgun" },
    UZI     = { Name = "UZI",     Price = 300, LevelRequired = 0,  Rarity = "Common",         Image = asset(73440329120716), CanPurchase = true },
    Laser   = { Name = "Laser",   Price = 40000, LevelRequired = 73,  Rarity = "Epic",      Image = asset(104390588207353),  CanPurchase = true },
    RPG     = { Name = "RPG",     Price = 100000, LevelRequired = 117,  Rarity = "Legendary",      Image = asset(135425656083964), CanPurchase = true, MasteryClass = "Explosive" },
    -- Arma de apoyo (zona de fuego): precio de escalera, no de TTK. TODO: Image real.
    Flare   = { Name = "Flare",   Price = 10000, LevelRequired = 34,  Rarity = "Epic",      Image = asset(92738287673873), CanPurchase = true, MasteryClass = "Explosive" },
    -- RESERVADO: la definición (Definitions/<Category>/<Id>.luau) ya existe; falta el Tool ServerStorage.WeaponTools.<Category>.<Id>.
    -- Descomentar con la Image real cuando esté el Tool (sin él se compraría y no haría nada); precio, nivel y rareza ya son los de la escalera.
    -- Revolver = { Name = "Revolver", Price = 6500, LevelRequired = 27, Rarity = "Rare", Image = "rbxassetid://0", CanPurchase = true, MasteryClass = "Pistol" },
    -- Burst = { Name = "Burst", Price = 12500, LevelRequired = 39, Rarity = "Epic", Image = "rbxassetid://0", CanPurchase = true, MasteryClass = "Pistol" },
},


	-- Un SurfaceAppearance en Shared.Locker.wraps con el id o el Name del wrap se le
	-- aplica encima sin declararlo aquí (ver el README de esa carpeta).
	WeaponWraps = {
		Default   = {
			Name = "Default",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Common",
			Image = asset(109044845487335),
			CanPurchase = false,
			BaseColor = Color3.fromRGB(255, 255, 255),
			isAnimated = false,
			StudsPerTile = 3,
		},
		-- Los wraps NO se venden: sólo se consiguen por maestría (Challenge, MasteryScope) o en bundles.
		-- TODO: Gold pide textura propia; de momento color y material.
		Mastery_Graphite = {
			Name = "Graphite",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Common",
			CanPurchase = false,
			TextureID = "rbxassetid://108982719125145",
			BaseColor = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			isAnimated = false,
			StudsPerTile = 3,
			Challenge = { Stat = "Kills", Goal = 100 },
		},
		Mastery_Copper = {
			Name = "Copper",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			TextureID = "rbxassetid://96296109109897",
			BaseColor = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			isAnimated = false,
			StudsPerTile = 3,
			Challenge = { Stat = "Kills", Goal = 300 },
		},
		Mastery_Jade = {
			Name = "Jade",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Rare",
			CanPurchase = false,
			TextureID = "rbxassetid://132271406255238",
			BaseColor = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			isAnimated = false,
			StudsPerTile = 3,
			Challenge = { Stat = "Kills", Goal = 750 },
		},
		Mastery_Cobalt = {
			Name = "Cobalt",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Epic",
			CanPurchase = false,
			TextureID = "rbxassetid://130253063639044",
			BaseColor = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			isAnimated = false,
			StudsPerTile = 3,
			Challenge = { Stat = "Kills", Goal = 1500 },
		},
		Mastery_Amethyst = {
			Name = "Amethyst",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Epic",
			CanPurchase = false,
			TextureID = "rbxassetid://84844353204611",
			BaseColor = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			isAnimated = false,
			StudsPerTile = 3,
			Challenge = { Stat = "Kills", Goal = 3000 },
		},
		Mastery_Garnet = {
			Name = "Garnet",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Epic",
			CanPurchase = false,
			TextureID = "rbxassetid://73191117977581",
			BaseColor = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			isAnimated = false,
			StudsPerTile = 3,
			Challenge = { Stat = "Precision", Goal = 500 },
		},
		Mastery_Gold = {
			Name = "Gold",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Legendary",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(255, 196, 45),
			Material = Enum.Material.Foil,
			isAnimated = false,
			StudsPerTile = 3,
			MasteryScope = "Weapon",
		},
		Mastery_Damascus = {
			Name = "Damascus",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Legendary",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			isAnimated = false,
			StudsPerTile = 3,
			MasteryScope = "Category",
		},
		Mastery_Galaxy = {
			Name = "Galaxy",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Mythic",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			MasteryScope = "All",
		},
		-- Del bundle limitado Founders (StoreProducts.Bundles): solo se consiguen con él y
		-- llevan número de serie. Nombre y color PROVISIONALES.
		Wrap_Founders_Groza = {
			Name = "Founders",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Mythic",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(212, 175, 55),
			Material = Enum.Material.Foil,
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Founders_UZI = {
			Name = "Founders",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Mythic",
			CanPurchase = false,
			BaseColor = Color3.fromRGB(212, 175, 55),
			Material = Enum.Material.Foil,
			isAnimated = false,
			StudsPerTile = 3,
		},
	},

	KillEffects = {
		-- TODO: todos comparten el icono genérico; subir iconos propios cuando haya arte.
		----------- Common -----------
		Default = { Name = "Default Kill", Price = 0, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://124668403297940", CanPurchase = false },
		----------- Rare -----------
		Oof = { Name = "Oof", Price = 2500, LevelRequired = 0, Rarity = "Rare", Image = "rbxassetid://81116230548876", CanPurchase = true },
		Tombstone = { Name = "Tombstone Kill", Price = 5000, LevelRequired = 11, Rarity = "Rare", Image = "rbxassetid://101870461174402", CanPurchase = true },
		Confetti = { Name = "Party Popper", Price = 6500, LevelRequired = 13, Rarity = "Rare", Image = "rbxassetid://82697661626956", CanPurchase = true },
		Gravity = { Name = "Gravity Kill", Price = 4000, LevelRequired = 10, Rarity = "Rare", Image = "rbxassetid://", CanPurchase = true },
		----------- Epic -----------
		-- Arte OPCIONAL en ReplicatedStorage.Templates.UFO (sin él, OVNI procedural).
		Abduction = { Name = "UFO Abduction", Price = 10000, LevelRequired = 17, Rarity = "Epic", Image = "rbxassetid://", CanPurchase = true },
		--Burning = { Name = "Burning Kill", Price = 10000, LevelRequired = 17, Rarity = "Epic", Image = "rbxassetid://", CanPurchase = true },
		Flattened = { Name = "Pancake", Price = 12500, LevelRequired = 19, Rarity = "Epic", Image = "rbxassetid://122316524845161", CanPurchase = true },
		Noobify = { Name = "Noobified", Price = 20000, LevelRequired = 25, Rarity = "Epic", Image = "rbxassetid://114920534302676", CanPurchase = true },
		XpOrbs = { Name = "XP Drop", Price = 25000, LevelRequired = 28, Rarity = "Epic", Image = "rbxassetid://90538303726391", CanPurchase = true },
		BlockBlast = { Name = "Blocked Out", Price = 40000, LevelRequired = 36, Rarity = "Epic", Image = "rbxassetid://86568984907825", CanPurchase = true },
		----------- Legendary -----------
		Balloons = { Name = "Up, Up & Away", Price = 50000, LevelRequired = 41, Rarity = "Legendary", Image = "rbxassetid://73830780173999", CanPurchase = true },
		-- Sonido OPCIONAL en ReplicatedStorage.Templates.Bobblehead.
		Bobblehead = { Name = "Bobblehead", Price = 65000, LevelRequired = 46, Rarity = "Legendary", Image = "rbxassetid://123175203510752", CanPurchase = true },
		-- Arte OPCIONAL en ReplicatedStorage.Templates.Electrocution (emitters que se ponen en el torso).
		Electrocution = { Name = "Electrocution", Price = 100000, LevelRequired = 58, Rarity = "Legendary", Image = "rbxassetid://78621057917847", CanPurchase = true },
		-- Sonido OPCIONAL en ReplicatedStorage.Templates.Disassemble. Precio y nivel PROVISIONALES.
		Disassemble = { Name = "Piece by Piece", Price = 125000, LevelRequired = 65, Rarity = "Legendary", Image = "rbxassetid://82921253343301", CanPurchase = true },
		-- PROVISIONAL: entrada real con nombre e Image de relleno; sustituir por el efecto
		-- definitivo (mismo precio, nivel y rareza). Sin módulo en KillEffectsRegistry cae al
		-- Default. Es el trofeo de la categoría.
		KE_P12 = { Name = "Kill P12", Price = 300000, LevelRequired = 102, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
	},

	Emotes = {
		-- Emotes (Tecla E / Resultados): Carga en servidor (ReplicatedStorage) animaciones genéricas de Roblox usando su CatalogEmoteId (excluye colaboraciones). "Salute" viene por defecto.
		----------- Common -----------
		Default       = { Name = "Salute", Price = 0, LevelRequired = 0, Rarity = "Common", CanPurchase = false, CatalogEmoteId = 3360689775 },
		Agree         = { Name = "Agree", Price = 400, LevelRequired = 2, Rarity = "Common", CanPurchase = true, CatalogEmoteId = 4849487550 },
		Celebrate     = { Name = "Celebrate", Price = 500, LevelRequired = 2, Rarity = "Common", CanPurchase = true, CatalogEmoteId = 3994127840 },
		Bored         = { Name = "Bored", Price = 650, LevelRequired = 3, Rarity = "Common", CanPurchase = true, CatalogEmoteId = 5230661597 },
		Beckon        = { Name = "Beckon", Price = 1000, LevelRequired = 4, Rarity = "Common", CanPurchase = true, CatalogEmoteId = 5230615437 },
		Haha          = { Name = "Haha", Price = 1250, LevelRequired = 5, Rarity = "Common", CanPurchase = true, CatalogEmoteId = 4102315500 },
		----------- Rare -----------
		KeepingTime   = { Name = "Keeping Time", Price = 2000, LevelRequired = 6, Rarity = "Rare", CanPurchase = true, CatalogEmoteId = 4646306072 },
		Greatest      = { Name = "Greatest", Price = 2500, LevelRequired = 7, Rarity = "Rare", CanPurchase = true, CatalogEmoteId = 3762654854 },
		Monkey        = { Name = "Monkey", Price = 4000, LevelRequired = 10, Rarity = "Rare", CanPurchase = true, CatalogEmoteId = 3716636630 },
		HeroLanding   = { Name = "Hero Landing", Price = 5000, LevelRequired = 11, Rarity = "Rare", CanPurchase = true, CatalogEmoteId = 5104377791 },
		FlossDance    = { Name = "Floss Dance", Price = 6500, LevelRequired = 13, Rarity = "Rare", CanPurchase = true, CatalogEmoteId = 5917570207 },
		----------- Epic -----------
		LineDance     = { Name = "Line Dance", Price = 10000, LevelRequired = 17, Rarity = "Epic", CanPurchase = true, CatalogEmoteId = 4049646104 },
		Godlike       = { Name = "Godlike", Price = 12500, LevelRequired = 19, Rarity = "Epic", CanPurchase = true, CatalogEmoteId = 3823158750 },
		QuietWaves    = { Name = "Quiet Waves", Price = 20000, LevelRequired = 25, Rarity = "Epic", CanPurchase = true, CatalogEmoteId = 7466046574 },
		DorkyDance    = { Name = "Dorky Dance", Price = 25000, LevelRequired = 28, Rarity = "Epic", CanPurchase = true, CatalogEmoteId = 4212499637 },
		Bodybuilder   = { Name = "Bodybuilder", Price = 40000, LevelRequired = 36, Rarity = "Epic", CanPurchase = true, CatalogEmoteId = 3994130516 },
		----------- Legendary -----------
		Idol          = { Name = "Idol", Price = 50000, LevelRequired = 41, Rarity = "Legendary", CanPurchase = true, CatalogEmoteId = 4102317848 },
		FancyFeet     = { Name = "Fancy Feet", Price = 65000, LevelRequired = 46, Rarity = "Legendary", CanPurchase = true, CatalogEmoteId = 3934988903 },
		TopRock       = { Name = "Top Rock", Price = 100000, LevelRequired = 58, Rarity = "Legendary", CanPurchase = true, CatalogEmoteId = 3570535774 },
		AroundTown    = { Name = "Around Town", Price = 125000, LevelRequired = 65, Rarity = "Legendary", CanPurchase = true, CatalogEmoteId = 3576747102 },
	},

	Faces = {
		-- "Default" DEBE existir con esta clave: DataTemplate la da poseída y equipada (Faces.Default, Loadout.Face).
		----------- Common (7)-----------
		Default = { Name = "Smile",          Price = 0,  LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://79175047578893", CanPurchase = false },
		Sigh       = { Name = "Sigh",       Price = 300,  LevelRequired = 0,  Rarity = "Common",    Image = "rbxassetid://77502892766951", CanPurchase = true },
		Meh        = { Name = "Meh",        Price = 400,   LevelRequired = 2,  Rarity = "Common",    Image = "rbxassetid://17848141083", CanPurchase = true },
		Pout       = { Name = "Pout",       Price = 500,   LevelRequired = 2,  Rarity = "Common",    Image = "rbxassetid://97580829209799", CanPurchase = true },
		Purr       = { Name = "Purr",       Price = 650,   LevelRequired = 3,  Rarity = "Common",    Image = "rbxassetid://73793991067813", CanPurchase = true },
		Unbothered = { Name = "Unbothered", Price = 1000,  LevelRequired = 4,  Rarity = "Common",    Image = "rbxassetid://112917697570516", CanPurchase = true },
		Smirk      = { Name = "Smirk",      Price = 1250,  LevelRequired = 5,  Rarity = "Common",    Image = "rbxassetid://113957522330582", CanPurchase = true },
		----------- Rare (5) -----------
		Cutie      = { Name = "Cutie",      Price = 2000,  LevelRequired = 6,  Rarity = "Rare",      Image = "rbxassetid://113135767356440", CanPurchase = true },
		Worried    = { Name = "Worried",    Price = 2500,  LevelRequired = 7,  Rarity = "Rare",      Image = "rbxassetid://89277236777187", CanPurchase = true },
		KO         = { Name = "K.O.",       Price = 4000,  LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://94201211759991", CanPurchase = true },
		Exhausted  = { Name = "Exhausted",  Price = 5000,  LevelRequired = 11, Rarity = "Rare",      Image = "rbxassetid://118367363713874", CanPurchase = true },
		Angry      = { Name = "Angry",      Price = 6500,  LevelRequired = 13, Rarity = "Rare",      Image = "rbxassetid://101878427779141", CanPurchase = true },
		----------- Epic (5)-----------
		Goofy      = { Name = "Goofy",      Price = 10000, LevelRequired = 17, Rarity = "Epic",      Image = "rbxassetid://17373537487", CanPurchase = true },
		Joy        = { Name = "Joy",        Price = 12500, LevelRequired = 19, Rarity = "Epic",      Image = "rbxassetid://18571318923", CanPurchase = true },
		Sly        = { Name = "Sly",        Price = 25000, LevelRequired = 28, Rarity = "Epic",      Image = "rbxassetid://138957466964629", CanPurchase = true },
		Face_P09 = { Name = "Face P09",  Price = 20000,  LevelRequired = 25,  Rarity = "Epic",      Image = "rbxassetid://117660665380644", CanPurchase = true },
		Face_P10 = { Name = "Face P10",  Price = 40000,  LevelRequired = 36,  Rarity = "Epic",      Image = "rbxassetid://17285554126", CanPurchase = true },
		Blep       = { Name = "Blep",       Price = 20000, LevelRequired = 25, Rarity = "Epic",      Image = "rbxassetid://122618931216206", CanPurchase = true },
		----------- Legendary (4) -----------
		Chomper    = { Name = "Chomper",    Price = 200000, LevelRequired = 83, Rarity = "Legendary", Image = "rbxassetid://139252772271446", CanPurchase = true },
		Face_P11 = { Name = "Face P11",  Price = 65000,  LevelRequired = 46,  Rarity = "Legendary", Image = "rbxassetid://18211093623", CanPurchase = true },
		Face_P12 = { Name = "Face P12",  Price = 100000, LevelRequired = 58, Rarity = "Legendary", Image = "rbxassetid://83359251486534", CanPurchase = true },
		Face_P13 = { Name = "Face P13",  Price = 125000, LevelRequired = 65, Rarity = "Legendary", Image = "rbxassetid://17225148343", CanPurchase = true },
		Derp       = { Name = "Derp",       Price = 50000, LevelRequired = 41, Rarity = "Legendary", Image = "rbxassetid://134592485348307", CanPurchase = true },
		Scream     = { Name = "Scream",     Price = 100000, LevelRequired = 58, Rarity = "Legendary", Image = "rbxassetid://17278359754", CanPurchase = true },
	},

	Hats = {
		-- CosmeticsTemplates.findHatTemplate busca el Accessory en Shared/Locker/Hats por Name y luego por clave. Los Hair* el Locker los pinta con ItemHair.
		-- Techo del catálogo: precio y nivel fijados a mano (la serie del dashboard no llega).
		----------- Common -----------
		Hair31 = { Name = "#01", Price = 300, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://76630236645248", CanPurchase = true },
		Hair29 = { Name = "#02", Price = 300, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://98908242920918", CanPurchase = true },
		Hair17 = { Name = "#03", Price = 300, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://70544022356431", CanPurchase = true },
		Hair27 = { Name = "#04", Price = 400, LevelRequired = 2, Rarity = "Common", Image = "rbxassetid://83056500862714", CanPurchase = true },
		Hair28 = { Name = "#05", Price = 400, LevelRequired = 2, Rarity = "Common", Image = "rbxassetid://96331702301128", CanPurchase = true },
		Hair19 = { Name = "#06", Price = 650, LevelRequired = 3, Rarity = "Common", Image = "rbxassetid://94255427959401", CanPurchase = true },
		Hair23 = { Name = "#07", Price = 650, LevelRequired = 3, Rarity = "Common", Image = "rbxassetid://115677006532654", CanPurchase = true },
		Hair16 = { Name = "#09", Price = 1000,  LevelRequired = 4,  Rarity = "Common",  Image = "rbxassetid://126531816780878",  CanPurchase = true },
		Hair30 = { Name = "#08", Price = 1250,  LevelRequired = 5,   Rarity = "Common",    Image = "rbxassetid://119189288324456", CanPurchase = true },
		----------- Rare -----------
		Hair24 = { Name = "#10", Price = 2000, LevelRequired = 6, Rarity = "Rare", Image = "rbxassetid://106909347694629", CanPurchase = true },
		Hair32 = { Name = "#11", Price = 2500, LevelRequired = 7, Rarity = "Rare", Image = "rbxassetid://82580377682955", CanPurchase = true },
		Hair18 = { Name = "#13", Price = 4000,  LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://117534358458320",  CanPurchase = true },
		Hair20 = { Name = "#12", Price = 5000, LevelRequired = 11, Rarity = "Rare", Image = "rbxassetid://74458594911799", CanPurchase = true },
		Hair33  = { Name = "#14",  Price = 6500,  LevelRequired = 13, Rarity = "Rare",      Image = "rbxassetid://77994600321504", CanPurchase = true },
		Snorkel = { Name = "Snorkel", Price = 4000, LevelRequired = 10, Rarity = "Rare",  Image = "rbxassetid://115843839111702",  CanPurchase = true },
		----------- Epic -----------
		Raccoon  = { Name = "Raccoon",   Price = 10000,  LevelRequired = 17,  Rarity = "Epic",      Image = "rbxassetid://97532336058006", CanPurchase = true },
		Ushanka  = { Name = "Ushanka",   Price = 12500,  LevelRequired = 19,  Rarity = "Epic",      Image = "rbxassetid://89553126297974", CanPurchase = true },
		Indiana  = { Name = "Indiana",   Price = 20000,  LevelRequired = 25,  Rarity = "Epic",      Image = "rbxassetid://128435788752887", CanPurchase = true },
		Beret  = { Name = "Beret",   Price = 25000,  LevelRequired = 28,  Rarity = "Epic",      Image = "rbxassetid://117481727483221", CanPurchase = true },
		Captain  = { Name = "Captain",  Price = 40000, LevelRequired = 36, Rarity = "Epic",      Image = "rbxassetid://130137968102712", CanPurchase = true },
		----------- Legendary -----------
		Bunny  = { Name = "Bunny",   Price = 65000,  LevelRequired = 46,  Rarity = "Legendary", Image = "rbxassetid://134209005674999", CanPurchase = true },
		Shark  = { Name = "Shark",   Price = 100000, LevelRequired = 58, Rarity = "Legendary", Image = "rbxassetid://134534862804519", CanPurchase = true },
		Cone  = { Name = "Cone",   Price = 125000, LevelRequired = 65, Rarity = "Legendary", Image = "rbxassetid://87414125761780", CanPurchase = true },
		KidCap   = { Name = "KidCap",   Price = 400000, LevelRequired = 119, Rarity = "Legendary", Image = "rbxassetid://114693348813351",  CanPurchase = true },
	},

	Outfits = {
		----------- Common -----------
		Default = { Name = "Dusty", Price = 0,    LevelRequired = 0,  Rarity = "Common",   Image = "rbxassetid://113812840207293", CanPurchase = false },
		Tourist = { Name = "Tourist",        Price = 400,  LevelRequired = 0,  Rarity = "Rare", Image = "rbxassetid://120382636547205", CanPurchase = true, Currency = "Gems" },
		----------- Rare -----------
		Casual  = { Name = "Casual Dad",         Price = 1000, LevelRequired = 0, Rarity = "Epic",     Image = "rbxassetid://138309329239258", CanPurchase = true, Currency = "Gems" },
		-- Gancho de primera compra: precio pensado para cerrarlo con el pack de Gems de 99 R$
		-- (temporadas-y-assets.md, en Telemetry). Revisarlo si cambian los packs.
		Jungle  = { Name = "Jorge",         Price = 400, LevelRequired = 0, Rarity = "Rare",     Image = "rbxassetid://137785541624765", CanPurchase = true, Currency = "Gems" },
		----------- Legendary -----------
		Ducky   = { Name = "Ducky",          Price = 2500, LevelRequired = 0, Rarity = "Legendary",     Image = "rbxassetid://131931384520146", CanPurchase = true, Currency = "Gems" },
		Agent  = { Name = "007",         Price = 2500, LevelRequired = 0, Rarity = "Legendary",     Image = "rbxassetid://81380638175638", CanPurchase = true, Currency = "Gems" },
		Armored  = { Name = "Fridge",         Price = 2500, LevelRequired = 0, Rarity = "Legendary",     Image = "rbxassetid://130012491007709", CanPurchase = true, Currency = "Gems" },
	},

	Banners = {
		-- Fondo de DeathScreen.Card que ve quien muere a manos del portador (Loadout.Banner).
		-- La Image de Studio se pisa: todos llevan Image, y Default es el fallback de la tarjeta.
		Default = { Name = "Default", Price = 0, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://74350418219200", CanPurchase = false },
		Banner1 = { Name = "Banner 1", Price = 5000, LevelRequired = 11, Rarity = "Rare", Image = "rbxassetid://71273279440699", CanPurchase = true },
		Banner2 = { Name = "Banner 2", Price = 12500, LevelRequired = 19, Rarity = "Epic", Image = "rbxassetid://132619218310875", CanPurchase = true },
	},
}

-- Miniaturas automáticas para emotes del catálogo de Roblox (rbxthumb).
for _, emote in ItemsConfig.Emotes do
	if emote.CatalogEmoteId and (emote.Image == nil or emote.Image == "") then
		emote.Image = "rbxthumb://type=Asset&id=" .. tostring(emote.CatalogEmoteId) .. "&w=150&h=150"
	end
end

return table.freeze(ItemsConfig)



