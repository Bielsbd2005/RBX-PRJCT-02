--!strict
--[[
	rewards/init.luau (Client Feature)
	Panel de recompensas (UserInterface.Rewards):

		Rewards
		  Action
		    Container
		      ClaimBtn      ← unirse al grupo y reclamar
		  Redeem
		    Content
		      Header
		        CloseBtn
		      Container
		        RedeemBtn   ← canjear código
		        TextBox     ← input del código

	Action: la fuente de verdad es Rewards.GroupClaimed (server). Una vez
	reclamado, el frame Action se oculta para siempre (al cargar y tras un
	claim exitoso). El grupo a unirse es el de la experiencia (game.CreatorId),
	que es justo el que el server comprueba con player:IsInGroup.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GroupService = game:GetService("GroupService")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion)
local Network = require(Shared.networking.Network)
local DataController = require(Client.core.data.DataController)
local PanelController = require(Client.core.ui.PanelController)
local BlurController = require(Client.core.ui.BlurController)
local Notify = require(Client.core.ui.NotificationController)

local BLUR_KEY = "Rewards"
local RESPONSE_TIMEOUT = 5

local RewardsFeature = {}

-- Grupo de la experiencia: 0 si la experiencia no pertenece a un grupo.
local function getGroupId(): number
	return if game.CreatorType == Enum.CreatorType.Group then game.CreatorId else 0
end

function RewardsFeature.start(menuController: any): any
	local janitor = Janitor.new()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- Botón de apertura en Menu.Container.TopFrame.RightContainer.Rewards
	local menuGui = menuController:getGui()
	local container = menuGui:WaitForChild("Container")
	local topFrame = container:WaitForChild("TopFrame")
	local rightContainer = topFrame:WaitForChild("RightContainer")
	local menuBtn = rightContainer:WaitForChild("Rewards") :: GuiButton

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local frame = uiGui:WaitForChild("Rewards") :: Frame

	local action = frame:WaitForChild("Action") :: Frame
	local actionContainer = action:WaitForChild("Container")
	local likeClaimBtn = actionContainer:WaitForChild("ClaimBtn") :: GuiButton

	local redeem = frame:WaitForChild("Redeem")
	local redeemContent = redeem:WaitForChild("Content")

	local redeemHeader = redeemContent:WaitForChild("Header")
	local closeBtn = redeemHeader:WaitForChild("CloseBtn") :: GuiButton

	local redeemContainer = redeemContent:WaitForChild("Container")
	local redeemBtn = redeemContainer:WaitForChild("RedeemBtn") :: GuiButton
	local codeTextBox = redeemContainer:WaitForChild("TextBox") :: TextBox


	local panel = PanelController.new(menuController, frame, menuBtn, closeBtn, {
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			-- Empezar siempre con el input de código limpio al (re)entrar.
			codeTextBox.Text = ""
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
		end,
	})
	janitor:Add(panel, "Destroy")

	-- Guard anti-spam por botón: token incremental para que un timeout obsoleto
	-- no reactive un botón que ya respondió.
	local likePending = false
	local codePending = false
	local likeToken = 0
	local codeToken = 0

	local function setLikePending(pending: boolean)
		likePending = pending
		likeClaimBtn.Active = not pending
		likeClaimBtn.AutoButtonColor = not pending
	end

	local function setCodePending(pending: boolean)
		codePending = pending
		redeemBtn.Active = not pending
		redeemBtn.AutoButtonColor = not pending
	end

	-- Reclamado → ocultar para siempre (persistido en GroupClaimed server-side).
	local function hideAction()
		action.Visible = false
	end

	janitor:Add(likeClaimBtn.MouseButton1Click:Connect(function()
		if likePending then
			return
		end

		local groupId = getGroupId()
		if groupId <= 0 then
			Notify.warning("This experience isn't linked to a group.")
			return
		end

		pcall(function()
			GroupService:PromptJoinAsync(groupId)
		end)

		setLikePending(true)
		likeToken += 1
		local token = likeToken
		task.delay(RESPONSE_TIMEOUT, function()
			if token == likeToken and likePending then
				setLikePending(false)
				Notify.warning("No response from the server. Try again.")
			end
		end)

		Network.Rewards.ClaimLikeJoin.Send({})
	end), "Disconnect")

	janitor:Add(redeemBtn.MouseButton1Click:Connect(function()
		if codePending then
			return
		end

		local code = codeTextBox.Text
		if code == "" then
			Notify.warning("Enter a code to redeem.")
			return
		end

		setCodePending(true)
		codeToken += 1
		local token = codeToken
		task.delay(RESPONSE_TIMEOUT, function()
			if token == codeToken and codePending then
				setCodePending(false)
				Notify.warning("No response from the server. Try again.")
			end
		end)

		Network.Rewards.RedeemCode.Send({ code = code })
	end), "Disconnect")

	janitor:Add(Network.Rewards.Response.Listen(function(data: {
		success: boolean,
		message: string,
		claimType: string,
		rewardCash: number,
	})
		if data.success then
			Notify.success(data.message)
		else
			Notify.warning(data.message)
		end

		if data.claimType == "LikeJoin" then
			likeToken += 1
			setLikePending(false)
			if data.success then
				hideAction()
			end
		elseif data.claimType == "Code" then
			codeToken += 1
			setCodePending(false)
			if data.success then
				codeTextBox.Text = ""
			end
		end
	end), true)

	DataController:WhenReady():andThen(function()
		local rewardsData = Fusion.peek(DataController.Rewards)
		if rewardsData.GroupClaimed == true then
			hideAction()
		end
	end)

	return janitor
end

return RewardsFeature
