local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)

local WeaponsSystemFolder = script.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local SpringService = require(Libraries:WaitForChild("SpringService"))
local DirectionalIndicatorGuiManager = require(Libraries:WaitForChild("DirectionalIndicatorGuiManager"))
local DamageBillboardHandler = require(Libraries:WaitForChild("DamageBillboardHandler"))
local WeaponsSystemGuiTemplate = WeaponsSystemFolder:WaitForChild("Assets"):WaitForChild("WeaponsSystemGui")

local ACTIVE_BUTTON_COLOR = Color3.fromRGB(0, 170, 255)
local INACTIVE_BUTTON_COLOR = Color3.fromRGB(0, 0, 0)
local ACTIVE_BUTTON_TRANSPARENCY = 0
local INACTIVE_BUTTON_TRANSPARENCY = 0.5
local HOTBAR_SELECTED_SCALE = 1.25
local HOTBAR_DEFAULT_SCALE = 1

local RELOAD_PROGRESS_STYLE = {
	FlipProgress = false,
	ImageId = "3587367081",
	ImageColor = Color3.new(255, 255, 255),
	ImageTrans = 0,
	MissingPartType = "TransAndColor", -- "Color" | "Trans" | "TransAndColor"
	ColorOfPercentPart = Color3.fromRGB(255, 255, 255),
	ColorOfMissingPart = Color3.fromRGB(0, 0, 0),
	TransOfPercentPart = 0,
	TransOfMissingPart = 0.25,
}

local WeaponsGui = {}
WeaponsGui.__index = WeaponsGui
local getJumpButton

local function isHotbarImageNode(node)
	return node and (node:IsA("ImageLabel") or node:IsA("ImageButton"))
end

local function getCategoryByToolName(toolName)
	if ItemsConfig.Main[toolName] ~= nil then
		return "Main"
	end
	if ItemsConfig.Special[toolName] ~= nil then
		return "Special"
	end
	return nil
end

local function setGuiTransparencyRecursive(guiObject, alpha)
	if guiObject:IsA("ImageLabel") or guiObject:IsA("ImageButton") then
		guiObject.ImageTransparency = alpha
	end
	if guiObject:IsA("TextLabel") or guiObject:IsA("TextButton") or guiObject:IsA("TextBox") then
		guiObject.TextTransparency = alpha
		guiObject.TextStrokeTransparency = math.clamp(alpha, 0, 1)
	end
	if guiObject:IsA("Frame") or guiObject:IsA("TextLabel") or guiObject:IsA("TextButton") or guiObject:IsA("TextBox") then
		guiObject.BackgroundTransparency = alpha
	end
	if guiObject:IsA("UIStroke") then
		guiObject.Transparency = alpha
	end

	for _, child in ipairs(guiObject:GetChildren()) do
		setGuiTransparencyRecursive(child, alpha)
	end
end

function WeaponsGui:_getInactiveButtonColor()
	if self.scopeEnabled then
		return Color3.fromRGB(255, 255, 255)
	end
	return INACTIVE_BUTTON_COLOR
end

function WeaponsGui:_setButtonVisual(button, isActive)
	if not button then return end
	button.ImageColor3 = isActive and ACTIVE_BUTTON_COLOR or self:_getInactiveButtonColor()
	button.ImageTransparency = isActive and ACTIVE_BUTTON_TRANSPARENCY or INACTIVE_BUTTON_TRANSPARENCY
end

function WeaponsGui:_setFireButtonsPressed(isPressed)
	self._isFirePressed = isPressed
	self:_setButtonVisual(self.smallFireButton, isPressed)
	self:_setButtonVisual(self.largeFireButton, isPressed)
end

function WeaponsGui:_disconnectActiveFireInput()
	if self._activeFireInputConn then
		self._activeFireInputConn:Disconnect()
		self._activeFireInputConn = nil
	end
	self._activeFireInput = nil
end

function WeaponsGui:_stopTouchFire()
	local currentWeapon = self.weaponsSystem.currentWeapon
	if currentWeapon and currentWeapon.instance and currentWeapon.instance:IsA("Tool") then
		currentWeapon.instance:Deactivate()
	end
	self:_setFireButtonsPressed(false)
	self:_disconnectActiveFireInput()
end

function WeaponsGui:_setReloadButtonsPressed(isPressed)
	self._isReloadPressed = isPressed
	self:_setButtonVisual(self.smallReloadButton, isPressed)
	self:_setButtonVisual(self.largeReloadButton, isPressed)
end

function WeaponsGui:_setJumpButtonsPressed(isPressed)
	self._isJumpPressed = isPressed
	self:_setButtonVisual(self.smallJumpButton, isPressed)
	self:_setButtonVisual(self.largeJumpButton, isPressed)
end

function WeaponsGui:_updateAimButtonsVisual()
	self:_setButtonVisual(self.smallAimButton, self.isZoomed)
	self:_setButtonVisual(self.largeAimButton, self.isZoomed)
end

function WeaponsGui:_refreshTouchButtonsVisuals()
	self:_updateAimButtonsVisual()
	self:_setFireButtonsPressed(self._isFirePressed or false)
	self:_setReloadButtonsPressed(self._isReloadPressed or false)
	self:_setJumpButtonsPressed(self._isJumpPressed or false)
end

function WeaponsGui:_setJumpButtonsVisible(isVisible)
	local visible = UserInputService.TouchEnabled and isVisible
	if self.smallJumpButton then self.smallJumpButton.Visible = visible end
	if self.largeJumpButton then self.largeJumpButton.Visible = visible end
end

function WeaponsGui:_disconnectHotbarConns()
	for _, conn in ipairs(self._hotbarConns) do
		conn:Disconnect()
	end
	table.clear(self._hotbarConns)
end

function WeaponsGui:_captureHotbarSlot(hotbarRoot, itemName)
	if not hotbarRoot then
		return nil
	end

	local itemsFolder = hotbarRoot:FindFirstChild("Items")
	if not itemsFolder then
		return nil
	end

	local itemFrame = itemsFolder:FindFirstChild(itemName)
	if not itemFrame or not itemFrame:IsA("GuiObject") then
		return nil
	end

	local imageNode = itemFrame:FindFirstChild("Image")
	if not isHotbarImageNode(imageNode) then
		imageNode = itemFrame:FindFirstChildWhichIsA("ImageButton") or itemFrame:FindFirstChildWhichIsA("ImageLabel")
	end

	return {
		frame = itemFrame,
		image = imageNode,
		baseSize = itemFrame.Size,
	}
end

function WeaponsGui:_setSlotScale(slotNode, scale)
	if not slotNode or not slotNode.frame then
		return
	end

	local baseSize = slotNode.baseSize
	if not baseSize then
		return
	end

	slotNode.frame.Size = UDim2.new(
		baseSize.X.Scale * scale,
		math.floor(baseSize.X.Offset * scale + 0.5),
		baseSize.Y.Scale * scale,
		math.floor(baseSize.Y.Offset * scale + 0.5)
	)
