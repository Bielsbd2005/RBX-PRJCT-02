--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local WeaponSkinWrapPreviewer = require(script.Parent.Previewers.WeaponSkinWrapPreviewer)
local UITheme = require(script.Parent.Parent.Parent.core.ui.UITheme)
local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)

export type LockerCatalogItem = {
	Id: string,
	Category: string,
	ItemKey: string,
	Name: string,
	Price: number,
	LevelRequired: number,
	Rarity: string,
	Image: string,
	CanPurchase: boolean,
	TextureID: string?,
	BaseColor: Color3?,
	Animated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponKey: string?,
	PreviewWeaponName: string?,
	KillGoal: number?,
	KillProgress: number?,
}

export type TemplateKey = "default" | "wraps"

export type LockerGridTemplates = {
	default: GuiObject,
	wraps: GuiObject,
}

type ItemGridCardRefs = {
	templateKey: TemplateKey,
	button: GuiButton?,
	itemNode: GuiObject?,
	itemNodeDefaultSize: UDim2?,
	viewportNode: ViewportFrame?,
	amountNode: TextLabel?,
	priceNode: TextLabel?,
	currencyNode: GuiObject?,
	ownedNode: TextLabel?,
	equippedNode: GuiObject?,
	lockedNode: GuiObject?,
	lockedLevelNode: TextLabel?,
	lockedTemplate: GuiObject?,
	lockedParent: Instance?,
	titleNode: GuiObject?,
	titleDefaultText: string?,
	barNode: GuiObject?,
	barFillNode: GuiObject?,
	barFillDefaultSize: UDim2?,
	barValueNode: TextLabel?,
	buttonStroke: UIStroke?,
	buttonStrokeCached: boolean?,
}

type LockerGridCallbacks = {
	canInteract: (() -> boolean)?,
	isItemOwned: (LockerCatalogItem) -> boolean,
	getItemAmount: ((LockerCatalogItem) -> number)?,
	isItemEquipped: (LockerCatalogItem) -> boolean,
	getCurrentLevel: () -> number,
	onSelectionChanged: (LockerCatalogItem?) -> (),
	onOwnedItemActivated: (LockerCatalogItem) -> (),
}

export type LockerGrid = {
	_itemGrid: GuiObject,
	_templates: LockerGridTemplates,
	_callbacks: LockerGridCallbacks,
	_canUseHoverAnimations: boolean,
	_populateGeneration: number,
	_activeGridCards: { GuiObject },
	_gridCardPools: { [TemplateKey]: { GuiObject } },
	_currentTemplateKey: TemplateKey?,
	_cachedGridCardRefs: { [GuiObject]: ItemGridCardRefs },
	_cardPreviewJanitors: { [GuiObject]: any },
	_gridButtonItems: { [GuiButton]: LockerCatalogItem },
	_selectedCatalogButton: GuiButton?,
	_selectedCatalogItem: LockerCatalogItem?,
	_activeGridScaleTweens: { [GuiButton]: Tween },
	_hoveredGridButtons: { [GuiButton]: boolean },
	_gridCardByButton: { [GuiButton]: GuiObject },
	_gridButtonByItemId: { [string]: GuiButton },
	_cachedLevel: number,
	_janitor: any,
	_populateJanitor: any,
	Destroy: (self: LockerGrid) -> (),
	Clear: (self: LockerGrid) -> (),
	Populate: (self: LockerGrid, items: { LockerCatalogItem }, selectedItemId: string?, templateKey: TemplateKey?) -> (),
	RefreshVisibleState: (self: LockerGrid, notifySelection: boolean?) -> (),
	GetSelectedItem: (self: LockerGrid) -> LockerCatalogItem?,
	GetCardForItem: (self: LockerGrid, itemId: string) -> GuiObject?,
	_getButtonStroke: (self: LockerGrid, button: GuiButton) -> UIStroke?,
	_buildGridCardRefs: (self: LockerGrid, card: GuiObject, templateKey: TemplateKey) -> ItemGridCardRefs,
	_getGridCardRefs: (self: LockerGrid, card: GuiObject) -> ItemGridCardRefs,
	_acquireGridCard: (self: LockerGrid, templateKey: TemplateKey) -> GuiObject,
	_returnCardToPool: (self: LockerGrid, card: GuiObject) -> (),
	_setSelectedButton: (self: LockerGrid, targetButton: GuiButton) -> (),
	_updateGridCardVisual: (self: LockerGrid, button: GuiButton) -> (),
	_getOrCreateGridButtonScale: (self: LockerGrid, button: GuiButton) -> UIScale,
	_tweenGridButtonScale: (self: LockerGrid, button: GuiButton, targetScale: number, tweenInfo: TweenInfo) -> (),
	_bindCatalogButtonHover: (self: LockerGrid, button: GuiButton) -> (),
	_clearCardViewportPreview: (self: LockerGrid, card: GuiObject) -> (),
	_applyWeaponSkinViewportPreview: (self: LockerGrid, card: GuiObject, item: LockerCatalogItem) -> boolean,
	_applyCatalogItemToCard: (self: LockerGrid, card: GuiObject, item: LockerCatalogItem, layoutOrder: number) -> (),
	_resetTransientState: (self: LockerGrid, notifySelection: boolean) -> (),
}

