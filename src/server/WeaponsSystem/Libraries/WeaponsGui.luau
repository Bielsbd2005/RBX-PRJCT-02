local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HapticService = game:GetService("HapticService")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local TeamUtils = require(Shared:WaitForChild("utils"):WaitForChild("TeamUtils"))

local WeaponsSystemFolder = script.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local SpringService = require(Libraries:WaitForChild("SpringService"))
local DirectionalIndicatorGuiManager = require(Libraries:WaitForChild("DirectionalIndicatorGuiManager"))
local DamageBillboardHandler = require(Libraries:WaitForChild("DamageBillboardHandler"))
local AutoAimSystem = require(Libraries:WaitForChild("AutoAimSystem"))
local WeaponsSystemGuiTemplate = WeaponsSystemFolder:WaitForChild("Assets"):WaitForChild("WeaponsSystemGui")

local ACTIVE_BUTTON_COLOR = Color3.fromRGB(0, 170, 255)
local INACTIVE_BUTTON_COLOR = Color3.fromRGB(0, 0, 0)
local ACTIVE_BUTTON_TRANSPARENCY = 0
local INACTIVE_BUTTON_TRANSPARENCY = 0.5
local HOTBAR_SELECTED_SCALE = 1.25
local HOTBAR_DEFAULT_SCALE = 1
local HOTBAR_AMMO_CURRENT_COLOR = "#FFFFFF"
local HOTBAR_AMMO_TOTAL_COLOR = "#8FD6FF"
local HIT_HIGHLIGHT_NAME = "WSLocalHitHighlight"
local HIT_HIGHLIGHT_OUTLINE_COLOR = Color3.fromRGB(255, 64, 64)
local HIT_HIGHLIGHT_TO_OUTLINE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIT_HIGHLIGHT_FADE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local VIGNETTE_KILL_COLOR = Color3.fromRGB(0, 172, 237)
local VIGNETTE_HEALTH_COLOR = Color3.fromRGB(255, 0, 0)
-- W7: constantes módulo para hit marker. Antes Color3.new(...) y Vector2.new(...)
-- por hit (en OnHitOtherPlayer) y por frame (en _layoutShotgunCrosshairCorners).
local CENTER_ANCHOR_V2 = Vector2.new(0.5, 0.5)
local HIT_MARKER_CENTER_POS = UDim2.new(0.5, 0, 0.5, 0)
local HIT_COLOR_INITIAL = Color3.new(1, 0.3, 0.3)
local HIT_COLOR_PEAK = Color3.new(1, 0, 0)
local HIT_COLOR_FADE = Color3.new(1, 1, 0.7)
local MOBILE_HAPTIC_HIT_INTENSITY = 0.18
local MOBILE_HAPTIC_HEADSHOT_INTENSITY = 0.4
local MOBILE_HAPTIC_HIT_DURATION = 0.04
local MOBILE_HAPTIC_HEADSHOT_DURATION = 0.065
local MOBILE_HAPTIC_COOLDOWN = 0.07
local MOBILE_HAPTIC_INPUT_TYPES = { Enum.UserInputType.Touch, Enum.UserInputType.Gamepad1 }
local MOBILE_HAPTIC_MOTORS = { Enum.VibrationMotor.Small, Enum.VibrationMotor.Large }

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

-- Pre-built sequences for _updateReloadProgressBar — style is constant so these
-- never need to change. Avoids ~480 userdata allocs per reload.
local _reloadSeqCache: {
	colorSeq: ColorSequence?,
	transSeq: NumberSequence?,
	whiteColor: ColorSequence?,
	zeroTrans: NumberSequence?,
}
do
	local s = RELOAD_PROGRESS_STYLE
	local colorKp = ColorSequence.new({
		ColorSequenceKeypoint.new(0, s.ColorOfPercentPart),
		ColorSequenceKeypoint.new(0.5, s.ColorOfPercentPart),
		ColorSequenceKeypoint.new(0.501, s.ColorOfMissingPart),
		ColorSequenceKeypoint.new(1, s.ColorOfMissingPart),
	})
	local transKp = NumberSequence.new({
		NumberSequenceKeypoint.new(0, s.TransOfPercentPart),
		NumberSequenceKeypoint.new(0.5, s.TransOfPercentPart),
		NumberSequenceKeypoint.new(0.501, s.TransOfMissingPart),
		NumberSequenceKeypoint.new(1, s.TransOfMissingPart),
	})
	local white = ColorSequence.new(Color3.new(1, 1, 1))
	local zero = NumberSequence.new(0)

	if s.MissingPartType == "Color" then
		_reloadSeqCache = { colorSeq = colorKp, transSeq = nil, whiteColor = nil, zeroTrans = zero }
	elseif s.MissingPartType == "Trans" then
		_reloadSeqCache = { colorSeq = nil, transSeq = transKp, whiteColor = white, zeroTrans = nil }
	elseif s.MissingPartType == "TransAndColor" then
		_reloadSeqCache = { colorSeq = colorKp, transSeq = transKp, whiteColor = nil, zeroTrans = nil }
	else
		_reloadSeqCache = { colorSeq = nil, transSeq = transKp, whiteColor = white, zeroTrans = nil }
	end
end

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

local function setGuiColorRecursive(guiObject, color)
	if guiObject:IsA("ImageLabel") or guiObject:IsA("ImageButton") then
		guiObject.ImageColor3 = color
	end
	if guiObject:IsA("Frame") or guiObject:IsA("TextLabel") or guiObject:IsA("TextButton") or guiObject:IsA("TextBox") then
		guiObject.BackgroundColor3 = color
	end
	if guiObject:IsA("UIStroke") then
		guiObject.Color = color
	end

	for _, child in ipairs(guiObject:GetChildren()) do
		setGuiColorRecursive(child, color)
	end
end

-- W11: lista plana pre-categorizada para el vignette. Antes refreshVignette
-- (disparado a 60Hz durante el tween 0.14s) hacía GetChildren recursivo +
-- 4 :IsA por nodo cada vez. Ahora 1 build + iterate flat list con flags.
type VignetteNode = {
	obj: Instance,
	hasImage: boolean,
	hasText: boolean,
	hasBackground: boolean,
	isStroke: boolean,
}

local function buildVignetteNodeList(root: Instance): { VignetteNode }
	local list: { VignetteNode } = {}
	local function visit(obj: Instance)
		local isImage = obj:IsA("ImageLabel") or obj:IsA("ImageButton")
		local isText = obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")
		local isFrame = obj:IsA("Frame")
		local isStroke = obj:IsA("UIStroke")
		if isImage or isText or isFrame or isStroke then
			table.insert(list, {
				obj = obj,
				hasImage = isImage,
				hasText = isText,
				hasBackground = isFrame or isText,
				isStroke = isStroke,
			})
		end
		for _, child in ipairs(obj:GetChildren()) do
			visit(child)
		end
	end
	visit(root)
	return list