end

function WeaponsGui:_getWeaponImageByTool(tool, category)
	if not tool then
		return ""
	end

	if category == "Main" then
		local config = ItemsConfig.Main[tool.Name]
		return if config and type(config.Image) == "string" then config.Image else ""
	end

	if category == "Special" then
		local config = ItemsConfig.Special[tool.Name]
		return if config and type(config.Image) == "string" then config.Image else ""
	end

	return ""
end

function WeaponsGui:_setSlotImage(slotNode, image)
	local imageNode = slotNode and slotNode.image
	if not isHotbarImageNode(imageNode) then
		return
	end

	imageNode.Image = image
	imageNode.ImageTransparency = if image == "" then 1 else 0
end

function WeaponsGui:_findMainSpecialTools()
	local mainTool = nil
	local specialTool = nil

	local character = LocalPlayer.Character
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	local containers = { character, backpack }

	for _, container in ipairs(containers) do
		if not container then
			continue
		end

		for _, child in ipairs(container:GetChildren()) do
			if not child:IsA("Tool") then
				continue
			end

			local category = getCategoryByToolName(child.Name)
			if category == "Main" then
				if not mainTool or (character and child:IsDescendantOf(character)) then
					mainTool = child
				end
			elseif category == "Special" then
				if not specialTool or (character and child:IsDescendantOf(character)) then
					specialTool = child
				end
			end
		end
	end

	return mainTool, specialTool
end

function WeaponsGui:_getSelectedSlotByCurrentWeapon(mainTool, specialTool)
	local currentWeapon = self.weaponsSystem.currentWeapon
	local currentTool = if currentWeapon then currentWeapon.instance else nil

	if currentTool and currentTool == specialTool then
		return 2
	end
	if currentTool and currentTool == mainTool then
		return 1
	end

	return self.hotbarSelectedSlot
end

function WeaponsGui:_applyHotbarSelectedVisual(selectedSlot)
	self.hotbarSelectedSlot = selectedSlot

	for _, layout in ipairs(self.hotbarLayouts) do
		self:_setSlotScale(layout.item1, if selectedSlot == 1 then HOTBAR_SELECTED_SCALE else HOTBAR_DEFAULT_SCALE)
		self:_setSlotScale(layout.item2, if selectedSlot == 2 then HOTBAR_SELECTED_SCALE else HOTBAR_DEFAULT_SCALE)
	end
end

function WeaponsGui:_refreshHotbar()
	local mainTool, specialTool = self:_findMainSpecialTools()
	self.hotbarMainTool = mainTool
	self.hotbarSpecialTool = specialTool

	local mainImage = self:_getWeaponImageByTool(mainTool, "Main")
	local specialImage = self:_getWeaponImageByTool(specialTool, "Special")

	for _, layout in ipairs(self.hotbarLayouts) do
		self:_setSlotImage(layout.item1, mainImage)
		self:_setSlotImage(layout.item2, specialImage)
	end

	local selectedSlot = self:_getSelectedSlotByCurrentWeapon(mainTool, specialTool)
	if selectedSlot ~= 1 and selectedSlot ~= 2 then
		selectedSlot = 1
	end

	self:_applyHotbarSelectedVisual(selectedSlot)
end

function WeaponsGui:_equipTool(tool)
	if not tool then
		return
	end

	local character = LocalPlayer.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid:EquipTool(tool)
end

function WeaponsGui:equipHotbarSlot(slot)
	local currentWeapon = self.weaponsSystem.currentWeapon
	if currentWeapon and currentWeapon.reloading and currentWeapon.cancelReload then
		currentWeapon:cancelReload()
	end

	if slot == 1 then
		self:_equipTool(self.hotbarMainTool)
		self:_applyHotbarSelectedVisual(1)
		return
	end

	if slot == 2 then
		self:_equipTool(self.hotbarSpecialTool)
		self:_applyHotbarSelectedVisual(2)
	end
end

function WeaponsGui:_registerHotbarButton(button, slot)
	if not button or not button:IsA("GuiButton") then
		return
	end

	table.insert(self._hotbarConns, button.Activated:Connect(function()
		self:equipHotbarSlot(slot)
	end))
end

function WeaponsGui:_setupHotbarLayout(hotbarRoot)
	if not hotbarRoot then
		return
	end

	local layout = {
		root = hotbarRoot,
		item1 = self:_captureHotbarSlot(hotbarRoot, "Item1"),
		item2 = self:_captureHotbarSlot(hotbarRoot, "Item2"),
	}

	table.insert(self.hotbarLayouts, layout)

	local item1Button = (layout.item1 and layout.item1.frame and layout.item1.frame:IsA("GuiButton") and layout.item1.frame)
		or (layout.item1 and layout.item1.image)
	local item2Button = (layout.item2 and layout.item2.frame and layout.item2.frame:IsA("GuiButton") and layout.item2.frame)
		or (layout.item2 and layout.item2.image)
	self:_registerHotbarButton(item1Button, 1)
	self:_registerHotbarButton(item2Button, 2)
end

function WeaponsGui:_tryJump()
	local character = LocalPlayer.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local state = humanoid:GetState()
	local isGroundState = state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed
		or state == Enum.HumanoidStateType.Climbing
		or state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Seated

	local isGroundedByMaterial = humanoid.FloorMaterial ~= Enum.Material.Air
	if isGroundState or isGroundedByMaterial then
		humanoid.Jump = true
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end

function WeaponsGui:_hideDefaultJumpButton()
	local jumpButton = getJumpButton()
	if jumpButton then
		jumpButton.Visible = false
		jumpButton.Active = false
		jumpButton.AutoButtonColor = false
		if jumpButton:IsA("ImageButton") then
			jumpButton.ImageTransparency = 1
		end
	end
end

function WeaponsGui:_trackAndHideDefaultJumpButton()
	self:_hideDefaultJumpButton()

	if self._touchGuiConn then
		self._touchGuiConn:Disconnect()
	end
	if self._playerGuiConn then
		self._playerGuiConn:Disconnect()
	end

	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local touchGui = playerGui:FindFirstChild("TouchGui")
	if touchGui then
		self._touchGuiConn = touchGui.DescendantAdded:Connect(function(descendant)
			if descendant.Name == "JumpButton" and descendant:IsA("GuiButton") then
				self:_hideDefaultJumpButton()
			end
		end)
	end

	self._playerGuiConn = playerGui.ChildAdded:Connect(function(child)
		if child.Name == "TouchGui" then
			self:_hideDefaultJumpButton()
			if self._touchGuiConn then
				self._touchGuiConn:Disconnect()
			end
			self._touchGuiConn = child.DescendantAdded:Connect(function(descendant)
				if descendant.Name == "JumpButton" and descendant:IsA("GuiButton") then
					self:_hideDefaultJumpButton()
				end
			end)
		end
	end)
end

