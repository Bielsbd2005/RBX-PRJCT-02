--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local LockerConfig = require(Shared.constants.LockerConfig) :: any

export type FusionSkinItem = {
	ItemKey: string,
	BaseSkinKey: string,
	Name: string,
	Rarity: string,
	TextureID: string?,
	BaseColor: Color3?,
	Animated: boolean?,
	StudsPerTile: number?,
	WeaponCategory: string?,
	WeaponId: string?,
	PreviewWeaponCategory: string?,
	PreviewWeaponKey: string?,
	PreviewWeaponName: string?,
}

type SlotMap = { [string]: FusionSkinItem? }
type AmountMap = { [string]: number }
type InventorySnapshot = {
	WeaponSkinsByWeapon: {
		[string]: { [string]: { [string]: number | boolean } },
	}?,
}

export type FusionSkinInventory = {
	_baseCatalogBySkinKey: { [string]: FusionSkinItem },
	_stackCatalogByItemKey: { [string]: FusionSkinItem },
	_slotAssignments: SlotMap,
	_ownedAmounts: AmountMap,
	_freeAmounts: AmountMap,
	BuildFromInventory: (self: FusionSkinInventory, inventory: InventorySnapshot?) -> (),
	SetSlotSkin: (self: FusionSkinInventory, slotId: string, itemKey: string) -> FusionSkinItem?,
	ClearSlot: (self: FusionSkinInventory, slotId: string) -> (),
	GetSlotSkin: (self: FusionSkinInventory, slotId: string) -> FusionSkinItem?,
	GetOccupiedRarity: (self: FusionSkinInventory) -> string?,
	GetAvailableItems: (self: FusionSkinInventory) -> { FusionSkinItem },
	GetFreeAmount: (self: FusionSkinInventory, itemKey: string) -> number,
	GetAssignedAmount: (self: FusionSkinInventory, itemKey: string) -> number,
}

local RARITY_RANK = LockerConfig.RarityRank :: { [string]: number }
local NON_FUSIONABLE_SKIN_KEYS = {
	Default = true,
} :: { [string]: boolean }

local function isFusionEligibleSkin(skinKey: string): boolean
	return NON_FUSIONABLE_SKIN_KEYS[skinKey] ~= true
end

local function toSkinItem(itemKey: string, definition: any): FusionSkinItem
	return {
		ItemKey = itemKey,
		BaseSkinKey = itemKey,
		Name = tostring(definition.Name or itemKey),
		Rarity = tostring(definition.Rarity or "Common"),
		TextureID = if type(definition.TextureID) == "string" then definition.TextureID else nil,
		BaseColor = if typeof(definition.BaseColor) == "Color3" then definition.BaseColor else nil,
		Animated = definition.Animated == true,
		StudsPerTile = tonumber(definition.StudsPerTile),
		WeaponCategory = nil,
		WeaponId = nil,
		PreviewWeaponCategory = nil,
		PreviewWeaponKey = nil,
		PreviewWeaponName = nil,
	}
end

local function buildCatalog(): { [string]: FusionSkinItem }
	local skins = ItemsConfig.WeaponSkins
	local catalog = {} :: { [string]: FusionSkinItem }

	for skinKey, definition in skins do
		if type(definition) == "table" and isFusionEligibleSkin(skinKey) then
			catalog[skinKey] = toSkinItem(skinKey, definition)
		end
	end

	return catalog
end

local function resolveOwnedAmount(rawValue: number | boolean): number
	if rawValue == true then
		return 1
	end

	if type(rawValue) == "number" and rawValue > 0 then
		return math.max(1, math.floor(rawValue))
	end

	return 0
end

local function makeStackItemKey(weaponCategory: string, weaponId: string, baseSkinKey: string): string
	return string.format("%s|%s|%s", weaponCategory, weaponId, baseSkinKey)
end

