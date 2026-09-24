--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BattlePassConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("BattlePassConfig"))
local LockerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerConfig"))
local WrapMastery = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("data"):WaitForChild("WrapMastery"))

local LockerMainCategory = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerMainCategory"))
local LockerCategory = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerCategory"))

type LockerCategoryKey = LockerMainCategory.LockerMainCategory

export type LockerCatalogItem = {
	qualifiedId: string,
	Category: string,
	id: string,
	Name: string,
	Price: number,
	Currency: string?,
	LevelRequired: number,
	Rarity: string,
	Image: string,
	CanPurchase: boolean,
	isBPExclusive: boolean,
	isVIPExclusive: boolean,
	-- Temporada del pase que lo regaló (proyección `Season` de ItemsConfig, la escribe
	-- el dashboard). Sin ella el ítem viene de la tienda y no lleva badge.
	Season: string?,
	-- Texto del badge de la card: "S1", "S2"… derivado de la season, o "VIP".
	SeasonLabel: string?,
	TextureID: string?,
	BaseColor: Color3?,
	Material: Enum.Material?,
	isAnimated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponId: string?,
	PreviewWeaponDisplayName: string?,
	KillGoal: number?,
	MasteryScope: string?,
	-- Vista Maestry, desafío sin desbloquear: progreso/objetivo que muestra la card.
	ChallengeProgress: number?,
	ChallengeGoal: number?,
	-- Vista Maestry: desafío ya desbloqueado; muestra "UNLOCKED" en vez del progreso.
	ChallengeUnlocked: boolean?,
}

export type LockerCatalog = {
	_itemsConfig: any,
	_itemsConfigByNav: { [LockerCategoryKey]: { [string]: string } },
	_defaultThumbnail: string,
	_templateCache: { [string]: { LockerCatalogItem } },
	_sortedCache: { [string]: { LockerCatalogItem } },
	_getRarityRank: (string) -> number,
	_isItemOwned: (LockerCatalogItem) -> boolean,
	_getTemplateItems: (self: LockerCatalog, categoryKey: LockerCategoryKey, navKey: string) -> { LockerCatalogItem },
	InvalidateSorted: (self: LockerCatalog) -> (),
	GetItems: (self: LockerCatalog, categoryKey: LockerCategoryKey, navKey: string) -> { LockerCatalogItem },
}

local EMPTY_CATALOG_ITEMS = table.freeze({}) :: { LockerCatalogItem }

local LockerCatalog = {}
LockerCatalog.__index = LockerCatalog

-- Código corto de temporada para el badge de la card ("S1"). El Id de la season
-- ya viene con ese formato desde el dashboard; si no encaja, se reconstruye con
-- el primer número que aparezca en el Id o en el Name.
local function formatSeasonCode(seasonId: string, seasonName: string?): string
	local upperId = string.upper(seasonId)
	if string.match(upperId, "^S%d+$") then
		return upperId
	end
	local number = string.match(seasonId, "%d+") or (if seasonName then string.match(seasonName, "%d+") else nil)
	return if number then "S" .. number else upperId
end

local function makeCatalogCacheKey(categoryKey: LockerCategoryKey, navKey: string): string
	return tostring(categoryKey) .. ":" .. tostring(navKey)
end

local function normalizeImageId(imageValue: any, fallback: string): string
	if type(imageValue) == "string" and imageValue ~= "" then
		return imageValue
	end

	return fallback
end

function LockerCatalog.new(
	itemsConfig: any,
	itemsConfigByNav: { [LockerCategoryKey]: { [string]: string } },
	defaultThumbnail: string,
	getRarityRank: (string) -> number,
	isItemOwned: (LockerCatalogItem) -> boolean
): LockerCatalog
	local self = setmetatable({}, LockerCatalog) :: any
	self._itemsConfig = itemsConfig
	self._itemsConfigByNav = itemsConfigByNav
	self._defaultThumbnail = defaultThumbnail
	self._templateCache = {}
	self._sortedCache = {}
	self._getRarityRank = getRarityRank
	self._isItemOwned = isItemOwned
	return self
end

