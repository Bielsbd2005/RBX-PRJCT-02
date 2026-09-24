--!strict
--[[
	Panel de acción del Locker (compra / bloqueo por nivel), único para todos los ítems.
	Studio, bajo UserInterface.Locker:
	  ActionFrame.Title.Text.Title / .Subtitle → título y subtítulo
	  ActionFrame.Title.Icon                    → icono (candado / compra)
	  ActionFrame**.ActionBtn                   → botón (búsqueda recursiva)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Client = script.Parent.Parent.Parent
local AssetIds = require(Shared.constants.AssetIds)
local CurrencyMod = require(Shared.constants.Currency)
local UITheme = require(Client.core.ui.UITheme)
local UIUtils = require(Client.core.ui.UIUtils)
local LockerCatalog = require(script.Parent.LockerCatalog)

type LockerCatalogItem = LockerCatalog.LockerCatalogItem

local FRAME_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DEFAULT_SCALE = 1
local HOVER_SCALE = 1.03
local CLICK_SCALE = 0.96
local ICON_LOCKED = AssetIds.Images.LockerLocked
local ICON_PURCHASE = AssetIds.Images.LockerPurchase
-- Mismo icono de gema que el grid (LockerGrid.STATUS_ICON_GEMS): el panel anuncia la
-- moneda antes de pulsar comprar.
local ICON_PURCHASE_GEMS = AssetIds.Images.LockerStatusGems
local COLOR_PURCHASE = Color3.fromRGB(255, 0, 127)
local COLOR_LOCKED = Color3.fromRGB(161, 161, 161)
local STROKE_DEFAULT = UITheme.StrokeDefault
local STROKE_HOVER = UITheme.StrokeHover

export type Deps = {
	frame: GuiObject,
	-- Búsqueda de nodos del feature: apunta lo que falte para no montar el locker.
	findNode: (root: Instance?, name: string) -> Instance?,
	janitor: any,
	canUseHoverAnimations: boolean,
	onActivated: () -> (),
}

export type LockerActionPanel = {
	show: (self: LockerActionPanel, item: LockerCatalogItem, level: number) -> (),
	hide: (self: LockerActionPanel) -> (),
}

type Internal = LockerActionPanel & {
	_frame: GuiObject,
	_titleLabel: TextLabel,
	_subtitleLabel: TextLabel,
	_icon: ImageLabel,
	_button: GuiButton,
	_buttonText: Instance?,
	_visiblePosition: UDim2,
	_hiddenPosition: UDim2,
	_visible: boolean,
	_frameTween: Tween?,
	_scaleTween: Tween?,
	_strokeTween: Tween?,
	_hovered: boolean,
}

local LockerActionPanel = {}
LockerActionPanel.__index = LockerActionPanel

local function resolveButtonTextTarget(button: GuiButton): Instance?
	for _, name in { "Title", "Label", "Text", "Price", "Value" } do
		local child = button:FindFirstChild(name)
		if child and child:IsA("TextLabel") then
			return child
		end
	end
	if button:IsA("TextButton") then
		return button
	end
	return button:FindFirstChildWhichIsA("TextLabel", true)
end

local function cancel(tween: Tween?): nil
	if tween then
		tween:Cancel()
	end
	return nil
end

local function bindButton(self: Internal, deps: Deps)
	local button = self._button
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = false

	local scaleNode = button:FindFirstChild("ButtonScale")
	if not (scaleNode and scaleNode:IsA("UIScale")) then
		scaleNode = Instance.new("UIScale")
		scaleNode.Name = "ButtonScale"
		scaleNode.Parent = button
	end
	local scale = scaleNode :: UIScale
	scale.Scale = DEFAULT_SCALE

	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = STROKE_DEFAULT
	end

	local function tweenTo(targetScale: number, targetColor: Color3, tweenInfo: TweenInfo)
		self._scaleTween = cancel(self._scaleTween)
		local scaleTween = TweenService:Create(scale, tweenInfo, { Scale = targetScale })
		self._scaleTween = scaleTween
		scaleTween:Play()
		if stroke then
			self._strokeTween = cancel(self._strokeTween)
			local strokeTween = TweenService:Create(stroke, tweenInfo, { Color = targetColor })
			self._strokeTween = strokeTween
			strokeTween:Play()
		end
	end

	local janitor = deps.janitor
	if deps.canUseHoverAnimations then
		janitor:Add(button.MouseEnter:Connect(function()
			self._hovered = true
			tweenTo(HOVER_SCALE, STROKE_HOVER, HOVER_TWEEN_INFO)
		end), "Disconnect")
		janitor:Add(button.MouseLeave:Connect(function()
			self._hovered = false
			tweenTo(DEFAULT_SCALE, STROKE_DEFAULT, HOVER_TWEEN_INFO)
		end), "Disconnect")
	end
	janitor:Add(button.MouseButton1Down:Connect(function()
		tweenTo(CLICK_SCALE, STROKE_HOVER, CLICK_TWEEN_INFO)
	end), "Disconnect")
	janitor:Add(button.MouseButton1Up:Connect(function()
		if self._hovered then
			tweenTo(HOVER_SCALE, STROKE_HOVER, HOVER_TWEEN_INFO)
		else
			tweenTo(DEFAULT_SCALE, STROKE_DEFAULT, HOVER_TWEEN_INFO)
		end
	end), "Disconnect")
	janitor:Add(button.Activated:Connect(deps.onActivated), "Disconnect")
end

-- nil si falta algún nodo (quedan apuntados en findNode).
function LockerActionPanel.new(deps: Deps): LockerActionPanel?
	local frame = deps.frame
	local title = deps.findNode(frame, "Title")
	local textContainer = deps.findNode(title, "Text")
	local button = deps.findNode(frame, "ActionBtn")
	local titleLabel = deps.findNode(textContainer, "Title")
	local subtitleLabel = deps.findNode(textContainer, "Subtitle")
	local icon = deps.findNode(title, "Icon")
	if not (button and titleLabel and subtitleLabel and icon) then
		return nil
	end

	-- El deslizamiento de ocultar es relativo al PADRE del ActionFrame: si en Studio se
	-- mueve dentro de otro contenedor, `1.15` deja de ser "bajo el borde de la pantalla"
	-- y pasa a ser "bajo el borde del contenedor".
	local visiblePosition = frame.Position
	local self = setmetatable({
		_frame = frame,
		_titleLabel = titleLabel :: TextLabel,
		_subtitleLabel = subtitleLabel :: TextLabel,
		_icon = icon :: ImageLabel,
		_button = button :: GuiButton,
		_buttonText = resolveButtonTextTarget(button :: GuiButton),
		_visiblePosition = visiblePosition,
		_hiddenPosition = UDim2.new(visiblePosition.X.Scale, visiblePosition.X.Offset, 1.15, visiblePosition.Y.Offset),
		_visible = false,
		_frameTween = nil,
		_scaleTween = nil,
		_strokeTween = nil,
		_hovered = false,
	}, LockerActionPanel) :: any

	frame.Visible = false
	frame.Position = self._hiddenPosition
	bindButton(self, deps)
	deps.janitor:Add(function()
		self._frameTween = cancel(self._frameTween)
		self._scaleTween = cancel(self._scaleTween)
		self._strokeTween = cancel(self._strokeTween)
	end, true)
	return self
end

local function tweenFrame(self: Internal, visible: boolean)
	self._frameTween = cancel(self._frameTween)
	if visible then
		self._frame.Visible = true
	end
	local target = if visible then self._visiblePosition else self._hiddenPosition
	local tween = TweenService:Create(self._frame, FRAME_TWEEN_INFO, { Position = target })
	self._frameTween = tween
	tween.Completed:Once(function()
		if self._frameTween == tween then
			self._frameTween = nil
			if not visible then
				self._frame.Visible = false
			end
		end
	end)
	tween:Play()
end

local function setButtonText(self: Internal, text: string)
	if self._buttonText then
		(self._buttonText :: any).Text = text
	end
end

function LockerActionPanel.show(self: Internal, item: LockerCatalogItem, level: number)
	local isLevelLocked = level < item.LevelRequired
	if isLevelLocked then
		self._titleLabel.Text = "THIS ITEM IS LOCKED"
		self._subtitleLabel.Text = string.format("Reach level %d to unlock this item.", item.LevelRequired)
		self._icon.Image = ICON_LOCKED
		setButtonText(self, "LOCKED")
		self._button.BackgroundColor3 = COLOR_LOCKED
	else
		self._titleLabel.Text = item.Name
		self._subtitleLabel.Text = item.Rarity
		self._icon.Image = if CurrencyMod.resolve(item.Currency) == CurrencyMod.GEMS then ICON_PURCHASE_GEMS else ICON_PURCHASE
		setButtonText(self, UIUtils.formatCashAmount(item.Price))
		self._button.BackgroundColor3 = COLOR_PURCHASE
	end
	self._button.Active = not isLevelLocked
	self._button.Selectable = not isLevelLocked

	self._visible = true
	tweenFrame(self, true)
end

function LockerActionPanel.hide(self: Internal)
	if self._visible then
		self._visible = false
		tweenFrame(self, false)
	end
end

return LockerActionPanel
