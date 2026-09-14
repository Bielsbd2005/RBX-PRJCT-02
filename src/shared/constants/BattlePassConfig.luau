--!strict
--[[
	BattlePassConfig.luau
	API de temporadas, tiers y recompensas del Battle Pass.

	Los DATOS viven en `BattlePassSeasons.luau` (generado por el dashboard de
	Telemetry, vista Temporadas): puntero `ActiveSeasonId`, `Products` (skips,
	globales) y la lista `Seasons` con curva, filler y `Rewards` por tier. Este
	módulo sólo construye los tiers a partir de esos datos y resuelve el puntero.

	Modelo (v2): cada nivel tiene UNA sola recompensa y es de tipo FREE o PASS.
	  • FREE  → cualquiera puede reclamarla.
	  • PASS  → requiere PremiumOwned (compra del pase Premium con Gems).

	Diseño escalable:
	  • Añadir una season = añadirla a `BattlePassSeasons.Seasons` (borrador);
	    activarla = mover `ActiveSeasonId`. Los perfiles existentes se resetean
	    automáticamente cuando `GetActiveSeason().Id` ya no coincide con el
	    `SeasonId` almacenado (BattlePassService._ensureSeason).
	  • Las recompensas se leen LIVE del config en cada claim (no se snapshotean
	    en el perfil).
	  • Los tiers son contiguos (Level == índice).

	Convenciones:
	  • Reward.Kind = "Cash" → usar Amount (number).
	  • Reward.Kind = "Gems" → usar Amount (number). Moneda premium: junto con
	    los packs de Robux es la ÚNICA forma de conseguir Gems.
	  • Reward.Kind = "Item" → usar Category + ItemId (deben existir en ItemsConfig).
	  • El premium se COMPRA CON GEMS (PremiumGemPrice; BattlePassService cobra
	    de Stats.Gems, sin developer product). PremiumProductId/PremiumRobuxPrice
	    son el flujo Robux directo LEGACY, dormido con ProductId = 0.
	  • Los skips de nivel se COMPRAN CON ROBUX: dos developer products, +1 nivel
	    (SkipProductId) y +5 niveles (Skip5ProductId), GLOBALES a todas las
	    seasons (`Products`). El cliente lanza el prompt y
	    BattlePassService:ProcessReceipt concede. ProductId = 0 = sin crear en
	    el panel de Roblox: el botón queda inactivo y el receipt no matchea.
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
	-- Sellos del dashboard (ISO 8601, opcionales). Con PublishedAt = publicada
	-- alguna vez; con EndedAt = pasada. Sin PublishedAt = borrador. Sólo
	-- informativos en el juego: la activa es la del puntero.
	PublishedAt: string?,
	EndedAt: string?,
	EndsAt: number,             -- Unix timestamp del fin de season (fuente del timer del HUD). 0 = sin contador.
	-- Premium con GEMS (flujo vigente): BattlePassService descuenta de Stats.Gems
	-- en un BatchUpdate atómico, sin developer product ni receipt. 0 = no
	-- comprable (el handler responde Unavailable y la UI no puede completar).
	PremiumGemPrice: number,    -- Precio del premium en Gems.
	-- Premium LEGACY Robux directo: dormido con ProductId = 0 (ResolveReceipt no
	-- matchea y el dispatcher de receipts lo ignora). Se conserva por si una
	-- promo futura vuelve a vender el pase como developer product.
	PremiumProductId: number,   -- Roblox developer product. 0 = desactivado.
	PremiumRobuxPrice: number,  -- Precio en Robux del flujo legacy (analytics).
	Tiers: { Tier },            -- contiguos, Level == índice
}

-- Skips de nivel con ROBUX (developer products), globales a todas las seasons.
-- RobuxPrice tiene que ser el mismo que el del panel de Roblox: se pinta en el
-- botón y va a analytics.
export type Products = {
	SkipProductId: number,      -- Developer product "+1 nivel". 0 = sin crear.
	SkipRobuxPrice: number,
	Skip5ProductId: number,     -- Developer product "+5 niveles". 0 = sin crear.
	Skip5RobuxPrice: number,
}

-- ────────────────────────────────────────────────────────────
-- CONFIGURACIÓN
-- ────────────────────────────────────────────────────────────

local ActionRewards = require(script.Parent:WaitForChild("ActionRewards"))
local BattlePassSeasons = require(script.Parent:WaitForChild("BattlePassSeasons")) :: any

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
	Diseño de la economía del pase: ver `docs/temporadas-y-assets.md` del
	dashboard de Telemetry (formato del fichero, estados de temporada, reglas
	del selector de recompensas y validaciones). Resumen:
	  · Curva de XP por tier: XpBase + (nivel - 1) · XpStep; el XP del pase SOLO
	    viene de kills (XPRates.PerKill), nunca del XP de nivel de cuenta.
	  · Filler de los tiers sin reward: Cash = CashBase + (nivel - 1) · CashStep.
	  · PremiumRule decide qué niveles son PASS ("even" = pares, "odd" = impares).
	  · NADA de lo que regala el pase se vende en la tienda, y un ítem de una
	    temporada pasada no vuelve a otro pase (lo valida el dashboard).
	  · Aquí sólo se avisa por reward Item cuyo ítem no exista en ItemsConfig.
]]

