--!strict
-- MobileControls.luau (Client/Server Library)
-- Gestiona los controles táctiles para dispositivos móviles (Aim, Fire, Reload, Jump).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local ACTIVE_BUTTON_COLOR = Color3.fromRGB(0, 170, 255)
local ACTIVE_BUTTON_TRANSPARENCY = 0
local INACTIVE_BUTTON_TRANSPARENCY = 0.5

local MobileControls = {}
MobileControls.__index = MobileControls

local getJumpButton = function()
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

function MobileControls.new(weaponsGui: any)
	local self = setmetatable({}, MobileControls)
	self.weaponsGui = weaponsGui

	self._isFirePressed = false
	self._isReloadPressed = false
	self._isJumpPressed = false

	self._activeAimInput = nil
	self._activeFireInput = nil
	self._activeReloadInput = nil
	self._activeJumpInput = nil

	self._activeFireInputConn = nil
	self._touchGuiConn = nil
	self._playerGuiConn = nil

	return self
end

function MobileControls:setup(gui: ScreenGui)
	self.gui = gui
	self.smallTouchscreen = gui:WaitForChild("SmallTouchscreen") :: GuiObject
	self.largeTouchscreen = gui:WaitForChild("LargeTouchscreen") :: GuiObject

	self.smallAimButton = self.smallTouchscreen:WaitForChild("AimButton") :: GuiButton
	self.smallAimButton:SetAttribute("NoClickSound", true)
	self.largeAimButton = self.largeTouchscreen:WaitForChild("AimButton") :: GuiButton
	self.largeAimButton:SetAttribute("NoClickSound", true)

	self.smallFireButton = self.smallTouchscreen:WaitForChild("FireButton") :: GuiButton
	self.smallFireButton:SetAttribute("NoClickSound", true)
	self.largeFireButton = self.largeTouchscreen:WaitForChild("FireButton") :: GuiButton
	self.largeFireButton:SetAttribute("NoClickSound", true)

	self.smallReloadButton = self.smallTouchscreen:WaitForChild("ReloadButton") :: GuiButton
	self.smallReloadButton:SetAttribute("NoClickSound", true)
	self.largeReloadButton = self.largeTouchscreen:WaitForChild("ReloadButton") :: GuiButton
	self.largeReloadButton:SetAttribute("NoClickSound", true)

	self.smallJumpButton = self.smallTouchscreen:FindFirstChild("JumpButton") :: GuiButton?
	if self.smallJumpButton then
		self.smallJumpButton.Active = true
		self.smallJumpButton:SetAttribute("NoClickSound", true)
	end
	self.largeJumpButton = self.largeTouchscreen:FindFirstChild("JumpButton") :: GuiButton?
	if self.largeJumpButton then
		self.largeJumpButton.Active = true
		self.largeJumpButton:SetAttribute("NoClickSound", true)
	end

	self.smallFireButton.Visible = UserInputService.TouchEnabled
	self.largeFireButton.Visible = UserInputService.TouchEnabled
	self.smallReloadButton.Visible = UserInputService.TouchEnabled
	self.largeReloadButton.Visible = UserInputService.TouchEnabled
	self:setJumpButtonsVisible(true)
	self:trackAndHideDefaultJumpButton()

	self:refreshTouchButtonsVisuals()
end

function MobileControls:_getInactiveButtonColor()
	if self.weaponsGui.scopeEnabled then
		return Color3.fromRGB(255, 255, 255)
	end
	return Color3.fromRGB(0, 0, 0)
end

function MobileControls:_setButtonVisual(button: GuiButton?, isActive: boolean)
	if not button then return end
	button.ImageColor3 = if isActive then ACTIVE_BUTTON_COLOR else self:_getInactiveButtonColor()
	button.ImageTransparency = if isActive then ACTIVE_BUTTON_TRANSPARENCY else INACTIVE_BUTTON_TRANSPARENCY
end

function MobileControls:_isInsideButton(pos: Vector3, button: GuiButton?): boolean
	if not pos or not button or not button.Visible then return false end
	local parent = button.Parent
	if parent and parent:IsA("GuiObject") and not parent.Visible then return false end
	local abs = button.AbsolutePosition
	local size = button.AbsoluteSize
	return pos.X >= abs.X and pos.X <= abs.X + size.X
		and pos.Y >= abs.Y and pos.Y <= abs.Y + size.Y
end

function MobileControls:dispatchTouchBegin(input: InputObject)
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

function MobileControls:dispatchTouchEnd(input: InputObject)
	self:onTouchAimButton(nil, input, Enum.UserInputState.End)
	self:onTouchFireButton(nil, input, Enum.UserInputState.End)
	self:onTouchReloadButton(nil, input, Enum.UserInputState.End)
	self:onTouchJumpButton(nil, input, Enum.UserInputState.End)
end

function MobileControls:onTouchAimButton(_button: GuiButton?, inputObj: InputObject, inputState: Enum.UserInputState)
	if inputState == Enum.UserInputState.Begin then
		if self._activeAimInput then return end
		self._activeAimInput = inputObj
	elseif inputState == Enum.UserInputState.End then
		if inputObj ~= self._activeAimInput then return end
		self._activeAimInput = nil
		self.weaponsGui:setZoomed(not self.weaponsGui.isZoomed)
	end
