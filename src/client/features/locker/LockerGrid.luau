--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local wrapPreviewTemplate = ReplicatedStorage:WaitForChild("Wrap")

local Janitor = require(Packages.janitor) :: any

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
}

type ItemGridCardRefs = {
	button: GuiButton?,
	itemNode: GuiObject?,
	viewportNode: ViewportFrame?,
	priceNode: TextLabel?,
	currencyNode: GuiObject?,
	ownedNode: TextLabel?,
	equippedNode: GuiObject?,
	lockedNode: GuiObject?,
	lockedLevelNode: TextLabel?,
	lockedTemplate: GuiObject?,
	lockedParent: Instance?,
}

type LockerGridCallbacks = {
	canInteract: (() -> boolean)?,
	isItemOwned: (LockerCatalogItem) -> boolean,
	isItemEquipped: (LockerCatalogItem) -> boolean,
	getCurrentLevel: () -> number,
	onSelectionChanged: (LockerCatalogItem?) -> (),
	onOwnedItemActivated: (LockerCatalogItem) -> (),
}

export type LockerGrid = {
	_itemGrid: GuiObject,
	_itemGridTemplate: GuiObject,
	_callbacks: LockerGridCallbacks,
	_canUseHoverAnimations: boolean,
	_populateGeneration: number,
	_activeGridCards: { GuiObject },
	_gridCardPool: { GuiObject },
	_cachedGridCardRefs: { [GuiObject]: ItemGridCardRefs },
	_cardPreviewJanitors: { [GuiObject]: any },
	_gridButtonItems: { [GuiButton]: LockerCatalogItem },
	_selectedCatalogButton: GuiButton?,
	_selectedCatalogItem: LockerCatalogItem?,
	_activeGridScaleTweens: { [GuiButton]: Tween },
	_hoveredGridButtons: { [GuiButton]: boolean },
	_gridCardByButton: { [GuiButton]: GuiObject },
	_gridButtonByItemId: { [string]: GuiButton },
	_janitor: any,
	_populateJanitor: any,
	Destroy: (self: LockerGrid) -> (),
	Clear: (self: LockerGrid) -> (),
	Populate: (self: LockerGrid, items: { LockerCatalogItem }, selectedItemId: string?) -> (),
	RefreshVisibleState: (self: LockerGrid) -> (),
	GetSelectedItem: (self: LockerGrid) -> LockerCatalogItem?,
	_getButtonStroke: (self: LockerGrid, button: GuiButton) -> UIStroke?,
	_getGridCardRefs: (self: LockerGrid, card: GuiObject) -> ItemGridCardRefs,
	_acquireGridCard: (self: LockerGrid) -> GuiObject,
	_setSelectedButton: (self: LockerGrid, targetButton: GuiButton) -> (),
	_updateGridCardVisual: (self: LockerGrid, button: GuiButton) -> (),
	_getOrCreateGridButtonScale: (self: LockerGrid, button: GuiButton) -> UIScale,
	_tweenGridButtonScale: (self: LockerGrid, button: GuiButton, targetScale: number, tweenInfo: TweenInfo) -> (),
	_bindCatalogButtonHover: (self: LockerGrid, button: GuiButton) -> (),
	_clearCardViewportPreview: (self: LockerGrid, card: GuiObject) -> (),
	_getWrapPreviewPrimaryPart: (self: LockerGrid, previewInstance: Instance) -> BasePart?,
	_applyWrapAppearanceToPrimaryPart: (self: LockerGrid, previewPrimaryPart: BasePart, item: LockerCatalogItem, previewJanitor: any) -> (),
	_applyWeaponSkinViewportPreview: (self: LockerGrid, card: GuiObject, item: LockerCatalogItem) -> boolean,
	_applyCatalogItemToCard: (self: LockerGrid, card: GuiObject, item: LockerCatalogItem, layoutOrder: number) -> (),
	_resetTransientState: (self: LockerGrid, notifySelection: boolean) -> (),
}