local GRID_BUTTON_HOVER_TWEEN_INFO = UITheme.HoverTweenInfo
local GRID_BUTTON_CLICK_TWEEN_INFO = UITheme.ClickTweenInfo
local GRID_BUTTON_DEFAULT_SCALE = 1
local GRID_BUTTON_HOVER_SCALE = UITheme.ButtonHoverScale
local GRID_BUTTON_CLICK_SCALE = UITheme.ButtonClickScale
local GRID_ITEM_DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)
local GRID_ITEM_LOCKED_WEAPON_COLOR = Color3.fromRGB(0, 0, 0)
local STROKE_DEFAULT = UITheme.StrokeDefault
local STROKE_WHITE = UITheme.StrokeHover
local POPULATE_SYNC_ITEM_COUNT = 24
local POPULATE_ASYNC_BATCH_SIZE = 16
local DEFAULT_WEAPON_SKIN_KEY = "Default"

local LockerGrid = {}
LockerGrid.__index = LockerGrid

function LockerGrid.new(
	itemGrid: GuiObject,
	templates: LockerGridTemplates,
	canUseHoverAnimations: boolean,
	callbacks: LockerGridCallbacks
): LockerGrid
	local self = setmetatable({}, LockerGrid) :: any
	self._itemGrid = itemGrid
	self._templates = templates
	self._callbacks = callbacks
	self._canUseHoverAnimations = canUseHoverAnimations
	self._populateGeneration = 0
	self._activeGridCards = {}
	self._gridCardPools = {
		default = {},
		wraps = {},
	}
	self._currentTemplateKey = nil
	self._cachedGridCardRefs = {}
	self._cardPreviewJanitors = {}
	self._gridButtonItems = {}
	self._selectedCatalogButton = nil
	self._selectedCatalogItem = nil
	self._activeGridScaleTweens = {}
	self._hoveredGridButtons = {}
	self._gridCardByButton = {}
	self._gridButtonByItemId = {}
	self._cachedLevel = 0
	self._janitor = Janitor.new()
	self._populateJanitor = Janitor.new()
	self._janitor:Add(self._populateJanitor, "Destroy")
	return self
end

function LockerGrid:_getButtonStroke(button: GuiButton): UIStroke?
	local card = self._gridCardByButton[button]
	if card then
		local refs = self._cachedGridCardRefs[card]
		if refs then
			if refs.buttonStrokeCached then
				return refs.buttonStroke
			end
			local stroke = button:FindFirstChildOfClass("UIStroke")
			refs.buttonStroke = if stroke and stroke:IsA("UIStroke") then stroke else nil
			refs.buttonStrokeCached = true
			return refs.buttonStroke
		end
	end
	local stroke = button:FindFirstChildOfClass("UIStroke")
	return if stroke and stroke:IsA("UIStroke") then stroke else nil
end

