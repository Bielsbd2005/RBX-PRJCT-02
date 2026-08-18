--!strict
--[[
	settings/init.luau (Client Feature)
	Panel de ajustes (UserInterface.Settings):

		Settings
		  Container
		    Header
		      CloseBtn
		    Content
		      MusicVolume   (slider) → SliderFrame { Slider, Value }
		      Sensitivity   (slider)
		      Vibration     (toggle) → ToggleContainer { Knob, HitArea } + Title
		      AutoShoot     (toggle)
		      Gifts         (toggle) → aceptar o no regalos de otros jugadores
		      CreditsBtn    (opcional)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Fusion = require(Packages.fusion)
local Janitor = require(Packages.janitor) :: any
local Network = require(Shared.networking.Network)
local DataController = require(Client.core.data.DataController)
local PanelController = require(Client.core.ui.PanelController)
local BlurController = require(Client.core.ui.BlurController)
local CameraFovEffect = require(Client.core.ui.CameraFovEffect)
local SliderController = require(Client.core.ui.SliderController)
local ToggleController = require(Client.core.ui.ToggleController)
local MenuHover = require(Client.core.ui.MenuHover)

local BLUR_KEY = "Settings"
local CREDITS_BLUR_KEY = "Credits"

local SLIDER_DEFAULTS: { [string]: number } = {
	MusicVolume = 0.5,
	SFXVolume = 0.8,
	CameraSensitivity = 0.5,
}
local TOGGLE_DEFAULTS: { [string]: boolean } = {
	Vibration = true,
	AutoShoot = true,
	GiftsEnabled = true,
}

local SettingsFeature = {}

local function saveSlider(key: string, value: number)
	Network.Settings.UpdateSlider.Send({
		key = key,
		value = math.clamp(value, 0, 1),
	})
end

local function saveToggle(key: string, value: boolean)
	Network.Settings.UpdateToggle.Send({
		key = key,
		value = value,
	})
end

function SettingsFeature.start(menuController: any): any
	local janitor = Janitor.new()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- Botón de apertura en Menu.Container.TopFrame.RightContainer.Settings
	local menuGui = menuController:getGui()
	local container = menuGui:WaitForChild("Container")
	local topFrame = container:WaitForChild("TopFrame")
	local rightContainer = topFrame:WaitForChild("RightContainer")
	local settingsBtn = rightContainer:WaitForChild("Settings") :: GuiButton

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local frame = uiGui:WaitForChild("Settings") :: Frame
	local settingsContainer = frame:WaitForChild("Container") :: Frame
	local content = settingsContainer:WaitForChild("Content") :: Frame

	local header = settingsContainer:WaitForChild("Header")
	local closeBtn = header:WaitForChild("CloseBtn") :: GuiButton

	local fovEffect = CameraFovEffect.new()
	janitor:Add(fovEffect, "Destroy")

	local panel = PanelController.new(menuController, frame, settingsBtn, closeBtn, {
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			fovEffect:expand()
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
			fovEffect:restore()
		end,
	})
	janitor:Add(panel, "Destroy")

	-- Credits: panel hermano abierto desde Settings.Container.Content.CreditsBtn.
	-- Abrirlo cierra Settings; cerrar Credits (Credits.Container.CloseBtn) regresa a Settings.
	local creditsBtnInstance = content:FindFirstChild("CreditsBtn")
	if creditsBtnInstance and creditsBtnInstance:IsA("GuiButton") then
		local creditsFrame = uiGui:WaitForChild("Credits") :: Frame
		local creditsContainer = creditsFrame:WaitForChild("Container") :: Frame
		local creditsCloseBtn = creditsContainer:WaitForChild("CloseBtn") :: GuiButton

		local creditsFov = CameraFovEffect.new()
		janitor:Add(creditsFov, "Destroy")

		local resetCreditsClose = MenuHover.bindButton(creditsCloseBtn, janitor)

		local creditsPanel = PanelController.new(menuController, creditsFrame, nil, nil, {
			onOpen = function()
				BlurController.acquire(CREDITS_BLUR_KEY)
				creditsFov:expand()
			end,
			onClose = function()
				BlurController.release(CREDITS_BLUR_KEY)
				creditsFov:restore()
			end,
		})
		janitor:Add(creditsPanel, "Destroy")

		janitor:Add(creditsBtnInstance.MouseButton1Click:Connect(function()
			panel:close()
			creditsPanel:open()
		end), "Disconnect")

		janitor:Add(creditsCloseBtn.MouseButton1Click:Connect(function()
			resetCreditsClose()
			creditsPanel:close()
			panel:open()
		end), "Disconnect")
	end

	-- Efectos inmediatos (onChange) ------------------------------------------
	-- L11: resolvemos LobbyMusic perezosamente en cada apply. Settings arranca
	-- antes que el feature de música, así que cachear el Sound al inicio dejaba
	-- el slider sin efecto si la música aún no se había creado.
	local function applyMusicVolume(value: number)
		local lobbyMusic = SoundService:FindFirstChild("LobbyMusic")
		if lobbyMusic and lobbyMusic:IsA("Sound") then
			lobbyMusic:SetAttribute("VolumeMultiplier", value)
		end
	end

	-- Slider de música: aplica volumen al vuelo, persiste al soltar.
	local musicSlider = SliderController.new({
		root = content:WaitForChild("MusicVolume"),
		onChange = applyMusicVolume,
		onCommit = function(value)
			saveSlider("MusicVolume", value)
		end,
	})
	janitor:Add(musicSlider, "Destroy")

	local sensSlider = SliderController.new({
		root = content:WaitForChild("Sensitivity"),
		onChange = function(value)
			player:SetAttribute("CameraSensitivity", value)
		end,
		onCommit = function(value)
			saveSlider("CameraSensitivity", value)
		end,
	})
	janitor:Add(sensSlider, "Destroy")

	local vibrationToggle = ToggleController.new({
		root = content:WaitForChild("Vibration"),
		onChange = function(state)
			player:SetAttribute("Vibration", state)
		end,
		onCommit = function(state)
			saveToggle("Vibration", state)
		end,
	})
	janitor:Add(vibrationToggle, "Destroy")

	local autoShootToggle = ToggleController.new({
		root = content:WaitForChild("AutoShoot"),
		onChange = function(state)
			player:SetAttribute("AutoShoot", state)
		end,
		onCommit = function(state)
			saveToggle("AutoShoot", state)
		end,
	})
	janitor:Add(autoShootToggle, "Destroy")

	local giftsToggle = ToggleController.new({
		root = content:WaitForChild("Gifts"),
		onCommit = function(state)
			saveToggle("GiftsEnabled", state)
		end,
	})
	janitor:Add(giftsToggle, "Destroy")

	-- Carga inicial: aplica los valores guardados (onChange) sin re-persistir.
	DataController:WhenReady():andThen(function()
		local saved = Fusion.peek(DataController.Settings)

		local function num(key: string): number
			local value = saved[key]
			return if type(value) == "number" then value else SLIDER_DEFAULTS[key]
		end
		local function bool(key: string): boolean
			local value = saved[key]
			return if type(value) == "boolean" then value else TOGGLE_DEFAULTS[key]
		end

		musicSlider:set(num("MusicVolume"))
		sensSlider:set(num("CameraSensitivity"))
		vibrationToggle:set(bool("Vibration"))
		autoShootToggle:set(bool("AutoShoot"))
		giftsToggle:set(bool("GiftsEnabled"))

		-- El valor de SFX se aplica como atributo para sistemas de sonido.
		player:SetAttribute("SFXVolume", num("SFXVolume"))
	end)

	return janitor
end

return SettingsFeature