function WeaponsGui.new(weaponsSystem)
	local self = setmetatable({}, WeaponsGui)
	self.weaponsSystem = weaponsSystem
	self.connections = {}
	self.enabled = false

	self.referenceViewportSize = Vector2.new(1000, 1000)
	self.scaleWeight = 0.75
	self.originalScaleAmounts = {}

	self.crosshairDampingRatio = 0.9
	self.crosshairFrequency = 3
	self.crosshairScaleTarget = 1
	self.crosshairScale = 1
	self.crosshairWeaponScale = 1
	self.crosshairEnabled = true

	self.scopeEnabled = false
	self.isZoomed = false
	self._uiReady = false

	self._lastWeaponInstance = nil
	self._isShotgun = false
	self._toolConns = {}
	self._kickCooldownEnd = 0
	self._activeJumpInput = nil
	self._activeFireInput = nil
	self._activeFireInputConn = nil
	self._isFirePressed = false
	self._isReloadPressed = false
	self._isJumpPressed = false
	self._hotbarConns = {}
	self.hotbarLayouts = {}
	self.hotbarMainTool = nil
	self.hotbarSpecialTool = nil
	self.hotbarSelectedSlot = 1
	self.killContainer = nil
	self.killContainerHideToken = 0
	self.killContainerDisplayTime = 0.45
	self.killContainerFadeTween = nil
	self.killContainerAlphaDriver = nil
	self.killContainerAlphaConn = nil
	self.ammoDisplayNode = nil
	self.ammoDisplayLabel = nil
	self._lastAmmoDisplayText = nil

	self.combatHUD = nil

	self.crosshairShotgunFrame = nil
	self.crosshairShotgunTopLeft = nil
	self.crosshairShotgunTopRight = nil
	self.crosshairShotgunBottomLeft = nil
	self.crosshairShotgunBottomRight = nil

	self.crosshairSpread = 0
	self.crosshairSpreadTarget = 0
	self.crosshairSpreadBase = 30
	self.crosshairSpreadAim = 20 --Tamaño de la mira cuando se enfoca
	self.crosshairSpreadFireKick = 25

	self.gui = WeaponsSystemGuiTemplate:Clone()
	self.gui.Enabled = false

	coroutine.wrap(function()
		self.scalingElementsFolder = self.gui:WaitForChild("ScalingElements")

		self.DirectionalIndicatorGuiManager = DirectionalIndicatorGuiManager.new(self)

		self.crosshairFrame = self.scalingElementsFolder:WaitForChild("Crosshair")
		self.crosshairBottom = self.crosshairFrame:WaitForChild("Bottom")
		self.crosshairLeft = self.crosshairFrame:WaitForChild("Left")
		self.crosshairRight = self.crosshairFrame:WaitForChild("Right")
		self.crosshairTop = self.crosshairFrame:WaitForChild("Top")
		self.origCrosshairScales = {}
		self.origCrosshairScales[self.crosshairBottom] = Vector2.new(self.crosshairBottom.Size.X.Scale, self.crosshairBottom.Size.Y.Scale)
		self.origCrosshairScales[self.crosshairLeft] = Vector2.new(self.crosshairLeft.Size.X.Scale, self.crosshairLeft.Size.Y.Scale)
		self.origCrosshairScales[self.crosshairRight] = Vector2.new(self.crosshairRight.Size.X.Scale, self.crosshairRight.Size.Y.Scale)
		self.origCrosshairScales[self.crosshairTop] = Vector2.new(self.crosshairTop.Size.X.Scale, self.crosshairTop.Size.Y.Scale)
		self.crosshairNormalSize = self.crosshairFrame.AbsoluteSize

		self.crosshairShotgunFrame = self.scalingElementsFolder:FindFirstChild("CrosshairShotgun")
		if self.crosshairShotgunFrame then
			self.crosshairShotgunTopLeft = self.crosshairShotgunFrame:WaitForChild("TopLeft")
			self.crosshairShotgunTopRight = self.crosshairShotgunFrame:WaitForChild("TopRight")
			self.crosshairShotgunBottomLeft = self.crosshairShotgunFrame:WaitForChild("BottomLeft")
			self.crosshairShotgunBottomRight = self.crosshairShotgunFrame:WaitForChild("BottomRight")
			self.crosshairShotgunFrame.Visible = false
		end

		self.hitMarker = self.scalingElementsFolder:WaitForChild("HitMarker"):WaitForChild("HitMarkerImage")
		self.killContainer = self.gui:FindFirstChild("KillContainer", true)
		if self.killContainer and self.killContainer:IsA("GuiObject") then
			self.killContainer.Visible = false
			self.killContainerAlphaDriver = Instance.new("NumberValue")
			self.killContainerAlphaDriver.Name = "KillContainerAlphaDriver"
			self.killContainerAlphaDriver.Value = 1
			self.killContainerAlphaDriver.Parent = self.killContainer
			self.killContainerAlphaConn = self.killContainerAlphaDriver.Changed:Connect(function(value)
				setGuiTransparencyRecursive(self.killContainer, value)
			end)
			setGuiTransparencyRecursive(self.killContainer, 1)
		end

		self.scopeFrame = self.gui:WaitForChild("Scope")
		local scopeImage = self.scopeFrame:WaitForChild("ScopeImage")

		self.ammoDisplayNode = self.gui:FindFirstChild("Ammo", true)
		if self.ammoDisplayNode and not (
			self.ammoDisplayNode:IsA("TextLabel")
			or self.ammoDisplayNode:IsA("TextButton")
			or self.ammoDisplayNode:IsA("TextBox")
		) then
			self.ammoDisplayLabel = self.ammoDisplayNode:FindFirstChildWhichIsA("TextLabel", true)
		else
			self.ammoDisplayLabel = self.ammoDisplayNode
		end

		self.smallTouchscreen = self.gui:WaitForChild("SmallTouchscreen")
		self.largeTouchscreen = self.gui:WaitForChild("LargeTouchscreen")
		self.hotbarPC = self.gui:FindFirstChild("Hotbar_PC")
		self.hotbarTouchscreen = self.gui:FindFirstChild("Hotbar_TouchScreen")

		self.smallAimButton = self.smallTouchscreen:WaitForChild("AimButton")
		self.smallAimButton.Activated:Connect(function() self:onTouchAimButtonActivated() end)
		self.largeAimButton = self.largeTouchscreen:WaitForChild("AimButton")
		self.largeAimButton.Activated:Connect(function() self:onTouchAimButtonActivated() end)

		self.smallFireButton = self.smallTouchscreen:WaitForChild("FireButton")
		self.smallFireButton.InputBegan:Connect(function(inputObj) self:onTouchFireButton(inputObj, Enum.UserInputState.Begin) end)
		self.smallFireButton.InputEnded:Connect(function(inputObj) self:onTouchFireButton(inputObj, Enum.UserInputState.End) end)
		self.largeFireButton = self.largeTouchscreen:WaitForChild("FireButton")
		self.largeFireButton.InputBegan:Connect(function(inputObj) self:onTouchFireButton(inputObj, Enum.UserInputState.Begin) end)
		self.largeFireButton.InputEnded:Connect(function(inputObj) self:onTouchFireButton(inputObj, Enum.UserInputState.End) end)

		self.smallReloadButton = self.smallTouchscreen:WaitForChild("ReloadButton")
		self.smallReloadButton.InputBegan:Connect(function(inputObj) self:onTouchReloadButton(inputObj, Enum.UserInputState.Begin) end)
		self.smallReloadButton.InputEnded:Connect(function(inputObj) self:onTouchReloadButton(inputObj, Enum.UserInputState.End) end)
		self.largeReloadButton = self.largeTouchscreen:WaitForChild("ReloadButton")
		self.largeReloadButton.InputBegan:Connect(function(inputObj) self:onTouchReloadButton(inputObj, Enum.UserInputState.Begin) end)
		self.largeReloadButton.InputEnded:Connect(function(inputObj) self:onTouchReloadButton(inputObj, Enum.UserInputState.End) end)

		self.smallJumpButton = self.smallTouchscreen:FindFirstChild("JumpButton")
		if self.smallJumpButton then
			self.smallJumpButton.Active = true
			self.smallJumpButton.Activated:Connect(function() self:_tryJump() end)
			self.smallJumpButton.InputBegan:Connect(function(inputObj) self:onTouchJumpButton(inputObj, Enum.UserInputState.Begin) end)
			self.smallJumpButton.InputEnded:Connect(function(inputObj) self:onTouchJumpButton(inputObj, Enum.UserInputState.End) end)
		end
		self.largeJumpButton = self.largeTouchscreen:FindFirstChild("JumpButton")
		if self.largeJumpButton then
			self.largeJumpButton.Active = true
			self.largeJumpButton.Activated:Connect(function() self:_tryJump() end)
			self.largeJumpButton.InputBegan:Connect(function(inputObj) self:onTouchJumpButton(inputObj, Enum.UserInputState.Begin) end)
			self.largeJumpButton.InputEnded:Connect(function(inputObj) self:onTouchJumpButton(inputObj, Enum.UserInputState.End) end)
		end

		self.smallFireButton.Visible = UserInputService.TouchEnabled
		self.largeFireButton.Visible = UserInputService.TouchEnabled
		self.smallReloadButton.Visible = UserInputService.TouchEnabled
		self.largeReloadButton.Visible = UserInputService.TouchEnabled
		self:_setJumpButtonsVisible(true)
		self:_trackAndHideDefaultJumpButton()

		self:_refreshTouchButtonsVisuals()
		self:_disconnectHotbarConns()
		table.clear(self.hotbarLayouts)
		self:_setupHotbarLayout(self.hotbarPC)
		self:_setupHotbarLayout(self.hotbarTouchscreen)
		self:_refreshHotbar()

		self.gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
		self.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() self:onScreenSizeChanged() end)
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() self:onScreenSizeChanged() end)
		self.gui:GetPropertyChangedSignal("Enabled"):Connect(function()
			if self.gui.Enabled then
				self:onScreenSizeChanged()
			end
		end)
		self:onScreenSizeChanged()

		-- Reload progress is rendered directly from WeaponsSystemGui Progress frame.

		WeaponData.OnClientEvent:Connect(function(cmd, otherPlayerPosition)
			if cmd == "HitByOtherPlayer" then
				self.DirectionalIndicatorGuiManager:ActivateDirectionalIndicator("DamageIndicator", otherPlayerPosition)
			end
		end)

		local preloadTargets = {
			self.crosshairBottom,
			self.crosshairLeft,
			self.crosshairRight,
			self.crosshairTop,
			scopeImage,
			self.smallAimButton,
			self.largeAimButton,
			self.smallFireButton,
			self.largeFireButton,
			self.smallReloadButton,
			self.largeReloadButton,
		}
		for _, layout in ipairs(self.hotbarLayouts) do
			if layout.item1 and layout.item1.image then
				table.insert(preloadTargets, layout.item1.image)
			end
			if layout.item2 and layout.item2.image then
				table.insert(preloadTargets, layout.item2.image)
			end
		end
		if self.killContainer then
			table.insert(preloadTargets, self.killContainer)
		end
		ContentProvider:PreloadAsync(preloadTargets)
	end)()

	return self
