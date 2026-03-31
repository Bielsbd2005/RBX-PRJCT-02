--!strict

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local MenuHover = require(Client.core.ui.MenuHover)
local GuiAnimator = require(Client.core.ui.animators.GuiAnimator)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local StoreProducts = require(Shared.constants.StoreProducts)

local StoreFeature = {}

local CLOSE_BUTTON_NAMES = {
	"CloseBtn",
	"Close",
	"close",
	"Cerrar",
} :: { string }

local CONTAINER_NAMES = {
	"Container",
	"Root",
	"MainFrame",
} :: { string }

local FOV_OPEN_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FOV_CLOSE_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FOV_EXPAND_DELTA = 10
local FOV_MAX = 90

type StoreProductDefinition = StoreProducts.StoreProductDefinition

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

local function findContainer(root: Instance): Frame?
	for _, containerName in CONTAINER_NAMES do
		local candidate = root:FindFirstChild(containerName, true)
		if candidate and candidate:IsA("Frame") then
			return candidate
		end
	end

	return nil
end

function StoreFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()
	local storeButton = findFooterButton(menuGui, "store")
	local storeGui = playerGui:FindFirstChild("Store")

	if not storeButton or not storeGui or not storeGui:IsA("ScreenGui") then
		return janitor
	end

	local main = storeGui:WaitForChild("Main")
	local footer = storeGui:WaitForChild("Footer")
	local container = findContainer(storeGui)
	local closeButton = footer:WaitForChild("CloseBtn") :: GuiButton
	local cashContainer = (main :: Instance):WaitForChild("Container"):WaitForChild("Cash")
	local animator = if container then GuiAnimator.new(storeGui, container) else nil
	local activeFovTween: Tween? = nil
	local savedFov: number? = nil
	local isOpen = false
	local canUseHoverAnimations = game:GetService("UserInputService").MouseEnabled
		and not game:GetService("UserInputService").TouchEnabled

	if animator then
		janitor:Add(animator, "Destroy")
	end

	if storeGui.Enabled then
		storeGui.Enabled = false
	end

	local function formatCashAmount(amount: number): string
		local formatted = tostring(math.max(0, math.floor(amount)))
		local withSeparators = string.reverse(formatted):gsub("(%d%d%d)", "%1,")
		withSeparators = string.reverse(withSeparators)
		if string.sub(withSeparators, 1, 1) == "," then
			withSeparators = string.sub(withSeparators, 2)
		end
		return withSeparators
	end

	local function applyProductToButton(button: GuiButton, product: StoreProductDefinition)
		local priceLabel = button:FindFirstChild("Price", true)
		if priceLabel and priceLabel:IsA("TextLabel") then
			priceLabel.Text = product.PriceText
		end

		local amountLabel = button:FindFirstChild("Ammount", true)
		if amountLabel and amountLabel:IsA("TextLabel") then
			amountLabel.Text = formatCashAmount(product.CashAmount)
		end

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
					hoverScale = 1.04,
					clickScale = 0.96,
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

	local function setMenuVisible(visible: boolean)
		if visible then
			menuController:show()
		else
			menuController:hide()
		end
	end

	local function tweenCameraFov(targetFov: number, tweenInfo: TweenInfo)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		if activeFovTween then
			activeFovTween:Cancel()
			activeFovTween = nil
		end

		activeFovTween = TweenService:Create(camera, tweenInfo, {
			FieldOfView = targetFov,
		})
		activeFovTween.Completed:Connect(function()
			if activeFovTween then
				activeFovTween = nil
			end
		end)
		activeFovTween:Play()
	end

	local function restoreFov()
		if savedFov == nil then
			return
		end

		tweenCameraFov(savedFov, FOV_CLOSE_TWEEN_INFO)
		savedFov = nil
	end

	local function openStoreGui()
		if isOpen then
			return
		end

		local camera = Workspace.CurrentCamera
		if camera and savedFov == nil then
			savedFov = camera.FieldOfView
			tweenCameraFov(math.min(savedFov + FOV_EXPAND_DELTA, FOV_MAX), FOV_OPEN_TWEEN_INFO)
		end

		isOpen = true
		if animator then
			animator:open()
		else
			storeGui.Enabled = true
		end
		setMenuVisible(false)
	end

	local function closeStoreGui()
		if not isOpen then
			return
		end

		isOpen = false
		if animator then
			animator:close()
		else
			storeGui.Enabled = false
		end
		restoreFov()
		setMenuVisible(true)
	end

	janitor:Add(storeButton.MouseButton1Click:Connect(openStoreGui), "Disconnect")

	local resetClose = MenuHover.bindButton(closeButton, janitor)
	janitor:Add(closeButton.MouseButton1Click:Connect(function()
		resetClose()
		closeStoreGui()
	end), "Disconnect")

	janitor:Add(storeGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if storeGui.Enabled == false and isOpen then
			isOpen = false
			restoreFov()
			setMenuVisible(true)
		end
	end), "Disconnect")

	janitor:Add(function()
		if activeFovTween then
			activeFovTween:Cancel()
			activeFovTween = nil
		end

		if isOpen then
			restoreFov()
			setMenuVisible(true)
		end
	end, true)

	return janitor
end

return StoreFeature