local GRID_BUTTON_HOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GRID_BUTTON_CLICK_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GRID_BUTTON_DEFAULT_SCALE = 1
local GRID_BUTTON_HOVER_SCALE = 1.04
local GRID_BUTTON_CLICK_SCALE = 0.96
local STROKE_DEFAULT = Color3.fromRGB(38, 38, 38)
local STROKE_WHITE = Color3.fromRGB(255, 255, 255)
local DEFAULT_VIEWPORT_ROTATION = Vector3.new(12, -18, 0)
local DEFAULT_VIEWPORT_FOV = 64
local DEFAULT_VIEWPORT_DISTANCE = 6
local DEFAULT_WRAP_STUDS_PER_TILE = 3
local WRAP_TEXTURE_SCROLL_SPEED_U = 1
local WRAP_TEXTURE_SCROLL_SPEED_V = 0
local POPULATE_SYNC_ITEM_COUNT = 12
local POPULATE_ASYNC_BATCH_SIZE = 8
local WRAP_TEXTURE_NAMES = {
	ScrollTexture_Back = true,
	ScrollTexture_Bottom = true,
	ScrollTexture_Left = true,
	ScrollTexture_Right = true,
} :: { [string]: boolean }

local _activeAnimatedWrapTextures = {} :: { [Texture]: boolean }
local _activeAnimatedWrapConnection: RBXScriptConnection? = nil

local function stopActiveAnimatedWrapLoopIfIdle(): ()
	if next(_activeAnimatedWrapTextures) ~= nil then
		return
	end

	if _activeAnimatedWrapConnection then
		_activeAnimatedWrapConnection:Disconnect()
		_activeAnimatedWrapConnection = nil
	end
end

local function ensureActiveAnimatedWrapLoop(): ()
	if _activeAnimatedWrapConnection then
		return
	end

	_activeAnimatedWrapConnection = RunService.Heartbeat:Connect(function(dt)
		for texture in _activeAnimatedWrapTextures do
			if texture.Parent == nil then
				_activeAnimatedWrapTextures[texture] = nil
			else
				local tileU = if texture.StudsPerTileU ~= 0 then texture.StudsPerTileU else 1
				local tileV = if texture.StudsPerTileV ~= 0 then texture.StudsPerTileV else 1
				texture.OffsetStudsU = (texture.OffsetStudsU + WRAP_TEXTURE_SCROLL_SPEED_U * dt) % tileU
				texture.OffsetStudsV = (texture.OffsetStudsV + WRAP_TEXTURE_SCROLL_SPEED_V * dt) % tileV
			end
		end

		stopActiveAnimatedWrapLoopIfIdle()
	end)
end

local function registerAnimatedWrapTextures(previewJanitor: any, textures: { Texture }): ()
	if #textures <= 0 then
		return
	end

	for _, texture in textures do
		_activeAnimatedWrapTextures[texture] = true
	end

	ensureActiveAnimatedWrapLoop()

	previewJanitor:Add(function()
		for _, texture in textures do
			_activeAnimatedWrapTextures[texture] = nil
		end
		stopActiveAnimatedWrapLoopIfIdle()
	end, true)
end

local LockerGrid = {}
LockerGrid.__index = LockerGrid

function LockerGrid.new(
	itemGrid: GuiObject,
	itemGridTemplate: GuiObject,
	canUseHoverAnimations: boolean,
	callbacks: LockerGridCallbacks
): LockerGrid
	local self = setmetatable({}, LockerGrid) :: any
	self._itemGrid = itemGrid
	self._itemGridTemplate = itemGridTemplate
	self._callbacks = callbacks
	self._canUseHoverAnimations = canUseHoverAnimations
	self._populateGeneration = 0
	self._activeGridCards = {}
	self._gridCardPool = {}
	self._cachedGridCardRefs = {}
	self._cardPreviewJanitors = {}
	self._gridButtonItems = {}
	self._selectedCatalogButton = nil
	self._selectedCatalogItem = nil
	self._activeGridScaleTweens = {}
	self._hoveredGridButtons = {}
	self._gridCardByButton = {}
	self._gridButtonByItemId = {}
	self._janitor = Janitor.new()
	self._populateJanitor = Janitor.new()
	self._janitor:Add(self._populateJanitor, "Destroy")
	return self
end

function LockerGrid:_getButtonStroke(button: GuiButton): UIStroke?
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke and stroke:IsA("UIStroke") then
		return stroke
	end

	return nil
end