end

local function applyVignetteAlpha(nodes: { VignetteNode }, alpha: number)
	local strokeAlpha = math.clamp(alpha, 0, 1)
	for _, n in nodes do
		local obj = n.obj :: any
		if n.hasImage then obj.ImageTransparency = alpha end
		if n.hasText then
			obj.TextTransparency = alpha
			obj.TextStrokeTransparency = strokeAlpha
		end
		if n.hasBackground then obj.BackgroundTransparency = alpha end
		if n.isStroke then obj.Transparency = alpha end
	end
end

local function applyVignetteColor(nodes: { VignetteNode }, color: Color3)
	for _, n in nodes do
		local obj = n.obj :: any
		if n.hasImage then obj.ImageColor3 = color end
		if n.hasBackground then obj.BackgroundColor3 = color end
		if n.isStroke then obj.Color = color end
	end
end

local function isMobileTouchDevice()
    return UserInputService.TouchEnabled
end

local _cachedHapticTargets: { { inputType: Enum.UserInputType, motor: Enum.VibrationMotor } }? = nil

local function getSupportedHapticTargets()
    if _cachedHapticTargets then
        return _cachedHapticTargets
    end
    local targets = {}
    for _, inputType in ipairs(MOBILE_HAPTIC_INPUT_TYPES) do
        for _, motor in ipairs(MOBILE_HAPTIC_MOTORS) do
            local ok, supported = pcall(function()
                return HapticService:IsMotorSupported(inputType, motor)
            end)
            if ok and supported then
                table.insert(targets, { inputType = inputType, motor = motor })
            end
        end
    end
    _cachedHapticTargets = targets
    return targets
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

-- Filtro de "tap directo". GuiObject.InputBegan dispara también cuando un
-- touch ya activo desliza dentro de los bounds (drag-onto), así que NO podemos
-- usar ese evento como trigger. En su lugar, escuchamos UserInputService.InputBegan
-- — que sólo dispara una vez al nacer el touch — y comprobamos si la posición
-- de origen cae dentro de un botón con _isInsideButton.
function WeaponsGui:_isInsideButton(pos, button)
	if not pos or not button or not button.Visible then return false end
	-- Si el padre (Small/LargeTouchscreen) está oculto, los bounds siguen siendo
	-- válidos pero el botón no es interactivo en pantalla.
	local parent = button.Parent
	if parent and parent:IsA("GuiObject") and not parent.Visible then return false end
	local abs = button.AbsolutePosition
	local size = button.AbsoluteSize
	return pos.X >= abs.X and pos.X <= abs.X + size.X
		and pos.Y >= abs.Y and pos.Y <= abs.Y + size.Y
end

function WeaponsGui:_dispatchTouchBegin(input)
	local pos = input.Position
	if self:_isInsideButton(pos, self.smallAimButton) then
		self:onTouchAimButton(self.smallAimButton, input, Enum.UserInputState.Begin)
	elseif self:_isInsideButton(pos, self.largeAimButton) then
		self:onTouchAimButton(self.largeAimButton, input, Enum.UserInputState.Begin)
	end
	if self:_isInsideButton(pos, self.smallFireButton) then
		self:onTouchFireButton(self.smallFireButton, input, Enum.UserInputState.Begin)
	elseif self:_isInsideButton(pos, self.largeFireButton) then
		self:onTouchFireButton(self.largeFireButton, input, Enum.UserInputState.Begin)
	end
	if self:_isInsideButton(pos, self.smallReloadButton) then
		self:onTouchReloadButton(self.smallReloadButton, input, Enum.UserInputState.Begin)
	elseif self:_isInsideButton(pos, self.largeReloadButton) then
		self:onTouchReloadButton(self.largeReloadButton, input, Enum.UserInputState.Begin)
	end
	if self.smallJumpButton and self:_isInsideButton(pos, self.smallJumpButton) then
		self:onTouchJumpButton(self.smallJumpButton, input, Enum.UserInputState.Begin)
	elseif self.largeJumpButton and self:_isInsideButton(pos, self.largeJumpButton) then
		self:onTouchJumpButton(self.largeJumpButton, input, Enum.UserInputState.Begin)
	end
end

function WeaponsGui:_dispatchTouchEnd(input)
	-- Cada handler filtra por su _activeXxxInput, así que pasar el evento a
	-- todos es seguro y simple.
	self:onTouchAimButton(nil, input, Enum.UserInputState.End)
	self:onTouchFireButton(nil, input, Enum.UserInputState.End)
	self:onTouchReloadButton(nil, input, Enum.UserInputState.End)
	self:onTouchJumpButton(nil, input, Enum.UserInputState.End)
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

