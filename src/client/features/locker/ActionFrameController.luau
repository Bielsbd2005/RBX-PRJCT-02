--!strict
-- ActionFrameController.luau (Client Feature Library)
-- Gestiona la interfaz y las animaciones/transiciones del panel lateral derecho (ActionFrame) del vestuario.

local TweenService = game:GetService("TweenService")
local Client = script.Parent.Parent.Parent
local UITheme = require(Client:WaitForChild("core"):WaitForChild("ui"):WaitForChild("UITheme"))
local UIUtils = require(Client:WaitForChild("core"):WaitForChild("ui"):WaitForChild("UIUtils"))

local STROKE_DEFAULT = UITheme.StrokeDefault
local STROKE_WHITE = UITheme.StrokeHover
local PURCHASE_BUTTON_HOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PURCHASE_BUTTON_CLICK_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ACTION_FRAME_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PURCHASE_BUTTON_DEFAULT_SCALE = 1
local PURCHASE_BUTTON_HOVER_SCALE = 1.03
local PURCHASE_BUTTON_CLICK_SCALE = 0.96

export type ActionFrameConfig = {
	actionFrame: GuiObject,
	purchaseButtonContainer: GuiButton,
	wrapsButtonContainer: GuiButton,
	purchasePriceLabel: TextLabel,
	purchaseIconLocked: GuiObject,
	purchaseLockedGradient: UIGradient,
	purchaseUnlockedGradient: UIGradient,
	visiblePosition: UDim2,
	hiddenPosition: UDim2,
}

local ActionFrameController = {}
ActionFrameController.__index = ActionFrameController

function ActionFrameController.new(config: ActionFrameConfig)
	local self = setmetatable({}, ActionFrameController)
	self.actionFrame = config.actionFrame
	self.purchaseButtonContainer = config.purchaseButtonContainer
	self.wrapsButtonContainer = config.wrapsButtonContainer
	self.purchasePriceLabel = config.purchasePriceLabel
	self.purchaseIconLocked = config.purchaseIconLocked
	self.purchaseLockedGradient = config.purchaseLockedGradient
	self.purchaseUnlockedGradient = config.purchaseUnlockedGradient
	self.visiblePosition = config.visiblePosition
	self.hiddenPosition = config.hiddenPosition

	self.activeActionFrameTween = nil :: Tween?
	self.activePurchaseScaleTween = nil :: Tween?
	self.activePurchaseStrokeTween = nil :: Tween?
	self.purchaseButtonIsHovered = false

	return self
end

local function getButtonStroke(button: GuiButton): UIStroke?
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		return stroke
	end
	local folder = button:FindFirstChild("Stroke")
	if folder then
		return folder:FindFirstChildOfClass("UIStroke")
	end
	return nil
end

function ActionFrameController:tweenFrame(visible: boolean)
	if self.activeActionFrameTween then
		self.activeActionFrameTween:Cancel()
		self.activeActionFrameTween = nil
	end

	if visible then
		self.actionFrame.Visible = true
	end

	local targetPos = if visible then self.visiblePosition else self.hiddenPosition
	local tween = TweenService:Create(self.actionFrame, ACTION_FRAME_TWEEN_INFO, {
		Position = targetPos,
	})
	self.activeActionFrameTween = tween
	tween.Completed:Once(function()
		if self.activeActionFrameTween == tween then
			self.activeActionFrameTween = nil
			if not visible then
				self.actionFrame.Visible = false
			end
		end
	end)
	tween:Play()
end

function ActionFrameController:showForItem(item: any, currentLevel: number)
	self.purchaseButtonContainer.Visible = true
	self.wrapsButtonContainer.Visible = false

	local isLevelLocked = currentLevel < item.LevelRequired
	self.purchasePriceLabel.Text = if isLevelLocked then "LOCKED" else UIUtils.formatCashAmount(item.Price)
	self.purchaseIconLocked.Visible = isLevelLocked
	self.purchaseLockedGradient.Enabled = isLevelLocked
	self.purchaseUnlockedGradient.Enabled = not isLevelLocked
	self.purchaseButtonContainer.Active = not isLevelLocked
	self.purchaseButtonContainer.Selectable = not isLevelLocked

	self:tweenFrame(true)