function LockerGrid:_buildGridCardRefs(card: GuiObject, templateKey: TemplateKey): ItemGridCardRefs
	local buttonNode = card:FindFirstChild("Button")
	local button = if buttonNode and buttonNode:IsA("GuiButton") then buttonNode else nil

	if templateKey == "wraps" then
		local viewportNode = if button then button:FindFirstChild("ViewportFrame") else nil
		local viewport = if viewportNode and viewportNode:IsA("ViewportFrame") then viewportNode else nil

		local equippedNode = if button then button:FindFirstChild("Equiped") else nil
		local amountNode = if viewport then viewport:FindFirstChild("Amount") else nil
		local titleNode = if button then button:FindFirstChild("Title") else nil
		local barNode = if button then button:FindFirstChild("Bar") else nil
		local wrapsLockedNode = if button then button:FindFirstChild("Locked") else nil
		local wrapsLockedGui = if wrapsLockedNode and wrapsLockedNode:IsA("GuiObject") then wrapsLockedNode else nil
		local barGui = if barNode and barNode:IsA("GuiObject") then barNode else nil
		local barFillNode = if barGui then barGui:FindFirstChild("Fill") else nil
		local barFillGui = if barFillNode and barFillNode:IsA("GuiObject") then barFillNode else nil
		local barValueNode = if barGui then barGui:FindFirstChild("Value") else nil

		local refs: ItemGridCardRefs = {
			templateKey = templateKey,
			button = button,
			itemNode = nil,
			itemNodeDefaultSize = nil,
			viewportNode = viewport,
			amountNode = if amountNode and amountNode:IsA("TextLabel") then amountNode else nil,
			priceNode = nil,
			currencyNode = nil,
			ownedNode = nil,
			equippedNode = if equippedNode and equippedNode:IsA("GuiObject") then equippedNode else nil,
			lockedNode = wrapsLockedGui,
			lockedLevelNode = nil,
			lockedTemplate = nil,
			lockedParent = nil,
			titleNode = if titleNode and titleNode:IsA("GuiObject") then titleNode else nil,
			titleDefaultText = if titleNode and titleNode:IsA("TextLabel") then titleNode.Text else nil,
			barNode = barGui,
			barFillNode = barFillGui,
			barFillDefaultSize = if barFillGui then barFillGui.Size else nil,
			barValueNode = if barValueNode and barValueNode:IsA("TextLabel") then barValueNode else nil,
		}

		self._cachedGridCardRefs[card] = refs
		return refs
	end

	local itemNode = if button then button:FindFirstChild("Item") else nil
	local resolvedItemNode = if itemNode and (itemNode:IsA("ImageLabel") or itemNode:IsA("ImageButton")) then itemNode else nil
	local viewportNode = if button then button:FindFirstChild("ViewportFrame") else nil
	local amountNode = if button then button:FindFirstChild("Amount") else nil
	local priceNode = if button then button:FindFirstChild("Price") else nil
	local currencyNode = if button then button:FindFirstChild("Currency") else nil
	local ownedNode = if button then button:FindFirstChild("Owned") else nil
	local equippedNode = if button then button:FindFirstChild("Equiped") else nil
	local lockedNode = if button then button:FindFirstChild("Locked") else nil
	local lockedGui = if lockedNode and lockedNode:IsA("GuiObject") then lockedNode else nil
	local lockedLevelNode = if lockedGui then lockedGui:FindFirstChild("Value") else nil

	local refs: ItemGridCardRefs = {
		templateKey = templateKey,
		button = button,
		itemNode = resolvedItemNode,
		itemNodeDefaultSize = if resolvedItemNode then resolvedItemNode.Size else nil,
		viewportNode = if viewportNode and viewportNode:IsA("ViewportFrame") then viewportNode else nil,
		amountNode = if amountNode and amountNode:IsA("TextLabel") then amountNode else nil,
		priceNode = if priceNode and priceNode:IsA("TextLabel") then priceNode else nil,
		currencyNode = if currencyNode and currencyNode:IsA("GuiObject") then currencyNode else nil,
		ownedNode = if ownedNode and ownedNode:IsA("TextLabel") then ownedNode else nil,
		equippedNode = if equippedNode and equippedNode:IsA("GuiObject") then equippedNode else nil,
		lockedNode = lockedGui,
		lockedLevelNode = if lockedLevelNode and lockedLevelNode:IsA("TextLabel") then lockedLevelNode else nil,
		lockedTemplate = if lockedGui then lockedGui:Clone() else nil,
		lockedParent = if lockedGui then lockedGui.Parent else nil,
		titleNode = nil,
		barNode = nil,
		barFillNode = nil,
		barFillDefaultSize = nil,
		barValueNode = nil,
	}

	self._cachedGridCardRefs[card] = refs
	return refs