function WeaponsGui:_playLocalHitHighlight(humanoidHit)
	if not humanoidHit or not humanoidHit:IsA("Humanoid") then
		return
	end

	local targetModel = humanoidHit.Parent
	if not targetModel or not targetModel:IsA("Model") then
		return
	end

	local existingState = self._activeHitHighlights[targetModel]
	if existingState then
		if existingState.colorTween then
			existingState.colorTween:Cancel()
		end
		if existingState.fadeTween then
			existingState.fadeTween:Cancel()
		end
		if existingState.highlight and existingState.highlight.Parent then
			existingState.highlight:Destroy()
		end
		self._activeHitHighlights[targetModel] = nil
	end

	local oldHighlight = targetModel:FindFirstChild(HIT_HIGHLIGHT_NAME)
	if oldHighlight and oldHighlight:IsA("Highlight") then
		oldHighlight:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = HIT_HIGHLIGHT_NAME
	highlight.Adornee = targetModel
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineColor = HIT_HIGHLIGHT_OUTLINE_COLOR
	highlight.FillTransparency = 0
	highlight.OutlineTransparency = 0
	highlight.Parent = targetModel

	self._hitHighlightSerial += 1
	local serial = self._hitHighlightSerial

	local colorTween = TweenService:Create(highlight, HIT_HIGHLIGHT_TO_OUTLINE_TWEEN, {
		FillColor = highlight.OutlineColor,
	})

	self._activeHitHighlights[targetModel] = {
		serial = serial,
		highlight = highlight,
		colorTween = colorTween,
		fadeTween = nil,
	}

	colorTween.Completed:Connect(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		local state = self._activeHitHighlights[targetModel]
		if not state or state.serial ~= serial or not highlight.Parent then
			return
		end

		local fadeTween = TweenService:Create(highlight, HIT_HIGHLIGHT_FADE_TWEEN, {
			FillTransparency = 1,
			OutlineTransparency = 1,
		})
		state.fadeTween = fadeTween

		fadeTween.Completed:Connect(function()
			local currentState = self._activeHitHighlights[targetModel]
			if currentState and currentState.serial == serial then
				self._activeHitHighlights[targetModel] = nil
			end
			if highlight.Parent then
				highlight:Destroy()
			end
		end)

		fadeTween:Play()
	end)

	colorTween:Play()
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
	local searchRoot = if itemsFolder then itemsFolder else hotbarRoot

	local itemFrame = searchRoot:FindFirstChild(itemName)
	if not itemFrame then
		local lowercaseName = string.lower(itemName)
		for _, child in ipairs(searchRoot:GetChildren()) do
			if string.lower(child.Name) == lowercaseName then
				itemFrame = child
				break
			end
		end
	end
	if not itemFrame or not itemFrame:IsA("GuiObject") then
		return nil
	end

	local imageNode = itemFrame:FindFirstChild("Image")
	if not isHotbarImageNode(imageNode) then
		imageNode = itemFrame:FindFirstChildWhichIsA("ImageButton") or itemFrame:FindFirstChildWhichIsA("ImageLabel")
	end

	local strokeNode = itemFrame:FindFirstChildWhichIsA("UIStroke", true)
	local ammoRoot = itemFrame:FindFirstChild("Ammo")
	local ammoValueNode = if ammoRoot then ammoRoot:FindFirstChild("Value") else nil
	local ammoValueLabel = if ammoValueNode and (
		ammoValueNode:IsA("TextLabel")
		or ammoValueNode:IsA("TextButton")
		or ammoValueNode:IsA("TextBox")
	) then ammoValueNode else nil

	if not ammoValueNode then
		ammoValueLabel = itemFrame:FindFirstChild("Value", true)
		if ammoValueLabel and (
			ammoValueLabel:IsA("TextLabel")
			or ammoValueLabel:IsA("TextButton")
			or ammoValueLabel:IsA("TextBox")
		) then
			ammoValueNode = ammoValueLabel
		end
	end

	return {
		frame = itemFrame,
		image = imageNode,
		stroke = if strokeNode and strokeNode:IsA("UIStroke") then strokeNode else nil,
		ammoValueNode = ammoValueNode,
		ammoValueLabel = ammoValueLabel,
		baseSize = itemFrame.Size,
	}
end

function WeaponsGui:_setSlotStrokeVisible(slotNode, isVisible)
	local stroke = slotNode and slotNode.stroke
	if not stroke then
		return
	end

	stroke.Enabled = isVisible
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
		self:_setSlotStrokeVisible(layout.item1, selectedSlot == 1)
		self:_setSlotStrokeVisible(layout.item2, selectedSlot == 2)
	end
end

function WeaponsGui:_resolveAmmoCapacityForTool(tool)
	if not tool then
		return nil
	end

	local currentWeapon = self.weaponsSystem.currentWeapon
	if currentWeapon and currentWeapon.instance == tool and currentWeapon.getConfigValue then
		local capacityFromWeapon = currentWeapon:getConfigValue("AmmoCapacity", nil)
		if type(capacityFromWeapon) == "number" then
			return math.max(0, math.floor(capacityFromWeapon + 0.5))
		end
	end

	local configuration = tool:FindFirstChildOfClass("Configuration")
	if configuration then
		local ammoCapacityValue = configuration:FindFirstChild("AmmoCapacity")
		if ammoCapacityValue and ammoCapacityValue:IsA("ValueBase") then
			local rawValue = ammoCapacityValue.Value
			if type(rawValue) == "number" then
				return math.max(0, math.floor(rawValue + 0.5))
			end
		end
	end

	return nil
end

function WeaponsGui:_formatHotbarAmmoRichText(currentAmmo, totalAmmo)
	return string.format(
		"<font color=\"%s\">%d</font><font color=\"%s\">/%d</font>",
		HOTBAR_AMMO_CURRENT_COLOR,
		currentAmmo,
		HOTBAR_AMMO_TOTAL_COLOR,
		totalAmmo
	)
end

function WeaponsGui:_setSlotAmmoText(slotNode, currentAmmo, totalAmmo)
	if not slotNode then
		return
	end

	local ammoValueLabel = slotNode.ammoValueLabel
	local ammoValueNode = slotNode.ammoValueNode
	local hasAmmo = type(currentAmmo) == "number" and type(totalAmmo) == "number"
	local richText = if hasAmmo
		then self:_formatHotbarAmmoRichText(
			math.max(0, math.floor(currentAmmo + 0.5)),
			math.max(0, math.floor(totalAmmo + 0.5))
		)
		else ""

	if ammoValueLabel then
		ammoValueLabel.RichText = true
		ammoValueLabel.Text = richText
		return
	end

	if ammoValueNode and ammoValueNode:IsA("StringValue") then
		ammoValueNode.Value = richText
	elseif ammoValueNode and ammoValueNode:IsA("IntValue") then
		ammoValueNode.Value = if hasAmmo then math.max(0, math.floor(currentAmmo + 0.5)) else 0
	elseif ammoValueNode and ammoValueNode:IsA("NumberValue") then
		ammoValueNode.Value = if hasAmmo then math.max(0, math.floor(currentAmmo + 0.5)) else 0
	end
end

function WeaponsGui:_updateHotbarAmmoDisplay(mainTool, specialTool)
	local mainCurrent = if mainTool then mainTool:GetAttribute("CurrentAmmo") else nil
	local specialCurrent = if specialTool then specialTool:GetAttribute("CurrentAmmo") else nil
	local mainTotal = self:_resolveAmmoCapacityForTool(mainTool)
	local specialTotal = self:_resolveAmmoCapacityForTool(specialTool)

	for _, layout in ipairs(self.hotbarLayouts) do
		self:_setSlotAmmoText(layout.item1, mainCurrent, mainTotal)
		self:_setSlotAmmoText(layout.item2, specialCurrent, specialTotal)
	end
end

-- W1: marca el hotbar dirty para que el próximo onRenderStepped lo refresque.
-- Inlineado en los handlers (vs método) para evitar el overhead del : call.
local function _markDirty(self)
	self._hotbarDirty = true
end

function WeaponsGui:_disconnectHotbarAmmoConns()
	for _, c in self._hotbarAmmoConns do
		c:Disconnect()
	end
	table.clear(self._hotbarAmmoConns)
end

