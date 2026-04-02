--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local MenuHover = require(Client.core.ui.MenuHover)

local CasesFeature = {}

local CLOSE_BUTTON_NAMES = {
	"CloseBtn",
	"Close",
	"close",
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
	for _, name in CLOSE_BUTTON_NAMES do
		local candidate = root:FindFirstChild(name, true)
		if candidate and candidate:IsA("GuiButton") then
			return candidate
		end
	end

	return nil
end

function CasesFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()
	local casesButton = findFooterButton(menuGui, "cases")
	local casesGui = playerGui:FindFirstChild("Cases")

	if not casesButton or not casesGui or not casesGui:IsA("ScreenGui") then
		return janitor
	end

	local closeButton = findCloseButton(casesGui)
	local cameraController = LockerCameraController.new("cases")
	local isOpen = false

	janitor:Add(cameraController, "Destroy")
	casesGui.Enabled = false

	local function setMenuVisibleInstant(visible: boolean)
		menuGui.Enabled = visible
	end

	local function openCasesGui()
		if isOpen then
			return
		end

		isOpen = true
		cameraController:apply()
		casesGui.Enabled = true
		setMenuVisibleInstant(false)
	end

	local function closeCasesGui()
		if not isOpen then
			return
		end

		isOpen = false
		cameraController:restore()
		casesGui.Enabled = false
		setMenuVisibleInstant(true)
	end

	janitor:Add(casesButton.MouseButton1Click:Connect(openCasesGui), "Disconnect")

	if closeButton then
		local resetClose = MenuHover.bindButton(closeButton, janitor)
		janitor:Add(closeButton.MouseButton1Click:Connect(function()
			resetClose()
			closeCasesGui()
		end), "Disconnect")
	end

	janitor:Add(casesGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if casesGui.Enabled == false and isOpen then
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

return CasesFeature
