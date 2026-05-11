--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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

local BLUR_KEY = "Settings"

local SettingsFeature = {}

type PendingChanges = {
	[string]: boolean,
}

local function setupSlider(
	settingNode: Instance,
	configKey: string,
	currentConfig: { [string]: boolean | number },
	janitor: any
): (number) -> ()
	local container = settingNode:WaitForChild("SliderContainer") :: Frame
	local drag = container:WaitForChild("Drag") :: Frame
	local dragDetector = drag:WaitForChild("UIDragDetector") :: UIDragDetector
	local indicatorFrame = settingNode:WaitForChild("SliderIndicatorFrame") :: Frame
	local indicator = indicatorFrame:WaitForChild("SliderIndicator") :: Frame
	local valueLabel = settingNode:WaitForChild("Value") :: TextLabel

	drag.AnchorPoint = Vector2.new(0.5, 0.5)
	indicator.AnchorPoint = Vector2.new(0, 0.5)
	indicator.Position = UDim2.new(0, 0, 0.5, 0)

	dragDetector.DragStyle = Enum.UIDragDetectorDragStyle.TranslateLine
	dragDetector.DragAxis = Vector2.new(1, 0)
	dragDetector.BoundingUI = container
	dragDetector.BoundingBehavior = Enum.UIDragDetectorBoundingBehavior.EntireObject

	janitor:Add(dragDetector.DragContinue:Connect(function()
		local minX = container.AbsolutePosition.X
		local maxX = minX + container.AbsoluteSize.X - drag.AbsoluteSize.X
		local currentX = drag.AbsolutePosition.X
		local travelSpace = maxX - minX

		local percentage = if travelSpace > 0
			then math.clamp((currentX - minX) / travelSpace, 0, 1)
			else 0

		currentConfig[configKey] = percentage

		local fillWidth = (currentX - minX) + (drag.AbsoluteSize.X / 2)
		indicator.Size = UDim2.new(0, fillWidth, 1, 0)
		valueLabel.Text = math.round(percentage * 100) .. "%"
	end), "Disconnect")

	return function(percentage: number)
		local clamped = math.clamp(percentage, 0, 1)
		currentConfig[configKey] = clamped

		local travelSpace = container.AbsoluteSize.X - drag.AbsoluteSize.X
		local centerPos = (travelSpace * clamped) + (drag.AbsoluteSize.X / 2)

		drag.Position = UDim2.new(0, centerPos, 0.5, 0)
		indicator.Size = UDim2.new(0, centerPos, 1, 0)
		valueLabel.Text = math.round(clamped * 100) .. "%"
	end
end

local function setupToggle(
	settingNode: Instance,
	configKey: string,
	currentConfig: { [string]: boolean | number },
	janitor: any
): (boolean) -> ()
	local toggleFrame = settingNode:WaitForChild("ToggleFrame") :: Frame
	local toggleBtn = toggleFrame:WaitForChild("Toggle") :: TextButton

	toggleBtn.AnchorPoint = Vector2.new(0, 0.5)

	local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local activeTweens = {} :: { Tween }

	janitor:Add(function()
		for _, tween in ipairs(activeTweens) do
			tween:Cancel()
		end
	end, true)

	return function(state: boolean)
		currentConfig[configKey] = state

		local targetPos: UDim2
		local buttonColor: Color3
		local frameColor: Color3

		if state then
			targetPos = UDim2.new(1, -toggleBtn.AbsoluteSize.X, 0.5, 0)
			buttonColor = Color3.fromRGB(255, 255, 255)
			frameColor = Color3.fromRGB(255, 139, 0)
			toggleBtn.Text = "ON"
		else
			targetPos = UDim2.new(0, 0, 0.5, 0)
			buttonColor = Color3.fromRGB(200, 200, 200)
			frameColor = Color3.fromRGB(55, 55, 74)
			toggleBtn.Text = "OFF"
		end

		for _, tween in ipairs(activeTweens) do
			tween:Cancel()
		end
		table.clear(activeTweens)

		local buttonTween = TweenService:Create(toggleBtn, tweenInfo, {
			Position = targetPos,
			BackgroundColor3 = buttonColor,
		})
		local frameTween = TweenService:Create(toggleFrame, tweenInfo, {
			BackgroundColor3 = frameColor,
		})

		table.insert(activeTweens, buttonTween)
		table.insert(activeTweens, frameTween)

		buttonTween:Play()
		frameTween:Play()
	end