end

function LockerGrid:_getGridCardRefs(card: GuiObject): ItemGridCardRefs
	local cached = self._cachedGridCardRefs[card]
	if cached then
		return cached
	end

	-- Fallback: legacy default template (should not normally hit since cards are built on acquire).
	return self:_buildGridCardRefs(card, "default")
end

function LockerGrid:_clearCardViewportPreview(card: GuiObject)
	local previewJanitor = self._cardPreviewJanitors[card]
	if previewJanitor then
		previewJanitor:Cleanup()
	end

	local refs = self:_getGridCardRefs(card)
	local viewportNode = refs.viewportNode
	if not viewportNode then
		return
	end

	viewportNode.CurrentCamera = nil
	for _, child in viewportNode:GetChildren() do
		if not child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	if refs.templateKey ~= "wraps" then
		viewportNode.Visible = false
	end
end

function LockerGrid:_applyWeaponSkinViewportPreview(card: GuiObject, item: LockerCatalogItem): boolean
	local refs = self:_getGridCardRefs(card)
	local viewportNode = refs.viewportNode
	if not viewportNode then
		return false
	end

	self:_clearCardViewportPreview(card)

	local previewJanitor = self._cardPreviewJanitors[card]
	if not previewJanitor then
		previewJanitor = Janitor.new()
		self._cardPreviewJanitors[card] = previewJanitor
	end

	return WeaponSkinWrapPreviewer.Render(viewportNode, item, previewJanitor)
end

local function shouldUseWeaponSkinViewportPreview(item: LockerCatalogItem): boolean
	return item.Category == "WeaponSkins" and item.ItemKey ~= DEFAULT_WEAPON_SKIN_KEY
end

local function shouldUseFullSizeWeaponImage(item: LockerCatalogItem): boolean
	return item.Category == "Main" or item.Category == "Special"
end

local function isKillChallengeItem(item: LockerCatalogItem): boolean
	local goal = item.KillGoal
	return goal ~= nil and goal > 0
end

function LockerGrid:_acquireGridCard(templateKey: TemplateKey): GuiObject
	local pool = self._gridCardPools[templateKey]
	local pooledCard = if pool then table.remove(pool) else nil
	if pooledCard then
		return pooledCard
	end

	local template = self._templates[templateKey]
	local card = template:Clone()
	self:_buildGridCardRefs(card, templateKey)
	return card
end

function LockerGrid:_returnCardToPool(card: GuiObject)
	local refs = self._cachedGridCardRefs[card]
	local templateKey: TemplateKey = if refs then refs.templateKey else "default"

	self:_clearCardViewportPreview(card)
	card.Visible = false

	if refs and refs.button then
		self._gridButtonItems[refs.button] = nil
		self._gridCardByButton[refs.button] = nil
	end

	local pool = self._gridCardPools[templateKey]
	if pool then
		table.insert(pool, card)
	end
end

