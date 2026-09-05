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
-- Precios y LevelRequired recalibrados el 2026-09-04 (ver data/change-log.json
-- del dashboard). Tasa de referencia: ~1.200 Cash/h y ~2.600 XP/h a ritmo de
-- diseño (~63 kills/h, Kill 10/HS 5/Assist 5 + fin de partida ~35). Bandas:
--   Common 150-250 (8-13 min) · Uncommon 500-1.000 (25-50 min) · Rare
--   1.500-2.500 (1,3-2 h) · Epic 4.000-6.500 (3-5 h) · Legendary 10.000-20.000
--   (8-17 h ≈ el pack Cash5). El nivel se deriva del precio: se desbloquea
--   cuando ya se podía pagar. La escalera anterior se aplicó a 300 Cash/h
--   (la tasa de un tester) y dejaba TODO el catálogo ×3-7 barato. Los
--   WeaponWraps tienen banda propia porque se compran por arma: ver la sección.

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
    AK      = { Name = "AK",      Price = 250,  LevelRequired = 3,  Rarity = "Common",    Image = asset(100246140710694), CanPurchase = true },
    Groza   = { Name = "Groza",   Price = 150,   LevelRequired = 0,  Rarity = "Common",  Image = asset(133051760713810), CanPurchase = true },
    Tommy   = { Name = "Tommy",   Price = 2000,  LevelRequired = 15,  Rarity = "Rare",      Image = asset(111814750317784), CanPurchase = true },
    Sniper  = { Name = "Sniper",  Price = 5000, LevelRequired = 26,  Rarity = "Epic",      Image = asset(86261275288637),  CanPurchase = true },
    Large   = { Name = "Large",   Price = 12500, LevelRequired = 43,  Rarity = "Legendary",      Image = asset(90736156284730),  CanPurchase = true },
},

