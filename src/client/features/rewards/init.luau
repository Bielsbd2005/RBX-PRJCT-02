--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion)
local Network = require(Shared.networking.Network)
local DataController = require(Client.core.data.DataController)
local PanelController = require(Client.core.ui.PanelController)

local RewardsFeature = {}

local function notify(message: string)
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "Rewards",
			Text = message,
			Duration = 3,
		})
	end)
end

local function trySetCore(coreName: string, payload: any?): boolean
	local ok, result = pcall(function()
		if payload == nil then
			StarterGui:SetCore(coreName, nil)
		else
			StarterGui:SetCore(coreName, payload)
		end
	end)

	if not ok then
		return false
	end

	return result == nil or result == true
end

local function promptEnableNotifications()
	if trySetCore("PromptNotificationsPermission") then
		return
	end

	if trySetCore("PromptEnableNotifications") then
		return
	end

	notify("No se pudo abrir el prompt de notificaciones en este dispositivo.")
end

local function promptCommunity()
	if game.CreatorType ~= Enum.CreatorType.Group then
		notify("Este juego no esta publicado bajo grupo/comunidad.")
		return
	end

	local groupId = game.CreatorId
	local communityUrl = "https://www.roblox.com/communities/" .. tostring(groupId)

	local opened = pcall(function()
		if typeof((GuiService :: any).OpenBrowserWindow) == "function" then
			(GuiService :: any):OpenBrowserWindow(communityUrl)
		else
			error("OpenBrowserWindow not available")
		end
	end)

	if opened then
		return
	end

	if trySetCore("PromptOpenURL", { Url = communityUrl }) then
		return
	end

	if trySetCore("PromptOpenURL", { URL = communityUrl }) then
		return
	end

	notify("No se pudo abrir el prompt de comunidad en este dispositivo.")
end

local function setClaimedVisual(button: ImageButton, claimed: boolean)
	button.AutoButtonColor = not claimed
	button.Active = not claimed
	button.ImageColor3 = if claimed then Color3.fromRGB(140, 140, 140) else Color3.fromRGB(255, 255, 255)
end

function RewardsFeature.start(menuController: any): any
	local janitor = Janitor.new()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	local menuBtn = menuGui.RightContainer:WaitForChild("rewards") :: GuiButton

	local gui = playerGui:WaitForChild("RewardsGui") :: ScreenGui
	local container = gui:WaitForChild("Container") :: Frame
	local mainFrame = container:WaitForChild("MainFrame") :: Frame
	local closeBtn = mainFrame:WaitForChild("CloseBtn") :: GuiButton
	local contentBackground = mainFrame:WaitForChild("ContentBackground") :: Frame

	local likeJoinClaimBtn = contentBackground:WaitForChild("Like&Join"):WaitForChild("Claim") :: ImageButton
	local notificationsClaimBtn = contentBackground:WaitForChild("Notifications"):WaitForChild("Claim") :: ImageButton
	local claimCodesNode = contentBackground:WaitForChild("ClaimCodes") :: Frame
	local claimCodeBtn = claimCodesNode:WaitForChild("Claim") :: ImageButton
	local codeTextBox = claimCodesNode:WaitForChild("TextBox") :: TextBox

	local panel = PanelController.new(menuController, gui, container, menuBtn, closeBtn)
	janitor:Add(panel, "Destroy")

	local pending = {
		LikeJoin = false,
		Notifications = false,
		Code = false,
	}

	local function setPending(button: ImageButton, key: string, isPending: boolean)
		pending[key] = isPending
		button.Active = not isPending
		button.AutoButtonColor = not isPending
		button.ImageTransparency = if isPending then 0.35 else 0
	end

	janitor:Add(likeJoinClaimBtn.MouseButton1Click:Connect(function()
		if pending.LikeJoin then
			return
		end

		promptCommunity()
		setPending(likeJoinClaimBtn, "LikeJoin", true)
		Network.Rewards.ClaimLikeJoin.Send({})
	end), "Disconnect")

	janitor:Add(notificationsClaimBtn.MouseButton1Click:Connect(function()
		if pending.Notifications then
			return
		end

		promptEnableNotifications()
		setPending(notificationsClaimBtn, "Notifications", true)
		Network.Rewards.ClaimNotifications.Send({})
	end), "Disconnect")

	janitor:Add(claimCodeBtn.MouseButton1Click:Connect(function()
		if pending.Code then
			return
		end

		local code = codeTextBox.Text
		if code == "" then
			notify("Escribe un codigo para reclamar.")
			return
		end

		setPending(claimCodeBtn, "Code", true)
		Network.Rewards.RedeemCode.Send({
			code = code,
		})
	end), "Disconnect")

	local stopListeningRewardsResponse = Network.Rewards.Response.Listen(function(data: {
		success: boolean,
		message: string,
		claimType: string,
		rewardCash: number,
	})
		notify(data.message)

		if data.claimType == "LikeJoin" then
			setPending(likeJoinClaimBtn, "LikeJoin", false)
			if data.success then
				setClaimedVisual(likeJoinClaimBtn, true)
			end
		elseif data.claimType == "Notifications" then
			setPending(notificationsClaimBtn, "Notifications", false)
			if data.success then
				setClaimedVisual(notificationsClaimBtn, true)
			end
		elseif data.claimType == "Code" then
			setPending(claimCodeBtn, "Code", false)
			if data.success then
				codeTextBox.Text = ""
			end
		end
	end)
	janitor:Add(stopListeningRewardsResponse, true)

	DataController:WhenReady():andThen(function()
		local rewardsData = Fusion.peek(DataController.Rewards)
		setClaimedVisual(likeJoinClaimBtn, rewardsData.LikeState == "Claimed")
		setClaimedVisual(notificationsClaimBtn, rewardsData.NotificationsClaimed == true)
	end)

	return janitor
end

return RewardsFeature
