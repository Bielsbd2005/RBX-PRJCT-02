--!strict
--[[
	Estado de inventario y loadout que lee el Locker, sin GUI: qué posee el jugador,
	qué lleva equipado y sobre qué arma se miran los wraps. Los lookups se reconstruyen
	desde DataController con rebuildOwned / rebuildEquipped; el feature los llama al
	cambiar Inventory o Loadout.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Fusion = require(ReplicatedStorage:WaitForChild("Packages").fusion) :: any
local DataController = require(script.Parent.Parent.Parent.core.data.DataController)
local LockerConfig = require(Shared.constants.LockerConfig)
local LockerCategory = require(Shared.constants.LockerCategory)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local LoadoutWraps = require(Shared.data.LoadoutWraps)
local LockerCatalog = require(script.Parent.LockerCatalog)

type WeaponCategory = WeaponCategoryMod.WeaponCategory
type LockerCatalogItem = LockerCatalog.LockerCatalogItem

export type LoadoutData = { [string]: string? }
export type StatsData = { Level: number, Cash: number, Gems: number? }

type InventoryData = {
	[string]: { [string]: boolean },
	WeaponWrapsByWeapon: {
		Main: { [string]: { [string]: number | boolean } },
		Special: { [string]: { [string]: number | boolean } },
	}?,
}

local CATEGORY_TO_LOADOUT_SLOT = LockerConfig.CategoryToLoadoutSlot :: { [string]: string }

local function optionalString(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

export type LockerInventoryState = {
	getLoadout: (self: LockerInventoryState) -> LoadoutData,
	getStats: (self: LockerInventoryState) -> StatsData,
	getLevel: (self: LockerInventoryState) -> number,
	rebuildOwned: (self: LockerInventoryState) -> (),
	rebuildEquipped: (self: LockerInventoryState) -> (),
	isOwned: (self: LockerInventoryState, category: string, itemId: string) -> boolean,
	ownsWrap: (self: LockerInventoryState, weaponCategory: string, weaponId: string, wrapId: string) -> boolean,
	countOwnedWraps: (self: LockerInventoryState, weaponCategory: WeaponCategory, weaponId: string) -> number,
	getEquipped: (self: LockerInventoryState, category: string) -> string?,
	getEquippedWeapon: (self: LockerInventoryState, category: WeaponCategory) -> string,
	resolveEquippedWrap: (self: LockerInventoryState, loadout: LoadoutData, weaponCategory: WeaponCategory, weaponId: string?) -> string,
	getWrapsTargetCategory: (self: LockerInventoryState) -> WeaponCategory,
	setWrapsTarget: (self: LockerInventoryState, weaponCategory: WeaponCategory, weaponId: string?) -> (),
	getWrapsTargetWeaponId: (self: LockerInventoryState, loadout: LoadoutData?) -> string,
	getWrapRequestContext: (self: LockerInventoryState, category: string) -> (string, string),
	getWeaponKills: (self: LockerInventoryState, weaponCategory: WeaponCategory, weaponId: string) -> number,
	isItemOwned: (self: LockerInventoryState, item: LockerCatalogItem) -> boolean,
	isItemEquipped: (self: LockerInventoryState, item: LockerCatalogItem) -> boolean,
}

type Internal = LockerInventoryState & {
	_onOwnedRebuilt: () -> (),
	_owned: { [string]: { [string]: boolean } },
	_ownedWrapsByWeapon: { [WeaponCategory]: { [string]: { [string]: number } } },
	_equipped: { [string]: string },
	_wrapsTargetCategory: WeaponCategory,
	_wrapsTargetWeaponIdByCategory: { [WeaponCategory]: string },
}

local LockerInventoryState = {}
LockerInventoryState.__index = LockerInventoryState

-- onOwnedRebuilt: tras reconstruir la posesión (el catálogo invalida su orden).
function LockerInventoryState.new(onOwnedRebuilt: () -> ()): LockerInventoryState
	local self = setmetatable({
		_onOwnedRebuilt = onOwnedRebuilt,
		_owned = {},
		_ownedWrapsByWeapon = { Main = {}, Special = {} },
		_equipped = {},
		_wrapsTargetCategory = WeaponCategoryMod.MAIN,
		_wrapsTargetWeaponIdByCategory = { Main = "", Special = "" },
	}, LockerInventoryState) :: any
	return self
end

function LockerInventoryState.getLoadout(_self: Internal): LoadoutData
	return Fusion.peek(DataController.Loadout) :: LoadoutData
end

function LockerInventoryState.getStats(_self: Internal): StatsData
	return Fusion.peek(DataController.Stats) :: StatsData
end

function LockerInventoryState.getLevel(self: Internal): number
	return math.max(0, math.floor(tonumber(self:getStats().Level) or 0))
end

function LockerInventoryState.rebuildOwned(self: Internal)
	local inventory = Fusion.peek(DataController.Inventory) :: InventoryData
	local nextOwned = {} :: { [string]: { [string]: boolean } }
	local nextWrapsByWeapon = { Main = {}, Special = {} } :: { [WeaponCategory]: { [string]: { [string]: number } } }

	for category, items in inventory do
		if category == "WeaponWrapsByWeapon" then
			for weaponCategory, weaponEntriesAny in items :: any do
				if WeaponCategoryMod.isValid(weaponCategory) then
					local weaponEntries = weaponEntriesAny :: { [string]: { [string]: number | boolean } }
					local categoryWrapLookup = nextWrapsByWeapon[weaponCategory :: WeaponCategory]
					for weaponId, ownedWrapsAny in weaponEntries do
						if type(ownedWrapsAny) == "table" then
							local wrapLookup = {} :: { [string]: number }
							for wrapId, wrapOwned in ownedWrapsAny do
								if wrapOwned == true then
									wrapLookup[wrapId] = 1
								elseif type(wrapOwned) == "number" and wrapOwned > 0 then
									wrapLookup[wrapId] = math.max(1, math.floor(wrapOwned))
								end
							end
							categoryWrapLookup[weaponId] = wrapLookup
						end
					end
				end
			end
		elseif category ~= LockerCategory.WEAPON_WRAPS then
			local categoryLookup = {} :: { [string]: boolean }
			for itemId, owned in items do
				if owned == true then
					categoryLookup[itemId] = true
				end
			end
			nextOwned[category] = categoryLookup
		end
	end

	self._owned = nextOwned
	self._ownedWrapsByWeapon = nextWrapsByWeapon
	self._onOwnedRebuilt()
end

function LockerInventoryState.rebuildEquipped(self: Internal)
	local loadout = self:getLoadout()
	local nextEquipped = {} :: { [string]: string }
	for category, slot in CATEGORY_TO_LOADOUT_SLOT do
		local equippedItem = optionalString(loadout[slot])
		if equippedItem then
			nextEquipped[category] = equippedItem
		end
	end
	self._equipped = nextEquipped
end

function LockerInventoryState.isOwned(self: Internal, category: string, itemId: string): boolean
	local categoryLookup = self._owned[category]
	return categoryLookup ~= nil and categoryLookup[itemId] == true
end

function LockerInventoryState.ownsWrap(self: Internal, weaponCategory: string, weaponId: string, wrapId: string): boolean
	local categoryLookup = self._ownedWrapsByWeapon[weaponCategory :: WeaponCategory]
	local weaponLookup = categoryLookup and categoryLookup[weaponId]
	return weaponLookup ~= nil and (weaponLookup[wrapId] or 0) > 0
end

-- Wraps poseídos para un arma, SIN contar el Default.
function LockerInventoryState.countOwnedWraps(self: Internal, weaponCategory: WeaponCategory, weaponId: string): number
	local categoryLookup = self._ownedWrapsByWeapon[weaponCategory]
	local weaponLookup = categoryLookup and categoryLookup[weaponId]
	if not weaponLookup then
		return 0
	end
	local count = 0
	for wrapId, amount in weaponLookup do
		if wrapId ~= ItemDefaults.ITEM_ID and (tonumber(amount) or 0) > 0 then
			count += 1
		end
	end
	return count
end

-- Lo equipado según el último rebuildEquipped, o el Loadout actual si aún no está.
function LockerInventoryState.getEquipped(self: Internal, category: string): string?
	local equippedItem = optionalString(self._equipped[category])
	if equippedItem then
		return equippedItem
	end
	local slot = CATEGORY_TO_LOADOUT_SLOT[category]
	return if slot then optionalString(self:getLoadout()[slot]) else nil
end

function LockerInventoryState.getEquippedWeapon(self: Internal, category: WeaponCategory): string
	return self:getEquipped(category) or ItemDefaults.ITEM_ID
end

function LockerInventoryState.resolveEquippedWrap(self: Internal, loadout: LoadoutData, weaponCategory: WeaponCategory, weaponId: string?): string
	return LoadoutWraps.resolveEquipped(loadout, weaponCategory, weaponId, function(category, id, wrapId)
		return self:ownsWrap(category, id, wrapId)
	end)
end

function LockerInventoryState.getWrapsTargetCategory(self: Internal): WeaponCategory
	return self._wrapsTargetCategory
end

-- El arma elegida se recuerda por categoría: al volver a Main o Special se miran sus wraps.
function LockerInventoryState.setWrapsTarget(self: Internal, weaponCategory: WeaponCategory, weaponId: string?)
	self._wrapsTargetCategory = weaponCategory
	self._wrapsTargetWeaponIdByCategory[weaponCategory] = optionalString(weaponId) or ""
end

-- Arma cuyos wraps se miran: la elegida en esta categoría, si no la equipada.
function LockerInventoryState.getWrapsTargetWeaponId(self: Internal, loadout: LoadoutData?): string
	local category = self._wrapsTargetCategory
	local stored = optionalString(self._wrapsTargetWeaponIdByCategory[category])
	if stored then
		return stored
	end
	if loadout then
		local slot = CATEGORY_TO_LOADOUT_SLOT[category]
		local weaponId = if slot then optionalString(loadout[slot]) else nil
		if weaponId then
			return weaponId
		end
	end
	return ItemDefaults.ITEM_ID
end

-- weaponCategory/weaponId que Shop.BuyItem y EquipItem piden para un wrap ("" si no lo es).
function LockerInventoryState.getWrapRequestContext(self: Internal, category: string): (string, string)
	if category ~= LockerCategory.WEAPON_WRAPS then
		return "", ""
	end
	return self._wrapsTargetCategory, self:getWrapsTargetWeaponId(self:getLoadout())
end

function LockerInventoryState.getWeaponKills(_self: Internal, weaponCategory: WeaponCategory, weaponId: string): number
	local weaponKills = Fusion.peek(DataController.WeaponKills) :: any
	local categoryKills = if type(weaponKills) == "table" then weaponKills[weaponCategory] else nil
	local value = if type(categoryKills) == "table" then tonumber(categoryKills[weaponId]) else nil
	return if value and value > 0 then math.floor(value) else 0
end

-- Un wrap se posee por arma: se mira sobre el arma objetivo de la vista de wraps.
function LockerInventoryState.isItemOwned(self: Internal, item: LockerCatalogItem): boolean
	if item.Category == LockerCategory.WEAPON_WRAPS then
		return self:ownsWrap(self._wrapsTargetCategory, self:getWrapsTargetWeaponId(self:getLoadout()), item.id)
	end
	return self:isOwned(item.Category, item.id)
end

function LockerInventoryState.isItemEquipped(self: Internal, item: LockerCatalogItem): boolean
	if item.Category == LockerCategory.WEAPON_WRAPS then
		local loadout = self:getLoadout()
		local weaponId = self:getWrapsTargetWeaponId(loadout)
		return self:resolveEquippedWrap(loadout, self._wrapsTargetCategory, weaponId) == item.id
	end
	return self:getEquipped(item.Category) == item.id
end

return LockerInventoryState
