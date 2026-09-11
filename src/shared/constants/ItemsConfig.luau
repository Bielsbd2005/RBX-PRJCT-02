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
	Price: number,          -- Precio (en la moneda de `Currency`)
	Currency: string?,      -- "Cash" (por defecto) | "Gems". Es la moneda REAL:
	                        -- ShopService descuenta de Stats.Cash o Stats.Gems
	                        -- según este campo (ver Shared.constants.Currency) y
	                        -- el Locker pinta el icono y ofrece el pack de esa
	                        -- moneda. No hay conversión: Price está expresado en
	                        -- `Currency`, así que cambiar el campo SIN cambiar el
	                        -- precio deja el ítem malbaratado (1250 Cash ≠ 1250 Gems).
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
-- Precios y LevelRequired recalibrados el 2026-09-12 (economía 2.0: ver
-- docs/la-economia-de-las-40-horas.md y data/change-log.json del dashboard).
-- Tasa de diseño: ~2.000 Cash/h y ~3.100 XP/h con el jugador de GameConfig
-- (~90 kills/h, 36 HS/h, 28 asistencias/h a 10 Cash; fin de partida ~150/h;
-- diarias ~280/h a 1,3 h/día). Bandas, en horas de ingreso puro:
--   Common 300-650 (0,15-0,33 h) · Uncommon 1.000-2.500 (0,5-1,25 h) · Rare
--   4.000-6.500 (2-3,25 h) · Epic 10.000-25.000 (5-12,5 h) · Legendary
--   40.000-65.000 (20-32,5 h) · techo 80.000 (Hat9, 40 h; fijado a mano
--   porque la serie de peldaños del dashboard no lo produce). El nivel se
--   deriva del precio: se desbloquea cuando ya se podía pagar. El peldaño más
--   barato de cada categoría no pide nivel. NADA de lo que regala el pase se
--   vende aquí (isBPExclusive = true, precio 0): los 14 ítems que estaban en
--   los dos sitios se quedan en el pase y sus peldaños los ocupan ítems nuevos
--   PROVISIONALES (nombre e Image de relleno) que Biel sustituirá por los reales. Los
--   WeaponWraps tienen banda propia porque se compran por arma: ver la sección.
-- Anterior (2026-09-04): 1.200 Cash/h con 63 kills/h, bandas 150-20.000.

local function asset(assetId: number): string
	return "rbxassetid://" .. tostring(assetId)
end