function LockerGrid:_updateGridCardVisual(button: GuiButton)
	local card = self._gridCardByButton[button]
	if not card or not card.Visible then
		return
	end

	local refs = self:_getGridCardRefs(card)
	local item = self._gridButtonItems[button]
	if not item then
		return
	end

	local owned = self._callbacks.isItemOwned(item)
	local itemAmount = if self._callbacks.getItemAmount then self._callbacks.getItemAmount(item) else if owned then 1 else 0
	local equipped = self._callbacks.isItemEquipped(item)
	local isSelectedButton = button == self._selectedCatalogButton

	if refs.templateKey == "wraps" then
		if refs.amountNode then
			refs.amountNode.Visible = itemAmount > 1
			if itemAmount > 1 then
				refs.amountNode.Text = "x" .. tostring(itemAmount)
			end
		end

		if refs.equippedNode then
			refs.equippedNode.Visible = equipped
		end

		local isChallenge = isKillChallengeItem(item) and not owned
		local isDefaultWrap = item.ItemKey == DEFAULT_WEAPON_SKIN_KEY
		if refs.titleNode then
			-- Si esta equipado se muestra solo el badge `Equiped`, sin titulo.
			refs.titleNode.Visible = not equipped
			if refs.titleNode:IsA("TextLabel") then
				if isChallenge then
					refs.titleNode.Text = refs.titleDefaultText or refs.titleNode.Text
				elseif isDefaultWrap then
					refs.titleNode.Text = "DEFAULT"
				else
					refs.titleNode.Text = tostring(item.Rarity)
				end
			end
		end
		if refs.barNode then
			refs.barNode.Visible = isChallenge
		end
		if refs.lockedNode then
			refs.lockedNode.Visible = isChallenge
		end

		if isChallenge then
			local goal = math.max(1, item.KillGoal or 0)
			local progress = math.clamp(item.KillProgress or 0, 0, goal)
			if refs.barFillNode then
				local defaultSize = refs.barFillDefaultSize or refs.barFillNode.Size
				local ratio = progress / goal
				refs.barFillNode.Size = UDim2.new(defaultSize.X.Scale * ratio, defaultSize.X.Offset, defaultSize.Y.Scale, defaultSize.Y.Offset)
			end
			if refs.barValueNode then
				refs.barValueNode.Text = tostring(progress) .. "/" .. tostring(goal)
			end
		end

		local stroke = self:_getButtonStroke(button)
		if not stroke then
			return
		end

		if isSelectedButton and not owned then
			stroke.Enabled = false
			stroke.Transparency = 1
			return
		end

		stroke.Enabled = true
		stroke.Transparency = 0
		stroke.Color = if equipped then STROKE_WHITE else STROKE_DEFAULT
		return
	end

	local currentLevel = self._cachedLevel
	local isLevelLocked = not owned and currentLevel < item.LevelRequired
	local shouldBlackoutWeaponImage = shouldUseFullSizeWeaponImage(item) and isLevelLocked

	if refs.itemNode then
		refs.itemNode.ImageColor3 = if shouldBlackoutWeaponImage then GRID_ITEM_LOCKED_WEAPON_COLOR else GRID_ITEM_DEFAULT_COLOR
	end

	if isLevelLocked then
		if refs.lockedNode == nil or refs.lockedNode.Parent == nil then
			local lockedTemplate = refs.lockedTemplate
			local lockedParent = refs.lockedParent
			if lockedTemplate and lockedParent and lockedParent:IsDescendantOf(card) then
				local clonedLocked = lockedTemplate:Clone()
				clonedLocked.Parent = lockedParent
				refs.lockedNode = clonedLocked

				local clonedLevelNode = clonedLocked:FindFirstChild("Value")
				refs.lockedLevelNode = if clonedLevelNode and clonedLevelNode:IsA("TextLabel") then clonedLevelNode else nil
			end
		end

		if refs.lockedNode then
			refs.lockedNode.Visible = true
		end

		if refs.lockedLevelNode then
			refs.lockedLevelNode.Text = "Lvl. " .. tostring(item.LevelRequired)
		end
	else
		if refs.lockedNode and refs.lockedNode.Parent then
			refs.lockedNode.Visible = false
		end
	end

	if refs.priceNode then
		refs.priceNode.Visible = not owned
	end

	if refs.currencyNode then
		refs.currencyNode.Visible = not owned
	end

	if refs.ownedNode then
		refs.ownedNode.Visible = owned and not equipped
	end

	if refs.amountNode then
		refs.amountNode.Visible = itemAmount > 1
		if itemAmount > 1 then
			refs.amountNode.Text = "x" .. tostring(itemAmount)
		end
	end

	if refs.equippedNode then
		refs.equippedNode.Visible = equipped
	end

	local stroke = self:_getButtonStroke(button)
	if not stroke then
		return
	end

	if isSelectedButton and not owned then
		stroke.Enabled = false
		stroke.Transparency = 1
		return
	end

	stroke.Enabled = true
	stroke.Transparency = 0
	stroke.Color = if equipped then STROKE_WHITE else STROKE_DEFAULT
end

function LockerGrid:_setSelectedButton(targetButton: GuiButton)
	local previousButton = self._selectedCatalogButton
	self._selectedCatalogButton = targetButton
	self._selectedCatalogItem = self._gridButtonItems[targetButton]

	if previousButton and previousButton ~= targetButton then
		self:_updateGridCardVisual(previousButton)
	end

	self:_updateGridCardVisual(targetButton)
	self._callbacks.onSelectionChanged(self._selectedCatalogItem)
end

