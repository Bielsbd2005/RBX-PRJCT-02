--!strict
--[[
	BattlePassConfig.luau
	Fuente única de verdad para temporadas, tiers y recompensas del Battle Pass.

	Modelo (v2): cada nivel tiene UNA sola recompensa y es de tipo FREE o PASS.
	  • FREE  → cualquiera puede reclamarla.
	  • PASS  → requiere PremiumOwned (compra del pase Premium con Robux).

	Diseño escalable:
	  • Añadir una nueva season = append a `Seasons`. Los perfiles existentes
	    se resetean automáticamente cuando `GetActiveSeason().Id` ya no coincide
	    con el `SeasonId` almacenado.
	  • Las recompensas se leen LIVE del config en cada claim (no se snapshotean
	    en el perfil).
	  • Los tiers son contiguos (Level == índice).

	Convenciones:
	  • Reward.Kind = "Cash" → usar Amount (number).
	  • Reward.Kind = "Gems" → usar Amount (number). Moneda premium: junto con
	    los packs de Robux es la ÚNICA forma de conseguir Gems.
	  • Reward.Kind = "Item" → usar Category + ItemId (deben existir en ItemsConfig).
	  • El premium y el skip se COMPRAN CON GEMS (PremiumGemPrice/SkipGemPrice;
	    BattlePassService cobra de Stats.Gems, sin developer product). Los campos
	    *ProductId/*RobuxPrice son el flujo Robux directo LEGACY, dormido con
	    ProductId = 0.
]]

-- ────────────────────────────────────────────────────────────
-- TIPOS
-- ────────────────────────────────────────────────────────────

export type RewardKind = "Cash" | "Gems" | "Item"

export type Reward = {
	Kind: RewardKind,
	Amount: number?,    -- Cash o Gems
	Category: string?,  -- Item: "Hats" | "Faces" | "KillEffects" | "Outfits" | "Main" | "Special" | "WeaponWraps"
	ItemId: string?,    -- Item: id en ItemsConfig
	Icon: string?,      -- Override de UI (rbxassetid://...). Si nil, fallback a ItemsConfig.
	Label: string?,     -- Override del texto. Si nil, fallback a "+Amount" o ItemsConfig.Name.
	-- WeaponWraps — modos mutuamente excluyentes:
	--   Global = true                       → grant a TODAS las armas (Main+Special).
	--   WeaponCategory + WeaponId definidos → grant SÓLO al arma indicada.
	Global: boolean?,
	WeaponCategory: string?, -- "Main" | "Special" (per-weapon wraps)
	WeaponId: string?,       -- itemId en ItemsConfig[WeaponCategory] (per-weapon wraps)
}

export type Tier = {
	Level: number,      -- 1..N (debe coincidir con índice del array)
	XPRequired: number, -- XP para completar este tier
	Reward: Reward,     -- recompensa única del nivel
	Premium: boolean,   -- true = PASS (requiere PremiumOwned); false = FREE
}

export type Season = {
	Id: string,
	Name: string,
	EndsAt: number,             -- os.time() deadline (fuente del timer)
	-- Compra con GEMS (flujo vigente): BattlePassService descuenta de Stats.Gems
	-- en un BatchUpdate atómico, sin developer product ni receipt. 0 = no
	-- comprable (el handler responde Unavailable y la UI no puede completar).
	PremiumGemPrice: number,    -- Precio del premium en Gems.
	SkipGemPrice: number,       -- Precio del "Skip Tier" (+1 nivel) en Gems.
	-- LEGACY Robux directo: dormido con ProductId = 0 (ResolveReceipt no matchea
	-- y el dispatcher de receipts lo ignora). Se conserva por si una promo
	-- futura vuelve a vender el pase como developer product.
	PremiumProductId: number,   -- Roblox developer product. 0 = desactivado.
	PremiumRobuxPrice: number,  -- Precio en Robux del flujo legacy (analytics).
	SkipProductId: number,      -- Developer product "Skip Tier". 0 = desactivado.
	SkipRobuxPrice: number,     -- Precio en Robux del flujo legacy (analytics).
	Tiers: { Tier },            -- contiguos, Level == índice
}

-- ────────────────────────────────────────────────────────────
-- CONFIGURACIÓN
-- ────────────────────────────────────────────────────────────

local ActionRewards = require(script.Parent:WaitForChild("ActionRewards"))

local BattlePassConfig = {}

-- XP rates por evento. v1: solo kills.
BattlePassConfig.XPRates = {
	PerKill = ActionRewards.GetXP("Kill"),
}

-- Icono por defecto para rewards Cash cuando un Reward no define Icon explícito.
BattlePassConfig.RewardIcons = {
	Cash = "rbxassetid://113694528712529",
	-- TODO: subir el icono de Gems y pegar el assetId. Con 0 la UI cae al
	-- icono de Cash, que confundiría las dos monedas: mejor dejarlo vacío.
	Gems = "",
}

--[[
	Curva de XP por tier. Tunear XP_BASE / XP_STEP mueve la curva entera.
	CALIBRACIÓN (2026-09-01): con 64 tiers, base 100 y step 10 la season suma
	26.560 XP ≈ 1.060 kills ≈ ~17h a ritmo medio (~63 kills/h) — unas 2h/semana
	en una season de 8: el jugador constante la termina con margen y el
	hardcore no la agota en la semana 1 (con step 5 eran 10,5h y sobraban 6
	semanas sin objetivo). Tier 1 = 100 XP (4 kills, gancho inmediato); tier 64
	= 730 (~3 partidas). La forma casi plana es deliberada: un pase vende
	progreso constante, sin muro final. El XP del pase solo viene de kills
	(XPRates) y respeta MatchXPCap (ver ServerBootstrap).
]]
local XP_BASE = 100
local XP_STEP = 10
local function xpForLevel(level: number): number
	return XP_BASE + (level - 1) * XP_STEP
end

local function cash(amount: number): Reward
	return { Kind = "Cash", Amount = amount }
end

local function gems(amount: number): Reward
	return { Kind = "Gems", Amount = amount }
end

local function item(category: string, itemId: string): Reward
	return { Kind = "Item", Category = category, ItemId = itemId }
end

local function globalWrap(itemId: string): Reward
	return { Kind = "Item", Category = "WeaponWraps", ItemId = itemId, Global = true }
end

local function weaponWrap(itemId: string, weaponCategory: string, weaponId: string): Reward
	return {
		Kind = "Item",
		Category = "WeaponWraps",
		ItemId = itemId,
		WeaponCategory = weaponCategory,
		WeaponId = weaponId,
	}
end

-- 64 niveles → 8 páginas de 8 slots. Editable: ajusta TIER_COUNT, los overrides
-- de recompensa y la regla de qué niveles son PASS.
local TIER_COUNT = 64

-- Recompensa por nivel: por defecto Cash escalado; overrides puntuales para items/wraps.
--
-- ECONOMÍA DE LANZAMIENTO (S1). Reglas de diseño de la tabla:
--   · Impares = FREE, pares = PASS (ver `isPremiumLevel`).
--   · Track FREE: un ítem visible por página (con dos exclusivas — Face5 en el
--     tier 1 como gancho inmediato y el wrap RPG Blue en el 21 — y un cierre
--     legendario en el 63) para que jugar sin pagar siga sintiéndose premiado.
--   · Track PASS: todas las demás exclusivas de S1 (Wrap_Pink, Gravity, Cone,
--     el outfit Ducky y la Crown como cierre del tier 64) e ítems de tienda
--     como atajo. Los outfits de tienda (Gems) NO van en el pase: regalarlos
--     canibalizaría su venta — el único outfit del pase es su exclusiva.
--   · GEMS — balanceados para VENDER PACKS, no para regalarlos. El pase cuesta
--     500 Gems (PremiumGemPrice) y la season devuelve 250 en total: 200 en el
--     track PASS (rebate del 40%: quien compró el pase termina con la mitad
--     del siguiente y necesita un pack para renovar) + 50 en el track FREE
--     (25+25: la "muestra" que enseña la moneda al F2P y le deja a un pack de
--     un outfit). NUNCA subir el total del PASS a ≥500: el pase se volvería
--     autosostenible y mataría la venta de packs para siempre.
--   · Outfits: solo Gems (tienda: Tourist 100, Inmate 1.000, Jungle 2.500) o
--     pase (Ducky, PASS 42). Ningún outfit se vende por Cash. Tourist a 100 =
--     pack mínimo: las 50 Gems free dejan al F2P a medio pack de comprarlo.
--   · Orden global↔por-arma: un weaponWrap cuyo globalWrap cae en un tier
--     ANTERIOR es un premio vacío (el grant global ya cubre todas las armas).
--     Aquí siempre per-weapon primero (Gold 2/30 → global 54; Red 14 → 36).
--   · Los wraps Mastery_* NO van en el pase: son recompensas de desafío de
--     kills (KillChallenge) y meterlos aquí las haría redundantes.
local REWARD_OVERRIDES: { [number]: Reward } = {
	-- Página 1 (1-8): gancho inmediato en ambos tracks.
	[1]  = item("Faces", "Face5"),                        -- FREE · cara exclusiva S1
	[2]  = weaponWrap("Wrap_Gold", "Main", "Default"),    -- PASS · oro en el arma inicial
	[5]  = item("Hats", "Hat1"),                          -- FREE · Bunny
	[6]  = globalWrap("Wrap_Pink"),                       -- PASS · wrap global exclusivo

	-- Página 2 (9-16).
	[9]  = weaponWrap("Wrap_Coral", "Special", "UZI"),    -- FREE
	[10] = item("KillEffects", "Gravity"),                -- PASS · kill effect exclusivo
	[11] = gems(25),                                      -- FREE · muestra de Gems al F2P
	[13] = item("Faces", "Face2"),                        -- FREE
	[14] = weaponWrap("Wrap_Red", "Main", "Tommy"),       -- PASS · wrap animado (per-weapon)
	[16] = gems(50),                                      -- PASS

	-- Página 3 (17-24).
	[17] = item("Hats", "Hat4"),                          -- FREE · Squid
	[18] = item("Hats", "Hat2"),                          -- PASS · Cone, exclusivo
	[21] = weaponWrap("Wrap_RPG_Blue", "Special", "RPG"), -- FREE · exclusiva free track
	[24] = item("Hats", "Hat12"),                         -- PASS · Sombrero

	-- Página 4 (25-32).
	[26] = globalWrap("Wrap_Neon"),                       -- PASS · neon global
	[29] = item("Faces", "Face10"),                       -- FREE
	[30] = weaponWrap("Wrap_Gold", "Main", "Sniper"),     -- PASS
	[32] = gems(50),                                      -- PASS

	-- Página 5 (33-40).
	[33] = item("Hats", "Hat13"),                         -- FREE · Shark
	[34] = item("Hats", "Hat5"),                          -- PASS · Alaska
	[35] = gems(25),                                      -- FREE · segunda muestra
	[36] = globalWrap("Wrap_Red"),                        -- PASS · upgrade del 14 a global
	[37] = item("Faces", "Face11"),                       -- FREE

	-- Página 6 (41-48).
	[42] = item("Outfits", "Ducky"),                      -- PASS · outfit del pase (premium)
	[43] = item("Hats", "Hat14"),                         -- FREE · Unicorn
	[46] = item("Faces", "Face4"),                        -- PASS
	[48] = gems(50),                                      -- PASS

	-- Página 7 (49-56).
	[49] = item("KillEffects", "Explosion"),              -- FREE · gancho fuerte tardío
	[52] = item("Hats", "Hat7"),                          -- PASS · IceCream
	[54] = globalWrap("Wrap_Gold"),                       -- PASS · oro en TODO el arsenal

	-- Página 8 (57-64): cierre de season.
	[58] = item("Faces", "Face7"),                        -- PASS · Kitty (legendaria)
	[62] = gems(50),                                      -- PASS
	[63] = item("Faces", "Face6"),                        -- FREE · cierre del track free
	[64] = item("Hats", "Hat3"),                          -- PASS · Crown, LA exclusiva de S1
}

-- Niveles PASS (requieren Premium). Regla por defecto: los pares son PASS, los
-- impares FREE. Editar a gusto del diseño.
local function isPremiumLevel(level: number): boolean
	return level % 2 == 0
end

--[[
	Cash filler de los tiers sin override. PRESUPUESTO AUDITADO (2026-09-01),
	con 30 tiers de filler (18 FREE + 12 PASS) esta fórmula reparte:
	  FREE 4.100 + PASS 2.450 = 6.550 Cash por season ≈ UN ítem top (6.500).
	Referencias contra las que se calibró — revisar si cambia cualquiera:
	  · Jugar hasta el final de season (~660 kills, ~10h) da ~13-16k de Cash
	    (kills+headshots+assists ~110/partida, fin de partida ~130, dailies 65/
	    día). El BP debe ser suplemento (~1/3), nunca el ingreso principal.
	  · El pack IAP grande vende 15.000 Cash por 799 R$: el track FREE jamás
	    puede acercarse a esa cifra o nadie compra packs.
	La fórmula anterior (100+25·(l-1), heredada de la tabla de pruebas) regalaba
	28.250 — más que el pack grande y que todo el cash jugado: rompía ambas.
]]
local function defaultCashFor(level: number): number
	return 50 + (level - 1) * 5
end

local function buildTiers(): { Tier }
	local tiers: { Tier } = {}
	for level = 1, TIER_COUNT do
		tiers[level] = {
			Level = level,
			XPRequired = xpForLevel(level),
			Reward = REWARD_OVERRIDES[level] or cash(defaultCashFor(level)),
			Premium = isPremiumLevel(level),
		}
	end
	return tiers
end

BattlePassConfig.Seasons = {
	{
		Id = "S1",
		Name = "Season 1",
		-- Cierre de S1: ~8 semanas desde el lanzamiento previsto (sep 2026).
		-- Ajustar al fijar la fecha real de release.
		EndsAt = os.time({ year = 2026, month = 11, day = 1, hour = 0, min = 0, sec = 0 }),
		-- 500 = justo por debajo del pack de 600 Gems (199 R$): el pack "natural"
		-- del pase es el de 199 R$ (precio de entrada que convierte más que los
		-- 399 R$ del flujo Robux antiguo) y deja 100 Gems de resto — resto que,
		-- sumado al rebate de 200 del propio pase, acerca al siguiente sink sin
		-- llegar nunca (ver REWARD_OVERRIDES: el pase jamás se autofinancia).
		PremiumGemPrice = 500,
		-- 100 = exactamente el pack mínimo (49 R$): cada skip es una compra
		-- impulsiva de un pack pequeño para quien va justo de Gems.
		SkipGemPrice = 100,
		-- Flujo Robux directo LEGACY, desactivado (el pase se compra con Gems).
		PremiumProductId = 0,
		PremiumRobuxPrice = 0,
		SkipProductId = 0,
		SkipRobuxPrice = 0,
		Tiers = buildTiers(),
	},
} :: { Season }

-- ────────────────────────────────────────────────────────────
-- API PÚBLICA
-- ────────────────────────────────────────────────────────────

-- v1: la season activa es siempre la primera.
function BattlePassConfig.GetActiveSeason(): Season
	return BattlePassConfig.Seasons[1]
end

function BattlePassConfig.GetTier(season: Season, level: number): Tier?
	if level < 1 or level > #season.Tiers then
		return nil
	end
	return season.Tiers[level]
end

function BattlePassConfig.GetMaxTier(season: Season): number
	return #season.Tiers
end

-- Set de ítems EXCLUSIVOS del BP: aparecen como reward en alguna season/tier y
-- además no se pueden conseguir de otra forma. Construido lazy y cacheado.
--
-- Estar en el pase NO basta para ser exclusivo: un ítem comprable en la tienda
-- (CanPurchase = true) o un wrap de desafío de kills (KillChallenge) que también
-- caiga en un tier es un atajo, no una exclusiva — marcarlo exclusivo lo haría
-- incomprable en la tienda (ShopService) e invisible en el locker para quien no
-- lo tenga (LockerCatalog), y los desafíos de kills serían indescubribles.
local _bpExclusiveCache: { [string]: { [string]: boolean } }? = nil
local function _buildBPExclusiveCache(): { [string]: { [string]: boolean } }
	local ItemsConfig = require(script.Parent.ItemsConfig) :: any
	local set: { [string]: { [string]: boolean } } = {}
	for _, season in BattlePassConfig.Seasons do
		for _, t in season.Tiers do
			local reward = t.Reward
			if reward.Kind == "Item" and reward.Category and reward.ItemId then
				local catalog = ItemsConfig[reward.Category]
				local def = if type(catalog) == "table" then catalog[reward.ItemId] else nil
				local obtainableElsewhere = type(def) == "table"
					and (def.CanPurchase == true or def.KillChallenge ~= nil)
				if not obtainableElsewhere then
					local cat = set[reward.Category]
					if not cat then
						cat = {}
						set[reward.Category] = cat
					end
					cat[reward.ItemId] = true
				end
			end
		end
	end
	return set
end

function BattlePassConfig.IsBPExclusive(category: string, itemId: string): boolean
	if _bpExclusiveCache == nil then
		_bpExclusiveCache = _buildBPExclusiveCache()
	end
	local cat = (_bpExclusiveCache :: any)[category]
	return cat ~= nil and cat[itemId] == true
end

-- Resuelve un productId a su (Season, kind). kind ∈ "Premium" | "Skip".
-- Devuelve (nil, nil) si el producto no pertenece a ningún BattlePass.
export type ReceiptKind = "Premium" | "Skip"
function BattlePassConfig.ResolveReceipt(productId: number): (Season?, ReceiptKind?)
	if productId == 0 then
		return nil, nil
	end
	for _, season in BattlePassConfig.Seasons do
		if season.PremiumProductId == productId then
			return season, "Premium"
		end
		if season.SkipProductId == productId then
			return season, "Skip"
		end
	end
	return nil, nil
end

return BattlePassConfig
