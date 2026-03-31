--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local LockerConfig = require(Shared.constants.LockerConfig) :: any

export type FusionSkinItem = {
	ItemKey: string,
	Name: string,
	Rarity: string,
	TextureID: string?,
	BaseColor: Color3?,
	Animated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponKey: string?,
	PreviewWeaponName: string?,
}

type SlotMap = { [string]: FusionSkinItem? }
type AmountMap = { [string]: number }
type InventorySnapshot = {
	WeaponSkinsByWeapon: {
		[string]: { [string]: { [string]: boolean } },
	}?,
}

export type FusionSkinInventory = {
	_itemsByKey: { [string]: FusionSkinItem },
	_slotAssignments: SlotMap,
	_ownedAmounts: AmountMap,
	_freeAmounts: AmountMap,
	BuildFromInventory: (self: FusionSkinInventory, inventory: InventorySnapshot?) -> (),
	SetSlotSkin: (self: FusionSkinInventory, slotId: string, skinKey: string) -> FusionSkinItem?,
	ClearSlot: (self: FusionSkinInventory, slotId: string) -> (),
	GetSlotSkin: (self: FusionSkinInventory, slotId: string) -> FusionSkinItem?,
	GetOccupiedRarity: (self: FusionSkinInventory) -> string?,
	GetAvailableItems: (self: FusionSkinInventory) -> { FusionSkinItem },
	GetFreeAmount: (self: FusionSkinInventory, skinKey: string) -> number,
	GetAssignedAmount: (self: FusionSkinInventory, skinKey: string) -> number,
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
		Name = tostring(definition.Name or itemKey),
		Rarity = tostring(definition.Rarity or "Common"),
		TextureID = if type(definition.TextureID) == "string" then definition.TextureID else nil,
		BaseColor = if typeof(definition.BaseColor) == "Color3" then definition.BaseColor else nil,
		Animated = definition.Animated == true,
		StudsPerTile = tonumber(definition.StudsPerTile),
		PreviewWeaponCategory = "Special",
		PreviewWeaponKey = "Default",
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
	self._itemsByKey = buildCatalog()
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
	if inventory and inventory.WeaponSkinsByWeapon then
		local wrapsByWeapon = inventory.WeaponSkinsByWeapon
		for _, wrapsByWeaponId in wrapsByWeapon do
			for _, ownedSkins in wrapsByWeaponId do
				for skinKey, isOwned in ownedSkins do
					if isOwned == true and self._itemsByKey[skinKey] then
						ownedAmounts[skinKey] = (ownedAmounts[skinKey] or 0) + 1
					end
				end
			end
		end
	end

	self._ownedAmounts = ownedAmounts

	local nextAssignments = {} :: SlotMap
	for slotId, assignedItem in self._slotAssignments do
		if assignedItem and (ownedAmounts[assignedItem.ItemKey] or 0) > 0 then
			nextAssignments[slotId] = assignedItem
		else
			nextAssignments[slotId] = nil
		end
	end
	self._slotAssignments = nextAssignments

	local freeAmounts = {} :: AmountMap
	for skinKey in self._itemsByKey do
		local ownedAmount = ownedAmounts[skinKey] or 0
		local assignedAmount = computeAssignedAmount(self._slotAssignments, skinKey)
		freeAmounts[skinKey] = math.max(0, ownedAmount - assignedAmount)
	end
	self._freeAmounts = freeAmounts
end

function FusionSkinInventory:SetSlotSkin(slotId: string, skinKey: string): FusionSkinItem?
	if not isFusionEligibleSkin(skinKey) then
		return nil
	end

	local targetSkin = self._itemsByKey[skinKey]
	if not targetSkin then
		return nil
	end

	local currentSkin = self._slotAssignments[slotId]
	if currentSkin and currentSkin.ItemKey == skinKey then
		return currentSkin
	end

	local occupiedRarity = self:GetOccupiedRarity()
	if occupiedRarity and targetSkin.Rarity ~= occupiedRarity then
		return nil
	end

	local availableCount = self._freeAmounts[skinKey] or 0
	if currentSkin then
		availableCount += 1
	end
	if availableCount <= 0 then
		return nil
	end

	self._slotAssignments[slotId] = targetSkin

	for keyedSkin in self._itemsByKey do
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

	for keyedSkin in self._itemsByKey do
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
	for skinKey, skinItem in self._itemsByKey do
		local amount = self._freeAmounts[skinKey] or 0
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
		return a.Name < b.Name
	end)

	return result
end

function FusionSkinInventory:GetFreeAmount(skinKey: string): number
	return self._freeAmounts[skinKey] or 0
end

function FusionSkinInventory:GetAssignedAmount(skinKey: string): number
	local ownedAmount = self._ownedAmounts[skinKey] or 0
	local freeAmount = self._freeAmounts[skinKey] or 0
	return math.max(0, ownedAmount - freeAmount)
end

return FusionSkinInventory
