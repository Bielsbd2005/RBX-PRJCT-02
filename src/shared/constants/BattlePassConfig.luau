--!strict
--[[
	BattlePassConfig.luau
	Fuente única de verdad para temporadas, tiers y recompensas del Battle Pass.

	Diseño escalable:
	  • Añadir una nueva season = append a `Seasons`. Los perfiles existentes
	    se resetean automáticamente cuando `GetActiveSeason().Id` ya no coincide
	    con el `SeasonId` almacenado.
	  • Las recompensas se leen LIVE del config en cada claim (no se snapshotean
	    en el perfil). Editar rewards mid-season afecta a claims futuros, no a
	    los ya hechos. Deferred a v2 si la balanceabilidad lo requiere.
	  • Los tiers son contiguos (Level == índice), validar al añadir entradas.
	  • XP rates se centralizan en `XPRates` para soportar boosters en v2.

	Convenciones:
	  • Reward.Kind = "Cash" → usar Amount (number).
	  • Reward.Kind = "Item" → usar Category + ItemId (deben existir en ItemsConfig).
	  • Icon/Label opcionales; el cliente fallback-ea a ItemsConfig[...].Image/Name.
	  • PremiumProductId = 0 indica "no configurado" (UI desactiva el botón).
]]

-- ────────────────────────────────────────────────────────────
-- TIPOS
-- ────────────────────────────────────────────────────────────

export type RewardKind = "Cash" | "Item"

