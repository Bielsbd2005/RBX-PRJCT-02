--!strict
--[[
	SettingsService.luau (Server)
	Escucha los cambios tipados de Settings del cliente, valida la clave y el rango,
	y actualiza el DataService atómicamente.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network = require(Shared.networking.Network)

local SettingsService = {}
SettingsService.__index = SettingsService

local _dataService: any = nil
local _started = false
local _cooldowns: { [number]: { [string]: number } } = {}

local RATE_LIMIT_SECONDS = 0.1

local NUMERIC_SETTINGS = {
	MusicVolume = true,
	CameraSensitivity = true,
}

local BOOLEAN_SETTINGS = {
	Vibration = true,
	AimAssist = true,
}

local function _checkCooldown(player: Player, action: string): boolean
	local playerCooldowns = _cooldowns[player.UserId]
	if not playerCooldowns then
		playerCooldowns = {}
		_cooldowns[player.UserId] = playerCooldowns
	end

	local last = playerCooldowns[action] or 0
	if time() - last < RATE_LIMIT_SECONDS then
		return false
	end

	playerCooldowns[action] = time()
	return true
end

local function _canUpdate(player: Player, key: string): boolean
	local profile = _dataService:GetProfile(player)
	if not profile then
		return false
	end

	if profile.Data.Settings[key] ~= nil then
		return true
	end

	warn(`[SettingsService] Intento de actualizar clave inválida de Settings: {key}`)
	return false
end

local function _onUpdateSlider(data: { key: string, value: number }, player: Player): ()
	if not _checkCooldown(player, "slider:" .. data.key) then
		return
	end

	if not NUMERIC_SETTINGS[data.key] or not _canUpdate(player, data.key) then
		return
	end

	local value = math.clamp(data.value, 0, 1)
	_dataService:SetValue(player, { "Settings", data.key }, value)
end

local function _onUpdateToggle(data: { key: string, value: boolean }, player: Player): ()
	if not _checkCooldown(player, "toggle:" .. data.key) then
		return
	end

	if not BOOLEAN_SETTINGS[data.key] or not _canUpdate(player, data.key) then
		return
	end

	_dataService:SetValue(player, { "Settings", data.key }, data.value)
end

function SettingsService:Start(dataService: any): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
	end)

	Network.Settings.UpdateSlider.Listen(_onUpdateSlider)
	Network.Settings.UpdateToggle.Listen(_onUpdateToggle)
end

return SettingsService
