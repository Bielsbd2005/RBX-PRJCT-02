--!strict
--[[
	API de temporadas, tiers y recompensas del Battle Pass. Los datos viven en
	`BattlePassSeasons.luau` (generado por el dashboard de Telemetry): aquí solo se
	construyen los tiers y se resuelve `ActiveSeasonId`.

	  • Cada nivel tiene una sola recompensa, FREE o PASS (PASS requiere PremiumOwned).
	  • Activar otra season = mover `ActiveSeasonId`; los perfiles se resetean al no
	    coincidir su SeasonId (BattlePassService._ensureSeason).
	  • Las recompensas se leen en vivo en cada claim, no se guardan en el perfil.
	  • Reward Item: Category + ItemId deben existir en ItemsConfig.
	  • El premium se compra con Gems (PremiumGemPrice). Los skips (+1/+5) son
	    developer products globales (`Products`); ProductId = 0 = sin crear en el
	    panel de Roblox (botón inactivo, el receipt no matchea).
]]

export type RewardKind = "Cash" | "Gems" | "Item"

export type Reward = {
	Kind: RewardKind,
	Amount: number?,    -- Cash o Gems
	Category: string?,  -- Item: "Hats" | "Faces" | "KillEffects" | "Outfits" | "Banners" | "Main" | "Special" | "WeaponWraps"
	ItemId: string?,    -- Item: id en ItemsConfig
	Icon: string?,      -- Override de UI (rbxassetid://...). Si nil, fallback a ItemsConfig.
	Label: string?,     -- Override del texto. Si nil, fallback a "+Amount" o ItemsConfig.Name.
	-- WeaponWraps, modos excluyentes: Global = true (todas las armas) o WeaponCategory + WeaponId.
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
	-- Sellos ISO 8601 del dashboard, solo informativos: sin PublishedAt = borrador.
	-- La activa es siempre la del puntero.
	PublishedAt: string?,
	EndedAt: string?,
	EndsAt: number,             -- Unix timestamp del fin de season (fuente del timer del HUD). 0 = sin contador.
	-- Descontado de Stats.Gems en un BatchUpdate atómico. 0 = no comprable.
	PremiumGemPrice: number,
	-- Flujo Robux directo antiguo, dormido con ProductId = 0; se conserva por si vuelve en una promo.
	PremiumProductId: number,
	PremiumRobuxPrice: number,
	Tiers: { Tier },            -- contiguos, Level == índice
}

-- RobuxPrice debe coincidir con el del panel de Roblox (se pinta y va a analytics).
export type Products = {
	SkipProductId: number,
	SkipRobuxPrice: number,
	Skip5ProductId: number,
	Skip5RobuxPrice: number,
}

local ActionRewards = require(script.Parent:WaitForChild("ActionRewards"))
local BattlePassSeasons = require(script.Parent:WaitForChild("BattlePassSeasons")) :: any

local BattlePassConfig = {}

-- El XP del pase solo viene de kills, nunca del XP de nivel de cuenta.
BattlePassConfig.XPRates = {
	PerKill = ActionRewards.GetXP("Kill"),
}

BattlePassConfig.RewardIcons = {
	Cash = "rbxassetid://113694528712529",
	-- TODO: subir el icono de Gems. Vacío a propósito: sin icono la UI caería al de
	-- Cash y confundiría las monedas.
	Gems = "",
}

local function _toNumber(value: any, fallback: number): number
	return if type(value) == "number" then value else fallback
end

local function _toString(value: any, fallback: string): string
	return if type(value) == "string" then value else fallback
end

local function _optionalString(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

-- Ausente o inválido → 0 (el HUD oculta el contador).
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

function BattlePassConfig.GetSeasonById(id: string): Season?
	return _seasonById[id]
end

-- Si el puntero no resuelve, se cae a la primera season de la lista.
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

-- Exclusivo = aparece en algún tier (de cualquier season, incluidos borradores y
-- pasadas) y no se consigue de otra forma. Un ítem comprable (CanPurchase) o de
-- KillChallenge que también esté en el pase no es exclusivo: marcarlo lo volvería
-- incomprable en ShopService e invisible en LockerCatalog.
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

export type SkipKind = "Skip" | "Skip5"

-- Devuelve (productId, robuxPrice, niveles). `_season` no se usa: los skips son globales.
function BattlePassConfig.GetSkipOffer(_season: Season, kind: SkipKind): (number, number, number)
	local products = BattlePassConfig.Products
	if kind == "Skip5" then
		return products.Skip5ProductId, products.Skip5RobuxPrice, 5
	end
	return products.SkipProductId, products.SkipRobuxPrice, 1
end

-- Devuelve (nil, nil) si el producto no es del pase. Los skips resuelven siempre a
-- la season activa; el premium busca primero en la activa.
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
