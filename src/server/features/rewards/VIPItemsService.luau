--!strict
--[[
	Beneficios del gamepass VIP fuera de la partida (el bonus de Cash vive en
	ResultsRewards):
	  • Ítems `isVIPExclusive` de ItemsConfig, al Inventory como cualquier otro ítem.
	    Si Roblox confirma que ya no lo posee (refund) se retiran y se desequipan, pero
	    solo los concedidos por aquí (InventoryMeta.Source = "VIP"): si el ítem llegó
	    por otra vía (p. ej. un reward del pase) se respeta.
	  • Gems de bienvenida (`WelcomeGems` del pass), una sola vez por perfil
	    (Rewards.VIPWelcomeClaimed). Un refund no las retira: pueden estar gastadas.
	  • Atributo `VipTag.ATTRIBUTE` en el Player, que los clientes leen para el tag.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ItemsConfig = require(Shared.constants.ItemsConfig)
local LockerConfig = require(Shared.constants.LockerConfig)
local StoreProducts = require(Shared.constants.StoreProducts)
local InventoryRepository = require(Shared.data.InventoryRepository)
local VipTag = require(Shared.utils.VipTag)

local GamePassService = require(script.Parent.Parent.Parent.core.GamePassService)
local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)
local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local GRANT_SOURCE = "VIP"

local VIP_PASS = StoreProducts.GamePasses.ByName.VIP
local VIP_PASS_ID = VIP_PASS.PassId
local WELCOME_GEMS = math.max(0, math.floor(VIP_PASS.WelcomeGems or 0))

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

-- `_sync` llega dos veces por jugador (posesión y perfil): si el BatchUpdate cediera,
-- las dos verían VIPWelcomeClaimed = false y concederían dos veces.
local _welcomeInFlight: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

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
end

local function _grantWelcome(player: Player, profileData: any)
	if WELCOME_GEMS <= 0 or _welcomeInFlight[player] then
		return
	end
	local rewards = profileData.Rewards
	if type(rewards) == "table" and rewards.VIPWelcomeClaimed == true then
		return
	end

	_welcomeInFlight[player] = true
	-- Marca y Gems en el mismo lote: o se conceden y quedan marcadas, o nada.
	local ok, result = pcall(function()
		return _dataService:BatchUpdate(player, {
			{ path = { "Rewards", "VIPWelcomeClaimed" }, value = true },
			{ path = { "Stats", "Gems" }, delta = WELCOME_GEMS },
			{ path = { "Stats", "TotalGemsEarned" }, delta = WELCOME_GEMS },
		})
	end)
	_welcomeInFlight[player] = nil

	if not ok or result == false then
		warn(("[VIPItemsService] Gems de bienvenida fallaron para %s: %s"):format(player.Name, tostring(result)))
		return
	end
	TelemetryService.RecordFlow(player, "source", "VIPWelcome", WELCOME_GEMS, VIP_PASS.Name, "Gems")
end

local function _sync(player: Player)
	local owns = GamePassService.Peek(player, VIP_PASS_ID)
	if owns == nil then
		return
	end
	player:SetAttribute(VipTag.ATTRIBUTE, owns)

	local profile = _dataService:GetProfile(player)
	if not profile then
		return
	end

	if owns then
		_grantWelcome(player, profile.Data)
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
