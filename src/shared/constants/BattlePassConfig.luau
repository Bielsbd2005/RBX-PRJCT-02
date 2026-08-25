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
	  • PremiumProductId = 0 indica "no configurado" (UI desactiva el botón).
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
	PremiumProductId: number,   -- Roblox developer product. 0 = sin configurar.
	PremiumRobuxPrice: number,  -- Precio en Robux del premium (para analytics).
	SkipProductId: number,      -- Developer product "Skip Tier" (+1 nivel). 0 = sin configurar.
	SkipRobuxPrice: number,     -- Precio en Robux del skip (para analytics).
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

-- Curva de XP por tier. Tunear XP_BASE / XP_STEP mueve la curva entera.
local XP_BASE = 100
local XP_STEP = 5
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
local REWARD_OVERRIDES: { [number]: Reward } = {
	[1]  = weaponWrap("Wrap_RPG_Blue", "Special", "RPG"),
	[3]  = globalWrap("Wrap_Pink"),
	[5]  = item("Faces", "Face2"),
	[10] = item("KillEffects", "Gravity"),
	[15] = item("Faces", "Face5"),
	[20] = item("Hats", "Hat2"),
	[25] = item("Faces", "Face9"),
	[30] = item("Hats", "Hat3"),

	-- Gems: repartidos por la temporada y escalando hacia el final, para que
	-- el pase tenga tirón hasta el tier 64. Todos caen en niveles PARES, que
	-- con `isPremiumLevel` son los de PASS: la moneda premium se reserva a
	-- quien compró el pase. Ajustar cantidades aquí es el único sitio.
	[8]  = gems(50),
	[16] = gems(75),
	[24] = gems(100),
	[32] = gems(150),
	[40] = gems(200),
	[48] = gems(250),
	[56] = gems(350),
	[64] = gems(500),
}

-- Niveles PASS (requieren Premium). Regla por defecto: los pares son PASS, los
-- impares FREE. Editar a gusto del diseño.
local function isPremiumLevel(level: number): boolean
	return level % 2 == 0
end

local function defaultCashFor(level: number): number
	return 100 + (level - 1) * 25
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
		-- Fecha ficticia para testing del timer. Reemplazar por la real.
		EndsAt = os.time({ year = 2026, month = 6, day = 13, hour = 0, min = 0, sec = 0 }),
		PremiumProductId = 3583494613, -- TODO: pegar el productId real de Roblox.
		PremiumRobuxPrice = 399,
		SkipProductId = 3583700824,    -- TODO: pegar el productId real del "Skip Tier".
		SkipRobuxPrice = 75,
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

-- Set de ítems que aparecen como reward en CUALQUIER season/tier del BP.
-- Construido lazy y cacheado.
local _bpExclusiveCache: { [string]: { [string]: boolean } }? = nil
local function _buildBPExclusiveCache(): { [string]: { [string]: boolean } }
	local set: { [string]: { [string]: boolean } } = {}
	for _, season in BattlePassConfig.Seasons do
		for _, t in season.Tiers do
			local reward = t.Reward
			if reward.Kind == "Item" and reward.Category and reward.ItemId then
				local cat = set[reward.Category]
				if not cat then
					cat = {}
					set[reward.Category] = cat
				end
				cat[reward.ItemId] = true
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
