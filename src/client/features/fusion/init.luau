--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local MenuHover = require(Client.core.ui.MenuHover)

local FusionFeature = {}

local CLOSE_BUTTON_NAMES = {
	"CloseBtn",
	"Close",
	"close",
	"Cerrar",
} :: { string }

local function findFooterButton(menuGui: ScreenGui, buttonName: string): GuiButton?
	local bottomContainer = menuGui:FindFirstChild("BottomContainer")
	if not bottomContainer then
		return nil
	end

	local footer = bottomContainer:FindFirstChild("Footer")
	if not footer then
		return nil
	end

	local targetButton = footer:FindFirstChild(buttonName)
	if targetButton and targetButton:IsA("GuiButton") then
		return targetButton
	end

	return nil
end

local function findCloseButton(root: Instance): GuiButton?
	for _, closeButtonName in CLOSE_BUTTON_NAMES do
		local candidate = root:FindFirstChild(closeButtonName, true)
		if candidate and candidate:IsA("GuiButton") then
			return candidate
		end
	end

	return nil
end

function FusionFeature.start(menuController: any): any
	local janitor = Janitor.new()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	local fusionButton = findFooterButton(menuGui, "fusion")
	if not fusionButton then
		warn("[FusionFeature] Footer button 'fusion' not found")
		return janitor
	end

	local fusionGui = playerGui:WaitForChild("Fusion") :: ScreenGui
	local closeButton = findCloseButton(fusionGui)
	local cameraController = LockerCameraController.new("fusion")
	janitor:Add(cameraController, "Destroy")

	fusionGui.Enabled = false

	local isOpen = false

	local function setMenuVisibleInstant(visible: boolean)
		menuGui.Enabled = visible
	end

	local function openFusionGui()
		if isOpen then
			return
		end

		isOpen = true
		cameraController:apply()
		fusionGui.Enabled = true
		setMenuVisibleInstant(false)
	end

	local function closeFusionGui()
		if not isOpen then
			return
		end

		isOpen = false
		fusionGui.Enabled = false
		cameraController:restore()
		setMenuVisibleInstant(true)
	end

	janitor:Add(fusionButton.MouseButton1Click:Connect(openFusionGui), "Disconnect")

	if closeButton then
		local resetClose = MenuHover.bindButton(closeButton, janitor)
		janitor:Add(closeButton.MouseButton1Click:Connect(function()
			resetClose()
			closeFusionGui()
		end), "Disconnect")
	end

	janitor:Add(fusionGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if fusionGui.Enabled == false and isOpen then
			isOpen = false
			cameraController:restore()
			setMenuVisibleInstant(true)
		end
	end), "Disconnect")

	janitor:Add(function()
		if isOpen then
			cameraController:restore()
			setMenuVisibleInstant(true)
		end
	end, true)

	return janitor
end

return FusionFeature
