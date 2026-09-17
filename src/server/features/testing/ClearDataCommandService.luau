--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)
local ItemsConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").constants.ItemsConfig)

local ClearDataCommandService = {}
ClearDataCommandService.__index = ClearDataCommandService

local _dataService: DataService = nil :: any
local _started = false

local ENABLE_CLEAR_COMMAND = RunService:IsStudio()
local COMMAND = "/resetdata"
-- Concede todos los banners de ItemsConfig.
local GRANT_BANNERS_COMMAND = "/banners"

-- Opt-in explícito (una lista vacía no abre a todos), para que copiar este servicio
-- fuera de Studio no lo deje abierto.
local OPEN_TO_ALL_IN_STUDIO = true
local ALLOWED_USER_IDS: { [number]: boolean } = {
	[286176976] = true,
}

local function _isAuthorized(player: Player): boolean
	if ALLOWED_USER_IDS[player.UserId] == true then
		return true
	end

	return OPEN_TO_ALL_IN_STUDIO and RunService:IsStudio()
end

local function _normalizeMessage(message: string): string
	return string.lower((message:gsub("^%s*(.-)%s*$", "%1")))
end

-- Sink con etiqueta propia para poder excluirlo del balance en telemetría.
local function _recordReset(player: Player)
	local profile = _dataService and _dataService:GetProfile(player)
	local data = profile and profile.Data
	local stats = data and data.Stats
	if not stats then
		return
	end

	local cash = stats.Cash
	if type(cash) == "number" and cash > 0 then
		TelemetryService.RecordFlow(player, "sink", "AdminReset", cash, nil, "Cash")
	end
	local gems = stats.Gems
	if type(gems) == "number" and gems > 0 then
		TelemetryService.RecordFlow(player, "sink", "AdminReset", gems, nil, "Gems")
	end
end

local function _onPlayerChatted(player: Player, message: string): ()
	if not ENABLE_CLEAR_COMMAND then
		return
	end

	local normalized = _normalizeMessage(message)
	if normalized ~= COMMAND and normalized ~= GRANT_BANNERS_COMMAND then
		return
	end

	if not _isAuthorized(player) then
		return
	end

	if normalized == GRANT_BANNERS_COMMAND then
		for bannerId in ItemsConfig.Banners do
			_dataService:GrantItem(player, "Banners", bannerId, "AdminCommand")
		end
		return
	end

	-- Antes del reset, mientras el saldo existe. El grant de bienvenida posterior lo
	-- registra TelemetryService al siguiente login (el reset pone JoinCount a cero).
	_recordReset(player)

	local success = _dataService:ResetProfile(player)
	if not success then
		player:Kick("No se pudieron borrar tus datos. Vuelve a intentar.")
		return
	end

	player:Kick("Tus datos fueron borrados para testing. Vuelve a entrar.")
end

function ClearDataCommandService:Start(dataService: DataService): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	Players.PlayerAdded:Connect(function(player: Player)
		player.Chatted:Connect(function(message: string)
			_onPlayerChatted(player, message)
		end)
	end)

	for _, player in Players:GetPlayers() do
		player.Chatted:Connect(function(message: string)
			_onPlayerChatted(player, message)
		end)
	end
end

return ClearDataCommandService