function WeaponsGui:_connectHotbarAmmoConns(mainTool, specialTool)
	-- Reconnect solo si cambió alguna de las dos tools (caso común: refresh
	-- intra-vida en el que las tools no cambiaron — evita disconnect+reconnect).
	if mainTool == self._hotbarLastMainTool and specialTool == self._hotbarLastSpecialTool then
		return
	end
	self._hotbarLastMainTool = mainTool
	self._hotbarLastSpecialTool = specialTool
	self:_disconnectHotbarAmmoConns()
	if mainTool then
		table.insert(
			self._hotbarAmmoConns,
			mainTool:GetAttributeChangedSignal("CurrentAmmo"):Connect(function()
				self._hotbarDirty = true
			end)
		)
	end
	if specialTool and specialTool ~= mainTool then
		table.insert(
			self._hotbarAmmoConns,
			specialTool:GetAttributeChangedSignal("CurrentAmmo"):Connect(function()
				self._hotbarDirty = true
			end)
		)
	end
end

function WeaponsGui:_connectHotbarCharacterEvents(character: Instance?)
	for _, c in self._hotbarCharConns do
		c:Disconnect()
	end
	table.clear(self._hotbarCharConns)
	if not character then return end
	-- Tool equip/unequip se manifiesta como Tool entrando/saliendo del Character.
	table.insert(self._hotbarCharConns, character.ChildAdded:Connect(function() _markDirty(self) end))
	table.insert(self._hotbarCharConns, character.ChildRemoved:Connect(function() _markDirty(self) end))
end

