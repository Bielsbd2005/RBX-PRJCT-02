--!strict

type LockerCategoryKey = "Style" | "Arsenal" | "Effects"

export type LockerCatalogItem = {
	Id: string,
	Category: string,
	ItemKey: string,
	Name: string,
	Price: number,
	LevelRequired: number,
	Rarity: string,
	Image: string,
	CanPurchase: boolean,
	TextureID: string?,
	BaseColor: Color3?,
	Animated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponKey: string?,
	PreviewWeaponName: string?,
}

type CatalogCacheEntry = {
	version: number,
	items: { LockerCatalogItem },
}

export type LockerCatalog = {
	_itemsConfig: any,
	_itemsConfigByNav: { [LockerCategoryKey]: { [string]: string } },
	_defaultThumbnail: string,
	_templateCache: { [string]: { LockerCatalogItem } },
	_sortedCache: { [string]: CatalogCacheEntry },
	_inventoryVersion: number,
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

local function normalizeImageId(imageValue: any, fallback: string): string
	if type(imageValue) == "string" then
		if imageValue == "" then
			return fallback
		end

		if string.find(imageValue, "rbxassetid://", 1, true) == 1 then
			return imageValue
		end

		local numericFromString = tonumber(imageValue)
		if numericFromString then
			return "rbxassetid://" .. tostring(math.floor(numericFromString))
		end

		return imageValue
	end

	if type(imageValue) == "number" then
		return "rbxassetid://" .. tostring(math.floor(imageValue))
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
	self._inventoryVersion = 0
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
			table.insert(catalogItems, {
				Id = tostring(sourceCategory) .. "." .. tostring(itemId),
				Category = tostring(sourceCategory),
				ItemKey = tostring(itemId),
				Name = tostring(definition.Name or itemId),
				Price = tonumber(definition.Price) or 0,
				LevelRequired = math.max(0, tonumber(definition.LevelRequired) or 0),
				Rarity = tostring(definition.Rarity or "Common"),
				Image = normalizeImageId(definition.Image, self._defaultThumbnail),
				CanPurchase = definition.CanPurchase == true,
				TextureID = if type(definition.TextureID) == "string" then definition.TextureID else nil,
				BaseColor = if typeof(definition.BaseColor) == "Color3" then definition.BaseColor else nil,
				Animated = definition.Animated == true,
				StudsPerTile = tonumber(definition.StudsPerTile),
			})
		end
	end

	self._templateCache[cacheKey] = table.freeze(catalogItems)
	return self._templateCache[cacheKey]
end

function LockerCatalog:InvalidateSorted(): ()
	self._inventoryVersion += 1
	table.clear(self._sortedCache)
end

function LockerCatalog:GetItems(categoryKey: LockerCategoryKey, navKey: string): { LockerCatalogItem }
	local cacheKey = makeCatalogCacheKey(categoryKey, navKey)
	local cachedEntry = self._sortedCache[cacheKey]
	if cachedEntry and cachedEntry.version == self._inventoryVersion then
		return cachedEntry.items
	end

	local templateItems = self:_getTemplateItems(categoryKey, navKey)
	if templateItems == EMPTY_CATALOG_ITEMS then
		return EMPTY_CATALOG_ITEMS
	end

	local catalogItems = table.clone(templateItems)

	table.sort(catalogItems, function(a, b)
		if a.LevelRequired ~= b.LevelRequired then
			return a.LevelRequired < b.LevelRequired
		end

		if a.Price ~= b.Price then
			return a.Price < b.Price
		end

		return a.Name < b.Name
	end)

	self._sortedCache[cacheKey] = {
		version = self._inventoryVersion,
		items = catalogItems,
	}

	return catalogItems
end

return LockerCatalog