end

getJumpButton = function()
	if UserInputService.TouchEnabled then
		local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
		if not playerGui then return nil end
		local touchGui = playerGui:FindFirstChild("TouchGui")
		if not touchGui then return nil end
		local touchControlFrame = touchGui:FindFirstChild("TouchControlFrame")
		if not touchControlFrame then return nil end
		return touchControlFrame:FindFirstChild("JumpButton")
	end
	return nil
end

function WeaponsGui:onScreenSizeChanged()
	if not self.scalingElementsFolder or not self.crosshairFrame then
		self._uiReady = false
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		self._uiReady = false
		return
	end

	local viewportSize = camera.ViewportSize
	if viewportSize.X <= 0 or viewportSize.Y <= 0 then
		self._uiReady = false
		return
	end

	if self.smallTouchscreen and self.largeTouchscreen then
		if UserInputService.TouchEnabled then
			local isSmallScreen
			local jumpButton = getJumpButton()
			if jumpButton then
				isSmallScreen = jumpButton.Size.X.Offset <= 70
			else
				isSmallScreen = self.gui.AbsoluteSize.Y < 600
			end
			self.smallTouchscreen.Visible = isSmallScreen
			self.largeTouchscreen.Visible = not isSmallScreen
		else
			self.smallTouchscreen.Visible = false
			self.largeTouchscreen.Visible = false
		end
	end

	if self.hotbarPC then
		self.hotbarPC.Visible = not UserInputService.TouchEnabled
	end
	if self.hotbarTouchscreen then
		self.hotbarTouchscreen.Visible = UserInputService.TouchEnabled
	end

	self:_refreshHotbar()

	for _, child in pairs(self.scalingElementsFolder:GetChildren()) do
		self:updateScale(child, viewportSize)
	end

	local crosshairAbsoluteSize = self.crosshairFrame.AbsoluteSize
	if crosshairAbsoluteSize.X <= 0 or crosshairAbsoluteSize.Y <= 0 then
		self._uiReady = false
		return
	end

	self.crosshairNormalSize = crosshairAbsoluteSize
	self.crosshairBottom.Size = UDim2.new(0, self.origCrosshairScales[self.crosshairBottom].X * self.crosshairNormalSize.X, 0, self.origCrosshairScales[self.crosshairBottom].Y * self.crosshairNormalSize.Y)
	self.crosshairLeft.Size = UDim2.new(0, self.origCrosshairScales[self.crosshairLeft].X * self.crosshairNormalSize.X, 0, self.origCrosshairScales[self.crosshairLeft].Y * self.crosshairNormalSize.Y)
	self.crosshairRight.Size = UDim2.new(0, self.origCrosshairScales[self.crosshairRight].X * self.crosshairNormalSize.X, 0, self.origCrosshairScales[self.crosshairRight].Y * self.crosshairNormalSize.Y)
	self.crosshairTop.Size = UDim2.new(0, self.origCrosshairScales[self.crosshairTop].X * self.crosshairNormalSize.X, 0, self.origCrosshairScales[self.crosshairTop].Y * self.crosshairNormalSize.Y)
	if self.crosshairShotgunFrame then
		self:_layoutShotgunCrosshairCorners()
	end

	self._uiReady = true