function LockerGrid:_getGridCardRefs(card: GuiObject): ItemGridCardRefs
	local cached = self._cachedGridCardRefs[card]
	if cached then
		return cached
	end

	local buttonNode = card:FindFirstChild("Button")
	local button = if buttonNode and buttonNode:IsA("GuiButton") then buttonNode else nil
	local itemNode = if button then button:FindFirstChild("Item", true) else nil
	local viewportNode = if button then button:FindFirstChildWhichIsA("ViewportFrame", true) else nil
	local priceNode = if button then button:FindFirstChild("Price", true) else nil
	local currencyNode = if button then button:FindFirstChild("Currency", true) else nil
	local ownedNode = if button then button:FindFirstChild("Owned", true) else nil
	local equippedNode = if button then button:FindFirstChild("Equiped", true) else nil
	local lockedNode = if button then button:FindFirstChild("Locked", true) else nil
	local lockedGui = if lockedNode and lockedNode:IsA("GuiObject") then lockedNode else nil
	local lockedLevelNode = if lockedGui then lockedGui:FindFirstChild("lvl", true) else nil

	local refs = {
		button = button,
		itemNode = if itemNode and (itemNode:IsA("ImageLabel") or itemNode:IsA("ImageButton")) then itemNode else nil,
		viewportNode = if viewportNode and viewportNode:IsA("ViewportFrame") then viewportNode else nil,
		priceNode = if priceNode and priceNode:IsA("TextLabel") then priceNode else nil,
		currencyNode = if currencyNode and currencyNode:IsA("GuiObject") then currencyNode else nil,
		ownedNode = if ownedNode and ownedNode:IsA("TextLabel") then ownedNode else nil,
		equippedNode = if equippedNode and equippedNode:IsA("GuiObject") then equippedNode else nil,
		lockedNode = lockedGui,
		lockedLevelNode = if lockedLevelNode and lockedLevelNode:IsA("TextLabel") then lockedLevelNode else nil,
		lockedTemplate = if lockedGui then lockedGui:Clone() else nil,
		lockedParent = if lockedGui then lockedGui.Parent else nil,
	}

	self._cachedGridCardRefs[card] = refs
	return refs
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
		child:Destroy()
	end
	viewportNode.Visible = false
end

function LockerGrid:_getWrapPreviewPrimaryPart(previewInstance: Instance): BasePart?
	if previewInstance:IsA("Model") then
		local primaryPart = previewInstance.PrimaryPart
		if primaryPart then
			return primaryPart
		end

		local mainPart = previewInstance:FindFirstChild("Main", true)
		if mainPart and mainPart:IsA("BasePart") then
			return mainPart
		end

		return previewInstance:FindFirstChildWhichIsA("BasePart", true)
	end

	if previewInstance:IsA("BasePart") then
		return previewInstance
	end

	return nil
end

function LockerGrid:_applyWrapAppearanceToPrimaryPart(previewPrimaryPart: BasePart, item: LockerCatalogItem, previewJanitor: any)
	local textureId = if type(item.TextureID) == "string" and item.TextureID ~= "" then item.TextureID else nil
	local baseColor = item.BaseColor
	local animated = item.Animated == true
	local studsPerTile = math.max(0.01, tonumber(item.StudsPerTile) or DEFAULT_WRAP_STUDS_PER_TILE)
	local scrollingTextures = {}

	if not textureId and typeof(baseColor) == "Color3" then
		previewPrimaryPart.Color = baseColor
	end

	for _, child in previewPrimaryPart:GetChildren() do
		if child:IsA("Texture") and WRAP_TEXTURE_NAMES[child.Name] then
			if textureId then
				child.Texture = textureId
				child.Transparency = 0
				child.StudsPerTileU = studsPerTile
				child.StudsPerTileV = studsPerTile
				table.insert(scrollingTextures, child)
			else
				child:Destroy()
			end
		end
	end

	if textureId and animated and #scrollingTextures > 0 then
		registerAnimatedWrapTextures(previewJanitor, scrollingTextures)
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

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewportNode
	previewJanitor:Add(worldModel, "Destroy")

	local clonedWrap = wrapPreviewTemplate:Clone()
	clonedWrap.Parent = worldModel
	previewJanitor:Add(clonedWrap, "Destroy")

	for _, descendant in clonedWrap:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end

	local previewPrimaryPart = self:_getWrapPreviewPrimaryPart(clonedWrap)
	if not previewPrimaryPart then
		return false
	end

	self:_applyWrapAppearanceToPrimaryPart(previewPrimaryPart, item, previewJanitor)

	local boundingCFrame: CFrame
	if clonedWrap:IsA("Model") then
		boundingCFrame = clonedWrap:GetBoundingBox()
	elseif clonedWrap:IsA("BasePart") then
		boundingCFrame = clonedWrap.CFrame
	else
		return false
	end

	local rotationCFrame = CFrame.Angles(
		math.rad(DEFAULT_VIEWPORT_ROTATION.X),
		math.rad(DEFAULT_VIEWPORT_ROTATION.Y),
		math.rad(DEFAULT_VIEWPORT_ROTATION.Z)
	)

	if clonedWrap:IsA("Model") then
		clonedWrap:PivotTo(boundingCFrame * rotationCFrame)
		boundingCFrame = clonedWrap:GetBoundingBox()
	else
		clonedWrap.CFrame = boundingCFrame * rotationCFrame
		boundingCFrame = clonedWrap.CFrame
	end

	viewportNode.Ambient = Color3.fromRGB(255, 255, 255)
	viewportNode.LightColor = Color3.fromRGB(255, 255, 255)
	viewportNode.LightDirection = Vector3.new(1, -2, 2)

	local camera = Instance.new("Camera")
	camera.FieldOfView = DEFAULT_VIEWPORT_FOV
	camera.Parent = viewportNode
	previewJanitor:Add(camera, "Destroy")
	viewportNode.CurrentCamera = camera

	local focusCFrame = previewPrimaryPart.CFrame
	local cameraPosition = (focusCFrame * CFrame.new(0, 0, DEFAULT_VIEWPORT_DISTANCE)).Position
	camera.CFrame = CFrame.lookAt(cameraPosition, focusCFrame.Position)
	viewportNode.Visible = true
	return true