end

function MobileControls:onTouchFireButton(_button: GuiButton?, inputObj: InputObject, inputState: Enum.UserInputState)
	if inputObj and self._activeJumpInput and inputObj == self._activeJumpInput then
		return
	end
	if inputState == Enum.UserInputState.Begin then
		if self._activeFireInput and self._activeFireInput ~= inputObj then
			return
		end
		if self.weaponsGui.crosshair and self.weaponsGui.crosshair.isShotgun then
			self.weaponsGui.crosshair:kickShotgunSpread()
		end
		local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
		if currentWeapon and currentWeapon.instance and currentWeapon.instance:IsA("Tool") then
			currentWeapon.instance:Activate()
		end
		self:_disconnectActiveFireInput()
		self._activeFireInput = inputObj
		self._activeFireInputConn = inputObj:GetPropertyChangedSignal("UserInputState"):Connect(function()
			if inputObj.UserInputState == Enum.UserInputState.End or inputObj.UserInputState == Enum.UserInputState.Cancel then
				self:stopTouchFire()
			end
		end)
		self:setFireButtonsPressed(true)
	elseif inputState == Enum.UserInputState.End then
		if inputObj ~= self._activeFireInput then return end
		self:stopTouchFire()
	end
end

function MobileControls:onTouchReloadButton(_button: GuiButton?, inputObj: InputObject, inputState: Enum.UserInputState)
	if inputState == Enum.UserInputState.Begin then
		self._activeReloadInput = inputObj
		self:setReloadButtonsPressed(true)
		local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
		if currentWeapon and currentWeapon.instance and currentWeapon.instance:IsA("Tool") then
			if currentWeapon.onReloadAction then
				currentWeapon:onReloadAction("Reload", Enum.UserInputState.Begin, nil)
			end
		end
	elseif inputState == Enum.UserInputState.End then
		if inputObj ~= self._activeReloadInput then return end
		self._activeReloadInput = nil
		self:setReloadButtonsPressed(false)
	end
end

function MobileControls:onTouchJumpButton(_button: GuiButton?, inputObj: InputObject, inputState: Enum.UserInputState)
	if inputState == Enum.UserInputState.Begin then
		self._activeJumpInput = inputObj
		self:setJumpButtonsPressed(true)
		self:_tryJump()
	elseif inputState == Enum.UserInputState.End then
		if inputObj ~= self._activeJumpInput then return end
		self._activeJumpInput = nil
		self:setJumpButtonsPressed(false)
	end
end

function MobileControls:_tryJump()
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

function MobileControls:setFireButtonsPressed(isPressed: boolean)
	self._isFirePressed = isPressed
	self:_setButtonVisual(self.smallFireButton, isPressed)
	self:_setButtonVisual(self.largeFireButton, isPressed)
end

function MobileControls:setReloadButtonsPressed(isPressed: boolean)
	self._isReloadPressed = isPressed
	self:_setButtonVisual(self.smallReloadButton, isPressed)
	self:_setButtonVisual(self.largeReloadButton, isPressed)
end

-- Fix selene parameter name to match the implementation
function MobileControls:setJumpButtonsPressed(isPressed: boolean)
	self._isJumpPressed = isPressed
	self:_setButtonVisual(self.smallJumpButton, isPressed)
	self:_setButtonVisual(self.largeJumpButton, isPressed)
end

function MobileControls:_disconnectActiveFireInput()
	if self._activeFireInputConn then
		self._activeFireInputConn:Disconnect()
		self._activeFireInputConn = nil
	end
	self._activeFireInput = nil
end

function MobileControls:stopTouchFire()
	local currentWeapon = self.weaponsGui.weaponsSystem.currentWeapon
	if currentWeapon and currentWeapon.instance and currentWeapon.instance:IsA("Tool") then
		currentWeapon.instance:Deactivate()
	end
	self:setFireButtonsPressed(false)
	self:_disconnectActiveFireInput()
end

function MobileControls:setJumpButtonsVisible(isVisible: boolean)
	local visible = UserInputService.TouchEnabled and isVisible
	if self.smallJumpButton then self.smallJumpButton.Visible = visible end
	if self.largeJumpButton then self.largeJumpButton.Visible = visible end
end

function MobileControls:updateAimButtonsVisual()
	self:_setButtonVisual(self.smallAimButton, self.weaponsGui.isZoomed)
	self:_setButtonVisual(self.largeAimButton, self.weaponsGui.isZoomed)
end

function MobileControls:refreshTouchButtonsVisuals()
	self:updateAimButtonsVisual()
	self:setFireButtonsPressed(self._isFirePressed)
	self:setReloadButtonsPressed(self._isReloadPressed)
	self:setJumpButtonsPressed(self._isJumpPressed)
end

function MobileControls:_hideDefaultJumpButton()
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

function MobileControls:trackAndHideDefaultJumpButton()
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

function MobileControls:Destroy()
	self:_disconnectActiveFireInput()
	if self._touchGuiConn then
		self._touchGuiConn:Disconnect()
		self._touchGuiConn = nil
	end
	if self._playerGuiConn then
		self._playerGuiConn:Disconnect()
		self._playerGuiConn = nil
	end
end

return MobileControls
