--!strict
-- Lectura de las recompensas del pase para pintarlas (casillas, preview y escena).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Client = script.Parent.Parent.Parent
local Fusion = require(ReplicatedStorage:WaitForChild("Packages").fusion) :: any
local DataController = require(Client.core.data.DataController)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local LockerConfig = require(Shared.constants.LockerConfig)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)

local BattlePassRewards = {}

BattlePassRewards.RARITY_FALLBACK = "Common"

-- Un wrap GLOBAL se previsualiza sobre el arma equipada en esta categoría.
local WRAP_PREVIEW_CATEGORY = WeaponCategoryMod.MAIN
local LOADOUT_SLOT_BY_WEAPON = LockerConfig.CategoryToLoadoutSlot :: { [string]: string }

-- "Body" y no "Outfit": así llama el nav del locker a Outfits (LockerConfig.ITEMS_CONFIG_BY_NAV).
local CATEGORY_LABEL: { [string]: string } = {
	Outfits = "Body",
	Faces = "Face",
	Hats = "Hat",
	KillEffects = "Kill Effect",
	Emotes = "Emote",
	WeaponWraps = "Wrap",
	Banners = "Banner",
	Main = "Weapon",
	Special = "Weapon",
}

BattlePassRewards.IMAGE_NODE_NAMES = table.freeze({ "Item", "ItemHat", "ItemHair", "ItemFace", "ItemBody" })

-- Hijo de LevelReward donde va la imagen; debe coincidir con resolveItemImageNode de LockerGrid.
function BattlePassRewards.imageNodeName(reward: BattlePassConfig.Reward): string
	if reward.Kind ~= "Item" then
		return "Item"
	end
	if reward.Category == "Faces" then
		return "ItemFace"
	elseif reward.Category == "Outfits" then
		return "ItemBody"
	elseif reward.Category == "Hats" then
		return if string.sub(reward.ItemId or "", 1, 4) == "Hair" then "ItemHair" else "ItemHat"
	end
	return "Item"
end

function BattlePassRewards.isWrap(reward: BattlePassConfig.Reward): boolean
	return reward.Kind == "Item" and reward.Category == "WeaponWraps" and reward.ItemId ~= nil
end

function BattlePassRewards.image(reward: BattlePassConfig.Reward): string
	if reward.Kind == "Cash" then
		return reward.Icon or BattlePassConfig.RewardIcons.Cash or ""
	end
	if reward.Kind == "Gems" then
		-- Sin icono, "" y no el de Cash: mejor sin imagen que con la moneda equivocada.
		return reward.Icon or BattlePassConfig.RewardIcons.Gems or ""
	end
	local catalog = ItemsConfig[reward.Category]
	local def = if type(catalog) == "table" then catalog[reward.ItemId] else nil
	local image = if def and type(def.Image) == "string" and def.Image ~= ""
		then def.Image
		elseif def and type(def.CatalogEmoteId) == "number"
		then "rbxthumb://type=Asset&id=" .. tostring(def.CatalogEmoteId) .. "&w=150&h=150"
		else ""
	return reward.Icon or image
end

function BattlePassRewards.rarity(reward: BattlePassConfig.Reward): string
	if reward.Kind == "Gems" then
		return "Legendary"
	end
	if reward.Kind ~= "Item" then
		return BattlePassRewards.RARITY_FALLBACK
	end
	local catalog = ItemsConfig[reward.Category]
	local def = if type(catalog) == "table" then catalog[reward.ItemId] else nil
	if type(def) == "table" and type(def.Rarity) == "string" then
		return def.Rarity
	end
	return BattlePassRewards.RARITY_FALLBACK
end

-- El TIPO de recompensa, no su cantidad.
function BattlePassRewards.valueText(reward: BattlePassConfig.Reward): string
	if reward.Label then
		return reward.Label
	end
	if reward.Kind == "Cash" or reward.Kind == "Gems" then
		return reward.Kind
	end
	local category = reward.Category or ""
	return CATEGORY_LABEL[category] or category
end

-- Imagen del arma de un wrap por arma; nil si es global (vale para todas).
function BattlePassRewards.wrapWeaponImage(reward: BattlePassConfig.Reward): string?
	if reward.Global or not WeaponCategoryMod.isValid(reward.WeaponCategory) then
		return nil
	end
	local catalog = ItemsConfig[reward.WeaponCategory :: string]
	local def = if type(catalog) == "table" and reward.WeaponId then catalog[reward.WeaponId] else nil
	return if type(def) == "table" and type(def.Image) == "string" and def.Image ~= "" then def.Image else nil
end

-- Wrap global sin loadout → id nil y el previewer cae al modelo "Default".
-- Se devuelve también el nombre visible: los modelos de Shared.Locker.weapons.*
-- pueden estar nombrados por id o por nombre.
function BattlePassRewards.wrapPreviewWeapon(reward: BattlePassConfig.Reward): (string, string?, string?)
	local category: string
	local weaponId: string?

	if WeaponCategoryMod.isValid(reward.WeaponCategory) then
		category = reward.WeaponCategory :: string
		weaponId = if type(reward.WeaponId) == "string" and reward.WeaponId ~= "" then reward.WeaponId else nil
	else
		category = WRAP_PREVIEW_CATEGORY
		local loadout = Fusion.peek(DataController.Loadout)
		local slot = LOADOUT_SLOT_BY_WEAPON[category]
		local equipped = if type(loadout) == "table" and slot then loadout[slot] else nil
		weaponId = if type(equipped) == "string" and equipped ~= "" then equipped else nil
	end

	local catalog = ItemsConfig[category]
	local def = if type(catalog) == "table" and weaponId then catalog[weaponId] else nil
	local displayName = if type(def) == "table" and type(def.Name) == "string" and def.Name ~= ""
		then def.Name
		else nil

	return category, weaponId, displayName
end

return BattlePassRewards
