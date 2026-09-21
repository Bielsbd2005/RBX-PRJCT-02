--!strict
--[[
	Concede los ítems `isVIPExclusive` de ItemsConfig a quien posee el gamepass VIP.
	Van al Inventory como cualquier otro ítem para reutilizar locker y equip tal cual.

	Si Roblox confirma que ya no lo posee (refund) se retiran y se desequipan, pero
	solo los concedidos por aquí (InventoryMeta.Source = "VIP"): si el ítem llegó por
	otra vía (p. ej. un reward del pase) se respeta.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ItemsConfig = require(Shared.constants.ItemsConfig)
local LockerConfig = require(Shared.constants.LockerConfig)
local StoreProducts = require(Shared.constants.StoreProducts)
local InventoryRepository = require(Shared.data.InventoryRepository)

local GamePassService = require(script.Parent.Parent.Parent.core.GamePassService)
local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local GRANT_SOURCE = "VIP"

local VIP_PASS_ID = StoreProducts.GamePasses.ByName.VIP.PassId

type VIPItem = { category: string, itemId: string }

local VIP_ITEMS: { VIPItem } = {}
for category, items in ItemsConfig :: any do
	for itemId, definition in items do
		if definition.isVIPExclusive == true then
			table.insert(VIP_ITEMS, { category = category, itemId = itemId })
		end
	end
end

local VIPItemsService = {}

local _dataService: DataService = nil :: any
local _started = false

local function _revoke(player: Player, profileData: any, item: VIPItem)
	local meta = profileData.InventoryMeta and profileData.InventoryMeta[item.category]
	local itemMeta = if type(meta) == "table" then meta[item.itemId] else nil
	if type(itemMeta) ~= "table" or itemMeta.Source ~= GRANT_SOURCE then
		return
	end

	local slot = LockerConfig.CategoryToLoadoutSlot[item.category]
	if slot and profileData.Loadout and profileData.Loadout[slot] == item.itemId then
		_dataService:SetValue(player, { "Loadout", slot }, nil)
	end
	_dataService:SetValue(player, { "Inventory", item.category, item.itemId }, nil)
	_dataService:SetValue(player, { "InventoryMeta", item.category, item.itemId }, nil)
	_dataService:SetValue(player, { "NewItemFlags", item.category, item.itemId }, nil)
end

local function _sync(player: Player)
	local owns = GamePassService.Peek(player, VIP_PASS_ID)
	if owns == nil then
		return
	end
	local profile = _dataService:GetProfile(player)
	if not profile then
		return
	end

	for _, item in VIP_ITEMS do
		local has = InventoryRepository.ownsItem(profile.Data, item.category, item.itemId)
		if owns and not has then
			_dataService:GrantItem(player, item.category, item.itemId, GRANT_SOURCE)
		elseif not owns and has then
			_revoke(player, profile.Data, item)
		end
	end
end

-- Posesión del pass y carga del perfil llegan asíncronas y en cualquier orden:
-- se sincroniza en ambas y `_sync` ignora la que llegue primero.
function VIPItemsService:Start(dataService: DataService): ()
	if _started then
		return
	end
	_started = true
	_dataService = dataService

	if #VIP_ITEMS == 0 then
		return
	end

	GamePassService.OnOwnershipResolved(function(player, passId)
		if passId == VIP_PASS_ID then
			_sync(player)
		end
	end)

	dataService.ProfileLoaded:Connect(_sync)

	for _, player in Players:GetPlayers() do
		task.spawn(_sync, player)
	end
end

return VIPItemsService
