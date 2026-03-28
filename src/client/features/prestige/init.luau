--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local PanelController = require(Client.core.ui.PanelController)
local DataController = require(Client.core.data.DataController)
local Network = require(Shared.networking.Network)
local PrestigeConfig = require(Shared.constants.PrestigeConfig)

local PrestigeFeature = {}

type StatsData = {
	Level: number,
	Kills: number,
	Deaths: number,
	Wins: number,
}

type PrestigeData = {
	Current: number,
}

type UiRefs = {
	kdValue: TextLabel?,
	killsValue: TextLabel?,
	winsValue: TextLabel?,
	playerBadge: GuiObject?,
	playerLevel: TextLabel?,
	playerName: TextLabel?,
	progressFill: Frame?,
	currentBadge: GuiObject?,
	nextBadge: GuiObject?,
	currentLevel: TextLabel?,
	nextPrestige: TextLabel?,
	requirement1Title: TextLabel?,
	requirement1Value: TextLabel?,
	requirement2Title: TextLabel?,
	requirement2Value: TextLabel?,
	prestigeButton: GuiButton?,
}

local function notify(message: string)
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "Prestige",
			Text = message,
			Duration = 3,
		})
	end)
end

local function toAssetUri(assetId: number): string
	if assetId <= 0 then
		return ""
	end

	return "rbxassetid://" .. tostring(assetId)
end

local function setText(label: TextLabel?, text: string)
	if label then
		label.Text = text
	end
end

local function setBadgeImage(node: GuiObject?, assetId: number)
	if not node then
		return
	end

	local imageUri = toAssetUri(assetId)
	if node:IsA("ImageLabel") or node:IsA("ImageButton") then
		node.Image = imageUri
		return
	end

	if node:IsA("TextLabel") or node:IsA("TextButton") then
		node.Text = if assetId > 0 then ("Badge " .. tostring(assetId)) else "-"
	end
end

local function tryGetTextLabel(parent: Instance?, childName: string): TextLabel?
	if not parent then
		return nil
	end

	local child = parent:FindFirstChild(childName)
	if child and child:IsA("TextLabel") then
		return child
	end

	return nil
end

local function tryGetGuiObject(parent: Instance?, childName: string): GuiObject?
	if not parent then
		return nil
	end

	local child = parent:FindFirstChild(childName)
	if child and child:IsA("GuiObject") then
		return child
	end

	return nil
end

local function resolveUiRefs(mainFrame: Frame): UiRefs
	local playerCard = mainFrame:FindFirstChild("PlayerCard")
	local playerCardMain = if playerCard then playerCard:FindFirstChild("MainFrame") else nil

	local kdNode = if playerCardMain then playerCardMain:FindFirstChild("K/D") else nil
	local killsNode = if playerCardMain then playerCardMain:FindFirstChild("Kills") else nil
	local winsNode = if playerCardMain then playerCardMain:FindFirstChild("Wins") else nil

	local prestigeNode = mainFrame:FindFirstChild("Prestige")
	local prestigeMain = if prestigeNode then prestigeNode:FindFirstChild("MainFrame") else nil
	local content = if prestigeMain then prestigeMain:FindFirstChild("Content") else nil
	local progress = if content then content:FindFirstChild("Progress") else nil
	local sliderFrame = if progress then progress:FindFirstChild("SliderIndicatorFrame") else nil

	local requirement1 = if content then content:FindFirstChild("Requirement1") else nil
	local requirement2 = if content then content:FindFirstChild("Requirement2") else nil

	local prestigeButtonNode = if prestigeMain then prestigeMain:FindFirstChild("Prestige") else nil

	return {
		kdValue = tryGetTextLabel(kdNode, "Value"),
		killsValue = tryGetTextLabel(killsNode, "Value"),
		winsValue = tryGetTextLabel(winsNode, "Value"),
		playerBadge = tryGetGuiObject(playerCard, "Badge"),
		playerLevel = tryGetTextLabel(playerCard, "Level"),
		playerName = tryGetTextLabel(playerCard, "Name"),
		progressFill = (if sliderFrame and sliderFrame:FindFirstChild("Fill") and sliderFrame.Fill:IsA("Frame") then sliderFrame.Fill else nil) :: Frame?,
		currentBadge = tryGetGuiObject(progress, "CurrentBadge"),
		nextBadge = tryGetGuiObject(progress, "NextBadge"),
		currentLevel = tryGetTextLabel(progress, "CurrentLevel"),
		nextPrestige = tryGetTextLabel(progress, "NextPrestige"),
		requirement1Title = tryGetTextLabel(requirement1, "Title"),
		requirement1Value = tryGetTextLabel(requirement1, "Value"),
		requirement2Title = tryGetTextLabel(requirement2, "Title"),
		requirement2Value = tryGetTextLabel(requirement2, "Value"),
		prestigeButton = if prestigeButtonNode and prestigeButtonNode:IsA("GuiButton") then prestigeButtonNode else nil,
	}
end

local function getStat(stats: StatsData, key: string): number
	local value = (stats :: any)[key]
	if type(value) ~= "number" then
		return 0
	end

	return math.max(0, math.floor(value))
end