Special = {
    -- Secondary/Special (corto rango o alto impacto)
    -- Arma de inicio (misma convención que Main.Default). Sin Image: el Locker
    -- cae en su thumbnail por defecto hasta que haya uno en el panel de Roblox.
    Default = { Name = "Default", Price = 0,   LevelRequired = 0,  Rarity = "Common",        CanPurchase = false },
    Short   = { Name = "Short",   Price = 650, LevelRequired = 7,  Rarity = "Uncommon",      Image = asset(118462878872416), CanPurchase = true },
    UZI     = { Name = "UZI",     Price = 200, LevelRequired = 0,  Rarity = "Common",         Image = asset(109948875778066), CanPurchase = true },
    Laser   = { Name = "Laser",   Price = 5000, LevelRequired = 26,  Rarity = "Epic",      Image = asset(80482264427643),  CanPurchase = true },
    RPG     = { Name = "RPG",     Price = 12500, LevelRequired = 43,  Rarity = "Legendary",      Image = asset(139650368086109), CanPurchase = true },
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
		-- ── Escalera Cash: colores planos → animada → material especial ──
		-- Banda PROPIA, ≈⅓ de la del ítem de su rareza (2026-09-04). Un wrap se
		-- compra POR ARMA (ShopService lo guarda en WeaponWrapsByWeapon), así que
		-- vestir el arsenal principal de oro son seis compras: a 12.500 cada una
		-- (lo que ponía la escalera de ítems) una skin de un arma costaba lo mismo
		-- que la Large; a 4.000 las seis suman dos Legendaries, que es lo que se
		-- lee. La rareza marca el tier de la skin, no el precio. Niveles derivados
		-- del precio a 1.200 Cash/h · 2.600 XP/h, como el resto del catálogo. El
		-- pase regala wraps por arma y UN global (Gold, tier 54): con tres
		-- globales a 11 armas el track PASS valía ×129 su precio.
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
			Price = 250,
			LevelRequired = 3,
			Rarity = "Uncommon",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(70, 150, 80),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Coral = {
			Name = "Coral",
			Price = 400,
			LevelRequired = 5,
			Rarity = "Uncommon",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(255, 120, 90),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Purple = {
			Name = "Royal Purple",
			Price = 800,
			LevelRequired = 8,
			Rarity = "Rare",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(130, 70, 200),
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Red  = {
			Name = "Crimson Flow",
			Price = 1500,
			LevelRequired = 13,
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
			Price = 2500,
			LevelRequired = 17,
			Rarity = "Epic",
			CanPurchase = true,
			BaseColor = Color3.fromRGB(0, 255, 170),
			Material = Enum.Material.Neon,
			isAnimated = false,
			StudsPerTile = 3,
		},
		Wrap_Gold = {
			Name = "Gold Wrap",
			Price = 4000,
			LevelRequired = 23,
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
			KillChallenge = { Kills = 100 },
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
		-- Los cuatro comparten Image de momento (icono genérico de la categoría):
		-- subir iconos propios por efecto cuando haya arte.
		Default   = { Name = "Default Kill",   Price = 0,   LevelRequired = 1, Rarity = "Common", Image = "rbxassetid://130437553674754", CanPurchase = false },
		Gravity   = { Name = "Gravity Kill",   Price = 0, LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://130437553674754", CanPurchase = false, isBPExclusive = true },
		Explosion = { Name = "Explosion Kill", Price = 4000, LevelRequired = 23, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
		Tornado   = { Name = "Tornado Kill",   Price = 6500, LevelRequired = 30, Rarity = "Epic",   Image = "rbxassetid://130437553674754", CanPurchase = true },
	},

	Faces = {
		-- "Default" = la cara base del rig (no es un decal de catálogo). Todo jugador
		-- la posee y equipa por DataTemplate, así que DEBE existir en el catálogo o
		-- el Locker no puede mostrar la cara equipada y applyFaceToHead no-opea.
		-- Usamos la textura built-in del engine (rbxasset://, no un assetId de catálogo
		-- desconocido) para que el catálogo renderice algo seguro y aplicarla restaure
		-- la cara base del head. No comprable, precio 0.
		Default = { Name = "Default",        Price = 0,  LevelRequired = 0, Rarity = "Common", Image = "rbxasset://textures/face.png", CanPurchase = false },
		Face1   = { Name = "Classic Smile",  Price = 250,  LevelRequired = 3, Rarity = "Common",   Image = "rbxassetid://79175047578893",  CanPurchase = true },
		Face2   = { Name = "Nervous",        Price = 650,  LevelRequired = 7, Rarity = "Uncommon",   Image = "rbxassetid://18571318923",    CanPurchase = true },
		Face3   = { Name = "Pout",           Price = 500,  LevelRequired = 6, Rarity = "Uncommon",   Image = "rbxassetid://97580829209799", CanPurchase = true },
		Face4   = { Name = "Kawaii",         Price = 6500,  LevelRequired = 30, Rarity = "Epic",   Image = "rbxassetid://94789972115859", CanPurchase = true },
		-- Exclusiva del Battle Pass (tier 1 FREE de S1).
		Face5   = { Name = "Nerd",           Price = 0,  LevelRequired = 0, Rarity = "Rare",   Image = "rbxassetid://17285554126",    CanPurchase = false, isBPExclusive = true },
		Face6   = { Name = "Deadpan",        Price = 10000,  LevelRequired = 38, Rarity = "Legendary",   Image = "rbxassetid://70391209868621", CanPurchase = true },
		Face7   = { Name = "Kitty",          Price = 20000,  LevelRequired = 55, Rarity = "Legendary",   Image = "rbxassetid://18626918162",    CanPurchase = true },
		Face8   = { Name = "Goofy",          Price = 150,  LevelRequired = 0, Rarity = "Common", Image = "rbxassetid://17373537487",    CanPurchase = true },
		Face9   = { Name = "Chill",          Price = 1500,  LevelRequired = 13, Rarity = "Rare",   Image = "rbxassetid://118980363558612", CanPurchase = true },
		Face10  = { Name = "Side Eye",       Price = 1000, LevelRequired = 10, Rarity = "Uncommon",   Image = "rbxassetid://18870092964",    CanPurchase = true },
		Face11  = { Name = "Angry",          Price = 2500, LevelRequired = 17, Rarity = "Rare",   Image = "rbxassetid://101878427779141", CanPurchase = true },
		Face12  = { Name = "Menace",         Price = 4000, LevelRequired = 23, Rarity = "Epic",   Image = "rbxassetid://112166980943980", CanPurchase = true },

	},

	Hats = {
		Hat1 = { Name = "Bunny",          Price = 150,  LevelRequired = 0,  Rarity = "Common",    Image = "rbxassetid://117004939623250", CanPurchase = true },
		Hat2 = { Name = "Cone",      Price = 0, LevelRequired = 10, Rarity = "Rare",      Image = "rbxassetid://138341632720877", CanPurchase = false, isBPExclusive = true },
		Hat3 = { Name = "Crown",        Price = 0, LevelRequired = 20, Rarity = "Legendary", Image = "rbxassetid://119183410438332", CanPurchase = false, isBPExclusive = true },
		Hat4 = { Name = "Squid",        Price = 2500, LevelRequired = 17, Rarity = "Rare", Image = "rbxassetid://74317816532636", CanPurchase = true },
		Hat5 = { Name = "Alaska",        Price = 4000, LevelRequired = 23, Rarity = "Epic", Image = "rbxassetid://83643028468192", CanPurchase = true },
		Hat6 = { Name = "Drink",        Price = 5000, LevelRequired = 26, Rarity = "Epic", Image = "rbxassetid://130927276777389", CanPurchase = true },
		Hat7 = { Name = "IceCream",        Price = 6500, LevelRequired = 30, Rarity = "Epic", Image = "rbxassetid://89103967355981", CanPurchase = true },
		-- OJO: Image comparte assetId con Hat7 (IceCream) — subir el thumbnail
		-- real del Spartan antes del launch o sale con imagen de helado.
		Hat8 = { Name = "Spartan",        Price = 10000, LevelRequired = 38, Rarity = "Legendary", Image = "rbxassetid://89103967355981", CanPurchase = true },
		Hat9 = { Name = "RaceHelmet",        Price = 20000, LevelRequired = 55, Rarity = "Legendary", Image = "rbxassetid://84090421736652", CanPurchase = true },
		Hat10 = { Name = "Pan",        Price = 200, LevelRequired = 3, Rarity = "Common", Image = "rbxassetid://97418970357486", CanPurchase = true },
		Hat11 = { Name = "Football",        Price = 250, LevelRequired = 3, Rarity = "Common", Image = "rbxassetid://86457108228550", CanPurchase = true },
		Hat12 = { Name = "Sombrero",        Price = 500, LevelRequired = 6, Rarity = "Uncommon", Image = "rbxassetid://79179819137524", CanPurchase = true },
		Hat13 = { Name = "Shark",        Price = 1000, LevelRequired = 10, Rarity = "Uncommon", Image = "rbxassetid://72319063957484", CanPurchase = true },
		Hat14 = { Name = "Unicorn",        Price = 1500, LevelRequired = 13, Rarity = "Rare", Image = "rbxassetid://112312308063894", CanPurchase = true },


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