function WeaponsGui:_setupHotbarEvents()
	-- Connect once: lifetime de la instancia WeaponsGui.
	if self._hotbarEventsSetup then return end
	self._hotbarEventsSetup = true

	-- Character respawn: re-hookear ChildAdded/Removed sobre el nuevo character
	-- y marcar dirty (cambian los tools disponibles).
	table.insert(
		self._hotbarLifetimeConns,
		LocalPlayer.CharacterAdded:Connect(function(char)
			_markDirty(self)
			self:_connectHotbarCharacterEvents(char)
		end)
	)
	table.insert(
		self._hotbarLifetimeConns,
		LocalPlayer.CharacterRemoving:Connect(function()
			_markDirty(self)
		end)
	)
	self:_connectHotbarCharacterEvents(LocalPlayer.Character)

	-- Backpack: una sola instancia por sesión (no se recrea con respawn).
	-- ChildAdded/Removed cubre tools entregadas/quitadas/equipadas.
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(self._hotbarLifetimeConns, backpack.ChildAdded:Connect(function() _markDirty(self) end))
		table.insert(self._hotbarLifetimeConns, backpack.ChildRemoved:Connect(function() _markDirty(self) end))
	else
		-- Backpack puede aparecer tras nosotros si el GUI se crea muy pronto.
		table.insert(
			self._hotbarLifetimeConns,
			LocalPlayer.ChildAdded:Connect(function(child)
				if child:IsA("Backpack") then
					table.insert(self._hotbarLifetimeConns, child.ChildAdded:Connect(function() _markDirty(self) end))
					table.insert(self._hotbarLifetimeConns, child.ChildRemoved:Connect(function() _markDirty(self) end))
					_markDirty(self)
				end
			end)
		)
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

	self:_updateHotbarAmmoDisplay(mainTool, specialTool)

	local selectedSlot = self:_getSelectedSlotByCurrentWeapon(mainTool, specialTool)
	if selectedSlot ~= 1 and selectedSlot ~= 2 then
		selectedSlot = 1
	end

	self:_applyHotbarSelectedVisual(selectedSlot)

	-- W1: hookear ammo listeners en las tools actuales (si cambiaron) + clear
	-- dirty al final del refresh.
	self:_connectHotbarAmmoConns(mainTool, specialTool)
	self._hotbarDirty = false
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
	self._activeHitHighlights = setmetatable({}, { __mode = "k" })
	self._hitHighlightSerial = 0

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
	-- W1: dirty flag para hotbar. Antes _refreshHotbar corría cada frame
	-- iterando Character + Backpack + FindFirstChildOfClass por slot. Ahora
	-- solo cuando algún evento (tool added/removed, ammo changed, weapon
	-- swap) marca dirty. Init true para refresh inicial.
	self._hotbarDirty = true
	self._hotbarLifetimeConns = {}
	self._hotbarCharConns = {}
	self._hotbarAmmoConns = {}
	self._hotbarLastMainTool = nil
	self._hotbarLastSpecialTool = nil
	self._kickCooldownEnd = 0
	self._activeJumpInput = nil
	self._activeFireInput = nil
	self._activeFireInputConn = nil
	self._activeAimInput = nil
	self._activeReloadInput = nil
	self._isFirePressed = false
	self._isReloadPressed = false
	self._isJumpPressed = false
	self._hotbarConns = {}
	self.hotbarLayouts = {}
	self.hotbarMainTool = nil
	self.hotbarSpecialTool = nil
	self.hotbarSelectedSlot = 1
	self.vignette = nil
	self.vignetteHideToken = 0
	self.vignetteDisplayTime = 0.45
	self.vignetteFadeTween = nil
	self.vignetteKillAlphaDriver = nil
	self.vignetteHealthAlphaDriver = nil
	self.vignetteStateConn = nil
	self.ammoDisplayNode = nil
	self.ammoDisplayLabel = nil
	self._lastAmmoDisplayText = nil

	self.combatHUD = nil

	self.crosshairShotgunFrame = nil
	self.crosshairShotgunTopLeft = nil
	self.crosshairShotgunTopRight = nil
	self.crosshairShotgunBottomLeft = nil
	self.crosshairShotgunBottomRight = nil

	self.outOfRangeFrame = nil
	self.outOfRangeDistanceLabel = nil
	self._lastOutOfRangeDistanceText = nil
	self._isOutOfRange = false
	self._shotgunDefaultOptimalRange = 30 -- fallback en studs si el Tool no define OptimalRange

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

		self.outOfRangeFrame = self.scalingElementsFolder:FindFirstChild("OutOfRange")
		if self.outOfRangeFrame then
			self.outOfRangeFrame.Visible = false
			self.outOfRangeDistanceLabel = self.outOfRangeFrame:FindFirstChild("Distance", true)
		end

		self.hitMarker = self.scalingElementsFolder:WaitForChild("HitMarker"):WaitForChild("HitMarkerImage")
		self.vignette = self.gui:FindFirstChild("Vignette", true)
		if not self.vignette then
			self.vignette = self.gui:FindFirstChild("KillContainer", true)
		end
		if self.vignette and self.vignette:IsA("GuiObject") then
			self.vignette.Visible = false
			self.vignetteKillAlphaDriver = self.vignette:FindFirstChild("KillAlphaDriver")
			if not (self.vignetteKillAlphaDriver and self.vignetteKillAlphaDriver:IsA("NumberValue")) then
				self.vignetteKillAlphaDriver = Instance.new("NumberValue")
				self.vignetteKillAlphaDriver.Name = "KillAlphaDriver"
				self.vignetteKillAlphaDriver.Parent = self.vignette
			end
			self.vignetteKillAlphaDriver.Value = 0

			self.vignetteHealthAlphaDriver = self.vignette:FindFirstChild("HealthAlphaDriver")
			if not (self.vignetteHealthAlphaDriver and self.vignetteHealthAlphaDriver:IsA("NumberValue")) then
				self.vignetteHealthAlphaDriver = Instance.new("NumberValue")
				self.vignetteHealthAlphaDriver.Name = "HealthAlphaDriver"
				self.vignetteHealthAlphaDriver.Parent = self.vignette
			end
			self.vignetteHealthAlphaDriver.Value = self.vignetteHealthAlphaDriver.Value or 0

			-- W11: build cacheado de la lista plana del subárbol del vignette.
			-- Subárbol estático en runtime — no recorremos descendants en cada
			-- Changed (que dispara a 60Hz durante el tween 0.14s).
			self._vignetteNodes = buildVignetteNodeList(self.vignette)

			local function refreshVignette()
				if not self.vignette or not self._vignetteNodes then
					return
				end

				local killAlpha = if self.vignetteKillAlphaDriver then self.vignetteKillAlphaDriver.Value else 0
				local healthAlpha = if self.vignetteHealthAlphaDriver then self.vignetteHealthAlphaDriver.Value else 0
				local visibleAlpha = math.max(killAlpha, healthAlpha)

				if visibleAlpha <= 0 then
					applyVignetteAlpha(self._vignetteNodes, 1)
					self.vignette.Visible = false
					return
				end

				local color = if killAlpha >= healthAlpha then VIGNETTE_KILL_COLOR else VIGNETTE_HEALTH_COLOR
				applyVignetteColor(self._vignetteNodes, color)
				applyVignetteAlpha(self._vignetteNodes, 1 - math.clamp(visibleAlpha, 0, 1))
				self.vignette.Visible = true
			end

			self.vignetteStateConn = self.vignetteKillAlphaDriver.Changed:Connect(refreshVignette)
			self.vignetteHealthAlphaDriver.Changed:Connect(refreshVignette)
			refreshVignette()
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

		-- NoClickSound: UISoundsController auto-bindea sonido de click a todo
		-- GuiButton en PlayerGui via .Activated. Estos botones móviles no deben sonar.
		-- Why: Activated dispara también cuando se suelta el dedo encima tras venir
		-- de fuera (drag-onto), produciendo clicks espurios al girar cámara.
		self.smallAimButton = self.smallTouchscreen:WaitForChild("AimButton")
		self.smallAimButton:SetAttribute("NoClickSound", true)
		self.largeAimButton = self.largeTouchscreen:WaitForChild("AimButton")
		self.largeAimButton:SetAttribute("NoClickSound", true)

		self.smallFireButton = self.smallTouchscreen:WaitForChild("FireButton")
		self.smallFireButton:SetAttribute("NoClickSound", true)
		self.largeFireButton = self.largeTouchscreen:WaitForChild("FireButton")
		self.largeFireButton:SetAttribute("NoClickSound", true)

		self.smallReloadButton = self.smallTouchscreen:WaitForChild("ReloadButton")
		self.smallReloadButton:SetAttribute("NoClickSound", true)
		self.largeReloadButton = self.largeTouchscreen:WaitForChild("ReloadButton")
		self.largeReloadButton:SetAttribute("NoClickSound", true)

		self.smallJumpButton = self.smallTouchscreen:FindFirstChild("JumpButton")
		if self.smallJumpButton then
			self.smallJumpButton.Active = true
			self.smallJumpButton:SetAttribute("NoClickSound", true)
		end
		self.largeJumpButton = self.largeTouchscreen:FindFirstChild("JumpButton")
		if self.largeJumpButton then
			self.largeJumpButton.Active = true
			self.largeJumpButton:SetAttribute("NoClickSound", true)
		end

		-- W4: el dispatch de tap directo se hace ahora desde las conexiones
		-- inputBegan/inputEnded de setEnabled (que sí viven en self.connections
		-- y se desconectan en setEnabled(false)/reinstantiation). Antes estas
		-- 2 conexiones quedaban colgadas para siempre porque no se trackeaban.
		-- _dispatchTouchBegin/End filtran internamente por _isInsideButton, que
		-- ya chequea Visible — en PC sin UI touch es no-op barato.

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
		-- W1: event-driven (LocalPlayer Character/Backpack changes + per-tool
		-- CurrentAmmo). Idempotente — _setupHotbarEvents tiene su propio guard.
		self:_setupHotbarEvents()
		self:_refreshHotbar()

		self.gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
		-- Audit mobile: trackear estas 3 conexiones en self.connections para que
		-- setEnabled(false)/Destroy las desconecte. Antes quedaban colgadas y,
		-- si setEnabled(true) se re-llamaba, duplicaban listeners. Disconnect
		-- previo defensivo por idempotencia.
		if self.connections.absoluteSize then self.connections.absoluteSize:Disconnect() end
		if self.connections.currentCamera then self.connections.currentCamera:Disconnect() end
		if self.connections.guiEnabled then self.connections.guiEnabled:Disconnect() end
		self.connections.absoluteSize = self.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() self:onScreenSizeChanged() end)
		self.connections.currentCamera = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() self:onScreenSizeChanged() end)
		self.connections.guiEnabled = self.gui:GetPropertyChangedSignal("Enabled"):Connect(function()
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
		if self.vignette then
			table.insert(preloadTargets, self.vignette)
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
			-- W4: tap directo (touch/MouseButton1) routed aquí — ya no en conexión
			-- separada que leakea. _dispatchTouchBegin filtra por _isInsideButton,
			-- que chequea Visible — en PC sin UI touch es no-op barato.
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				if self.smallFireButton then
					self:_dispatchTouchBegin(input)
				end
			end

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
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				if self.smallFireButton then
					self:_dispatchTouchEnd(input)
				end
			end

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
	if not self.vignette then return end
	self.vignetteHideToken += 1
	if self.vignetteFadeTween then
		self.vignetteFadeTween:Cancel()
		self.vignetteFadeTween = nil
	end

	if immediate then
		if self.vignetteKillAlphaDriver then
			self.vignetteKillAlphaDriver.Value = 0
		elseif self._vignetteNodes then
			applyVignetteAlpha(self._vignetteNodes, 1)
		end
		if not self.vignetteHealthAlphaDriver or self.vignetteHealthAlphaDriver.Value <= 0 then
			self.vignette.Visible = false
		end
		return
	end

	local hideToken = self.vignetteHideToken
	local alphaDriver = self.vignetteKillAlphaDriver
	if alphaDriver then
		self.vignetteFadeTween = TweenService:Create(alphaDriver, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 0 })
		self.vignetteFadeTween:Play()
		self.vignetteFadeTween.Completed:Once(function()
			if self.vignetteHideToken ~= hideToken or not self.vignette then
				return
			end
			if not self.vignetteHealthAlphaDriver or self.vignetteHealthAlphaDriver.Value <= 0 then
				self.vignette.Visible = false
			end
			self.vignetteFadeTween = nil
		end)
	elseif self._vignetteNodes then
		applyVignetteAlpha(self._vignetteNodes, 1)
		self.vignette.Visible = false
	end
