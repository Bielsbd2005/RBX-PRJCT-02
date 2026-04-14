--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local MenuHover = require(Client.core.ui.MenuHover)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local DataController = require(Client.core.data.DataController)
local FusionSkinRenderer = require(script.FusionSkinRenderer)
local FusionSkinInventory = require(script.FusionSkinInventory)

local FusionFeature = {}

local STROKE_DEFAULT = Color3.fromRGB(38, 38, 38)
local STROKE_WHITE = Color3.fromRGB(255, 255, 255)
local MENU_HOVER_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local INPUT_BUTTON_DEFAULT_IMAGE = "rbxassetid://100090954804591"
local SKIN_BUTTON_IMAGE = "rbxassetid://71136216021149"
local INPUT_BUTTON_DEFAULT_IMAGE_COLOR = Color3.fromRGB(54, 54, 54)
local INPUT_BUTTON_DEFAULT_BACKGROUND = Color3.fromRGB(82, 82, 82)
local OUTPUT_LIGHT_DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)

local CLOSE_BUTTON_NAMES = {
	"CloseBtn",
	"Close",
	"close",
	"Cerrar",
} :: { string }

type FusionSkinItem = FusionSkinInventory.FusionSkinItem

type InputRefs = {
	slotId: string,
	wrapper: GuiObject,
	clickButton: GuiButton,
	root: GuiObject,
	addLabel: GuiObject?,
	skinContainer: GuiObject?,
	viewport: ViewportFrame?,
	removeButton: GuiButton?,
	rarityLabel: TextLabel?,
	buttonRarityLabel: TextLabel?,
}

type TemplateRefs = {
	root: GuiObject,
	button: GuiButton?,
	viewport: ViewportFrame?,
	rarity: TextLabel?,
	amount: TextLabel?,
}

type InventoryData = {
	WeaponSkinsByWeapon: {
		[string]: { [string]: { [string]: number | boolean } },
	}?,
}

type RarityTheme = {
	Background: Color3,
	ImageColor: Color3,
	Stroke: Color3,
	RarityText: Color3,
	RarityStroke: Color3,
}

type VisualDefaults = {
	backgroundNode: GuiObject,
	backgroundColor: Color3,
	imageColors: { [GuiObject]: Color3 },
	strokeColors: { [UIStroke]: Color3 },
	rarityTextColor: Color3?,
	rarityStrokeColor: Color3?,
}

local RARITY_THEMES = {
	Legendary = {
		Background = Color3.fromRGB(253, 236, 118),
		ImageColor = Color3.fromRGB(238, 184, 95),
		Stroke = Color3.fromRGB(249, 181, 73),
		RarityText = Color3.new(1, 1, 1),
		RarityStroke = Color3.fromRGB(200, 154, 57),
	},
	Epic = {
		Background = Color3.fromRGB(224, 126, 255),
		ImageColor = Color3.fromRGB(186, 98, 255),
		Stroke = Color3.fromRGB(172, 0, 247),
		RarityText = Color3.fromRGB(255, 210, 255),
		RarityStroke = Color3.fromRGB(161, 60, 241),
	},
	Rare = {
		Background = Color3.fromRGB(184, 220, 255),
		ImageColor = Color3.fromRGB(151, 190, 240),
		Stroke = Color3.fromRGB(92, 132, 236),
		RarityText = Color3.fromRGB(235, 244, 231),
		RarityStroke = Color3.fromRGB(114, 162, 220),
	},
	Common = {
		Background = Color3.fromRGB(202, 202, 202),
		ImageColor = Color3.fromRGB(229, 229, 229),
		Stroke = Color3.fromRGB(162, 162, 162),
		RarityText = Color3.new(1, 1, 1),
		RarityStroke = Color3.fromRGB(143, 143, 143),
	},
} :: { [string]: RarityTheme }

local RARITY_UPGRADE_BY_THEME = {
	Common = "Rare",
	Uncommon = "Rare",
	Rare = "Epic",
	Epic = "Legendary",
	Legendary = "Legendary",
} :: { [string]: string }

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

