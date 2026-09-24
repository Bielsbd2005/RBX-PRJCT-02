--!strict
--[[
	Listener tipado para mutaciones de Settings desde el cliente.

	Whitelist por handler:
	  • UpdateSlider  → claves en NUMERIC_SETTINGS, value clamped a [0,1].
	  • UpdateToggle  → claves en BOOLEAN_SETTINGS, value bool.

	Añadir un setting nuevo:
	  1. Añadir el campo al DataTemplate.Settings con default sensato.
	  2. Añadir la clave a la whitelist de su tipo aquí.
	  3. UI cliente envía vía Network.Settings.UpdateX correspondiente.

	No persiste valores fuera de los whitelists — defensa contra clientes
	que intenten escribir secciones arbitrarias del perfil.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network   = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local RateLimiter = require(script.Parent.Parent.Parent.utils.RateLimiter)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local M = NetGuards.MAX

local SettingsService = {}
SettingsService.__index = SettingsService

local _dataService: DataService = nil :: any
local _started = false

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

-- Por clave, y solo tras validarla contra la whitelist (así rotar claves no abre más
-- que ~10 claves × 1/RATE_LIMIT_SECONDS): uno global descartaba en silencio un cambio
-- legítimo de otra clave y el perfil se quedaba con el valor anterior.
local _limiter = RateLimiter.new(RATE_LIMIT_SECONDS)

-- userId → clave → último valor recibido dentro del cooldown.
local _deferredByUserId: { [number]: { [string]: any } } = {}

-- Un cambio dentro del cooldown no se descarta: se guarda el último y se aplica al
-- vencer. Si no, dos toques rápidos al mismo toggle dejaban el perfil en el valor
-- intermedio mientras la UI mostraba el final.
local function _applySetting(player: Player, key: string, value: any): ()
	if _limiter:tryConsume(player, key) then
		_dataService:SetValue(player, { "Settings", key }, value)
		return
	end

	local userId = player.UserId
	local deferred = _deferredByUserId[userId]
	if not deferred then
		deferred = {}
		_deferredByUserId[userId] = deferred
	end
	local alreadyScheduled = deferred[key] ~= nil
	deferred[key] = value
	if alreadyScheduled then
		return
	end
	task.delay(RATE_LIMIT_SECONDS, function()
		local pending = _deferredByUserId[userId]
		local latest = if pending then pending[key] else nil
		if latest == nil then
			return
		end
		pending[key] = nil
		if player.Parent ~= Players then
			return
		end
		_limiter:mark(player, key)
		_dataService:SetValue(player, { "Settings", key }, latest)
	end)
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

local function _onUpdateSlider(data: Network.SliderPayload, player: Player): ()
	if not NetGuards.validate(data, { key = M.SettingKey }) then
		return
	end
	if type(data.value) ~= "number" or data.value ~= data.value then -- NaN check
		return
	end

	if not NUMERIC_SETTINGS[data.key] or not _canUpdate(player, data.key) then
		return
	end

	_applySetting(player, data.key, math.clamp(data.value, 0, 1))
end

local function _onUpdateToggle(data: Network.TogglePayload, player: Player): ()
	if not NetGuards.validate(data, { key = M.SettingKey }) then
		return
	end
	if type(data.value) ~= "boolean" then
		return
	end

	if not BOOLEAN_SETTINGS[data.key] or not _canUpdate(player, data.key) then
		return
	end

	_applySetting(player, data.key, data.value)
end

function SettingsService:Start(dataService: DataService): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService


	Network.Settings.UpdateSlider.Listen(_onUpdateSlider)
	Network.Settings.UpdateToggle.Listen(_onUpdateToggle)
	Players.PlayerRemoving:Connect(function(player: Player)
		_deferredByUserId[player.UserId] = nil
	end)
end

return SettingsService
