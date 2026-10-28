--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
	isVIPExclusive: boolean,
	-- Texto del badge de la card: "VIP", o el número de un wrap limitado ("#127", lo pone
	-- LockerWrapsView). Sin él la card no lleva badge.
	SeasonLabel: string?,
	TextureID: string?,
	BaseColor: Color3?,
	Material: Enum.Material?,
	isAnimated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponId: string?,
	PreviewWeaponDisplayName: string?,
	-- Wrap de maestría (WrapMastery): no se compra, se gana con el arma.
	IsMasteryWrap: boolean?,
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

local function makeCatalogCacheKey(categoryKey: LockerCategoryKey, navKey: string): string
	return tostring(categoryKey) .. ":" .. tostring(navKey)
end

local function normalizeImageId(imageValue: any, fallback: string, catalogEmoteId: number?): string
	if type(imageValue) == "string" and imageValue ~= "" then
		return imageValue
	end

	if type(catalogEmoteId) == "number" and catalogEmoteId > 0 then
		return "rbxthumb://type=Asset&id=" .. tostring(catalogEmoteId) .. "&w=150&h=150"
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
			local isVIPExclusive = definition.isVIPExclusive == true

			table.insert(catalogItems, {
				qualifiedId = LockerConfig.makeQualifiedId(tostring(sourceCategory), tostring(itemId)),
				Category = tostring(sourceCategory),
				id = tostring(itemId),
				Name = tostring(definition.Name or itemId),
				Price = tonumber(definition.Price) or 0,
				Currency = if type(definition.Currency) == "string" then definition.Currency else nil,
				LevelRequired = math.max(0, tonumber(definition.LevelRequired) or 0),
				Rarity = tostring(definition.Rarity or "Common"),
				Image = normalizeImageId(definition.Image, self._defaultThumbnail, definition.CatalogEmoteId),
				CanPurchase = definition.CanPurchase == true,
				isVIPExclusive = isVIPExclusive,
				SeasonLabel = if isVIPExclusive then "VIP" else nil,
				TextureID = if type(definition.TextureID) == "string" then definition.TextureID else nil,
				BaseColor = if typeof(definition.BaseColor) == "Color3" then definition.BaseColor else nil,
				Material = if typeof(definition.Material) == "EnumItem" and definition.Material.EnumType == Enum.Material then definition.Material else nil,
				isAnimated = definition.isAnimated == true,
				StudsPerTile = tonumber(definition.StudsPerTile),
				IsMasteryWrap = WrapMastery.isMasteryWrap(tostring(itemId)),
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

	-- Items exclusivos del VIP: ocultos hasta poseerlos. La invalidación
	-- de _sortedCache vía InvalidateSorted() (al cambiar Inventory) reconstruye
	-- la lista cuando uno entra al inventario.
	-- Salvo en Wraps: su posesión depende del arma objetivo del momento y la clave de caché
	-- no la incluye; LockerWrapsView.build ya filtra por lo que posee esa arma.
	local isWrapsNav = categoryKey == LockerMainCategory.ARSENAL and navKey == LockerCategory.WEAPON_WRAPS
	local catalogItems = {} :: { LockerCatalogItem }
	for _, item in templateItems do
		if not isWrapsNav and item.isVIPExclusive and not self._isItemOwned(item) then
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

		-- Los borders van todos a precio 0: sin esto "Border 10" saldría antes que "Border 2".
		if a.LevelRequired ~= b.LevelRequired then
			return a.LevelRequired < b.LevelRequired
		end

		return a.Name < b.Name
	end)

	self._sortedCache[cacheKey] = catalogItems

	return catalogItems
end

return LockerCatalog