-- ── Builder ──────────────────────────────────────────────────

local function _toNumber(value: any, fallback: number): number
	return if type(value) == "number" then value else fallback
end

local function _toString(value: any, fallback: string): string
	return if type(value) == "string" then value else fallback
end

local function _optionalString(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

-- ISO 8601 → Unix timestamp, una sola vez al construir. Ausente o inválido → 0
-- (el HUD oculta el contador). El aviso sale una vez por season.
local function _parseEndsAt(seasonId: string, value: any): number
	if value == nil then
		return 0
	end
	if type(value) == "string" and value ~= "" then
		local ok, parsed = pcall(DateTime.fromIsoDate, value)
		if ok and parsed then
			return (parsed :: DateTime).UnixTimestamp
		end
	end
	warn(("[BattlePassConfig] EndsAt inválido en la season %s (%s): sin contador"):format(seasonId, tostring(value)))
	return 0
end

local function _isPremiumLevel(rule: string, level: number): boolean
	if rule == "odd" then
		return level % 2 == 1
	elseif rule == "all" then
		return true
	elseif rule == "none" then
		return false
	end
	return level % 2 == 0 -- "even" (por defecto)
end

local function _copyReward(raw: any): Reward
	local reward: Reward = {
		Kind = raw.Kind,
		Amount = if type(raw.Amount) == "number" then raw.Amount else nil,
		Category = _optionalString(raw.Category),
		ItemId = _optionalString(raw.ItemId),
		Icon = _optionalString(raw.Icon),
		Label = _optionalString(raw.Label),
		Global = if raw.Global == true then true else nil,
		WeaponCategory = _optionalString(raw.WeaponCategory),
		WeaponId = _optionalString(raw.WeaponId),
	}
	return reward
end

local function _warnMissingItems(seasonId: string, rewards: { [number]: any })
	local ItemsConfig = require(script.Parent:WaitForChild("ItemsConfig")) :: any
	for level, raw in rewards do
		if type(raw) == "table" and raw.Kind == "Item" then
			local catalog = if type(raw.Category) == "string" then ItemsConfig[raw.Category] else nil
			local def = if type(catalog) == "table" and type(raw.ItemId) == "string" then catalog[raw.ItemId] else nil
			if type(def) ~= "table" then
				warn(("[BattlePassConfig] %s tier %s: el ítem %s.%s no existe en ItemsConfig"):format(
					seasonId,
					tostring(level),
					tostring(raw.Category),
					tostring(raw.ItemId)
				))
			end
		end
	end
end

local function buildTiers(seasonData: any): { Tier }
	local seasonId = _toString(seasonData.Id, "?")
	local tierCount = math.max(0, math.floor(_toNumber(seasonData.TierCount, 0)))
	local xpBase = _toNumber(seasonData.XpBase, 0)
	local xpStep = _toNumber(seasonData.XpStep, 0)
	local cashBase = _toNumber(seasonData.CashBase, 0)
	local cashStep = _toNumber(seasonData.CashStep, 0)
	local premiumRule = _toString(seasonData.PremiumRule, "even")
	if premiumRule ~= "even" and premiumRule ~= "odd" and premiumRule ~= "all" and premiumRule ~= "none" then
		warn(("[BattlePassConfig] PremiumRule desconocida en la season %s (%s): se usa \"even\""):format(seasonId, premiumRule))
		premiumRule = "even"
	end
	local rewards: { [number]: any } = if type(seasonData.Rewards) == "table" then seasonData.Rewards else {}
	_warnMissingItems(seasonId, rewards)

	local tiers: { Tier } = {}
	for level = 1, tierCount do
		local raw = rewards[level]
		local reward: Reward = if type(raw) == "table"
			then _copyReward(raw)
			else { Kind = "Cash", Amount = cashBase + (level - 1) * cashStep }
		tiers[level] = {
			Level = level,
			XPRequired = xpBase + (level - 1) * xpStep,
			Reward = reward,
			Premium = _isPremiumLevel(premiumRule, level),
		}
	end
	return tiers
end

local function buildSeason(seasonData: any): Season
	local id = _toString(seasonData.Id, "?")
	return {
		Id = id,
		Name = _toString(seasonData.Name, id),
		PublishedAt = _optionalString(seasonData.PublishedAt),
		EndedAt = _optionalString(seasonData.EndedAt),
		EndsAt = _parseEndsAt(id, seasonData.EndsAt),
		PremiumGemPrice = _toNumber(seasonData.PremiumGemPrice, 0),
		PremiumProductId = _toNumber(seasonData.PremiumProductId, 0),
		PremiumRobuxPrice = _toNumber(seasonData.PremiumRobuxPrice, 0),
		Tiers = buildTiers(seasonData),
	}
end

local rawProducts: any = if type(BattlePassSeasons.Products) == "table" then BattlePassSeasons.Products else {}
BattlePassConfig.Products = {
	SkipProductId = _toNumber(rawProducts.SkipProductId, 0),
	SkipRobuxPrice = _toNumber(rawProducts.SkipRobuxPrice, 0),
	Skip5ProductId = _toNumber(rawProducts.Skip5ProductId, 0),
	Skip5RobuxPrice = _toNumber(rawProducts.Skip5RobuxPrice, 0),
} :: Products

local seasons: { Season } = {}
if type(BattlePassSeasons.Seasons) == "table" then
	for _, seasonData in ipairs(BattlePassSeasons.Seasons) do
		if type(seasonData) == "table" then
			table.insert(seasons, buildSeason(seasonData))
		end
	end
end
if #seasons == 0 then
	warn("[BattlePassConfig] BattlePassSeasons no define ninguna season")
end
BattlePassConfig.Seasons = seasons

local _seasonById: { [string]: Season } = {}
for _, season in seasons do
	if _seasonById[season.Id] then
		warn(("[BattlePassConfig] Id de season repetido: %s"):format(season.Id))
	end
	_seasonById[season.Id] = season
end

BattlePassConfig.ActiveSeasonId = _toString(BattlePassSeasons.ActiveSeasonId, "")

-- ────────────────────────────────────────────────────────────
-- API PÚBLICA
-- ────────────────────────────────────────────────────────────

function BattlePassConfig.GetSeasonById(id: string): Season?
	return _seasonById[id]
end

-- La season activa es la del puntero `ActiveSeasonId`. Si no resuelve, se
-- avisa una vez por servidor/cliente y se cae a la primera de la lista.
local _warnedActive = false
function BattlePassConfig.GetActiveSeason(): Season
	local active = _seasonById[BattlePassConfig.ActiveSeasonId]
	if active then
		return active
	end
	if not _warnedActive then
		_warnedActive = true
		warn(("[BattlePassConfig] ActiveSeasonId \"%s\" no existe en BattlePassSeasons: se usa la primera season"):format(
			BattlePassConfig.ActiveSeasonId
		))
	end
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

-- Set de ítems EXCLUSIVOS del BP: aparecen como reward en alguna season/tier
-- (activa, borrador o pasada: lo asignado a un borrador deja de venderse en
-- cuanto se publica y las exclusivas de temporadas pasadas siguen invendibles)
-- y además no se pueden conseguir de otra forma. Construido lazy y cacheado.
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

-- Skips de nivel vendidos con Robux: "Skip" = +1 nivel, "Skip5" = +5 niveles.
export type SkipKind = "Skip" | "Skip5"

-- Devuelve (productId, robuxPrice, niveles que concede) de un skip. Los skips
-- son globales (`Products`); `season` se conserva en la firma por
-- compatibilidad con los llamadores y no se usa.
function BattlePassConfig.GetSkipOffer(_season: Season, kind: SkipKind): (number, number, number)
	local products = BattlePassConfig.Products
	if kind == "Skip5" then
		return products.Skip5ProductId, products.Skip5RobuxPrice, 5
	end
	return products.SkipProductId, products.SkipRobuxPrice, 1
end

-- Resuelve un productId a su (Season, kind). kind ∈ "Premium" | "Skip" | "Skip5".
-- Los skips resuelven SIEMPRE a la season activa (son globales); el premium
-- por Robux se busca primero en la activa y después en el resto (un receipt
-- reentregado tras cambiar de season sigue concediendo sobre la activa: ver
-- BattlePassService:ProcessReceipt). Devuelve (nil, nil) si el producto no
-- pertenece a ningún BattlePass.
export type ReceiptKind = "Premium" | SkipKind
function BattlePassConfig.ResolveReceipt(productId: number): (Season?, ReceiptKind?)
	if productId == 0 then
		return nil, nil
	end
	local products = BattlePassConfig.Products
	if products.SkipProductId == productId then
		return BattlePassConfig.GetActiveSeason(), "Skip"
	end
	if products.Skip5ProductId == productId then
		return BattlePassConfig.GetActiveSeason(), "Skip5"
	end
	local active = BattlePassConfig.GetActiveSeason()
	if active and active.PremiumProductId == productId then
		return active, "Premium"
	end
	for _, season in BattlePassConfig.Seasons do
		if season.PremiumProductId == productId then
			return season, "Premium"
		end
	end
	return nil, nil
end

return BattlePassConfig