end

function WeaponsGui:getWeightedScaleAmount(originalScaleAmount, newScreenDim, referenceScreenDim)
	return (1 - self.scaleWeight) * originalScaleAmount * referenceScreenDim / newScreenDim + self.scaleWeight * originalScaleAmount
end

function WeaponsGui:updateScale(guiObject, viewportSize)
	if guiObject:IsA("GuiObject") then
		local xScale = guiObject.Size.X.Scale
		local yScale = guiObject.Size.Y.Scale
		if xScale ~= 0 or yScale ~= 0 or self.originalScaleAmounts[guiObject] ~= nil then
			if self.originalScaleAmounts[guiObject] == nil then
				self.originalScaleAmounts[guiObject] = Vector2.new(xScale, yScale)
			end
			xScale = self:getWeightedScaleAmount(self.originalScaleAmounts[guiObject].X, viewportSize.X, self.referenceViewportSize.X)
			yScale = self:getWeightedScaleAmount(self.originalScaleAmounts[guiObject].Y, viewportSize.Y, self.referenceViewportSize.Y)
			guiObject.Size = UDim2.new(xScale, 0, yScale, 0)
		end
		return
	end
	for _, child in ipairs(guiObject:GetChildren()) do
		self:updateScale(child, viewportSize)
	end
end

function WeaponsGui:setEnabled(enabled)
	if self.enabled == enabled then return end
	self.enabled = enabled
	if self.enabled then
		if self.gui then
			self.gui.Enabled = true
		end
		task.defer(function()
			self:onScreenSizeChanged()
		end)
		task.delay(0.1, function()
			self:onScreenSizeChanged()
		end)

		self.connections.renderStepped = RunService.RenderStepped:Connect(function(dt) self:onRenderStepped(dt) end)
		self.connections.inputBegan = UserInputService.InputBegan:Connect(function(input,gp)
			if not gp then
				if input.KeyCode == Enum.KeyCode.One then
					self:equipHotbarSlot(1)
					return
				elseif input.KeyCode == Enum.KeyCode.Two then
					self:equipHotbarSlot(2)
					return
				end
			end

			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				self:setZoomed(true)
			elseif not gp and input.UserInputType == Enum.UserInputType.MouseButton1 then
				if self._isShotgun then self:_kickShotgunSpread() end
			end
		end)
		self.connections.inputEnded = UserInputService.InputEnded:Connect(function(input,gp)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				self:setZoomed(false)
			end
		end)
	else
		self:setZoomed(false)
		self:hideKillContainer(true)
		self:_stopReloadProgressAnimation(true)
		self:_stopTouchFire()
		self:_setReloadButtonsPressed(false)
		self:_setJumpButtonsPressed(false)
		self._lastAmmoDisplayText = nil
		self:_updateAmmoDisplay()

		-- Cleanup CombatHUD
		if self.combatHUD then
			self.combatHUD:hide()
		end

		for _, v in pairs(self.connections) do
			v:Disconnect()
		end
		self.connections = {}
		for _,c in pairs(self._toolConns) do
			c:Disconnect()
		end
		self._toolConns = {}
	end
	if self.gui then
		self.gui.Enabled = self.enabled
	end
end

function WeaponsGui:hideKillContainer(immediate)
	if not self.killContainer then return end
	self.killContainerHideToken += 1
	if self.killContainerFadeTween then
		self.killContainerFadeTween:Cancel()
		self.killContainerFadeTween = nil
	end

	if immediate then
		if self.killContainerAlphaDriver then
			self.killContainerAlphaDriver.Value = 1
		else
			setGuiTransparencyRecursive(self.killContainer, 1)
		end
		self.killContainer.Visible = false
		return
	end

	local hideToken = self.killContainerHideToken
	local alphaDriver = self.killContainerAlphaDriver
	if alphaDriver then
		self.killContainerFadeTween = TweenService:Create(alphaDriver, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 1 })
		self.killContainerFadeTween:Play()
		self.killContainerFadeTween.Completed:Once(function()
			if self.killContainerHideToken ~= hideToken or not self.killContainer then
				return
			end
			self.killContainer.Visible = false
			self.killContainerFadeTween = nil
		end)
	else
		setGuiTransparencyRecursive(self.killContainer, 1)
		self.killContainer.Visible = false
	end
end

function WeaponsGui:showKillContainer()
	if not self.killContainer or not self.enabled then return end

	self.killContainerHideToken += 1
	local hideToken = self.killContainerHideToken
	if self.killContainerFadeTween then
		self.killContainerFadeTween:Cancel()
		self.killContainerFadeTween = nil
	end

	self.killContainer.Visible = true
	if self.killContainerAlphaDriver then
		self.killContainerAlphaDriver.Value = 1
		self.killContainerFadeTween = TweenService:Create(self.killContainerAlphaDriver, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 0 })
		self.killContainerFadeTween:Play()
	else
		setGuiTransparencyRecursive(self.killContainer, 0)
	end

	task.delay(self.killContainerDisplayTime, function()
		if self.killContainerHideToken ~= hideToken then
			return
		end
		self:hideKillContainer(false)
	end)
end

function WeaponsGui:setCrosshairEnabled(crosshairEnabled)
	self.crosshairEnabled = crosshairEnabled
	self:_refreshCrosshairVisibility()
	if self.hitMarker then
		self.hitMarker.ImageTransparency = 1
		self.hitMarker.Visible = self.crosshairEnabled
	end
end

function WeaponsGui:_refreshCrosshairVisibility()
	local shouldShow = self.crosshairEnabled and not self._isReloadProgressAnimating

	if self.crosshairFrame then
		self.crosshairFrame.Visible = shouldShow and not self._isShotgun
	end
	if self.crosshairShotgunFrame then
		self.crosshairShotgunFrame.Visible = shouldShow and self._isShotgun
	end
end

function WeaponsGui:setScopeEnabled(scopeEnabled)
	self.scopeEnabled = scopeEnabled
	if self.scopeFrame then
		self.scopeFrame.Visible = self.scopeEnabled
	end
	self:_refreshTouchButtonsVisuals()
	self:_hideDefaultJumpButton()
	if self.smallFireButton then self.smallFireButton.Visible = UserInputService.TouchEnabled end
	if self.largeFireButton then self.largeFireButton.Visible = UserInputService.TouchEnabled end
	if self.smallReloadButton then self.smallReloadButton.Visible = UserInputService.TouchEnabled end
	if self.largeReloadButton then self.largeReloadButton.Visible = UserInputService.TouchEnabled end
	self:_setJumpButtonsVisible(true)