local function resolveWeaponDisplayName(weaponCategory: string, weaponId: string): string
	local categoryConfig = ItemsConfig[weaponCategory]
	if type(categoryConfig) == "table" then
		local weaponConfig = categoryConfig[weaponId]
		if type(weaponConfig) == "table" and type(weaponConfig.Name) == "string" and weaponConfig.Name ~= "" then
			return weaponConfig.Name
		end
	end

	return weaponId
end

local function toStackItem(baseItem: FusionSkinItem, weaponCategory: string, weaponId: string): FusionSkinItem
	local weaponDisplayName = resolveWeaponDisplayName(weaponCategory, weaponId)
	return {
		ItemKey = makeStackItemKey(weaponCategory, weaponId, baseItem.BaseSkinKey),
		BaseSkinKey = baseItem.BaseSkinKey,
		Name = string.format("%s (%s)", baseItem.Name, weaponDisplayName),
		Rarity = baseItem.Rarity,
		TextureID = baseItem.TextureID,
		BaseColor = baseItem.BaseColor,
		Animated = baseItem.Animated,
		StudsPerTile = baseItem.StudsPerTile,
		WeaponCategory = weaponCategory,
		WeaponId = weaponId,
		PreviewWeaponCategory = weaponCategory,
		PreviewWeaponKey = weaponId,
		PreviewWeaponName = weaponDisplayName,
	}
end

local function computeAssignedAmount(slotAssignments: SlotMap, skinKey: string): number
	local amount = 0
	for _, assignedSkin in slotAssignments do
		if assignedSkin and assignedSkin.ItemKey == skinKey then
			amount += 1
		end
	end
	return amount
end

local FusionSkinInventory = {}
FusionSkinInventory.__index = FusionSkinInventory

function FusionSkinInventory.new(slotIds: { string }): FusionSkinInventory
	local self = setmetatable({}, FusionSkinInventory) :: any
	self._baseCatalogBySkinKey = buildCatalog()
	self._stackCatalogByItemKey = {}
	self._slotAssignments = {}
	self._ownedAmounts = {}
	self._freeAmounts = {}

	for _, slotId in slotIds do
		self._slotAssignments[slotId] = nil
	end

	return self
end

function FusionSkinInventory:BuildFromInventory(inventory: InventorySnapshot?): ()
	local ownedAmounts = {} :: AmountMap
	local stackCatalogByItemKey = {} :: { [string]: FusionSkinItem }
	if inventory and inventory.WeaponSkinsByWeapon then
		local wrapsByWeapon = inventory.WeaponSkinsByWeapon
		for weaponCategory, wrapsByWeaponId in wrapsByWeapon do
			for weaponId, ownedSkins in wrapsByWeaponId do
				for skinKey, ownedValue in ownedSkins do
					local baseItem = self._baseCatalogBySkinKey[skinKey]
					local ownedAmount = resolveOwnedAmount(ownedValue)
					if ownedAmount > 0 and baseItem then
						local stackItem = toStackItem(baseItem, weaponCategory, weaponId)
						stackCatalogByItemKey[stackItem.ItemKey] = stackItem
						ownedAmounts[stackItem.ItemKey] = ownedAmount
					end
				end
			end
		end
	end

	self._stackCatalogByItemKey = stackCatalogByItemKey
	self._ownedAmounts = ownedAmounts

	local nextAssignments = {} :: SlotMap
	for slotId, assignedItem in self._slotAssignments do
		if assignedItem and (ownedAmounts[assignedItem.ItemKey] or 0) > 0 then
			nextAssignments[slotId] = stackCatalogByItemKey[assignedItem.ItemKey]
		else
			nextAssignments[slotId] = nil
		end
	end
	self._slotAssignments = nextAssignments

	local freeAmounts = {} :: AmountMap
	for itemKey in self._stackCatalogByItemKey do
		local ownedAmount = ownedAmounts[itemKey] or 0
		local assignedAmount = computeAssignedAmount(self._slotAssignments, itemKey)
		freeAmounts[itemKey] = math.max(0, ownedAmount - assignedAmount)
	end
	self._freeAmounts = freeAmounts