end

function LockerGrid:_acquireGridCard(): GuiObject
	local pooledCard = table.remove(self._gridCardPool)
	if pooledCard then
		return pooledCard
	end

	return self._itemGridTemplate:Clone()
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
	local equipped = self._callbacks.isItemEquipped(item)
	local currentLevel = self._callbacks.getCurrentLevel()
	local isLevelLocked = not owned and currentLevel < item.LevelRequired
	local isSelectedButton = button == self._selectedCatalogButton

	if isLevelLocked then
		if refs.lockedNode == nil or refs.lockedNode.Parent == nil then
			local lockedTemplate = refs.lockedTemplate
			local lockedParent = refs.lockedParent
			if lockedTemplate and lockedParent and lockedParent:IsDescendantOf(card) then
				local clonedLocked = lockedTemplate:Clone()
				clonedLocked.Parent = lockedParent
				refs.lockedNode = clonedLocked

				local clonedLevelNode = clonedLocked:FindFirstChild("lvl", true)
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
		if refs.lockedNode then
			refs.lockedNode:Destroy()
			refs.lockedNode = nil
			refs.lockedLevelNode = nil
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
	self:_clearCardViewportPreview(card)
	local usesViewportPreview = item.Category == "WeaponSkins" and self:_applyWeaponSkinViewportPreview(card, item)

	if refs.viewportNode then
		refs.viewportNode.Visible = usesViewportPreview
	end

	if refs.itemNode and (refs.itemNode:IsA("ImageLabel") or refs.itemNode:IsA("ImageButton")) then
		refs.itemNode.Visible = not usesViewportPreview
		refs.itemNode.Image = item.Image
	end

	if refs.priceNode then
		refs.priceNode.Text = tostring(item.Price)
		refs.priceNode.Visible = true
	end

	if refs.currencyNode then
		refs.currencyNode.Visible = true
	end

	if refs.ownedNode then
		refs.ownedNode.Visible = false
	end

	if refs.equippedNode then
		refs.equippedNode.Visible = false
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

		self:_setSelectedButton(button)

		local selectedItem = self._gridButtonItems[button]
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
		self:_clearCardViewportPreview(card)
		card.Visible = false
	end
end

function LockerGrid:Populate(items: { LockerCatalogItem }, selectedItemId: string?)
	self:_resetTransientState(false)
	local generation = self._populateGeneration
	local totalItems = #items
	local syncItemCount = math.min(totalItems, POPULATE_SYNC_ITEM_COUNT)

	local function applyCatalogItem(layoutOrder: number)
		local card = self._activeGridCards[layoutOrder]
		if not card then
			card = self:_acquireGridCard()
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

function LockerGrid:RefreshVisibleState()
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
	self._callbacks.onSelectionChanged(self._selectedCatalogItem)
end

function LockerGrid:GetSelectedItem(): LockerCatalogItem?
	return self._selectedCatalogItem
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
	stopActiveAnimatedWrapLoopIfIdle()
end

return LockerGrid