function LockerCatalog:_getTemplateItems(categoryKey: LockerCategoryKey, navKey: string): { LockerCatalogItem }
	local cacheKey = makeCatalogCacheKey(categoryKey, navKey)
	local cachedItems = self._templateCache[cacheKey]
	if cachedItems then
		return cachedItems
	end

	local categoryMap = self._itemsConfigByNav[categoryKey]
	local sourceCategory = categoryMap and categoryMap[navKey]
	if not sourceCategory then
		self._templateCache[cacheKey] = EMPTY_CATALOG_ITEMS
		return EMPTY_CATALOG_ITEMS
	end

	local sourceItems = self._itemsConfig[sourceCategory]
	if type(sourceItems) ~= "table" then
		self._templateCache[cacheKey] = EMPTY_CATALOG_ITEMS
		return EMPTY_CATALOG_ITEMS
	end

	local catalogItems = {} :: { LockerCatalogItem }
	for itemId, definition in sourceItems do
		if type(definition) == "table" then
			local killGoalValue: number? = nil
			local killChallenge = definition.KillChallenge
			if type(killChallenge) == "table" then
				local kills = tonumber((killChallenge :: any).Kills)
				if kills and kills > 0 then
					killGoalValue = math.floor(kills)
				end
			end

			local seasonId: string? = if type(definition.Season) == "string" and definition.Season ~= ""
				then definition.Season
				else nil
			local isVIPExclusive = definition.isVIPExclusive == true
			local seasonLabel: string? = if isVIPExclusive then "VIP" else nil
			if seasonId and not isVIPExclusive then
				local seasonDef = BattlePassConfig.GetSeasonById(seasonId)
				seasonLabel = formatSeasonCode(seasonId, if seasonDef then seasonDef.Name else nil)
			end

			table.insert(catalogItems, {
				qualifiedId = LockerConfig.makeQualifiedId(tostring(sourceCategory), tostring(itemId)),
				Category = tostring(sourceCategory),
				id = tostring(itemId),
				Name = tostring(definition.Name or itemId),
				Price = tonumber(definition.Price) or 0,
				Currency = if type(definition.Currency) == "string" then definition.Currency else nil,
				LevelRequired = math.max(0, tonumber(definition.LevelRequired) or 0),
				Rarity = tostring(definition.Rarity or "Common"),
				Image = normalizeImageId(definition.Image, self._defaultThumbnail),
				CanPurchase = definition.CanPurchase == true,
				-- BP-exclusive si lo flagea ItemsConfig O si es reward de cualquier season del pase.
				isBPExclusive = definition.isBPExclusive == true
					or BattlePassConfig.IsBPExclusive(tostring(sourceCategory), tostring(itemId)),
				isVIPExclusive = isVIPExclusive,
				Season = seasonId,
				SeasonLabel = seasonLabel,
				TextureID = if type(definition.TextureID) == "string" then definition.TextureID else nil,
				BaseColor = if typeof(definition.BaseColor) == "Color3" then definition.BaseColor else nil,
				Material = if typeof(definition.Material) == "EnumItem" and definition.Material.EnumType == Enum.Material then definition.Material else nil,
				isAnimated = definition.isAnimated == true,
				StudsPerTile = tonumber(definition.StudsPerTile),
				KillGoal = killGoalValue,
				MasteryScope = WrapMastery.scopeOf(tostring(itemId)),
			})
		end
	end

	self._templateCache[cacheKey] = table.freeze(catalogItems)
	return self._templateCache[cacheKey]
end

function LockerCatalog:InvalidateSorted(): ()
	table.clear(self._sortedCache)
end

function LockerCatalog:GetItems(categoryKey: LockerCategoryKey, navKey: string): { LockerCatalogItem }
	local cacheKey = makeCatalogCacheKey(categoryKey, navKey)
	local cachedItems = self._sortedCache[cacheKey]
	if cachedItems then
		return cachedItems
	end

	local templateItems = self:_getTemplateItems(categoryKey, navKey)
	if templateItems == EMPTY_CATALOG_ITEMS then
		return EMPTY_CATALOG_ITEMS
	end

	-- Items exclusivos del Battle Pass o del VIP: ocultos hasta poseerlos. La invalidación
	-- de _sortedCache vía InvalidateSorted() (al cambiar Inventory) reconstruye
	-- la lista cuando un item BP entra al inventario.
	-- Salvo en Wraps: su posesión depende del arma objetivo del momento y la clave de caché
	-- no la incluye; LockerWrapsView.build ya filtra por lo que posee esa arma.
	local isWrapsNav = categoryKey == LockerMainCategory.ARSENAL and navKey == LockerCategory.WEAPON_WRAPS
	local catalogItems = {} :: { LockerCatalogItem }
	for _, item in templateItems do
		if not isWrapsNav and (item.isBPExclusive or item.isVIPExclusive) and not self._isItemOwned(item) then
			continue
		end
		table.insert(catalogItems, item)
	end

	table.sort(catalogItems, function(a, b)
		local aOwned = self._isItemOwned(a)
		local bOwned = self._isItemOwned(b)
		if aOwned ~= bOwned then
			return aOwned
		end

		if a.Price ~= b.Price then
			return a.Price < b.Price
		end

		return a.Name < b.Name
	end)

	self._sortedCache[cacheKey] = catalogItems

	return catalogItems
end

return LockerCatalog