end

function WeaponsGui:setCrosshairWeaponScale(scale)
	if self.crosshairWeaponScale == scale then return end
	self.crosshairWeaponScale = scale
end

function WeaponsGui:setCrosshairScaleTarget(target, dampingRatio, frequency)
	if typeof(dampingRatio) == "number" then
		self.crosshairDampingRatio = dampingRatio
	end
	if typeof(frequency) == "number" then
		self.crosshairFrequency = frequency
	end
	if self.crosshairScaleTarget == target then return end
	self.crosshairScaleTarget = target
	SpringService:Target(self, self.crosshairDampingRatio, self.crosshairFrequency, { crosshairScale = self.crosshairScaleTarget })
end

function WeaponsGui:setCrosshairScale(scale)
	if self.crosshairScale == scale then return end
	self.crosshairScale = scale
	SpringService:Target(self, self.crosshairDampingRatio, self.crosshairFrequency, { crosshairScale = self.crosshairScaleTarget })
end

function WeaponsGui:_disconnectToolConns()
	for _,c in pairs(self._toolConns) do
		c:Disconnect()
	end
	table.clear(self._toolConns)
end

function WeaponsGui:_connectToolConns(tool)
	self:_disconnectToolConns()
	if not tool then return end
	if tool:IsA("Tool") then
		tool.ManualActivationOnly = UserInputService.TouchEnabled
	end
	table.insert(self._toolConns, tool.Activated:Connect(function()
		if self._isShotgun then self:_kickShotgunSpread() end
	end))
	if tool:IsA("Tool") then
		table.insert(self._toolConns, tool.AncestryChanged:Connect(function(_, parent)
			if not parent then self:_disconnectToolConns() end
		end))
	end
end

function WeaponsGui:_setCrosshairVariant(isShotgun)
	self._isShotgun = isShotgun and true or false
	self:_refreshCrosshairVisibility()
	if self._isShotgun then
		self.crosshairWeaponScale = 1
		self.crosshairSpreadTarget = self.isZoomed and self.crosshairSpreadAim or self.crosshairSpreadBase
	else
		self.crosshairSpreadTarget = 0
	end
	SpringService:Target(self, self.crosshairDampingRatio, self.crosshairFrequency, { crosshairSpread = self.crosshairSpreadTarget })
end

function WeaponsGui:_applyCrosshairByWeapon()
	local w = self.weaponsSystem.currentWeapon
	local tool = w and w.instance
	if tool == self._lastWeaponInstance then return end
	self._lastWeaponInstance = tool
	local isShotgun = tool and tool:GetAttribute("Shotgun") == true
	self:_setCrosshairVariant(isShotgun)
	self:_connectToolConns(tool)
end

function WeaponsGui:_layoutShotgunCrosshairCorners()
	if not (self.crosshairShotgunFrame and self._isShotgun) then return end
	local s = self.crosshairSpread
	local size = math.floor(self.crosshairNormalSize.Y * 0.45)
	local ox = s
	local oy = s
	self.crosshairShotgunTopLeft.AnchorPoint = Vector2.new(0.5,0.5)
	self.crosshairShotgunTopLeft.Position = UDim2.new(0.5,-ox,0.5,-oy)
	self.crosshairShotgunTopLeft.Size = UDim2.new(0, size, 0, size)
	self.crosshairShotgunTopRight.AnchorPoint = Vector2.new(0.5,0.5)
	self.crosshairShotgunTopRight.Position = UDim2.new(0.5,ox,0.5,-oy)
	self.crosshairShotgunTopRight.Size = UDim2.new(0, size, 0, size)
	self.crosshairShotgunBottomLeft.AnchorPoint = Vector2.new(0.5,0.5)
	self.crosshairShotgunBottomLeft.Position = UDim2.new(0.5,-ox,0.5,oy)
	self.crosshairShotgunBottomLeft.Size = UDim2.new(0, size, 0, size)
	self.crosshairShotgunBottomRight.AnchorPoint = Vector2.new(0.5,0.5)
	self.crosshairShotgunBottomRight.Position = UDim2.new(0.5,ox,0.5,oy)
	self.crosshairShotgunBottomRight.Size = UDim2.new(0, size, 0, size)
end

function WeaponsGui:_kickShotgunSpread()
	if not self._isShotgun then return end
	local kick = self.crosshairSpreadBase + self.crosshairSpreadFireKick
	self.crosshairSpreadTarget = kick
	SpringService:Target(self, 0.6, 5, { crosshairSpread = self.crosshairSpreadTarget })
	self._kickCooldownEnd = os.clock() + 0.12
	task.delay(0.06, function()
		self.crosshairSpreadTarget = self.isZoomed and self.crosshairSpreadAim or self.crosshairSpreadBase
		SpringService:Target(self, 0.85, 4, { crosshairSpread = self.crosshairSpreadTarget })
	end)
end

function WeaponsGui:OnHitOtherPlayer(damage, humanoidHit)
	if self.currentHitTween then self.currentHitTween:Cancel() end
	if self.currentFadeTween then self.currentFadeTween:Cancel() end
	self.hitMarker.AnchorPoint = Vector2.new(0.5, 0.5)
	self.hitMarker.Position = UDim2.new(0.5, 0, 0.5, 0)
	self.hitMarker.ImageTransparency = 0
	self.hitMarker.Size = UDim2.new(0.03, 0, 0, 0)
	self.hitMarker.ImageColor3 = Color3.new(1, 0.3, 0.3)
	self.hitMarker.Rotation = 0
	local minSize = 30
	local initialSize = math.max(self.hitMarker.AbsoluteSize.X, minSize)
	self.hitMarker.Size = UDim2.new(0, initialSize, 0, initialSize)
	local hitTweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
	local maxSize = math.max(self.hitMarker.AbsoluteSize.X * 2, minSize * 2)
	local hitGoal = { Size = UDim2.new(0, maxSize, 0, maxSize), ImageColor3 = Color3.new(1, 0, 0), Rotation = math.random(-15, 15) }
	self.currentHitTween = TweenService:Create(self.hitMarker, hitTweenInfo, hitGoal)
	self.currentHitTween:Play()
	local fadeTweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, 0.15)
	local midSize = math.max(maxSize * 0.75, minSize * 1.5)
	local fadeGoal = { Size = UDim2.new(0, midSize, 0, midSize), ImageTransparency = 1, ImageColor3 = Color3.new(1, 1, 0.7), Rotation = 0 }
	self.currentFadeTween = TweenService:Create(self.hitMarker, fadeTweenInfo, fadeGoal)
	self.currentFadeTween:Play()
	DamageBillboardHandler:ShowDamageBillboard(damage, humanoidHit.Parent:FindFirstChild("Head"))
end