local ItemsConfig: ItemsConfigType = {

Main = {
    -- Primary (rango medio, daño sostenido)
    -- "Default" es el arma de inicio: viene poseída y equipada en DataTemplate,
    -- InventoryRepository.ownsWeapon la da siempre por poseída y es el fallback
    -- de LoadoutService/ShopService (ItemDefaults.ITEM_ID). Precio 0 y sin
    -- compra, como el Default del resto de categorías.
    Default = { Name = "Default", Price = 0,    LevelRequired = 0,  Rarity = "Common",    Image = asset(115787466520426), CanPurchase = false },
    AK      = { Name = "AK",      Price = 500,  LevelRequired = 5,  Rarity = "Common",    Image = asset(100246140710694), CanPurchase = true },
    Groza   = { Name = "Groza",   Price = 150,   LevelRequired = 0,  Rarity = "Common",  Image = asset(133051760713810), CanPurchase = true },
    Tommy   = { Name = "Tommy",   Price = 5000,  LevelRequired = 21,  Rarity = "Rare",      Image = asset(111814750317784), CanPurchase = true },
    Sniper  = { Name = "Sniper",  Price = 12500, LevelRequired = 36,  Rarity = "Epic",      Image = asset(86261275288637),  CanPurchase = true },
    Large   = { Name = "Large",   Price = 50000, LevelRequired = 75,  Rarity = "Legendary",      Image = asset(90736156284730),  CanPurchase = true },
},

Special = {
    -- Secondary/Special (corto rango o alto impacto)
    -- Arma de inicio (misma convención que Main.Default). Sin Image: el Locker
    -- cae en su thumbnail por defecto hasta que haya uno en el panel de Roblox.
    Default = { Name = "Default", Price = 0,   LevelRequired = 0,  Rarity = "Common",        CanPurchase = false },
    Short   = { Name = "Short",   Price = 1000, LevelRequired = 8,  Rarity = "Uncommon",      Image = asset(118462878872416), CanPurchase = true },
    UZI     = { Name = "UZI",     Price = 300, LevelRequired = 0,  Rarity = "Common",         Image = asset(109948875778066), CanPurchase = true },
    Laser   = { Name = "Laser",   Price = 12500, LevelRequired = 36,  Rarity = "Epic",      Image = asset(80482264427643),  CanPurchase = true },
    RPG     = { Name = "RPG",     Price = 50000, LevelRequired = 75,  Rarity = "Legendary",      Image = asset(139650368086109), CanPurchase = true },
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
		-- ── Exclusivas del Battle Pass (S1) ──
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
		},
		-- ── Wraps del pase S1 (2026-09-12) ──
		-- Regla: nada que regale el pase se vende en la tienda. Antes el pase
		-- daba Gold, Coral, Red y Neon en armas concretas (y Gold global en el
		-- 54); ahora da estos siete, que sólo existen aquí. Nombre y color son
		-- PROVISIONALES (los elige Biel); la definición es sólo datos. La rareza
		-- sigue al tier en el que caen. El Prism del 54 es la pieza estrella:
		-- cuando haya arte, darle TextureID animada como Wrap_Red.
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
		},
		Wrap_S1_Tide = {
			Name = "Tide",
			Price = 0,
			LevelRequired = 0,
			Rarity = "Uncommon",
			CanPurchase = false,
			isBPExclusive = true,
			BaseColor = Color3.fromRGB(40, 160, 200),
			isAnimated = false,
			StudsPerTile = 3,
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
		},
		-- ── Escalera Cash: colores planos → animada → material especial ──
		-- Banda PROPIA, ≈⅓ de la del ítem de su rareza (desde el 2026-09-04). Un
		-- wrap se compra POR ARMA (ShopService lo guarda en WeaponWrapsByWeapon):
		-- vestir de oro el arsenal principal son seis compras, y a 12.500 cada una
		-- (2026-09-12) suman ≈ un Legendary y medio, que es lo que se lee. La
		-- rareza marca el tier de la skin, no el precio: Gold "Legendary" cuesta
		-- lo que un Epic de la tienda. Niveles derivados del precio a 2.000
		-- Cash/h · 3.100 XP/h, como el resto del catálogo. El pase ya no regala
		-- ninguno de estos: sus wraps son los Wrap_S1_* de arriba.
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
			Rarity = "Uncommon",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(70, 150, 80),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Coral = {
			Name = "Coral",
			Price = 650,
			LevelRequired = 6,
			Rarity = "Uncommon",
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
		-- Los wraps son SIEMPRE de Cash: las Gems compran el pase, los skips y
		-- los outfits, y nada más. Que la moneda premium signifique exactamente
		-- una categoría es lo que la hace legible de un vistazo.
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
		-- Los cuatro comparten Image de momento (icono genérico de la categoría):
		-- subir iconos propios por efecto cuando haya arte.
		Default   = { Name = "Default Kill",   Price = 0,   LevelRequired = 1, Rarity = "Common", Image = "rbxassetid://130437553674754", CanPurchase = false },
		Gravity   = { Name = "Gravity Kill",   Price = 0, LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://130437553674754", CanPurchase = false, isBPExclusive = true },
		Explosion = { Name = "Explosion Kill", Price = 0, LevelRequired = 0, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = false, isBPExclusive = true },
		Tornado   = { Name = "Tornado Kill",   Price = 20000, LevelRequired = 46, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		-- PROVISIONAL (2026-09-12): entrada real con nombre e Image de relleno; sustituir por el
		-- ítem definitivo (mismo precio y nivel). Sin módulo en KillEffectsRegistry cae al Default.
		-- PRIORIDAD sobre caras y sombreros: sin él la categoría queda vacía por debajo de las 10 h.
		KE_A = { Name = "New Kill", Price = 5000, LevelRequired = 0, Rarity = "Rare", Image = "rbxassetid://0", CanPurchase = true },
	},

	Faces = {
		-- "Default" = la cara base del rig (no es un decal de catálogo). Todo jugador
		-- la posee y equipa por DataTemplate, así que DEBE existir en el catálogo o
		-- el Locker no puede mostrar la cara equipada y applyFaceToHead no-opea.
		-- Usamos la textura built-in del engine (rbxasset://, no un assetId de catálogo
		-- desconocido) para que el catálogo renderice algo seguro y aplicarla restaure
		-- la cara base del head. No comprable, precio 0.
		Default = { Name = "Default",        Price = 0,  LevelRequired = 0, Rarity = "Common", Image = "rbxasset://textures/face.png", CanPurchase = false },
		Face1   = { Name = "Classic Smile",  Price = 400,  LevelRequired = 4, Rarity = "Common",   Image = "rbxassetid://79175047578893",  CanPurchase = true },
		Face2   = { Name = "Nervous",        Price = 0,  LevelRequired = 0, Rarity = "Uncommon",   Image = "rbxassetid://18571318923",    CanPurchase = false, isBPExclusive = true },
		Face3   = { Name = "Pout",           Price = 1250,  LevelRequired = 9, Rarity = "Uncommon",   Image = "rbxassetid://97580829209799", CanPurchase = true },
		Face4   = { Name = "Kawaii",         Price = 0,  LevelRequired = 0, Rarity = "Epic",   Image = "rbxassetid://94789972115859", CanPurchase = false, isBPExclusive = true },
		-- Exclusiva del Battle Pass (tier 1 FREE de S1).
		Face5   = { Name = "Nerd",           Price = 0,  LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://17285554126",    CanPurchase = false, isBPExclusive = true },
		Face6   = { Name = "Deadpan",        Price = 0,  LevelRequired = 0, Rarity = "Legendary",   Image = "rbxassetid://70391209868621", CanPurchase = false, isBPExclusive = true },
		Face7   = { Name = "Kitty",          Price = 0,  LevelRequired = 0, Rarity = "Legendary",   Image = "rbxassetid://18626918162",    CanPurchase = false, isBPExclusive = true },
		Face8   = { Name = "Goofy",          Price = 300,  LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://17373537487",    CanPurchase = true },
		Face9   = { Name = "Chill",          Price = 4000,  LevelRequired = 19, Rarity = "Rare",   Image = "rbxassetid://118980363558612", CanPurchase = true },
		Face10  = { Name = "Side Eye",       Price = 0, LevelRequired = 0, Rarity = "Uncommon",   Image = "rbxassetid://18870092964",    CanPurchase = false, isBPExclusive = true },
		Face11  = { Name = "Angry",          Price = 0, LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://101878427779141", CanPurchase = false, isBPExclusive = true },
		Face12  = { Name = "Menace",         Price = 12500, LevelRequired = 36, Rarity = "Epic",   Image = "rbxassetid://112166980943980", CanPurchase = true },
		-- PROVISIONALES (2026-09-12): entradas reales con nombre e Image de relleno; sustituir por
		-- el ítem definitivo (mismo precio y nivel). Con Image 0 la cara se aplica en blanco.
		Face13 = { Name = "Face13", Price = 2000,  LevelRequired = 12, Rarity = "Uncommon",  Image = "rbxassetid://0", CanPurchase = true },
		Face14 = { Name = "Face14", Price = 2500,  LevelRequired = 14, Rarity = "Uncommon",  Image = "rbxassetid://0", CanPurchase = true },
		Face15 = { Name = "Face15", Price = 6500,  LevelRequired = 25, Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Face16 = { Name = "Face16", Price = 20000, LevelRequired = 46, Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Face17 = { Name = "Face17", Price = 40000, LevelRequired = 67, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },
		Face18 = { Name = "Face18", Price = 65000, LevelRequired = 86, Rarity = "Legendary", Image = "rbxassetid://0", CanPurchase = true },

	},

	Hats = {
		Hat1 = { Name = "Bunny",          Price = 0,  LevelRequired = 0,  Rarity = "Common",    Image = "rbxassetid://117004939623250", CanPurchase = false, isBPExclusive = true },
		Hat2 = { Name = "Cone",      Price = 0, LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://138341632720877", CanPurchase = false, isBPExclusive = true },
		Hat3 = { Name = "Crown",        Price = 0, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://119183410438332", CanPurchase = false, isBPExclusive = true },
		Hat4 = { Name = "Squid",        Price = 0, LevelRequired = 0, Rarity = "Rare", Image = "rbxassetid://74317816532636", CanPurchase = false, isBPExclusive = true },
		Hat5 = { Name = "Alaska",        Price = 0, LevelRequired = 0, Rarity = "Epic", Image = "rbxassetid://83643028468192", CanPurchase = false, isBPExclusive = true },
		Hat6 = { Name = "Drink",        Price = 20000, LevelRequired = 46, Rarity = "Epic", Image = "rbxassetid://130927276777389", CanPurchase = true },
		Hat7 = { Name = "IceCream",        Price = 0, LevelRequired = 0, Rarity = "Epic", Image = "rbxassetid://89103967355981", CanPurchase = false, isBPExclusive = true },
		-- OJO: Image comparte assetId con Hat7 (IceCream) — subir el thumbnail
		-- real del Spartan antes del launch o sale con imagen de helado.
		Hat8 = { Name = "Spartan",        Price = 40000, LevelRequired = 67, Rarity = "Legendary", Image = "rbxassetid://89103967355981", CanPurchase = true },
		Hat9 = { Name = "RaceHelmet",        Price = 80000, LevelRequired = 96, Rarity = "Legendary", Image = "rbxassetid://84090421736652", CanPurchase = true },
		Hat10 = { Name = "Pan",        Price = 300, LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://97418970357486", CanPurchase = true },
		Hat11 = { Name = "Football",        Price = 500, LevelRequired = 5, Rarity = "Common", Image = "rbxassetid://86457108228550", CanPurchase = true },
		Hat12 = { Name = "Sombrero",        Price = 0, LevelRequired = 0, Rarity = "Uncommon", Image = "rbxassetid://79179819137524", CanPurchase = false, isBPExclusive = true },
		Hat13 = { Name = "Shark",        Price = 0, LevelRequired = 0, Rarity = "Uncommon", Image = "rbxassetid://72319063957484", CanPurchase = false, isBPExclusive = true },
		Hat14 = { Name = "Unicorn",        Price = 0, LevelRequired = 0, Rarity = "Rare", Image = "rbxassetid://112312308063894", CanPurchase = false, isBPExclusive = true },
		-- PROVISIONALES (2026-09-12): entradas reales con nombre e Image de relleno; sustituir por
		-- el ítem definitivo (mismo precio y nivel). Sin Accessory en Shared (findHatTemplate) el
		-- sombrero se equipa en datos pero no se dibuja.
		Hat15 = { Name = "Hat15", Price = 400,   LevelRequired = 4,  Rarity = "Common",    Image = "rbxassetid://0", CanPurchase = true },
		Hat16 = { Name = "Hat16", Price = 1000,  LevelRequired = 8,  Rarity = "Uncommon",  Image = "rbxassetid://0", CanPurchase = true },
		Hat17 = { Name = "Hat17", Price = 2500,  LevelRequired = 14, Rarity = "Uncommon",  Image = "rbxassetid://0", CanPurchase = true },
		Hat18 = { Name = "Hat18", Price = 4000,  LevelRequired = 19, Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Hat19 = { Name = "Hat19", Price = 6500,  LevelRequired = 25, Rarity = "Rare",      Image = "rbxassetid://0", CanPurchase = true },
		Hat20 = { Name = "Hat20", Price = 12500, LevelRequired = 36, Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },
		Hat21 = { Name = "Hat21", Price = 25000, LevelRequired = 52, Rarity = "Epic",      Image = "rbxassetid://0", CanPurchase = true },


	},

	Outfits = {
		-- Las claves coinciden con los .rbxm en Shared.Bodies (outfitId = clave = nombre del modelo).
		-- Image = thumbnail 2D de la tarjeta del locker. Placeholder rbxassetid://0 → reemplazar por el ID real.
		-- REGLA DE MONETIZACIÓN: los outfits NUNCA se venden por Cash. O se pagan
		-- en Gems (tienda) o son exclusivas del Battle Pass. Es la categoría
		-- premium del juego: el sink principal que empuja la compra de packs.
		Default = { Name = "Default Outfit", Price = 0,    LevelRequired = 1,  Rarity = "Common",   Image = "rbxassetid://107928751959121", CanPurchase = false },
		-- Exclusiva del pase S1 (track PASS, tier 42).
		Ducky   = { Name = "Ducky",          Price = 0, LevelRequired = 0, Rarity = "Uncommon",     Image = "rbxassetid://137997678899031", CanPurchase = false, isBPExclusive = true },
		-- Tienda (Gems). Los precios están calibrados contra los packs de gemas
		-- de StoreProducts (100 / 250 / 600 / 1400 / 3000) para que cada uno
		-- caiga dentro de un pack y no obligue a comprar dos. Tourist a 100 es
		-- EL gancho de conversión: cuesta exactamente el pack mínimo (49 R$), y
		-- con las 50 Gems free del pase el F2P queda a medio pack de su primer
		-- ítem premium. Gates de nivel bajos a propósito: la barrera ya es la
		-- moneda premium.
		Tourist = { Name = "Tourist",        Price = 100,  LevelRequired = 0,  Rarity = "Common", Image = "rbxassetid://119849081428861", CanPurchase = true, Currency = "Gems" },
		Inmate  = { Name = "Inmate",         Price = 1000, LevelRequired = 5, Rarity = "Epic",     Image = "rbxassetid://75053707941889", CanPurchase = true, Currency = "Gems" },
		Jungle  = { Name = "Jungle",         Price = 2500, LevelRequired = 10, Rarity = "Legendary",     Image = "rbxassetid://109406925958012", CanPurchase = true, Currency = "Gems" },
	},
}

return table.freeze(ItemsConfig)