local function updatePlayerCard(uiRefs: UiRefs, player: Player, stats: StatsData, prestige: PrestigeData)
	local deaths = math.max(0, stats.Deaths)
	local kd = if deaths <= 0 then stats.Kills else (stats.Kills / deaths)

	setText(uiRefs.kdValue, string.format("%.2f", kd))
	setText(uiRefs.killsValue, tostring(stats.Kills))
	setText(uiRefs.winsValue, tostring(stats.Wins))
	setText(uiRefs.playerLevel, tostring(stats.Level))
	setText(uiRefs.playerName, player.DisplayName)

	local currentBadgeAssetId = PrestigeConfig.GetCurrentBadgeAssetId(prestige.Current)
	setBadgeImage(uiRefs.playerBadge, currentBadgeAssetId)
end

local function updatePrestigeContent(uiRefs: UiRefs, stats: StatsData, prestige: PrestigeData)
	local currentPrestige = math.max(0, prestige.Current)
	local currentDefinition = PrestigeConfig.GetDefinition(currentPrestige)
	local nextDefinition = PrestigeConfig.GetNextDefinition(currentPrestige)

	local currentBadgeAssetId = PrestigeConfig.GetCurrentBadgeAssetId(currentPrestige)
	setBadgeImage(uiRefs.currentBadge, currentBadgeAssetId)

	local currentUnlockLevel = if currentDefinition then currentDefinition.UnlockLevel else 0
	setText(uiRefs.currentLevel, "Lvl " .. tostring(currentUnlockLevel))
	setText(uiRefs.nextPrestige, if nextDefinition then ("Lvl " .. tostring(nextDefinition.UnlockLevel)) else "MAX")

	if not nextDefinition then
		setBadgeImage(uiRefs.nextBadge, 0)
		setText(uiRefs.requirement1Title, "Max prestige reached")
		setText(uiRefs.requirement1Value, "Done")
		setText(uiRefs.requirement2Title, "")
		setText(uiRefs.requirement2Value, "")

		if uiRefs.progressFill then
			uiRefs.progressFill.Size = UDim2.new(1, 0, 1, 0)
		end

		if uiRefs.prestigeButton then
			uiRefs.prestigeButton.Active = false
			uiRefs.prestigeButton.AutoButtonColor = false
		end

		return
	end

	setBadgeImage(uiRefs.nextBadge, nextDefinition.BadgeAssetId)

	local levelProgress = 0
	if nextDefinition.UnlockLevel > 0 then
		levelProgress = math.clamp(stats.Level / nextDefinition.UnlockLevel, 0, 1)
	end

	if uiRefs.progressFill then
		uiRefs.progressFill.Size = UDim2.new(levelProgress, 0, 1, 0)
	end

	local requirement1 = nextDefinition.Requirement1
	local requirement2 = nextDefinition.Requirement2
	local currentReq1 = getStat(stats, requirement1.StatKey)
	local currentReq2 = getStat(stats, requirement2.StatKey)

	setText(uiRefs.requirement1Title, requirement1.Title)
	setText(uiRefs.requirement1Value, string.format("%d/%d", currentReq1, requirement1.Required))
	setText(uiRefs.requirement2Title, requirement2.Title)
	setText(uiRefs.requirement2Value, string.format("%d/%d", currentReq2, requirement2.Required))

	local canPrestige = stats.Level >= nextDefinition.UnlockLevel
		and currentReq1 >= requirement1.Required
		and currentReq2 >= requirement2.Required

	if uiRefs.prestigeButton then
		uiRefs.prestigeButton.Active = canPrestige
		uiRefs.prestigeButton.AutoButtonColor = canPrestige
	end
end

function PrestigeFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	local menuBtn = menuGui.RightContainer:WaitForChild("prestige") :: GuiButton

	local gui = playerGui:WaitForChild("PrestigeGui") :: ScreenGui
	local container = gui:WaitForChild("Container") :: Frame
	local closeBtn = container:WaitForChild("MainFrame"):WaitForChild("CloseBtn") :: GuiButton
	local mainFrame = container:WaitForChild("MainFrame") :: Frame

	local panel = PanelController.new(menuController, gui, container, menuBtn, closeBtn)
	janitor:Add(panel, "Destroy")

	local uiRefs = resolveUiRefs(mainFrame)
	local requestPending = false

	if uiRefs.prestigeButton then
		janitor:Add(uiRefs.prestigeButton.MouseButton1Click:Connect(function()
			if requestPending then
				return
			end

			requestPending = true
			Network.Prestige.Request.Send({})
		end), "Disconnect")
	end

	local stopListeningResponse = Network.Prestige.Response.Listen(function(data: {
		success: boolean,
		message: string,
		newPrestige: number,
	})
		requestPending = false
		notify(data.message)
	end)
	janitor:Add(stopListeningResponse, true)

	DataController:WhenReady():andThen(function()
		local function updateUi()
			local stats = Fusion.peek(DataController.Stats) :: StatsData
			local prestige = Fusion.peek(DataController.Prestige) :: PrestigeData
			updatePlayerCard(uiRefs, player, stats, prestige)
			updatePrestigeContent(uiRefs, stats, prestige)
		end

		local statsObserver = fusionScope:Observer(DataController.Stats)
		janitor:Add(statsObserver:onBind(updateUi), true)

		local prestigeObserver = fusionScope:Observer(DataController.Prestige)
		janitor:Add(prestigeObserver:onBind(updateUi), true)
	end)

	return janitor
end

return PrestigeFeature