local function findFirstLabelByName(root: Instance, name: string): TextLabel?
	local target = root:FindFirstChild(name, true)
	if target and target:IsA("TextLabel") then
		return target
	end
	return nil
end

local function findFirstGuiObjectByName(root: Instance, name: string): GuiObject?
	local target = root:FindFirstChild(name, true)
	if target and target:IsA("GuiObject") then
		return target
	end
	return nil
end

local function findStroke(root: Instance): UIStroke?
	local stroke = root:FindFirstChildOfClass("UIStroke")
	if stroke and stroke:IsA("UIStroke") then
		return stroke
	end

	local nestedStroke = root:FindFirstChildWhichIsA("UIStroke", true)
	if nestedStroke and nestedStroke:IsA("UIStroke") then
		return nestedStroke
	end

	return nil
end

local function resolveRarityTheme(rarity: string?): RarityTheme
	if rarity then
		local exact = RARITY_THEMES[rarity]
		if exact then
			return exact
		end
	end

	return RARITY_THEMES.Common
end

local function captureVisualDefaults(root: GuiObject, rarityLabel: TextLabel?, backgroundNode: GuiObject?): VisualDefaults
	local resolvedBackgroundNode = if backgroundNode then backgroundNode else root
	local imageColors = {} :: { [GuiObject]: Color3 }
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			imageColors[descendant] = descendant.ImageColor3
		end
	end

	local strokeColors = {} :: { [UIStroke]: Color3 }
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("UIStroke") then
			strokeColors[descendant] = descendant.Color
		end
	end

	return {
		backgroundNode = resolvedBackgroundNode,
		backgroundColor = resolvedBackgroundNode.BackgroundColor3,
		imageColors = imageColors,
		strokeColors = strokeColors,
		rarityTextColor = if rarityLabel then rarityLabel.TextColor3 else nil,
		rarityStrokeColor = if rarityLabel then rarityLabel.TextStrokeColor3 else nil,
	}
end

local function applyVisualTheme(
	root: GuiObject,
	rarityLabel: TextLabel?,
	defaults: VisualDefaults,
	theme: RarityTheme,
	applyStrokeTheme: boolean
): ()
	defaults.backgroundNode.BackgroundColor3 = theme.Background

	for imageNode in defaults.imageColors do
		if imageNode.Parent ~= nil then
			if imageNode:IsA("ImageLabel") then
				imageNode.ImageColor3 = theme.ImageColor
			elseif imageNode:IsA("ImageButton") then
				imageNode.ImageColor3 = theme.ImageColor
			end
		end
	end

	if applyStrokeTheme then
		for stroke in defaults.strokeColors do
			if stroke.Parent ~= nil then
				stroke.Color = theme.Stroke
			end
		end
	end

	if rarityLabel then
		rarityLabel.TextColor3 = theme.RarityText
		rarityLabel.TextStrokeColor3 = theme.RarityStroke
	end
end

local function restoreVisualTheme(
	root: GuiObject,
	rarityLabel: TextLabel?,
	defaults: VisualDefaults,
	restoreStrokeTheme: boolean
): ()
	defaults.backgroundNode.BackgroundColor3 = defaults.backgroundColor

	for imageNode, defaultColor in defaults.imageColors do
		if imageNode.Parent ~= nil then
			if imageNode:IsA("ImageLabel") then
				imageNode.ImageColor3 = defaultColor
			elseif imageNode:IsA("ImageButton") then
				imageNode.ImageColor3 = defaultColor
			end
		end
	end

	if restoreStrokeTheme then
		for stroke, defaultColor in defaults.strokeColors do
			if stroke.Parent ~= nil then
				stroke.Color = defaultColor
			end
		end
	end

	if rarityLabel and defaults.rarityTextColor and defaults.rarityStrokeColor then
		rarityLabel.TextColor3 = defaults.rarityTextColor
		rarityLabel.TextStrokeColor3 = defaults.rarityStrokeColor
	end
end

