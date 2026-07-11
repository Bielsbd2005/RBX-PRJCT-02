--!strict
--[[
	settings/init.luau (Client Feature)
	Panel de ajustes. La GUI nueva vive en UserInterface.Settings:

		Settings
		  Header
		    CloseBtn
		  Content
		    MusicVolume   (slider) → SliderFrame { Slider, Value }
		    Sensitivity   (slider)
		    Vibration     (toggle) → ToggleContainer { Knob, HitArea } + Title
		    AutoShoot     (toggle)
		    Gifts         (toggle) → aceptar o no regalos de otros jugadores
		    CreditsBtn    (sin acción por ahora)

	Toda la mecánica de slider/toggle vive en SliderController/ToggleController;
	aquí solo cableamos: onChange aplica el efecto inmediato y onCommit persiste.
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

local BLUR_KEY = "Settings"
local CREDITS_BLUR_KEY = "Credits"

-- Defaults espejados de DataTemplate.Settings (fallback si el perfil no trae valor).
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

	-- Botón de apertura opcional (Menu.TopFrame.Settings). Si no existe, Settings se
	-- configura igual, solo sin abrirse desde el menú. Resolvemos prefiriendo
	-- TopFrame y cayendo al hijo directo de Menu (compat. con disposición antigua).
	local menuGui = menuController:getGui()
	local topFrame = menuGui:FindFirstChild("TopFrame")
	local settingsBtnInstance = (topFrame and topFrame:FindFirstChild("Settings"))
		or menuGui:FindFirstChild("Settings")
		or menuGui:FindFirstChild("settings")
	local settingsBtn: GuiButton? = if settingsBtnInstance and settingsBtnInstance:IsA("GuiButton")
		then settingsBtnInstance
		else nil

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local frame = uiGui:WaitForChild("Settings") :: Frame
	local content = frame:WaitForChild("Content") :: Frame

	-- CloseBtn en Settings.Header.CloseBtn. Se resuelve de forma defensiva por si
	-- el Header aún no está durante la migración (opcional, sin colgar el feature).
	local header = frame:FindFirstChild("Header")
	local closeInstance = header and header:FindFirstChild("CloseBtn")
	local closeBtn: GuiButton? = if closeInstance and closeInstance:IsA("GuiButton")
		then closeInstance
		else nil

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

	-- Credits: panel hermano abierto desde Settings.Content.CreditsBtn. Abrirlo
	-- cierra Settings; cerrar Credits (Credits.Header.CloseBtn) lleva al Menu.
	local creditsBtnInstance = content:FindFirstChild("CreditsBtn")
	if creditsBtnInstance and creditsBtnInstance:IsA("GuiButton") then
		local creditsFrame = uiGui:WaitForChild("Credits") :: Frame
		local creditsHeader = creditsFrame:FindFirstChild("Header")
		local creditsCloseInstance = creditsHeader and creditsHeader:FindFirstChild("CloseBtn")
		local creditsCloseBtn: GuiButton? = if creditsCloseInstance and creditsCloseInstance:IsA("GuiButton")
			then creditsCloseInstance
			else nil

		local creditsFov = CameraFovEffect.new()
		janitor:Add(creditsFov, "Destroy")

		-- menuBtn = nil: la apertura se cablea a mano para cerrar Settings antes
		-- (el toggle del Menu de ambos pasos se cancela en el mismo frame).
		local creditsPanel = PanelController.new(menuController, creditsFrame, nil, creditsCloseBtn, {
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

		janitor:Add((creditsBtnInstance :: GuiButton).MouseButton1Click:Connect(function()
			panel:close()
			creditsPanel:open()
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

	-- Aceptar regalos de otros jugadores. Solo persiste: el enforcement es
	-- server-side (GiftingService lee Settings.GiftsEnabled del receptor).
	-- Con timeout y opcional: si la GUI publicada aún no trae el frame Gifts,
	-- el resto de settings debe seguir cargando igual (un WaitForChild
	-- infinito aquí bloqueaba TODA la aplicación de valores guardados).
	local giftsToggle: any = nil
	local giftsNode = content:WaitForChild("Gifts", 5)
	if giftsNode then
		giftsToggle = ToggleController.new({
			root = giftsNode,
			onCommit = function(state)
				saveToggle("GiftsEnabled", state)
			end,
		})
		janitor:Add(giftsToggle, "Destroy")
	else
		warn("[SettingsFeature] Falta Settings.Content.Gifts; toggle de regalos omitido.")
	end

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
		if giftsToggle then
			giftsToggle:set(bool("GiftsEnabled"))
		end

		-- El slider de SFX se quitó de la GUI, pero el valor guardado sigue
		-- aplicándose como atributo para los sistemas de sonido que lo lean.
		player:SetAttribute("SFXVolume", num("SFXVolume"))
	end)

	return janitor
end

return SettingsFeature
