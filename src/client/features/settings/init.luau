--!strict
--[[
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

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Fusion = require(Packages.fusion)
local Janitor = require(Packages.janitor) :: any
local Network = require(Shared.networking.Network)
local DataController = require(Client.core.data.DataController)
local PanelController = require(Client.core.ui.PanelController)
local BlurController = require(Client.core.ui.BlurController)
local SliderController = require(Client.core.ui.SliderController)
local ToggleController = require(Client.core.ui.ToggleController)
local MenuHover = require(Client.core.ui.MenuHover)
local GameSounds = require(Client.core.ui.GameSounds)

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

	local panel = PanelController.new(menuController, frame, settingsBtn, closeBtn, {
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
		end,
	})
	janitor:Add(panel, "Destroy")

	-- Credits es panel hermano: abrirlo cierra Settings y cerrarlo vuelve a Settings.
	local creditsBtnInstance = content:FindFirstChild("CreditsBtn")
	if creditsBtnInstance and creditsBtnInstance:IsA("GuiButton") then
		local creditsFrame = uiGui:WaitForChild("Credits") :: Frame
		local creditsContainer = creditsFrame:WaitForChild("Container") :: Frame
		local creditsCloseBtn = creditsContainer:WaitForChild("CloseBtn") :: GuiButton

		local resetCreditsClose = MenuHover.bindButton(creditsCloseBtn, janitor)

		local creditsPanel = PanelController.new(menuController, creditsFrame, nil, nil, {
			onOpen = function()
				BlurController.acquire(CREDITS_BLUR_KEY)
			end,
			onClose = function()
				BlurController.release(CREDITS_BLUR_KEY)
			end,
		})
		janitor:Add(creditsPanel, "Destroy")

		-- Settings va en silencio (true): en la transición solo suena Credits.
		janitor:Add(creditsBtnInstance.MouseButton1Click:Connect(function()
			panel:close(true)
			creditsPanel:open()
		end), "Disconnect")

		janitor:Add(creditsCloseBtn.MouseButton1Click:Connect(function()
			resetCreditsClose()
			creditsPanel:close()
			panel:open(true)
		end), "Disconnect")
	end

	-- LobbyMusic se resuelve en cada apply: Settings arranca antes que el feature de
	-- música y el Sound puede no existir aún.
	local function applyMusicVolume(value: number)
		local lobbyMusic = GameSounds.resolve(GameSounds.LobbyMusic)
		if lobbyMusic then
			lobbyMusic:SetAttribute("VolumeMultiplier", value)
		end
	end

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

		player:SetAttribute("SFXVolume", num("SFXVolume"))
	end)

	return janitor
end

return SettingsFeature