function WeaponsGui:onRenderStepped(dt)
	if not self._uiReady then
		self:onScreenSizeChanged()
		return
	end
	if not self.enabled or not self.gui then return end
	self:_hideDefaultJumpButton()
	self:_applyCrosshairByWeapon()
	self:_refreshHotbar()
	self:_updateAmmoDisplay()
	if self._isShotgun then
		if os.clock() >= (self._kickCooldownEnd or 0) then
			local want = self.isZoomed and self.crosshairSpreadAim or self.crosshairSpreadBase
			if math.abs(self.crosshairSpreadTarget - want) > 0.1 then
				self.crosshairSpreadTarget = want
				SpringService:Target(self, self.crosshairDampingRatio, self.crosshairFrequency, { crosshairSpread = want })
			end
		end
		if self.crosshairShotgunFrame and self.crosshairEnabled then
			self:_layoutShotgunCrosshairCorners()
		end
	else
		if self.crosshairFrame and self.crosshairEnabled then
			local crosshairSize = self.crosshairNormalSize * self.crosshairScale * self.crosshairWeaponScale
			self.crosshairFrame.Size = UDim2.new(0, crosshairSize.X, 0, crosshairSize.Y)
		end
	end
end

function WeaponsGui:_updateAmmoDisplay()
	local weapon = self.weaponsSystem.currentWeapon
	local ammoText = ""

	if weapon and weapon.instance then
		local currentAmmo = weapon.instance:GetAttribute("CurrentAmmo")
		if type(currentAmmo) == "number" then
			ammoText = tostring(math.max(0, math.floor(currentAmmo + 0.5)))
		end
	end

	if self._lastAmmoDisplayText == ammoText then
		return
	end
	self._lastAmmoDisplayText = ammoText

	local textNode = self.ammoDisplayLabel
	if textNode and (
		textNode:IsA("TextLabel")
		or textNode:IsA("TextButton")
		or textNode:IsA("TextBox")
	) then
		textNode.Text = ammoText
		return
	end

	if self.ammoDisplayNode and self.ammoDisplayNode:IsA("StringValue") then
		self.ammoDisplayNode.Value = ammoText
	elseif self.ammoDisplayNode and self.ammoDisplayNode:IsA("IntValue") then
		self.ammoDisplayNode.Value = tonumber(ammoText) or 0
	elseif self.ammoDisplayNode and self.ammoDisplayNode:IsA("NumberValue") then
		self.ammoDisplayNode.Value = tonumber(ammoText) or 0
	end
end

function WeaponsGui:setZoomed(zoomed)
	if zoomed == self.isZoomed then return end
	self.isZoomed = zoomed
	self:_updateAimButtonsVisual()
	if self.weaponsSystem.camera then
		self.weaponsSystem.camera:setForceZoomed(self.isZoomed)
	end
	if self._isShotgun then
		self.crosshairSpreadTarget = self.isZoomed and self.crosshairSpreadAim or self.crosshairSpreadBase
		SpringService:Target(self, self.crosshairDampingRatio, self.crosshairFrequency, { crosshairSpread = self.crosshairSpreadTarget })
	end
end

function WeaponsGui:onTouchAimButtonActivated()
	self:setZoomed(not self.isZoomed)
end

function WeaponsGui:onTouchFireButton(inputObj, inputState)
	if inputObj and self._activeJumpInput and inputObj == self._activeJumpInput then
		return
	end
	if inputState == Enum.UserInputState.Begin then
		if self._activeFireInput and self._activeFireInput ~= inputObj then
			return
		end
		local currentWeapon = self.weaponsSystem.currentWeapon
		if self._isShotgun then self:_kickShotgunSpread() end
		if currentWeapon and currentWeapon.instance and currentWeapon.instance:IsA("Tool") then
			currentWeapon.instance:Activate()
		end
		self:_disconnectActiveFireInput()
		self._activeFireInput = inputObj
		self._activeFireInputConn = inputObj:GetPropertyChangedSignal("UserInputState"):Connect(function()
			if inputObj.UserInputState == Enum.UserInputState.End or inputObj.UserInputState == Enum.UserInputState.Cancel then
				self:_stopTouchFire()
			end
		end)
		self:_setFireButtonsPressed(true)
	elseif inputState == Enum.UserInputState.End and inputObj and inputObj.UserInputState == Enum.UserInputState.End then
		self:_stopTouchFire()
	end
end

function WeaponsGui:onTouchReloadButton(inputObj, inputState)
	if inputState == Enum.UserInputState.Begin then
		self:_setReloadButtonsPressed(true)
		local currentWeapon = self.weaponsSystem.currentWeapon
		if currentWeapon and currentWeapon.instance and currentWeapon.instance:IsA("Tool") then
			if currentWeapon.onReloadAction then
				currentWeapon:onReloadAction("Reload", Enum.UserInputState.Begin, nil)
			end
		end
	elseif inputState == Enum.UserInputState.End then
		self:_setReloadButtonsPressed(false)
	end
end

function WeaponsGui:onTouchJumpButton(inputObj, inputState)
	if inputState == Enum.UserInputState.Begin then
		self._activeJumpInput = inputObj
		self:_setJumpButtonsPressed(true)
		self:_tryJump()
	elseif inputState == Enum.UserInputState.End then
		if inputObj and self._activeJumpInput == inputObj then
			self._activeJumpInput = nil
		end
		self:_setJumpButtonsPressed(false)
	end
end

function WeaponsGui:onWeaponEquipped(weapon)
	self:_stopReloadProgressAnimation(true)
	self:_refreshHotbar()
	return
end

function WeaponsGui:onWeaponUnequipped()
	self:_stopReloadProgressAnimation(true)
	self:_refreshHotbar()
	return
end

function WeaponsGui:onWeaponReloadStarted(weapon, reloadTime)
	self:playReloadProgressAnimation(reloadTime)
end

function WeaponsGui:stopReloadProgressAnimation()
	self:_stopReloadProgressAnimation(true)
end

function WeaponsGui:_getReloadProgressFrame()
	if self.scalingElementsFolder then
		local fromScaling = self.scalingElementsFolder:FindFirstChild("Progress")
		if fromScaling then
			return fromScaling
		end
	end

	return self.gui:FindFirstChild("Progress")
end

function WeaponsGui:_setReloadProgressVisible(isVisible)
	local progressFrame = self:_getReloadProgressFrame()
	if progressFrame and progressFrame:IsA("GuiObject") then
		progressFrame.Visible = isVisible
	end
end

function WeaponsGui:_stopReloadProgressAnimation(hideProgress)
	self._reloadProgressRunId = (self._reloadProgressRunId or 0) + 1

	if self._reloadProgressTween then
		self._reloadProgressTween:Cancel()
		self._reloadProgressTween = nil
	end

	if self._reloadProgressConnection then
		self._reloadProgressConnection:Disconnect()
		self._reloadProgressConnection = nil
	end

	self._isReloadProgressAnimating = false
	self:_refreshCrosshairVisibility()

	if hideProgress ~= false then
		self:_setReloadProgressVisible(false)
	end