function LockerGrid:_getOrCreateGridButtonScale(button: GuiButton): UIScale
	local scaleNode = button:FindFirstChild("ButtonScale")
	if scaleNode and scaleNode:IsA("UIScale") then
		return scaleNode
	end

	local newScale = Instance.new("UIScale")
	newScale.Name = "ButtonScale"
	newScale.Scale = GRID_BUTTON_DEFAULT_SCALE
	newScale.Parent = button
	return newScale
end

function LockerGrid:_tweenGridButtonScale(button: GuiButton, targetScale: number, tweenInfo: TweenInfo)
	local scaleNode = self:_getOrCreateGridButtonScale(button)
	if math.abs(scaleNode.Scale - targetScale) <= 0.001 and self._activeGridScaleTweens[button] == nil then
		return
	end

	local currentTween = self._activeGridScaleTweens[button]
	if currentTween then
		currentTween:Cancel()
		self._activeGridScaleTweens[button] = nil
	end

	local tween = TweenService:Create(scaleNode, tweenInfo, { Scale = targetScale })
	self._activeGridScaleTweens[button] = tween
	tween.Completed:Connect(function()
		if self._activeGridScaleTweens[button] == tween then
			self._activeGridScaleTweens[button] = nil
		end
	end)
	tween:Play()
end

function LockerGrid:_bindCatalogButtonHover(button: GuiButton)
	self:_tweenGridButtonScale(button, GRID_BUTTON_DEFAULT_SCALE, GRID_BUTTON_HOVER_TWEEN_INFO)

	if not self._canUseHoverAnimations then
		self._populateJanitor:Add(button.MouseButton1Down:Connect(function()
			self:_tweenGridButtonScale(button, GRID_BUTTON_CLICK_SCALE, GRID_BUTTON_CLICK_TWEEN_INFO)
		end), "Disconnect")

		self._populateJanitor:Add(button.MouseButton1Up:Connect(function()
			self:_tweenGridButtonScale(button, GRID_BUTTON_DEFAULT_SCALE, GRID_BUTTON_HOVER_TWEEN_INFO)
		end), "Disconnect")
		return
	end

	self._populateJanitor:Add(button.MouseEnter:Connect(function()
		self._hoveredGridButtons[button] = true
		self:_tweenGridButtonScale(button, GRID_BUTTON_HOVER_SCALE, GRID_BUTTON_HOVER_TWEEN_INFO)
	end), "Disconnect")

	self._populateJanitor:Add(button.MouseLeave:Connect(function()
		self._hoveredGridButtons[button] = false
		self:_tweenGridButtonScale(button, GRID_BUTTON_DEFAULT_SCALE, GRID_BUTTON_HOVER_TWEEN_INFO)
	end), "Disconnect")

	self._populateJanitor:Add(button.MouseButton1Down:Connect(function()
		self:_tweenGridButtonScale(button, GRID_BUTTON_CLICK_SCALE, GRID_BUTTON_CLICK_TWEEN_INFO)
	end), "Disconnect")

	self._populateJanitor:Add(button.MouseButton1Up:Connect(function()
		local targetScale = if self._hoveredGridButtons[button] then GRID_BUTTON_HOVER_SCALE else GRID_BUTTON_DEFAULT_SCALE
		self:_tweenGridButtonScale(button, targetScale, GRID_BUTTON_HOVER_TWEEN_INFO)
	end), "Disconnect")
end