export type Reward = {
	Kind: RewardKind,
	Amount: number?,    -- Cash
	Category: string?,  -- Item: "Hats" | "Faces" | "KillEffects" | "Outfits" | "Main" | "Special"
	ItemId: string?,    -- Item: id en ItemsConfig
	Icon: string?,      -- Override de UI (rbxassetid://...). Si nil, fallback a ItemsConfig.
	Label: string?,     -- Override del texto del Value. Si nil, fallback a "+Amount" o ItemsConfig.Name.
}

export type Tier = {
	Level: number,      -- 1..N (debe coincidir con índice del array)
	XPRequired: number, -- XP para completar este tier
	Free: Reward,
	Premium: Reward,
}

export type Season = {
	Id: string,
	Name: string,
	StartsAt: number,           -- os.time() informativo (v2: selección por fechas)
	EndsAt: number,
	PremiumProductId: number,   -- Roblox developer product. 0 = sin configurar.
	SkipProductId: number,      -- Roblox developer product (skip 1 tier). 0 = sin configurar.
	Tiers: { Tier },            -- contiguos, Level == índice
}

-- ────────────────────────────────────────────────────────────
-- CONFIGURACIÓN
-- ────────────────────────────────────────────────────────────

local ActionRewards = require(script.Parent:WaitForChild("ActionRewards"))

local BattlePassConfig = {}

-- XP rates por evento. v1: solo kills.
-- PerKill reusa ActionRewards.GetXP("Kill") para mantener una única fuente de
-- verdad: si el balance cambia en ActionRewards, el BP lo hereda sin drift.
BattlePassConfig.XPRates = {
	PerKill = ActionRewards.GetXP("Kill"),
}

-- Icono por defecto para rewards Cash cuando un Reward no define Icon
-- explícito. Si queda como string vacío, el ImageLabel del slot se renderiza
-- sin textura.
BattlePassConfig.RewardIcons = {
	Cash = "rbxassetid://113694528712529",
}

-- Curva de XP por tier. Base 100 + 5 XP por nivel completado. Da una rampa
-- suave (level 1 = 100 XP ≈ 4 kills, level 30 = 245 XP ≈ 10 kills) sin
-- explotar el grind: total S1 ≈ 5175 XP vs 3000 con curva plana anterior.
-- Tunear `XP_BASE` y `XP_STEP` aquí mueve la curva entera.
local XP_BASE = 100
local XP_STEP = 5
local function xpForLevel(level: number): number
	return XP_BASE + (level - 1) * XP_STEP
end

-- Helper local para reducir el ruido de declaración de tiers.
-- Acepta override opcional de XPRequired para casos puntuales (boss tier, etc.).
local function tier(level: number, free: Reward, premium: Reward, xpRequired: number?): Tier
	return {
		Level = level,
		XPRequired = xpRequired or xpForLevel(level),
		Free = free,
		Premium = premium,
	}
end

local function cash(amount: number): Reward
	return { Kind = "Cash", Amount = amount }
end

local function item(category: string, itemId: string): Reward
	return { Kind = "Item", Category = category, ItemId = itemId }
end

BattlePassConfig.Seasons = {
	{
		Id = "S1",
		Name = "Season 1",
		StartsAt = 0,
		-- Fecha ficticia para testing visual del label TimeLeft. Reemplazar
		-- por la fecha real antes de release. 2026-06-13 00:00 UTC ≈ "6 weeks,
		-- 2 days" desde 2026-04-30 (formato exacto del ejemplo de diseño).
		EndsAt = os.time({ year = 2026, month = 6, day = 13, hour = 0, min = 0, sec = 0 }),
		PremiumProductId = 3583494613, -- TODO: pegar el productId real de Roblox.
		SkipProductId = 3583700824,             -- TODO: pegar el productId real del "Skip Tier".
		Tiers = {
			tier(1,  cash(100),  cash(250)),
			tier(2,  cash(100),  cash(300)),
			tier(3,  cash(150),  cash(350)),
			tier(4,  cash(150),  cash(400)),
			tier(5,  cash(200),  item("Faces", "Face2")),
			tier(6,  cash(200),  cash(500)),
			tier(7,  cash(250),  cash(550)),
			tier(8,  cash(250),  cash(600)),
			tier(9,  cash(300),  cash(650)),
			tier(10, cash(300),  item("KillEffects", "Gravity")),
			tier(11, cash(350),  cash(750)),
			tier(12, cash(350),  cash(800)),
			tier(13, cash(400),  cash(850)),
			tier(14, cash(400),  cash(900)),
			tier(15, cash(450),  item("Faces", "Face5")),
			tier(16, cash(450),  cash(1000)),
			tier(17, cash(500),  cash(1100)),
			tier(18, cash(500),  cash(1200)),
			tier(19, cash(550),  cash(1300)),
			tier(20, cash(550),  item("Hats", "Hat2")),
			tier(21, cash(600),  cash(1500)),
			tier(22, cash(600),  cash(1600)),
			tier(23, cash(650),  cash(1700)),
			tier(24, cash(650),  cash(1800)),
			tier(25, cash(700),  item("Faces", "Face9")),
			tier(26, cash(700),  cash(2000)),
			tier(27, cash(750),  cash(2200)),
			tier(28, cash(750),  cash(2400)),
			tier(29, cash(800),  cash(2600)),
			tier(30, cash(1000), item("Hats", "Hat3")),
		},
	},
}

-- ────────────────────────────────────────────────────────────
-- API PÚBLICA
-- ────────────────────────────────────────────────────────────

-- v1: la season activa es siempre la primera. v2: seleccionar por os.time().
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

-- Set de ítems que aparecen como reward en CUALQUIER season/tier/track del BP.
-- Construido lazy y cacheado: la primera llamada a IsBPExclusive recorre todas
-- las seasons, las siguientes son lookups O(1). Single source of truth: editar
-- los rewards en `Seasons` automáticamente actualiza el set; no hace falta
-- también flag-ear `isBPExclusive = true` en ItemsConfig (aunque ese flag sigue
-- funcionando como override manual en LockerCatalog/ShopService).
local _bpExclusiveCache: { [string]: { [string]: boolean } }? = nil
local function _buildBPExclusiveCache(): { [string]: { [string]: boolean } }
	local set: { [string]: { [string]: boolean } } = {}
	for _, season in BattlePassConfig.Seasons do
		for _, t in season.Tiers do
			for _, reward in { t.Free, t.Premium } do
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
-- Permite que ProcessReceipt despache un único receipt entre los dos tipos
-- de compra del BP sin necesitar un mapa global externo.
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