end

function WeaponsGui:showKillContainer()
	if self.vignetteKillAlphaDriver then
		self.vignetteKillAlphaDriver.Value = 0
	end
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
	local shotgunInRange = self._isShotgun and not self._isOutOfRange
	if self.crosshairShotgunFrame then
		self.crosshairShotgunFrame.Visible = shouldShow and shotgunInRange
	end
	if self.outOfRangeFrame then
		self.outOfRangeFrame.Visible = shouldShow and self._isShotgun and self._isOutOfRange
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
	-- Reset out-of-range state al cambiar de variant: si volvemos a un arma no
	-- shotgun, OutOfRange debe ocultarse hasta que vuelva a aplicarse la lógica.
	self._isOutOfRange = false
	self:_refreshCrosshairVisibility()
	if self._isShotgun then
		self.crosshairWeaponScale = 1
		self.crosshairSpreadTarget = self.isZoomed and self.crosshairSpreadAim or self.crosshairSpreadBase
	else
		self.crosshairSpreadTarget = 0
	end
	SpringService:Target(self, self.crosshairDampingRatio, self.crosshairFrequency, { crosshairSpread = self.crosshairSpreadTarget })
end

-- W1: throttle del shotgun OutOfRange check. Solo corre en mobile (autoshoot),
-- y a 10Hz es imperceptible para el aviso visual. Antes raycast de 300 studs
-- + RaycastParams.new() + table literal por frame.
local SHOTGUN_RANGE_TICK_INTERVAL = 0.1

function WeaponsGui:_updateShotgunRangeState()
	if not self._isShotgun then return end
	if not self.outOfRangeFrame then return end -- sin frame OutOfRange no hay nada que togglear

	-- OutOfRange solo en dispositivos tactiles: en movil el AutoShoot decide por
	-- el jugador y avisar es util; en PC el jugador controla el disparo
	-- manualmente y la advertencia es ruido innecesario.
	if not (UserInputService.TouchEnabled and not UserInputService.MouseEnabled) then
		if self._isOutOfRange then
			self._isOutOfRange = false
			self:_refreshCrosshairVisibility()
		end
		return
	end

	-- W1: gate por tiempo (10Hz). Por frame el raycast + creación de
	-- RaycastParams era todo desperdiciado en estado estable.
	local now = os.clock()
	if now - (self._shotgunRangeLastTickAt or 0) < SHOTGUN_RANGE_TICK_INTERVAL then return end
	self._shotgunRangeLastTickAt = now

	local camera = workspace.CurrentCamera
	if not camera then return end

	local weapon = self.weaponsSystem.currentWeapon
	local tool = weapon and weapon.instance
	local optimalRange = self._shotgunDefaultOptimalRange
	if tool then
		local attr = tool:GetAttribute("OptimalRange")
		if type(attr) == "number" and attr > 0 then
			optimalRange = attr
		end
	end

	-- OutOfRange aplica cuando estamos APUNTANDO a un enemigo (raycast desde el
	-- centro de camara). No usamos AutoAim.findBestTarget porque su threshold de
	-- 80px solo se cumple cuando el aim assist fuerte de movil engancha la mira;
	-- en PC el usuario apunta manualmente y rara vez cae dentro de ese radio,
	-- asi que OutOfRange no aparecia nunca.
	local outOfRange = false
	local distance: number? = nil

	-- Audit mobile: el centro de viewport siempre coincide con
	-- camera.CFrame.LookVector (no necesita ViewportPointToRay, que aloca
	-- un Ray + Vector3 por tick del shotgun range check).
	local cameraCFrame = camera.CFrame
	local cameraOrigin = cameraCFrame.Position
	local cameraDir = cameraCFrame.LookVector

	-- W1: RaycastParams + filter cacheados en self. Mutamos slots in-place.
	local rayParams = self._shotgunRangeParams
	if not rayParams then
		rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.IgnoreWater = true
		self._shotgunRangeParams = rayParams
	end
	local filter = self._shotgunRangeFilter
	if not filter then
		filter = table.create(2)
		self._shotgunRangeFilter = filter
	end
	local n = 0
	if LocalPlayer and LocalPlayer.Character then
		n += 1
		filter[n] = LocalPlayer.Character
	end
	if tool then
		n += 1
		filter[n] = tool
	end
	for i = n + 1, #filter do
		filter[i] = nil
	end
	rayParams.FilterDescendantsInstances = filter

	local maxRay = AutoAimSystem.MAX_DISTANCE or 300
	local result = workspace:Raycast(cameraOrigin, cameraDir * maxRay, rayParams)
	if result and result.Instance then
		local hitChar = result.Instance:FindFirstAncestorOfClass("Model")
		if hitChar and hitChar:FindFirstChildOfClass("Humanoid") then
			local hum = hitChar:FindFirstChildOfClass("Humanoid")
			local localChar = LocalPlayer and LocalPlayer.Character
			local sameTeam = localChar and TeamUtils.isSameTeam(localChar, hitChar) or false
			if hum and hum.Health > 0 and not sameTeam and hitChar ~= localChar then
				distance = (result.Position - cameraOrigin).Magnitude
				outOfRange = distance > optimalRange
			end
		end
	end

	if outOfRange ~= self._isOutOfRange then
		self._isOutOfRange = outOfRange
		self:_refreshCrosshairVisibility()
	end

	if outOfRange and distance and self.outOfRangeDistanceLabel then
		-- Studs que faltan por acercarse para entrar en el rango optimo.
		local remaining = math.max(0, distance - optimalRange)
		local text = tostring(math.floor(remaining + 0.5))
		if text ~= self._lastOutOfRangeDistanceText then
			self._lastOutOfRangeDistanceText = text
			local label = self.outOfRangeDistanceLabel
			if label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox") then
				label.Text = text
			end
		end
	end
end

function WeaponsGui:_applyCrosshairByWeapon()
	local w = self.weaponsSystem.currentWeapon
	local tool = w and w.instance
	if tool == self._lastWeaponInstance then return end
	self._lastWeaponInstance = tool
	-- W1: weapon swap → marcar hotbar dirty (cambia selected slot visual).
	self._hotbarDirty = true
	local isShotgun = tool and tool:GetAttribute("Shotgun") == true
	self:_setCrosshairVariant(isShotgun)
	self:_connectToolConns(tool)