function LockerGrid:_applyCatalogItemToCard(card: GuiObject, item: LockerCatalogItem, layoutOrder: number)
	card.Name = item.Name
	card.LayoutOrder = layoutOrder
	card.Visible = true

	local refs = self:_getGridCardRefs(card)
	local needsViewport = shouldUseWeaponSkinViewportPreview(item)
		or (refs.templateKey == "wraps" and item.Category == "WeaponSkins")
	local usesViewportPreview = false

	if needsViewport then
		self:_clearCardViewportPreview(card)
		usesViewportPreview = self:_applyWeaponSkinViewportPreview(card, item)
	elseif self._cardPreviewJanitors[card] then
		self:_clearCardViewportPreview(card)
	end

	if refs.viewportNode then
		if refs.templateKey == "wraps" then
			refs.viewportNode.Visible = true
		else
			refs.viewportNode.Visible = usesViewportPreview
		end
	end

	if refs.itemNode and (refs.itemNode:IsA("ImageLabel") or refs.itemNode:IsA("ImageButton")) then
		refs.itemNode.Visible = not usesViewportPreview
		refs.itemNode.Image = item.Image
		if shouldUseFullSizeWeaponImage(item) then
			refs.itemNode.Size = UDim2.fromScale(1, 1)
			refs.itemNode.ImageColor3 = if self._cachedLevel >= item.LevelRequired then GRID_ITEM_DEFAULT_COLOR else GRID_ITEM_LOCKED_WEAPON_COLOR
		elseif refs.itemNodeDefaultSize then
			refs.itemNode.Size = refs.itemNodeDefaultSize
		end
	end

	if refs.priceNode then
		refs.priceNode.Text = UIUtils.formatCashAmount(item.Price)
		refs.priceNode.Visible = true
	end

	if refs.currencyNode then
		refs.currencyNode.Visible = true
	end

	if refs.ownedNode then
		refs.ownedNode.Visible = false
	end

	if refs.amountNode then
		refs.amountNode.Visible = false
		refs.amountNode.Text = ""
	end

	if refs.equippedNode then
		refs.equippedNode.Visible = false
	end

	if refs.titleNode then
		refs.titleNode.Visible = false
	end

	if refs.barNode then
		refs.barNode.Visible = false
	end

	local button = refs.button
	if not button then
		return
	end

	self._gridButtonItems[button] = item
	self._gridCardByButton[button] = card
	self._gridButtonByItemId[item.Id] = button

	button.Active = true
	button.AutoButtonColor = false
	button.Selectable = true
	button:SetAttribute("ItemId", item.Id)
	button:SetAttribute("ItemName", item.Name)
	button:SetAttribute("Price", item.Price)
	button:SetAttribute("Rarity", item.Rarity)
	button:SetAttribute("CanPurchase", item.CanPurchase)

	self:_bindCatalogButtonHover(button)
	self._populateJanitor:Add(button.Activated:Connect(function()
		local canInteract = self._callbacks.canInteract
		if canInteract and not canInteract() then
			return
		end

		local selectedItem = self._gridButtonItems[button]
		if self._selectedCatalogButton == button and not (selectedItem and selectedItem.Category == "KillEffects") then
			return
		end

		self:_setSelectedButton(button)

		if selectedItem and self._callbacks.isItemOwned(selectedItem) then
			self._callbacks.onOwnedItemActivated(selectedItem)
		end
	end), "Disconnect")

	self:_updateGridCardVisual(button)
end

function LockerGrid:_resetTransientState(notifySelection: boolean)
	self._populateJanitor:Cleanup()
	self._populateGeneration += 1
	self._selectedCatalogButton = nil
	self._selectedCatalogItem = nil
	table.clear(self._gridButtonItems)
	table.clear(self._gridCardByButton)
	table.clear(self._gridButtonByItemId)

	for _, tween in self._activeGridScaleTweens do
		tween:Cancel()
	end
	table.clear(self._activeGridScaleTweens)
	table.clear(self._hoveredGridButtons)

	if notifySelection then
		self._callbacks.onSelectionChanged(nil)
	end
end

function LockerGrid:Clear()
	self:_resetTransientState(true)

	for index = #self._activeGridCards, 1, -1 do
		local card = self._activeGridCards[index]
		self:_returnCardToPool(card)
		self._activeGridCards[index] = nil
	end

	self._currentTemplateKey = nil
end