end

function ActionFrameController:showOwnedWeapon()
	self.purchaseButtonContainer.Visible = false
	self.wrapsButtonContainer.Visible = true
	self:tweenFrame(true)
end

function ActionFrameController:hide()
	self:tweenFrame(false)
end

function ActionFrameController:setupAnimations(canUseHoverAnimations: boolean, janitor: any)
	local purchaseButton = self.purchaseButtonContainer
	local purchaseButtonScaleNode = purchaseButton:FindFirstChildWhichIsA("UIScale")
	if not purchaseButtonScaleNode then
		local sc = Instance.new("UIScale")
		sc.Scale = PURCHASE_BUTTON_DEFAULT_SCALE
		sc.Parent = purchaseButton
		purchaseButtonScaleNode = sc
	end
	purchaseButtonScaleNode.Scale = PURCHASE_BUTTON_DEFAULT_SCALE

	local purchaseButtonStroke = getButtonStroke(purchaseButton)
	if purchaseButtonStroke then
		purchaseButtonStroke.Color = STROKE_DEFAULT
	end

	local function tweenScale(targetScale: number, tweenInfo: TweenInfo)
		if self.activePurchaseScaleTween then
			self.activePurchaseScaleTween:Cancel()
		end
		self.activePurchaseScaleTween = TweenService:Create(purchaseButtonScaleNode, tweenInfo, { Scale = targetScale })
		self.activePurchaseScaleTween:Play()
	end

	local function tweenStroke(targetColor: Color3, tweenInfo: TweenInfo)
		if not purchaseButtonStroke then return end
		if self.activePurchaseStrokeTween then
			self.activePurchaseStrokeTween:Cancel()
		end
		self.activePurchaseStrokeTween = TweenService:Create(purchaseButtonStroke, tweenInfo, { Color = targetColor })
		self.activePurchaseStrokeTween:Play()
	end

	if canUseHoverAnimations then
		janitor:Add(purchaseButton.MouseEnter:Connect(function()
			self.purchaseButtonIsHovered = true
			tweenScale(PURCHASE_BUTTON_HOVER_SCALE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
			tweenStroke(STROKE_WHITE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
		end), "Disconnect")

		janitor:Add(purchaseButton.MouseLeave:Connect(function()
			self.purchaseButtonIsHovered = false
			tweenScale(PURCHASE_BUTTON_DEFAULT_SCALE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
			tweenStroke(STROKE_DEFAULT, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
		end), "Disconnect")
	end

	janitor:Add(purchaseButton.MouseButton1Down:Connect(function()
		tweenScale(PURCHASE_BUTTON_CLICK_SCALE, PURCHASE_BUTTON_CLICK_TWEEN_INFO)
		tweenStroke(STROKE_WHITE, PURCHASE_BUTTON_CLICK_TWEEN_INFO)
	end), "Disconnect")

	janitor:Add(purchaseButton.MouseButton1Up:Connect(function()
		local targetScale = if self.purchaseButtonIsHovered and canUseHoverAnimations
			then PURCHASE_BUTTON_HOVER_SCALE
			else PURCHASE_BUTTON_DEFAULT_SCALE
		tweenScale(targetScale, PURCHASE_BUTTON_HOVER_TWEEN_INFO)

		local targetStrokeColor = if self.purchaseButtonIsHovered and canUseHoverAnimations then STROKE_WHITE else STROKE_DEFAULT
		tweenStroke(targetStrokeColor, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
	end), "Disconnect")
end

function ActionFrameController:Destroy()
	if self.activeActionFrameTween then self.activeActionFrameTween:Cancel() end
	if self.activePurchaseScaleTween then self.activePurchaseScaleTween:Cancel() end
	if self.activePurchaseStrokeTween then self.activePurchaseStrokeTween:Cancel() end
end

return ActionFrameController
