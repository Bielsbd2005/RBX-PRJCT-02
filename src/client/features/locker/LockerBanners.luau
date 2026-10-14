--!strict
--[[
	Vista de banners del Locker (Effects → Banners). No usa la grid de ítems
	(Locker.Content.ScrollingFrame): mientras está activa esa grid se oculta y se
	muestra Locker.Content.Banners, un ScrollingFrame propio con una tarjeta por
	banner poseído clonada de Banners.Template.

	Template (ImageButton):
	  · Image       → el banner (Image de ItemsConfig.Banners).
	  · Equiped     → UIStroke, solo encendido en el banner equipado.
	  · Footer      → ImageLabel decorativo del pie de la tarjeta.
	    · Value     → TextLabel con el estado ("EQUIPED" en verde / "OWNED" / precio).
	  · Glow        → Frame con UIGradient de fondo teñido por rareza.

	Pulsar un banner poseído lo equipa; uno sin poseer se selecciona y se compra
	desde el ActionFrame del Locker, como los ítems de la grid.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent.Parent
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any
local LockerGrid = require(script.Parent:WaitForChild("LockerGrid"))
local UITheme = require(Client:WaitForChild("core"):WaitForChild("ui"):WaitForChild("UITheme"))
local UIUtils = require(Client:WaitForChild("core"):WaitForChild("ui"):WaitForChild("UIUtils"))

type LockerCatalogItem = LockerGrid.LockerCatalogItem

export type Callbacks = {
	canInteract: () -> boolean,
	isItemOwned: (item: LockerCatalogItem) -> boolean,
	isItemEquipped: (item: LockerCatalogItem) -> boolean,
	onActivated: (item: LockerCatalogItem) -> (),
}

type BannerCard = {
	root: ImageButton,
	item: LockerCatalogItem,
	stroke: UIStroke?,
	statusValueNode: TextLabel?,
	statusValueDefaultColor: Color3?,
	equippedLabel: GuiObject?,
	glowNode: GuiObject?,
	scaleNode: UIScale,
}

-- Mismo ritmo de entrada que las cards de la grid (LockerGrid.PlayStagger).
local STAGGER_DELAY = 0.025
local STAGGER_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Colores y textos idénticos a ItemTemplate (LockerGrid).
local STATUS_EQUIPPED_TEXT_COLOR = Color3.fromRGB(124, 255, 0)
local STATUS_EQUIPPED_TEXT = "EQUIPED"
local STATUS_OWNED_TEXT = "OWNED"

local RARITY_GLOW = UITheme.LockerRarityGlow
local RARITY_FALLBACK = "Common"

local BUTTON_DEFAULT_SCALE = 1
local BUTTON_HOVER_SCALE = UITheme.ButtonHoverScale
local BUTTON_CLICK_SCALE = UITheme.ButtonClickScale
local BUTTON_HOVER_TWEEN_INFO = UITheme.HoverTweenInfo
local BUTTON_CLICK_TWEEN_INFO = UITheme.ClickTweenInfo

local LockerBanners = {}
LockerBanners.__index = LockerBanners

local function findEquippedStroke(card: Instance): UIStroke?
	local stroke = card:FindFirstChild("Equiped") or card:FindFirstChild("Equipped")
	if stroke and stroke:IsA("UIStroke") then
		return stroke
	end
	for _, descendant in card:GetDescendants() do
		if (descendant.Name == "Equiped" or descendant.Name == "Equipped") and descendant:IsA("UIStroke") then
			return descendant
		end
	end
	return card:FindFirstChildOfClass("UIStroke")
end

local function findStatusValueNode(card: Instance): TextLabel?
	local valueNode = card:FindFirstChild("Value", true)
	if valueNode and valueNode:IsA("TextLabel") then
		return valueNode
	end
	local statusNode = card:FindFirstChild("Status", true)
	if statusNode then
		local val = statusNode:FindFirstChild("Value")
		if val and val:IsA("TextLabel") then
			return val
		end
	end
	local oldNode = card:FindFirstChild("Equiped") or card:FindFirstChild("Equipped")
	if oldNode and oldNode:IsA("TextLabel") then
		return oldNode
	end
	return nil
end

local function findEquippedLabel(card: Instance): GuiObject?
	local node = card:FindFirstChild("Equiped") or card:FindFirstChild("Equipped")
	if node and node:IsA("GuiObject") and not node:IsA("TextLabel") then
		return node
	end
	return nil
end

local function findGlowNode(card: Instance): GuiObject?
	local glow = card:FindFirstChild("Glow", true)
	if glow and glow:IsA("GuiObject") then
		return glow
	end
	return nil
end

local function getOrCreateScale(button: GuiButton): UIScale
	local scale = button:FindFirstChild("ButtonScale")
	if scale and scale:IsA("UIScale") then
		return scale
	end
	local newScale = Instance.new("UIScale")
	newScale.Name = "ButtonScale"
	newScale.Scale = BUTTON_DEFAULT_SCALE
	newScale.Parent = button
	return newScale
end

function LockerBanners.new(
	frame: ScrollingFrame,
	template: ImageButton,
	referenceGrid: ScrollingFrame,
	callbacks: Callbacks
)
	local self = setmetatable({}, LockerBanners)
	self._frame = frame
	self._template = template
	self._callbacks = callbacks
	self._cards = {} :: { BannerCard }
	self._cardsJanitor = Janitor.new()
	self._staggerTweens = {} :: { Tween }
	self._canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	frame.CanvasSize = referenceGrid.CanvasSize
	frame.AutomaticCanvasSize = if referenceGrid.AutomaticCanvasSize ~= Enum.AutomaticSize.None
		then referenceGrid.AutomaticCanvasSize
		else Enum.AutomaticSize.Y

	template.Visible = false
	frame.Visible = false
	return self
end

function LockerBanners:_cancelStagger()
	for _, tween in self._staggerTweens do
		tween:Cancel()
	end
	table.clear(self._staggerTweens)
end

function LockerBanners:_clearCards()
	self:_cancelStagger()
	self._cardsJanitor:Cleanup()
	for _, card in self._cards do
		card.root:Destroy()
	end
	table.clear(self._cards)
end

function LockerBanners:_applyRarityVisuals(card: BannerCard)
	local rarity = card.item.Rarity or RARITY_FALLBACK
	local glowColor = RARITY_GLOW[rarity] or RARITY_GLOW[RARITY_FALLBACK]
	local glowNode = card.glowNode
	if glowNode and glowColor then
		if glowNode:IsA("ImageLabel") or glowNode:IsA("ImageButton") then
			glowNode.ImageColor3 = glowColor
		elseif glowNode:IsA("Frame") then
			glowNode.BackgroundColor3 = glowColor
		end
	end
end

function LockerBanners:_updateCard(card: BannerCard)
	local equipped = self._callbacks.isItemEquipped(card.item)
	if card.stroke then
		card.stroke.Enabled = equipped
	end
	if card.statusValueNode then
		card.statusValueNode.Text = if equipped
			then STATUS_EQUIPPED_TEXT
			elseif self._callbacks.isItemOwned(card.item) then STATUS_OWNED_TEXT
			else UIUtils.formatCashAmount(card.item.Price)
		card.statusValueNode.TextColor3 = if equipped
			then STATUS_EQUIPPED_TEXT_COLOR
			else (card.statusValueDefaultColor or Color3.fromRGB(255, 255, 255))
	end
	if card.equippedLabel then
		card.equippedLabel.Visible = equipped
	end
end

function LockerBanners:_bindHoverAnimations(card: BannerCard)
	local button = card.root
	local scale = card.scaleNode

	local function tweenScale(target: number, info: TweenInfo)
		TweenService:Create(scale, info, { Scale = target }):Play()
	end

	if not self._canUseHoverAnimations then
		self._cardsJanitor:Add(button.MouseButton1Down:Connect(function()
			tweenScale(BUTTON_CLICK_SCALE, BUTTON_CLICK_TWEEN_INFO)
		end), "Disconnect")

		self._cardsJanitor:Add(button.MouseButton1Up:Connect(function()
			tweenScale(BUTTON_DEFAULT_SCALE, BUTTON_HOVER_TWEEN_INFO)
		end), "Disconnect")
		return
	end

	self._cardsJanitor:Add(button.MouseEnter:Connect(function()
		tweenScale(BUTTON_HOVER_SCALE, BUTTON_HOVER_TWEEN_INFO)
	end), "Disconnect")

	self._cardsJanitor:Add(button.MouseLeave:Connect(function()
		tweenScale(BUTTON_DEFAULT_SCALE, BUTTON_HOVER_TWEEN_INFO)
	end), "Disconnect")

	self._cardsJanitor:Add(button.MouseButton1Down:Connect(function()
		tweenScale(BUTTON_CLICK_SCALE, BUTTON_CLICK_TWEEN_INFO)
	end), "Disconnect")

	self._cardsJanitor:Add(button.MouseButton1Up:Connect(function()
		tweenScale(BUTTON_HOVER_SCALE, BUTTON_HOVER_TWEEN_INFO)
	end), "Disconnect")
end

function LockerBanners:_createCard(item: LockerCatalogItem, layoutOrder: number): BannerCard
	local template: ImageButton = self._template
	local root = template:Clone()
	root.Name = item.id
	root.LayoutOrder = layoutOrder
	root.Visible = true
	root.Image = item.Image

	local statusValueNode = findStatusValueNode(root)
	local scaleNode = getOrCreateScale(root)

	local card: BannerCard = {
		root = root,
		item = item,
		stroke = findEquippedStroke(root),
		statusValueNode = statusValueNode,
		statusValueDefaultColor = if statusValueNode then statusValueNode.TextColor3 else nil,
		equippedLabel = findEquippedLabel(root),
		glowNode = findGlowNode(root),
		scaleNode = scaleNode,
	}

	self:_applyRarityVisuals(card)
	self:_bindHoverAnimations(card)

	self._cardsJanitor:Add(root.Activated:Connect(function()
		if not self._callbacks.canInteract() or self._callbacks.isItemEquipped(item) then
			return
		end
		self._callbacks.onActivated(item)
	end), "Disconnect")

	self:_updateCard(card)
	root.Parent = self._frame
	return card
end

function LockerBanners:Show(items: { LockerCatalogItem }, stagger: boolean?)
	self:_clearCards()
	for index, item in items do
		table.insert(self._cards, self:_createCard(item, index))
	end
	self._frame.Visible = true

	if stagger then
		self._frame.CanvasPosition = Vector2.zero
		for index, card in self._cards do
			local scale = card.scaleNode
			scale.Scale = 0
			local info = TweenInfo.new(
				STAGGER_TWEEN_INFO.Time,
				STAGGER_TWEEN_INFO.EasingStyle,
				STAGGER_TWEEN_INFO.EasingDirection,
				0,
				false,
				(index - 1) * STAGGER_DELAY
			)
			local tween = TweenService:Create(scale, info, { Scale = BUTTON_DEFAULT_SCALE })
			table.insert(self._staggerTweens, tween)
			tween:Play()
		end
	end
end

function LockerBanners:Hide()
	self._frame.Visible = false
	self:_clearCards()
end

function LockerBanners:IsVisible(): boolean
	return self._frame.Visible
end

function LockerBanners:Refresh()
	for _, card in self._cards do
		self:_updateCard(card)
	end
end

function LockerBanners:Destroy()
	self:_clearCards()
	self._cardsJanitor:Destroy()
end

return LockerBanners