function LockerGrid:Populate(items: { LockerCatalogItem }, selectedItemId: string?, templateKey: TemplateKey?)
	local resolvedTemplateKey: TemplateKey = templateKey or "default"

	if self._currentTemplateKey ~= nil and self._currentTemplateKey ~= resolvedTemplateKey then
		self:_resetTransientState(false)
		for index = #self._activeGridCards, 1, -1 do
			local card = self._activeGridCards[index]
			self:_returnCardToPool(card)
			self._activeGridCards[index] = nil
		end
	else
		self:_resetTransientState(false)
	end

	self._currentTemplateKey = resolvedTemplateKey
	self._cachedLevel = self._callbacks.getCurrentLevel()
	local generation = self._populateGeneration
	local totalItems = #items
	local syncItemCount = math.min(totalItems, POPULATE_SYNC_ITEM_COUNT)

	local function applyCatalogItem(layoutOrder: number)
		local card = self._activeGridCards[layoutOrder]
		if not card then
			card = self:_acquireGridCard(resolvedTemplateKey)
			card.Parent = self._itemGrid
			self._activeGridCards[layoutOrder] = card
		end

		local item = items[layoutOrder]
		self:_applyCatalogItemToCard(card, item, layoutOrder)
	end

	for layoutOrder = 1, syncItemCount do
		applyCatalogItem(layoutOrder)
	end

	for index = totalItems + 1, #self._activeGridCards do
		local card = self._activeGridCards[index]
		if card then
			self:_clearCardViewportPreview(card)
			card.Visible = false
			local refs = self:_getGridCardRefs(card)
			local button = refs.button
			if button then
				self._gridButtonItems[button] = nil
				self._gridCardByButton[button] = nil
			end
		end
	end

	local selectedResolved = false

	local function selectByItemId(itemId: string): boolean
		local targetButton = self._gridButtonByItemId[itemId]
		if not targetButton then
			return false
		end

		self:_setSelectedButton(targetButton)
		return true
	end

	local function selectFirstVisibleItem(): boolean
		if totalItems <= 0 then
			self._callbacks.onSelectionChanged(nil)
			return false
		end

		local firstCard = self._activeGridCards[1]
		if not firstCard then
			self._callbacks.onSelectionChanged(nil)
			return false
		end

		local refs = self:_getGridCardRefs(firstCard)
		if not refs.button then
			self._callbacks.onSelectionChanged(nil)
			return false
		end

		self:_setSelectedButton(refs.button)
		return true
	end

	if selectedItemId then
		selectedResolved = selectByItemId(selectedItemId)
	elseif totalItems > 0 then
		selectedResolved = selectFirstVisibleItem()
	else
		self._callbacks.onSelectionChanged(nil)
	end

	if totalItems <= syncItemCount then
		if selectedItemId and not selectedResolved then
			selectFirstVisibleItem()
		end
		return
	end

	task.defer(function()
		local layoutOrder = syncItemCount + 1

		while layoutOrder <= totalItems do
			if generation ~= self._populateGeneration then
				return
			end

			local batchEnd = math.min(layoutOrder + POPULATE_ASYNC_BATCH_SIZE - 1, totalItems)
			for index = layoutOrder, batchEnd do
				if generation ~= self._populateGeneration then
					return
				end

				applyCatalogItem(index)

				if selectedItemId and not selectedResolved and items[index].Id == selectedItemId then
					selectedResolved = selectByItemId(selectedItemId)
				end
			end

			layoutOrder = batchEnd + 1
			task.wait()
		end

		if generation ~= self._populateGeneration then
			return
		end

		if selectedItemId and not selectedResolved then
			selectFirstVisibleItem()
		end
	end)
end

function LockerGrid:RefreshVisibleState(notifySelection: boolean?)
	self._cachedLevel = self._callbacks.getCurrentLevel()
	for _, card in self._activeGridCards do
		if card.Visible then
			local refs = self:_getGridCardRefs(card)
			local button = refs.button
			if button then
				self:_updateGridCardVisual(button)
			end
		end
	end

	self._selectedCatalogItem = if self._selectedCatalogButton then self._gridButtonItems[self._selectedCatalogButton] else nil
	if notifySelection ~= false then
		self._callbacks.onSelectionChanged(self._selectedCatalogItem)
	end
end

function LockerGrid:GetSelectedItem(): LockerCatalogItem?
	return self._selectedCatalogItem
end

function LockerGrid:GetCardForItem(itemId: string): GuiObject?
	local button = self._gridButtonByItemId[itemId]
	if not button then
		return nil
	end
	return self._gridCardByButton[button]
end

function LockerGrid:Destroy()
	self._populateGeneration += 1
	self._janitor:Destroy()
	for _, previewJanitor in self._cardPreviewJanitors do
		previewJanitor:Destroy()
	end
	table.clear(self._cardPreviewJanitors)
	for _, tween in self._activeGridScaleTweens do
		tween:Cancel()
	end
	table.clear(self._activeGridScaleTweens)
	table.clear(self._hoveredGridButtons)
	table.clear(self._gridCardByButton)
	table.clear(self._gridButtonByItemId)
end

return LockerGrid