end

function WeaponsGui:_layoutShotgunCrosshairCorners()
	if not (self.crosshairShotgunFrame and self._isShotgun) then return end
	local s = self.crosshairSpread
	local size = math.floor(self.crosshairNormalSize.Y * 0.45)
	-- W7: AnchorPoint solo se asigna una vez por corner (no cambia entre frames).
	-- Antes se reasignaba el mismo Vector2.new(0.5,0.5) cada frame.
	if not self._shotgunAnchorsSet then
		self.crosshairShotgunTopLeft.AnchorPoint = CENTER_ANCHOR_V2
		self.crosshairShotgunTopRight.AnchorPoint = CENTER_ANCHOR_V2
		self.crosshairShotgunBottomLeft.AnchorPoint = CENTER_ANCHOR_V2
		self.crosshairShotgunBottomRight.AnchorPoint = CENTER_ANCHOR_V2
		self._shotgunAnchorsSet = true
	end
	self.crosshairShotgunTopLeft.Position = UDim2.new(0.5,-s,0.5,-s)
	self.crosshairShotgunTopLeft.Size = UDim2.new(0, size, 0, size)
	self.crosshairShotgunTopRight.Position = UDim2.new(0.5,s,0.5,-s)
	self.crosshairShotgunTopRight.Size = UDim2.new(0, size, 0, size)
	self.crosshairShotgunBottomLeft.Position = UDim2.new(0.5,-s,0.5,s)
	self.crosshairShotgunBottomLeft.Size = UDim2.new(0, size, 0, size)
	self.crosshairShotgunBottomRight.Position = UDim2.new(0.5,s,0.5,s)
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

function WeaponsGui:_pulseMobileHaptics(isHeadshot)
	if not isMobileTouchDevice() then
		return
	end

	local now = os.clock()
	if now - (self._lastMobileHapticAt or 0) < MOBILE_HAPTIC_COOLDOWN then
		return
	end
	self._lastMobileHapticAt = now

	local targets = getSupportedHapticTargets()
	if #targets == 0 then
		if not self._warnedNoMobileHaptics then
			self._warnedNoMobileHaptics = true
			warn("WeaponsGui: HapticService no reporta motores soportados para este dispositivo")
		end
		return
	end

	local intensity = if isHeadshot then MOBILE_HAPTIC_HEADSHOT_INTENSITY else MOBILE_HAPTIC_HIT_INTENSITY
	local duration = if isHeadshot then MOBILE_HAPTIC_HEADSHOT_DURATION else MOBILE_HAPTIC_HIT_DURATION
	local pulseId = (self._mobileHapticPulseId or 0) + 1
	self._mobileHapticPulseId = pulseId

	-- W12: pcall fuera del loop. Antes N exception frames por hit
	-- (1 pcall × cada target × cada fase). Headshot doblaba el coste.
	pcall(function()
		for _, target in ipairs(targets) do
			HapticService:SetMotor(target.inputType, target.motor, intensity)
		end
	end)

	task.delay(duration, function()
		if self._mobileHapticPulseId ~= pulseId then
			return
		end
		pcall(function()
			for _, target in ipairs(targets) do
				HapticService:SetMotor(target.inputType, target.motor, 0)
			end
		end)
	end)
end

function WeaponsGui:OnHitOtherPlayer(damage, humanoidHit, hitPart)
	if self.currentHitTween then self.currentHitTween:Cancel() end
	if self.currentFadeTween then self.currentFadeTween:Cancel() end
	local isHeadshot = hitPart and hitPart.Name == "Head"
	self:_pulseMobileHaptics(isHeadshot)
	-- W7: AnchorPoint solo se setea la primera vez (no cambia).
	if not self._hitMarkerAnchorSet then
		self.hitMarker.AnchorPoint = CENTER_ANCHOR_V2
		self._hitMarkerAnchorSet = true
	end
	self.hitMarker.Position = HIT_MARKER_CENTER_POS
	self.hitMarker.ImageTransparency = 0
	self.hitMarker.Size = UDim2.new(0.03, 0, 0, 0)
	self.hitMarker.ImageColor3 = HIT_COLOR_INITIAL
	self.hitMarker.Rotation = 0
	local minSize = 30
	local initialSize = math.max(self.hitMarker.AbsoluteSize.X, minSize)
	self.hitMarker.Size = UDim2.new(0, initialSize, 0, initialSize)
	local hitTweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
	local maxSize = math.max(self.hitMarker.AbsoluteSize.X * 2, minSize * 2)
	local hitGoal = { Size = UDim2.new(0, maxSize, 0, maxSize), ImageColor3 = HIT_COLOR_PEAK, Rotation = math.random(-15, 15) }
	self.currentHitTween = TweenService:Create(self.hitMarker, hitTweenInfo, hitGoal)
	self.currentHitTween:Play()
	local fadeTweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, 0.15)
	local midSize = math.max(maxSize * 0.75, minSize * 1.5)
	local fadeGoal = { Size = UDim2.new(0, midSize, 0, midSize), ImageTransparency = 1, ImageColor3 = HIT_COLOR_FADE, Rotation = 0 }
	self.currentFadeTween = TweenService:Create(self.hitMarker, fadeTweenInfo, fadeGoal)
	self.currentFadeTween:Play()
	self:_playLocalHitHighlight(humanoidHit)
	DamageBillboardHandler:ShowDamageBillboard(damage, humanoidHit.Parent:FindFirstChild("Head"), isHeadshot)
end

