--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local PanelController = require(Client.core.ui.PanelController)

local PlayTimeRewardsFeature = {}

function PlayTimeRewardsFeature.start(menuController: any): any
	local janitor = Janitor.new()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	local menuBtn = menuGui.RightContainer:WaitForChild("playtime") :: GuiButton

	local gui = playerGui:WaitForChild("PlayTimeRewards") :: ScreenGui
	local container = gui:WaitForChild("Container") :: Frame
	local mainFrame = container:WaitForChild("MainFrame") :: Frame
	local closeBtn = mainFrame:WaitForChild("CloseBtn") :: GuiButton

	local panel = PanelController.new(menuController, gui, container, menuBtn, closeBtn)
	janitor:Add(panel, "Destroy")

	return janitor
end

return PlayTimeRewardsFeature