end

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
	local settingsBtn = menuGui.Top:WaitForChild("settings") :: GuiButton

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local frame = uiGui:WaitForChild("Settings") :: Frame

	local contentBg = frame:WaitForChild("ContentBackground") :: Frame
	local settingsList = contentBg:WaitForChild("SettingsList") :: Frame
	local closeBtn = frame:WaitForChild("CloseBtn") :: GuiButton
	local resetBtn = contentBg:WaitForChild("Reset") :: GuiButton

	local musicSetting = settingsList:WaitForChild("Music")
	local sensSetting = settingsList:WaitForChild("Sensitivity")
	local vibSetting = settingsList:WaitForChild("Vibration")
	local aimSetting = settingsList:WaitForChild("AimAssist")

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

	local currentConfig = {
		MusicVolume = 0.5,
		CameraSensitivity = 0.5,
		Vibration = true,
		AimAssist = true,
	}
	local pendingChanges: PendingChanges = {}

	local function markPending(key: string)
		pendingChanges[key] = true
	end

	local function flushPendingSaves()
		for key in pendingChanges do
			if key == "MusicVolume" or key == "CameraSensitivity" then
				saveSlider(key, currentConfig[key] :: number)
			else
				saveToggle(key, currentConfig[key] :: boolean)
			end
			pendingChanges[key] = nil
		end
	end

	local updateMusic = setupSlider(musicSetting, "MusicVolume", currentConfig, janitor)
	local updateSens = setupSlider(sensSetting, "CameraSensitivity", currentConfig, janitor)
	local updateVib = setupToggle(vibSetting, "Vibration", currentConfig, janitor)
	local updateAim = setupToggle(aimSetting, "AimAssist", currentConfig, janitor)

	local musicDragDetector = (musicSetting :: Instance):WaitForChild("SliderContainer"):WaitForChild("Drag"):WaitForChild("UIDragDetector") :: UIDragDetector
	local sensDragDetector = (sensSetting :: Instance):WaitForChild("SliderContainer"):WaitForChild("Drag"):WaitForChild("UIDragDetector") :: UIDragDetector
	local vibToggleBtn = (vibSetting :: Instance):WaitForChild("ToggleFrame"):WaitForChild("Toggle") :: TextButton
	local aimToggleBtn = (aimSetting :: Instance):WaitForChild("ToggleFrame"):WaitForChild("Toggle") :: TextButton

	janitor:Add(musicDragDetector.DragEnd:Connect(function()
		markPending("MusicVolume")
	end), "Disconnect")

	janitor:Add(sensDragDetector.DragEnd:Connect(function()
		markPending("CameraSensitivity")
	end), "Disconnect")

	janitor:Add(vibToggleBtn.MouseButton1Click:Connect(function()
		local newState = not (currentConfig.Vibration :: boolean)
		updateVib(newState)
		markPending("Vibration")
	end), "Disconnect")

	janitor:Add(aimToggleBtn.MouseButton1Click:Connect(function()
		local newState = not (currentConfig.AimAssist :: boolean)
		updateAim(newState)
		markPending("AimAssist")
	end), "Disconnect")

	janitor:Add(resetBtn.MouseButton1Click:Connect(function()
		updateMusic(0.5)
		updateSens(0.5)
		updateVib(true)
		updateAim(true)

		markPending("MusicVolume")
		markPending("CameraSensitivity")
		markPending("Vibration")
		markPending("AimAssist")
	end), "Disconnect")

	janitor:Add(closeBtn.MouseButton1Click:Connect(function()
		flushPendingSaves()
	end), "Disconnect")

	janitor:Add(frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible == false then
			flushPendingSaves()
		end
	end), "Disconnect")

	janitor:Add(function()
		flushPendingSaves()
	end, true)

	DataController:WhenReady():andThen(function()
		local savedSettings = Fusion.peek(DataController.Settings)

		updateMusic(savedSettings.MusicVolume or 0.5)
		updateSens(savedSettings.CameraSensitivity or 0.5)
		updateVib(if savedSettings.Vibration ~= nil then savedSettings.Vibration else true)
		updateAim(if savedSettings.AimAssist ~= nil then savedSettings.AimAssist else true)
	end)

	return janitor
end

return SettingsFeature
