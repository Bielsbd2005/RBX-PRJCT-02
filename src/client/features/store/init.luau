--!strict

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local FeaturePanelController = require(Client.core.ui.FeaturePanelController)
local NavTabController = require(Client.core.ui.NavTabController)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local BlurController = require(Client.core.ui.BlurController)
local StoreProducts = require(Shared.constants.StoreProducts)

local BLUR_KEY = "Store"

local StoreFeature = {}

local FOV_OPEN_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FOV_CLOSE_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FOV_EXPAND_DELTA = 10
local FOV_MAX = 90

type StoreProductDefinition = StoreProducts.StoreProductDefinition

function StoreFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()
	local storeButton = UIUtils.findFooterButton(menuGui, "store")
	local storeGui = playerGui:FindFirstChild("Store")

	if not storeButton or not storeGui or not storeGui:IsA("ScreenGui") then
		return janitor
	end

	local containerNode = storeGui:FindFirstChild("Container")
	if not containerNode or not containerNode:IsA("Frame") then
		warn("[StoreFeature] No se pudo encontrar el Container en", storeGui:GetFullName())
		return janitor
	end
	local container = containerNode :: Frame

	local nav = container:WaitForChild("Nav")
	local closeButton = nav:WaitForChild("CloseBtn") :: GuiButton

	local cashContainer = container:WaitForChild("Cash") :: GuiObject

	local activeFovTween: Tween? = nil
	local savedFov: number? = nil
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	local function applyProductToButton(button: GuiButton, product: StoreProductDefinition)
		local priceLabel = button:WaitForChild("Price") :: TextLabel
		local amountLabel = button:WaitForChild("Ammount") :: TextLabel
		priceLabel.Text = product.PriceText
		amountLabel.Text = UIUtils.formatCashAmount(product.CashAmount)

		button.Active = product.ProductId > 0
		button.Selectable = product.ProductId > 0
		button.AutoButtonColor = false
	end

	local function bindCashButtons()
		for _, product in StoreProducts.ProductsInOrder do
			local buttonNode = cashContainer:FindFirstChild(product.ButtonName)
			if buttonNode and buttonNode:IsA("GuiButton") then
				local button = buttonNode :: GuiButton
				applyProductToButton(button, product)
				InteractiveScaleTween.bindButton(button, janitor, {
					enableHover = canUseHoverAnimations,
					hoverScale = UITheme.ButtonHoverScale,
					clickScale = UITheme.ButtonClickScale,
				})
				janitor:Add(button.Activated:Connect(function()
					if product.ProductId <= 0 then
						warn("[StoreFeature] ProductId no configurado para", product.ButtonName)
						return
					end

					MarketplaceService:PromptProductPurchase(player, product.ProductId)
				end), "Disconnect")
			end
		end
	end

	bindCashButtons()

	-- ── Nav tabs ─────────────────────────────────────────────
	local navFrames = {} :: { [string]: GuiObject }
	local activeNavTab: string? = nil
	local navTabController = NavTabController.new()
	janitor:Add(navTabController, "Destroy")

	local strokeTweens = {} :: { [GuiButton]: Tween }
	local function tweenStroke(button: GuiButton, stroke: UIStroke, color: Color3)
		local existing = strokeTweens[button]
		if existing then
			existing:Cancel()
		end
		local tween = TweenService:Create(stroke, UITheme.NavTweenInfo, { Color = color })
		strokeTweens[button] = tween
		tween:Play()
	end
	janitor:Add(function()
		for _, tween in strokeTweens do
			tween:Cancel()
		end
		table.clear(strokeTweens)
	end, true)

	local function setActiveTab(name: string)
		if activeNavTab == name then return end
		activeNavTab = name
		for tabName, frame in navFrames do
			frame.Visible = (tabName == name)
		end
		navTabController:setActive(name)
	end

	for _, child in nav:GetChildren() do
		if child:IsA("GuiButton") and child.Name ~= "CloseBtn" and child.Name ~= "Close" then
			local btn = child :: GuiButton
			local targetFrame = container:FindFirstChild(btn.Name)

			if targetFrame and targetFrame:IsA("GuiObject") then
				navFrames[btn.Name] = targetFrame
				navTabController:register(btn.Name, btn)

				local stroke = btn:FindFirstChildOfClass("UIStroke")
				if stroke then
					local defaultColor = stroke.Color

					janitor:Add(btn.MouseEnter:Connect(function()
						if canUseHoverAnimations then
							tweenStroke(btn, stroke, UITheme.StrokeHover)
						end
					end), "Disconnect")

					janitor:Add(btn.MouseLeave:Connect(function()
						tweenStroke(btn, stroke, defaultColor)
					end), "Disconnect")
				end

				janitor:Add(btn.Activated:Connect(function()
					setActiveTab(btn.Name)
				end), "Disconnect")
			end
		end
	end

	local hasSetDefault = false
	for name, frame in navFrames do
		if name == "Cash" or (not hasSetDefault and not navFrames["Cash"]) then
			frame.Visible = true
			activeNavTab = name
			hasSetDefault = true
		else
			frame.Visible = false
		end
	end
	if activeNavTab then
		navTabController:setActive(activeNavTab)
	end

	-- ── FOV camera ────────────────────────────────────────────
	local function tweenCameraFov(targetFov: number, tweenInfo: TweenInfo)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		if activeFovTween then
			activeFovTween:Cancel()
			activeFovTween = nil
		end

		local tween = TweenService:Create(camera, tweenInfo, {
			FieldOfView = targetFov,
		})
		activeFovTween = tween
		tween.Completed:Connect(function()
			if activeFovTween == tween then
				activeFovTween = nil
			end
		end)
		tween:Play()
	end

	local function restoreFov()
		local fov = savedFov
		if fov == nil then
			return
		end

		tweenCameraFov(fov, FOV_CLOSE_TWEEN_INFO)
		savedFov = nil
	end

	-- ── Panel controller ──────────────────────────────────────
	local panel = FeaturePanelController.new({
		menuController = menuController,
		screenGui = storeGui,
		openButton = storeButton,
		closeButton = closeButton,
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			local camera = Workspace.CurrentCamera
			local fov = if camera then camera.FieldOfView else nil
			if camera and fov and savedFov == nil then
				savedFov = fov
				tweenCameraFov(math.min(fov + FOV_EXPAND_DELTA, FOV_MAX), FOV_OPEN_TWEEN_INFO)
			end
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
			restoreFov()
		end,
	})
	janitor:Add(panel, "Destroy")

	janitor:Add(function()
		if activeFovTween then
			activeFovTween:Cancel()
			activeFovTween = nil
		end
	end, true)

	return janitor
end

return StoreFeature