end

function WeaponsGui:playReloadProgressAnimation(reloadTime)
	self._isReloadProgressAnimating = true
	self:_refreshCrosshairVisibility()
	self:_setReloadProgressVisible(true)

	self._reloadProgressRunId = (self._reloadProgressRunId or 0) + 1
	local runId = self._reloadProgressRunId

	local progressFrame = self:_getReloadProgressFrame()
	if not progressFrame then
		warn("[WeaponsGui] Progress frame not found for reload animation.")
		self._isReloadProgressAnimating = false
		self:_refreshCrosshairVisibility()
		return
	end

	local progressValue = progressFrame:FindFirstChild("ProgressValue")
	if not progressValue then
		progressValue = Instance.new("NumberValue")
		progressValue.Name = "ProgressValue"
		progressValue.Value = 0
		progressValue.Parent = progressFrame
	end

	if self._reloadProgressTween or self._reloadProgressConnection then
		self:_stopReloadProgressAnimation(false)
	end

	progressValue.Value = 0
	self:_updateReloadProgressBar(0)

	local tweenInfo = TweenInfo.new(math.max(0.01, tonumber(reloadTime) or 0.01), Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
	self._reloadProgressTween = TweenService:Create(progressValue, tweenInfo, { Value = 100 })

	self._reloadProgressConnection = progressValue.Changed:Connect(function(value)
		if runId ~= self._reloadProgressRunId then
			return
		end
		self:_updateReloadProgressBar(value)
	end)

	self._reloadProgressTween:Play()

	local activeTween = self._reloadProgressTween
	activeTween.Completed:Connect(function()
		if runId ~= self._reloadProgressRunId then
			return
		end

		if self._reloadProgressConnection then
			self._reloadProgressConnection:Disconnect()
			self._reloadProgressConnection = nil
		end
		self._reloadProgressTween = nil
		self._isReloadProgressAnimating = false
		self:_refreshCrosshairVisibility()
		self:_updateReloadProgressBar(0)
		self:_setReloadProgressVisible(false)
		progressValue.Value = 0
	end)
end

function WeaponsGui:_updateReloadProgressBar(progressPercent)
	local progressFrame = self:_getReloadProgressFrame()
	if not progressFrame then
		return
	end

	local frame1 = progressFrame:FindFirstChild("Frame1")
	local frame2 = progressFrame:FindFirstChild("Frame2")
	if not frame1 or not frame2 then
		return
	end

	local frame1ImageLabel = frame1:FindFirstChildOfClass("ImageLabel") or frame1
	local frame2ImageLabel = frame2:FindFirstChildOfClass("ImageLabel") or frame2
	if not frame1ImageLabel:IsA("ImageLabel") and not frame1ImageLabel:IsA("ImageButton") then
		return
	end
	if not frame2ImageLabel:IsA("ImageLabel") and not frame2ImageLabel:IsA("ImageButton") then
		return
	end

	local g1 = frame1ImageLabel:FindFirstChildOfClass("UIGradient")
	local g2 = frame2ImageLabel:FindFirstChildOfClass("UIGradient")
	if not g1 or not g2 then
		return
	end

	local style = RELOAD_PROGRESS_STYLE
	local percentNumber = math.clamp(progressPercent * 3.6, 0, 360)

	g1.Rotation = (style.FlipProgress == false)
		and math.clamp(percentNumber, 180, 360)
		or 180 - math.clamp(percentNumber, 0, 180)
	g2.Rotation = (style.FlipProgress == false)
		and math.clamp(percentNumber, 0, 180)
		or 180 - math.clamp(percentNumber, 180, 360)

	frame1ImageLabel.ImageColor3 = style.ImageColor
	frame2ImageLabel.ImageColor3 = style.ImageColor
	frame1ImageLabel.ImageTransparency = style.ImageTrans
	frame2ImageLabel.ImageTransparency = style.ImageTrans
	frame1ImageLabel.Image = "rbxassetid://" .. style.ImageId
	frame2ImageLabel.Image = "rbxassetid://" .. style.ImageId

	if style.MissingPartType == "Color" then
		g1.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, style.ColorOfPercentPart),
			ColorSequenceKeypoint.new(0.5, style.ColorOfPercentPart),
			ColorSequenceKeypoint.new(0.501, style.ColorOfMissingPart),
			ColorSequenceKeypoint.new(1, style.ColorOfMissingPart),
		})
		g2.Color = g1.Color
		g1.Transparency = NumberSequence.new(0)
		g2.Transparency = NumberSequence.new(0)
	elseif style.MissingPartType == "Trans" then
		local transSeq = NumberSequence.new({
			NumberSequenceKeypoint.new(0, style.TransOfPercentPart),
			NumberSequenceKeypoint.new(0.5, style.TransOfPercentPart),
			NumberSequenceKeypoint.new(0.501, style.TransOfMissingPart),
			NumberSequenceKeypoint.new(1, style.TransOfMissingPart),
		})
		g1.Transparency = transSeq
		g2.Transparency = transSeq
		g1.Color = ColorSequence.new(Color3.new(1, 1, 1))
		g2.Color = ColorSequence.new(Color3.new(1, 1, 1))
	elseif style.MissingPartType == "TransAndColor" then
		local transSeq = NumberSequence.new({
			NumberSequenceKeypoint.new(0, style.TransOfPercentPart),
			NumberSequenceKeypoint.new(0.5, style.TransOfPercentPart),
			NumberSequenceKeypoint.new(0.501, style.TransOfMissingPart),
			NumberSequenceKeypoint.new(1, style.TransOfMissingPart),
		})
		local colorSeq = ColorSequence.new({
			ColorSequenceKeypoint.new(0, style.ColorOfPercentPart),
			ColorSequenceKeypoint.new(0.5, style.ColorOfPercentPart),
			ColorSequenceKeypoint.new(0.501, style.ColorOfMissingPart),
			ColorSequenceKeypoint.new(1, style.ColorOfMissingPart),
		})
		g1.Transparency = transSeq
		g2.Transparency = transSeq
		g1.Color = colorSeq
		g2.Color = colorSeq
	else
		warn("Unknown MissingPartType. Only Trans, Color, TransAndColor are allowed. Falling back to Trans.")
		local fallbackSeq = NumberSequence.new({
			NumberSequenceKeypoint.new(0, style.TransOfPercentPart),
			NumberSequenceKeypoint.new(0.5, style.TransOfPercentPart),
			NumberSequenceKeypoint.new(0.501, style.TransOfMissingPart),
			NumberSequenceKeypoint.new(1, style.TransOfMissingPart),
		})
		g1.Transparency = fallbackSeq
		g2.Transparency = fallbackSeq
		g1.Color = ColorSequence.new(Color3.new(1, 1, 1))
		g2.Color = ColorSequence.new(Color3.new(1, 1, 1))
	end
end

return WeaponsGui
