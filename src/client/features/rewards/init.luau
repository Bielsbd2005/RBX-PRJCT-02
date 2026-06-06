--!strict
--[[
	rewards/init.luau (Client Feature)
	Panel de recompensas. Estructura de la GUI nueva (UserInterface.Rewards):

		Rewards
		  Header
		    CloseBtn
		  LikeAndJoin
		    ClaimBtn        ← unirse al grupo y reclamar
		  Redeem
		    Container
		      RedeemBtn     ← canjear código
		      TextBox       ← input del código

	Like&Join: la fuente de verdad es Rewards.GroupClaimed (server). Una vez
	reclamado, el frame LikeAndJoin se oculta para siempre (al cargar y tras un
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
local CameraFovEffect = require(Client.core.ui.CameraFovEffect)
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

	-- Botón de apertura opcional (Menu.Rewards).
	local menuGui = menuController:getGui()
	local menuBtnInstance = menuGui:FindFirstChild("Rewards")
	local menuBtn: GuiButton? = if menuBtnInstance and menuBtnInstance:IsA("GuiButton")
		then menuBtnInstance
		else nil

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local frame = uiGui:WaitForChild("Rewards") :: Frame

	local likeAndJoin = frame:WaitForChild("LikeAndJoin") :: Frame
	local likeClaimBtn = likeAndJoin:WaitForChild("ClaimBtn") :: GuiButton

	local redeem = frame:WaitForChild("Redeem")
	local redeemContainer = redeem:WaitForChild("Container")
	local redeemBtn = redeemContainer:WaitForChild("RedeemBtn") :: GuiButton
	local codeTextBox = redeemContainer:WaitForChild("TextBox") :: TextBox

	-- CloseBtn en Rewards.Redeem.Header.CloseBtn (defensivo/opcional por migración).
	local redeemHeader = redeem:FindFirstChild("Header")
	local closeInstance = redeemHeader and redeemHeader:FindFirstChild("CloseBtn")
	local closeBtn: GuiButton? = if closeInstance and closeInstance:IsA("GuiButton")
		then closeInstance
		else nil

	local fovEffect = CameraFovEffect.new()
	janitor:Add(fovEffect, "Destroy")

	local panel = PanelController.new(menuController, frame, menuBtn, closeBtn, {
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			fovEffect:expand()
			-- Empezar siempre con el input de código limpio al (re)entrar.
			codeTextBox.Text = ""
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
			fovEffect:restore()
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
	local function hideLikeAndJoin()
		likeAndJoin.Visible = false
	end

	janitor:Add(likeClaimBtn.MouseButton1Click:Connect(function()
		if likePending then
			return
		end

		local groupId = getGroupId()
		if groupId <= 0 then
			Notify.warning("Esta experiencia no pertenece a un grupo.")
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
				Notify.warning("Sin respuesta del servidor.")
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
			Notify.warning("Escribe un código para canjear.")
			return
		end

		setCodePending(true)
		codeToken += 1
		local token = codeToken
		task.delay(RESPONSE_TIMEOUT, function()
			if token == codeToken and codePending then
				setCodePending(false)
				Notify.warning("Sin respuesta del servidor.")
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
				hideLikeAndJoin()
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
			hideLikeAndJoin()
		end
	end)

	return janitor
end

return RewardsFeature