function WeaponsGui:onRenderStepped(dt)
	if not self._uiReady then
		self:onScreenSizeChanged()
		return
	end
	if not self.enabled or not self.gui then return end
	-- _hideDefaultJumpButton se llamaba aquí cada frame. Redundante: el
	-- listener instalado por _trackAndHideDefaultJumpButton (en setEnabled)
	-- ya re-oculta el botón si Roblox lo re-parenta. Llamadas restantes
	-- (setEnabled, setScopeEnabled, etc.) cubren state changes que mutan UI.
	self:_applyCrosshairByWeapon()
	-- W1: refresh solo cuando algo cambió. Antes _findMainSpecialTools +
	-- FindFirstChildOfClass por slot + .Text/.RichText writes cada frame.
	if self._hotbarDirty then
		self:_refreshHotbar()
	end
	self:_updateAmmoDisplay()
	-- W8: cache local. Antes self._isShotgun se releía 3× por frame.
	local isShotgun = self._isShotgun
	if isShotgun then
		if os.clock() >= (self._kickCooldownEnd or 0) then
			local want = self.isZoomed and self.crosshairSpreadAim or self.crosshairSpreadBase
			if math.abs(self.crosshairSpreadTarget - want) > 0.1 then
				self.crosshairSpreadTarget = want
				SpringService:Target(self, self.crosshairDampingRatio, self.crosshairFrequency, { crosshairSpread = want })
			end
		end
		if self.crosshairShotgunFrame and self.crosshairEnabled then
			local s = self.crosshairSpread
			if s ~= self._lastShotgunSpread then
				self._lastShotgunSpread = s
				self:_layoutShotgunCrosshairCorners()
			end
		end
		self:_updateShotgunRangeState()
	else
		if self.crosshairFrame and self.crosshairEnabled then
			local cs = self.crosshairScale * self.crosshairWeaponScale
			if cs ~= self._lastCrosshairComputedScale then
				self._lastCrosshairComputedScale = cs
				local crosshairSize = self.crosshairNormalSize * cs
				self.crosshairFrame.Size = UDim2.new(0, crosshairSize.X, 0, crosshairSize.Y)
			end
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

-- _dispatchTouchBegin garantiza que estos handlers sólo se llaman con un input
-- cuya posición de origen cae dentro del botón correspondiente. _dispatchTouchEnd
-- los llama a todos en End; cada uno filtra por su _activeXxxInput.

function WeaponsGui:onTouchAimButton(_button, inputObj, inputState)
	if inputState == Enum.UserInputState.Begin then
		if self._activeAimInput then return end
		self._activeAimInput = inputObj
	elseif inputState == Enum.UserInputState.End then
		if inputObj ~= self._activeAimInput then return end
		self._activeAimInput = nil
		self:setZoomed(not self.isZoomed)
	end
end

function WeaponsGui:onTouchFireButton(_button, inputObj, inputState)
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
	elseif inputState == Enum.UserInputState.End then
		if inputObj ~= self._activeFireInput then return end
		self:_stopTouchFire()
	end
end

function WeaponsGui:onTouchReloadButton(_button, inputObj, inputState)
	if inputState == Enum.UserInputState.Begin then
		self._activeReloadInput = inputObj
		self:_setReloadButtonsPressed(true)
		local currentWeapon = self.weaponsSystem.currentWeapon
		if currentWeapon and currentWeapon.instance and currentWeapon.instance:IsA("Tool") then
			if currentWeapon.onReloadAction then
				currentWeapon:onReloadAction("Reload", Enum.UserInputState.Begin, nil)
			end
		end
	elseif inputState == Enum.UserInputState.End then
		if inputObj ~= self._activeReloadInput then return end
		self._activeReloadInput = nil
		self:_setReloadButtonsPressed(false)
	end
end

function WeaponsGui:onTouchJumpButton(_button, inputObj, inputState)
	if inputState == Enum.UserInputState.Begin then
		self._activeJumpInput = inputObj
		self:_setJumpButtonsPressed(true)
		self:_tryJump()
	elseif inputState == Enum.UserInputState.End then
		if inputObj and self._activeJumpInput == inputObj then
			self._activeJumpInput = nil
			self:_setJumpButtonsPressed(false)
		end
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
		-- Reset owner/timer al ocultar — el siguiente reload arranca limpio.
		self._reloadProgressOwner = nil
		self._reloadProgressStartedAt = nil
	end
end

function WeaponsGui:playReloadProgressAnimation(reloadTime)
	-- Dedupe defensivo: si ya hay una animación corriendo iniciada hace muy
	-- poco (< 150ms) y para el mismo currentWeapon, ignorar. Esto previene
	-- restarts visuales por dos paths concurrentes (e.g., auto-reload + broadcast
	-- tardío del server, o Equipped + Activated ambos disparando reload).
	local currentWeapon = self.weaponsSystem and self.weaponsSystem.currentWeapon
	local now = os.clock()
	if self._isReloadProgressAnimating
		and self._reloadProgressOwner == currentWeapon
		and self._reloadProgressStartedAt
		and (now - self._reloadProgressStartedAt) < 0.15
	then
		return
	end
	self._reloadProgressStartedAt = now
	self._reloadProgressOwner = currentWeapon

	-- Limpiar antes de bumpear runId. Si lo hacemos al revés, el _stop interno
	-- vuelve a incrementar _reloadProgressRunId y deja stale el `runId` local
	-- que capturan los callbacks Changed/Completed → barra congelada en 0% y
	-- nunca se oculta al terminar.
	if self._reloadProgressTween or self._reloadProgressConnection then
		self:_stopReloadProgressAnimation(false)
	end

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

	progressValue.Value = 0

	-- Set constant style properties once per reload (not per tick)
	local frame1 = progressFrame:FindFirstChild("Frame1")
	local frame2 = progressFrame:FindFirstChild("Frame2")
	if frame1 and frame2 then
		local f1img = frame1:FindFirstChildOfClass("ImageLabel") or frame1
		local f2img = frame2:FindFirstChildOfClass("ImageLabel") or frame2
		local style = RELOAD_PROGRESS_STYLE
		local imageAsset = "rbxassetid://" .. style.ImageId
		for _, img in { f1img, f2img } do
			if img:IsA("ImageLabel") or img:IsA("ImageButton") then
				img.ImageColor3 = style.ImageColor
				img.ImageTransparency = style.ImageTrans
				img.Image = imageAsset
			end
		end
		local g1 = f1img:FindFirstChildOfClass("UIGradient")
		local g2 = f2img:FindFirstChildOfClass("UIGradient")
		if g1 and g2 then
			local cache = _reloadSeqCache
			if cache.colorSeq then
				g1.Color = cache.colorSeq
				g2.Color = cache.colorSeq
			end
			if cache.whiteColor then
				g1.Color = cache.whiteColor
				g2.Color = cache.whiteColor
			end
			if cache.transSeq then
				g1.Transparency = cache.transSeq
				g2.Transparency = cache.transSeq
			end
			if cache.zeroTrans then
				g1.Transparency = cache.zeroTrans
				g2.Transparency = cache.zeroTrans
			end
		end
	end

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
		self._reloadProgressOwner = nil
		self._reloadProgressStartedAt = nil
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

	local percentNumber = math.clamp(progressPercent * 3.6, 0, 360)

	g1.Rotation = (RELOAD_PROGRESS_STYLE.FlipProgress == false)
		and math.clamp(percentNumber, 180, 360)
		or 180 - math.clamp(percentNumber, 0, 180)
	g2.Rotation = (RELOAD_PROGRESS_STYLE.FlipProgress == false)
		and math.clamp(percentNumber, 0, 180)
		or 180 - math.clamp(percentNumber, 180, 360)
end

return WeaponsGui