local function applyInputButtonVisual(button: GuiButton, rarity: string?): ()
	local theme = resolveRarityTheme(rarity)
	button.BackgroundColor3 = theme.Background
	if button:IsA("ImageButton") then
		button.Image = SKIN_BUTTON_IMAGE
		button.ImageColor3 = theme.ImageColor
	end
end

local function restoreInputButtonVisual(button: GuiButton): ()
	button.BackgroundColor3 = INPUT_BUTTON_DEFAULT_BACKGROUND
	if button:IsA("ImageButton") then
		button.Image = INPUT_BUTTON_DEFAULT_IMAGE
		button.ImageColor3 = INPUT_BUTTON_DEFAULT_IMAGE_COLOR
	end
end

local function collectInputRefs(inputContainer: Instance): { InputRefs }
	local result = {} :: { InputRefs }

	for _, child in inputContainer:GetChildren() do
		if child:IsA("GuiObject") and string.match(child.Name, "^Input%d+Wrapper$") then
			local slotId = child.Name
			local rootName = string.gsub(slotId, "Wrapper$", "")
			local rootNode = child:FindFirstChild(rootName)
			local root = if rootNode and rootNode:IsA("GuiObject") then rootNode else child
			local clickButton = if child:IsA("GuiButton") then child else child:FindFirstChildWhichIsA("GuiButton", true)
			local skinNode = root:FindFirstChild("Skin")
			local skinContainer = if skinNode and skinNode:IsA("GuiObject") then skinNode else nil
			local removeNode = if skinContainer then skinContainer:FindFirstChild("Remove", true) else nil
			if clickButton then
				local refs: InputRefs = {
					slotId = slotId,
					wrapper = child,
					clickButton = clickButton,
					root = root,
					addLabel = (function()
						local add = root:FindFirstChild("Add")
						if add and add:IsA("GuiObject") then
							return add
						end
						return nil
					end)(),
					skinContainer = skinContainer,
					viewport = if skinContainer then skinContainer:FindFirstChildWhichIsA("ViewportFrame", true) else nil,
					removeButton = if removeNode and removeNode:IsA("GuiButton") then removeNode else nil,
					rarityLabel = if skinContainer then findFirstLabelByName(skinContainer, "Rarity") else nil,
					buttonRarityLabel = findFirstLabelByName(clickButton, "Rarity"),
				}

				table.insert(result, refs)
			end
		end
	end

	table.sort(result, function(a, b)
		return a.slotId < b.slotId
	end)

	return result
end

local function resolveTemplateRefs(templateNode: GuiObject): TemplateRefs
	local button = if templateNode:IsA("GuiButton") then templateNode else templateNode:FindFirstChildWhichIsA("GuiButton", true)
	return {
		root = templateNode,
		button = button,
		viewport = templateNode:FindFirstChildWhichIsA("ViewportFrame", true),
		rarity = findFirstLabelByName(templateNode, "Rarity"),
		amount = findFirstLabelByName(templateNode, "Amount"),
	}
end

function FusionFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	local fusionButton = findFooterButton(menuGui, "fusion")
	if not fusionButton then
		warn("[FusionFeature] Footer button 'fusion' not found")
		return janitor
	end

	local fusionGui = playerGui:WaitForChild("Fusion") :: ScreenGui
	local closeButton = findCloseButton(fusionGui)
	local cameraController = LockerCameraController.new("fusion")
	local renderer = FusionSkinRenderer.new()

	janitor:Add(cameraController, "Destroy")
	janitor:Add(renderer, "Destroy")

	local containerNode = fusionGui:FindFirstChild("Container", true)
	if not containerNode or not containerNode:IsA("GuiObject") then
		warn("[FusionFeature] Missing Fusion.Container")
		return janitor
	end

	local inputContainer = containerNode:FindFirstChild("InputContainer", true)
	if not inputContainer then
		warn("[FusionFeature] Missing Fusion.Container.InputContainer")
		return janitor
	end

	local outputNode = containerNode:FindFirstChild("Output", true)
	local outputButton = if outputNode and outputNode:IsA("GuiButton") then outputNode else nil
	local outputLightNode = containerNode:FindFirstChild("Light", true)
	local outputLight = if outputLightNode and (outputLightNode:IsA("ImageLabel") or outputLightNode:IsA("ImageButton"))
		then outputLightNode
		else nil

	local skinsFrame = fusionGui:FindFirstChild("SkinsFrame", true)
	if not skinsFrame or not skinsFrame:IsA("GuiObject") then
		warn("[FusionFeature] Missing Fusion.SkinsFrame")
		return janitor
	end

	local hideButtonNode = skinsFrame:FindFirstChild("HideBtn", true)
	local hideButton = if hideButtonNode and hideButtonNode:IsA("GuiButton") then hideButtonNode else nil

	local itemGridNode = skinsFrame:FindFirstChild("ItemGrid", true)
	if not itemGridNode or not itemGridNode:IsA("GuiObject") then
		warn("[FusionFeature] Missing Fusion.SkinsFrame.ItemGrid")
		return janitor
	end

	local templateNode = itemGridNode:FindFirstChild("Template")
	if not templateNode or not templateNode:IsA("GuiObject") then
		warn("[FusionFeature] Missing Fusion.SkinsFrame.ItemGrid.Template")
		return janitor
	end

	templateNode.Visible = false

	local inputRefs = collectInputRefs(inputContainer)
	if #inputRefs <= 0 then
		warn("[FusionFeature] No InputXWrapper nodes found in Fusion UI")
		return janitor
	end

	local slotIds = table.create(#inputRefs) :: { string }
	for index, refs in inputRefs do
		slotIds[index] = refs.slotId
	end

	local inventoryState = FusionSkinInventory.new(slotIds)
	local activeSlotId: string? = nil
	local hoveredSlots = {} :: { [string]: boolean }
	local strokeTweens = {} :: { [string]: Tween? }
	local inputVisualDefaults = {} :: { [GuiObject]: VisualDefaults }
	local gridVisualDefaults = {} :: { [GuiObject]: VisualDefaults }
	local gridCards = {} :: { GuiObject }
	local gridJanitor = Janitor.new()
	janitor:Add(gridJanitor, "Destroy")
	janitor:Add(function()
		for slotId, tween in strokeTweens do
			if tween then
				tween:Cancel()
			end
			strokeTweens[slotId] = nil
		end
	end, true)

	local function setMenuVisibleInstant(visible: boolean)
		menuGui.Enabled = visible
	end

	local function refreshInputVisual(refs: InputRefs)
		local slotSkin = inventoryState:GetSlotSkin(refs.slotId)
		local filled = slotSkin ~= nil
		local themedRoot = if refs.skinContainer then refs.skinContainer else refs.root
		local backgroundTarget = findFirstGuiObjectByName(themedRoot, "WeaponSkin")
		local defaults = inputVisualDefaults[themedRoot]
		if not defaults then
			defaults = captureVisualDefaults(themedRoot, refs.buttonRarityLabel, backgroundTarget)
			inputVisualDefaults[themedRoot] = defaults
		end

		if refs.addLabel then
			refs.addLabel.Visible = not filled
		end
		if refs.skinContainer then
			refs.skinContainer.Visible = filled
		end
		if refs.rarityLabel then
			refs.rarityLabel.Text = if slotSkin then slotSkin.Rarity else ""
			refs.rarityLabel.Visible = false
		end
		if refs.buttonRarityLabel then
			refs.buttonRarityLabel.Text = if slotSkin then slotSkin.Rarity else ""
			refs.buttonRarityLabel.Visible = filled
		end

		if slotSkin then
			applyVisualTheme(themedRoot, refs.buttonRarityLabel, defaults, resolveRarityTheme(slotSkin.Rarity), false)
			applyInputButtonVisual(refs.clickButton, slotSkin.Rarity)
		else
			restoreVisualTheme(themedRoot, refs.buttonRarityLabel, defaults, false)
			restoreInputButtonVisual(refs.clickButton)
		end

		if refs.viewport then
			if slotSkin then
				renderer:RenderSkin(refs.viewport, slotSkin)
			else
				renderer:ClearViewport(refs.viewport)
			end
		end
	end

	local function resolveOutputUpgradeRarity(): string?
		if #inputRefs ~= 4 then
			return nil
		end

		local sourceRarity: string? = nil
		for _, refs in inputRefs do
			local slotSkin = inventoryState:GetSlotSkin(refs.slotId)
			if not slotSkin then
				return nil
			end

			if sourceRarity == nil then
				sourceRarity = slotSkin.Rarity
			elseif slotSkin.Rarity ~= sourceRarity then
				return nil
			end
		end

		if sourceRarity == nil then
			return nil
		end

		return RARITY_UPGRADE_BY_THEME[sourceRarity]
	end

	local function refreshOutputVisual()
		if not outputButton then
			if outputLight then
				outputLight.ImageColor3 = OUTPUT_LIGHT_DEFAULT_COLOR
			end
			return
		end

		local upgradedRarity = resolveOutputUpgradeRarity()
		if upgradedRarity then
			applyInputButtonVisual(outputButton, upgradedRarity)
			if outputLight then
				outputLight.ImageColor3 = resolveRarityTheme(upgradedRarity).ImageColor
			end
		else
			restoreInputButtonVisual(outputButton)
			if outputLight then
				outputLight.ImageColor3 = OUTPUT_LIGHT_DEFAULT_COLOR
			end
		end
	end

	local function refreshAllInputs()
		for _, refs in inputRefs do
			refreshInputVisual(refs)
		end
		refreshOutputVisual()
	end

	local function refreshInputStroke(refs: InputRefs)
		local stroke = findStroke(refs.root) or findStroke(refs.wrapper)
		if not stroke then
			return
		end

		local isSelected = activeSlotId == refs.slotId
		local isHovered = hoveredSlots[refs.slotId] == true
		local targetColor = if isSelected or isHovered then STROKE_WHITE else STROKE_DEFAULT

		local currentTween = strokeTweens[refs.slotId]
		if currentTween then
			currentTween:Cancel()
		end

		local tween = TweenService:Create(stroke, MENU_HOVER_TWEEN_INFO, { Color = targetColor })
		strokeTweens[refs.slotId] = tween
		tween:Play()
	end

	local function refreshAllInputStrokes()
		for _, refs in inputRefs do
			refreshInputStroke(refs)
		end
	end

	local function closeSkinsPanel()
		activeSlotId = nil
		skinsFrame.Visible = false
		refreshAllInputStrokes()
	end

	local function populateGrid()
		gridJanitor:Cleanup()
		local available = inventoryState:GetAvailableItems()

		for _, card in gridCards do
			card.Visible = false
		end

		for index, item in available do
			local card = gridCards[index]
			if not card then
				card = templateNode:Clone()
				card.Name = "Skin_" .. item.ItemKey
				card.Parent = itemGridNode
				card.Visible = true
				gridCards[index] = card
			end

			local refs = resolveTemplateRefs(card)
			card.LayoutOrder = index
			card.Visible = true

			if refs.rarity then
				refs.rarity.Text = item.Rarity
			end

			local cardDefaults = gridVisualDefaults[card]
			if not cardDefaults then
				cardDefaults = captureVisualDefaults(card, refs.rarity, findFirstGuiObjectByName(card, "WeaponSkin"))
				gridVisualDefaults[card] = cardDefaults
			end
			applyVisualTheme(card, refs.rarity, cardDefaults, resolveRarityTheme(item.Rarity), true)

			local amount = inventoryState:GetFreeAmount(item.ItemKey)
			if refs.amount then
				refs.amount.Visible = amount > 1
				refs.amount.Text = "x" .. tostring(amount)
			end

			if refs.viewport then
				renderer:RenderSkin(refs.viewport, item)
			end

			local button = refs.button
			if button then
				button.Active = true
				button.AutoButtonColor = false
				button.Selectable = true
				button:SetAttribute("SkinKey", item.ItemKey)
				button:SetAttribute("Rarity", item.Rarity)
				if button:IsA("ImageButton") then
					button.Image = SKIN_BUTTON_IMAGE
				end

				InteractiveScaleTween.bindButton(button, janitor, {
					enableHover = canUseHoverAnimations,
					scaleTarget = card,
				})

				gridJanitor:Add(button.Activated:Connect(function()
					local slotId = activeSlotId
					if not slotId then
						return
					end

					local assigned = inventoryState:SetSlotSkin(slotId, item.ItemKey)
					if not assigned then
						return
					end

					refreshAllInputs()
					closeSkinsPanel()
				end), "Disconnect")
			end
		end
	end

	for _, refs in inputRefs do
		InteractiveScaleTween.bindButton(refs.clickButton, janitor, {
			enableHover = canUseHoverAnimations,
			scaleTarget = refs.root,
		})

		if canUseHoverAnimations then
			janitor:Add(refs.clickButton.MouseEnter:Connect(function()
				hoveredSlots[refs.slotId] = true
				refreshInputStroke(refs)
			end), "Disconnect")

			janitor:Add(refs.clickButton.MouseLeave:Connect(function()
				hoveredSlots[refs.slotId] = false
				refreshInputStroke(refs)
			end), "Disconnect")
		end

		janitor:Add(refs.clickButton.Activated:Connect(function()
			activeSlotId = refs.slotId
			refreshAllInputStrokes()
			populateGrid()
			skinsFrame.Visible = true
		end), "Disconnect")

		if refs.removeButton then
			InteractiveScaleTween.bindButton(refs.removeButton, janitor, {
				enableHover = canUseHoverAnimations,
				defaultScale = 1,
				hoverScale = 1.06,
				clickScale = 0.95,
			})

			janitor:Add(refs.removeButton.Activated:Connect(function()
				inventoryState:ClearSlot(refs.slotId)
				refreshAllInputs()

				if activeSlotId ~= nil then
					populateGrid()
				end
			end), "Disconnect")
		end
	end

	DataController:WhenReady():andThen(function()
		local inventory = Fusion.peek(DataController.Inventory) :: InventoryData
		inventoryState:BuildFromInventory(inventory)
		refreshAllInputs()
		if activeSlotId ~= nil then
			populateGrid()
		end

		local inventoryObserver = fusionScope:Observer(DataController.Inventory)
		janitor:Add(inventoryObserver:onBind(function()
			local updatedInventory = Fusion.peek(DataController.Inventory) :: InventoryData
			inventoryState:BuildFromInventory(updatedInventory)
			refreshAllInputs()
			if activeSlotId ~= nil then
				populateGrid()
			end
		end), true)
	end)

	fusionGui.Enabled = false
	skinsFrame.Visible = false
	refreshAllInputs()
	refreshAllInputStrokes()

	local isOpen = false

	local function openFusionGui()
		if isOpen then
			return
		end

		isOpen = true
		cameraController:apply()
		fusionGui.Enabled = true
		setMenuVisibleInstant(false)
	end

	local function closeFusionGui()
		if not isOpen then
			return
		end

		isOpen = false
		closeSkinsPanel()
		fusionGui.Enabled = false
		cameraController:restore()
		setMenuVisibleInstant(true)
	end

	janitor:Add(fusionButton.MouseButton1Click:Connect(openFusionGui), "Disconnect")

	if closeButton then
		local resetClose = MenuHover.bindButton(closeButton, janitor)
		janitor:Add(closeButton.MouseButton1Click:Connect(function()
			resetClose()
			closeFusionGui()
		end), "Disconnect")
	end

	if hideButton then
		local resetHide = MenuHover.bindButton(hideButton, janitor)
		janitor:Add(hideButton.MouseButton1Click:Connect(function()
			resetHide()
			closeSkinsPanel()
		end), "Disconnect")
	end

	janitor:Add(fusionGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if fusionGui.Enabled == false and isOpen then
			isOpen = false
			closeSkinsPanel()
			cameraController:restore()
			setMenuVisibleInstant(true)
		end
	end), "Disconnect")

	janitor:Add(function()
		if isOpen then
			cameraController:restore()
			setMenuVisibleInstant(true)
		end
	end, true)

	return janitor
end

return FusionFeature
