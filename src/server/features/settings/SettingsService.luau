--!strict
--[[
	SettingsService.luau (Server)
	Listener tipado para mutaciones de Settings desde el cliente.

	Whitelist por handler:
	  • UpdateSlider  → claves en NUMERIC_SETTINGS, value clamped a [0,1].
	  • UpdateToggle  → claves en BOOLEAN_SETTINGS, value bool.
	  • UpdateChoice  → claves en CHOICE_SETTINGS, value string en su set.
	  • UpdateColor   → claves en COLOR_SETTINGS, RGB clamped a [0,1].

	Añadir un setting nuevo:
	  1. Añadir el campo al DataTemplate.Settings con default sensato.
	  2. Añadir la clave a la whitelist de su tipo aquí.
	  3. UI cliente envía vía Network.Settings.UpdateX correspondiente.

	No persiste valores fuera de los whitelists — defensa contra clientes
	que intenten escribir secciones arbitrarias del perfil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network   = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local M = NetGuards.MAX

local SettingsService = {}
SettingsService.__index = SettingsService

local _dataService: DataService = nil :: any
local _started = false
-- Cooldown global por player (no por-key) para evitar spam por rotación de keys.
-- Un usuario que mueva un slider Y cambie un toggle dentro de 100ms verá el
-- segundo action descartado — UX impact despreciable, anti-spam asegurado.
local _cooldowns: { [number]: number } = {}

local RATE_LIMIT_SECONDS = 0.1

-- Sliders: value se clampa a [0,1] (mapeo a unidades reales en el cliente).
local NUMERIC_SETTINGS = {
	MasterVolume = true,
	MusicVolume = true,
	SFXVolume = true,
	CameraSensitivity = true,
	FOV = true,
	HUDScale = true,
}

local BOOLEAN_SETTINGS = {
	Vibration = true,
	AutoShoot = true,
	ShowDamageNumbers = true,
	GiftsEnabled = true,
}

-- Enums: clave → set de valores válidos. Defensa contra clientes que envían
-- strings arbitrarias.
local CHOICE_SETTINGS: { [string]: { [string]: boolean } } = {
	ColorblindMode = {
		None = true,
		Protanopia = true,
		Deuteranopia = true,
		Tritanopia = true,
	},
	Language = {
		en = true, es = true, fr = true, pt = true, de = true,
		it = true, ja = true, ko = true, zh = true, ru = true,
	},
}

-- Colores: clave → true (presencia indica que el setting acepta RGB).
local COLOR_SETTINGS = {
	CrosshairColor = true,
}

local function _checkCooldown(player: Player): boolean
	local last = _cooldowns[player.UserId] or 0
	if time() - last < RATE_LIMIT_SECONDS then
		return false
	end

	_cooldowns[player.UserId] = time()
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
	if not NetGuards.validate(data, { key = M.SettingKey }) then
		return
	end
	if type(data.value) ~= "number" or data.value ~= data.value then -- NaN check
		return
	end

	if not _checkCooldown(player) then
		return
	end

	if not NUMERIC_SETTINGS[data.key] or not _canUpdate(player, data.key) then
		return
	end

	local value = math.clamp(data.value, 0, 1)
	_dataService:SetValue(player, { "Settings", data.key }, value)
end

local function _onUpdateToggle(data: { key: string, value: boolean }, player: Player): ()
	if not NetGuards.validate(data, { key = M.SettingKey }) then
		return
	end
	if type(data.value) ~= "boolean" then
		return
	end

	if not _checkCooldown(player) then
		return
	end

	if not BOOLEAN_SETTINGS[data.key] or not _canUpdate(player, data.key) then
		return
	end

	_dataService:SetValue(player, { "Settings", data.key }, data.value)
end

local function _onUpdateChoice(data: { key: string, value: string }, player: Player): ()
	if not NetGuards.validate(data, { key = M.SettingKey, value = M.SettingChoice }) then
		return
	end

	if not _checkCooldown(player) then
		return
	end

	local validValues = CHOICE_SETTINGS[data.key]
	if not validValues or not validValues[data.value] then
		warn(`[SettingsService] Choice inválida {data.key}={data.value}`)
		return
	end

	if not _canUpdate(player, data.key) then
		return
	end

	_dataService:SetValue(player, { "Settings", data.key }, data.value)
end

local function _onUpdateColor(data: { key: string, r: number, g: number, b: number }, player: Player): ()
	if not NetGuards.validate(data, { key = M.SettingKey }) then
		return
	end
	if type(data.r) ~= "number" or type(data.g) ~= "number" or type(data.b) ~= "number" then
		return
	end
	if data.r ~= data.r or data.g ~= data.g or data.b ~= data.b then
		return
	end

	if not _checkCooldown(player) then
		return
	end

	if not COLOR_SETTINGS[data.key] or not _canUpdate(player, data.key) then
		return
	end

	local color = {
		R = math.clamp(data.r, 0, 1),
		G = math.clamp(data.g, 0, 1),
		B = math.clamp(data.b, 0, 1),
	}
	_dataService:SetValue(player, { "Settings", data.key }, color)
end

function SettingsService:Start(dataService: DataService): ()
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
	Network.Settings.UpdateChoice.Listen(_onUpdateChoice)
	Network.Settings.UpdateColor.Listen(_onUpdateColor)
end

return SettingsService