end

function FusionSkinInventory:SetSlotSkin(slotId: string, itemKey: string): FusionSkinItem?
	local targetSkin = self._stackCatalogByItemKey[itemKey]
	if not targetSkin then
		return nil
	end

	if not isFusionEligibleSkin(targetSkin.BaseSkinKey) then
		return nil
	end

	local currentSkin = self._slotAssignments[slotId]
	if currentSkin and currentSkin.ItemKey == itemKey then
		return currentSkin
	end

	local occupiedRarity = self:GetOccupiedRarity()
	if occupiedRarity and targetSkin.Rarity ~= occupiedRarity then
		return nil
	end

	local availableCount = self._freeAmounts[itemKey] or 0
	if currentSkin then
		availableCount += 1
	end
	if availableCount <= 0 then
		return nil
	end

	self._slotAssignments[slotId] = targetSkin

	for keyedSkin in self._stackCatalogByItemKey do
		local ownedAmount = self._ownedAmounts[keyedSkin] or 0
		local assignedAmount = computeAssignedAmount(self._slotAssignments, keyedSkin)
		self._freeAmounts[keyedSkin] = math.max(0, ownedAmount - assignedAmount)
	end

	return targetSkin
end

function FusionSkinInventory:ClearSlot(slotId: string): ()
	if self._slotAssignments[slotId] == nil then
		return
	end

	self._slotAssignments[slotId] = nil

	for keyedSkin in self._stackCatalogByItemKey do
		local ownedAmount = self._ownedAmounts[keyedSkin] or 0
		local assignedAmount = computeAssignedAmount(self._slotAssignments, keyedSkin)
		self._freeAmounts[keyedSkin] = math.max(0, ownedAmount - assignedAmount)
	end
end

function FusionSkinInventory:GetSlotSkin(slotId: string): FusionSkinItem?
	return self._slotAssignments[slotId]
end

function FusionSkinInventory:GetOccupiedRarity(): string?
	for _, assignedSkin in self._slotAssignments do
		if assignedSkin then
			return assignedSkin.Rarity
		end
	end
	return nil
end

function FusionSkinInventory:GetAvailableItems(): { FusionSkinItem }
	local occupiedRarity = self:GetOccupiedRarity()
	local result = {} :: { FusionSkinItem }
	for itemKey, skinItem in self._stackCatalogByItemKey do
		local amount = self._freeAmounts[itemKey] or 0
		if amount > 0 and (occupiedRarity == nil or skinItem.Rarity == occupiedRarity) then
			table.insert(result, skinItem)
		end
	end

	table.sort(result, function(a, b)
		local rarityA = RARITY_RANK[a.Rarity] or 0
		local rarityB = RARITY_RANK[b.Rarity] or 0
		if rarityA ~= rarityB then
			return rarityA > rarityB
		end

		if a.PreviewWeaponCategory ~= b.PreviewWeaponCategory then
			return tostring(a.PreviewWeaponCategory or "") < tostring(b.PreviewWeaponCategory or "")
		end

		if a.PreviewWeaponName ~= b.PreviewWeaponName then
			return tostring(a.PreviewWeaponName or "") < tostring(b.PreviewWeaponName or "")
		end

		return a.Name < b.Name
	end)

	return result
end

function FusionSkinInventory:GetFreeAmount(itemKey: string): number
	return self._freeAmounts[itemKey] or 0
end

function FusionSkinInventory:GetAssignedAmount(itemKey: string): number
	local ownedAmount = self._ownedAmounts[itemKey] or 0
	local freeAmount = self._freeAmounts[itemKey] or 0
	return math.max(0, ownedAmount - freeAmount)
end

return FusionSkinInventory
