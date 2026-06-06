--!strict
-- Crosshair.luau (Client/Server Library)
-- Gestiona la retícula de apuntado (estándar y escopeta) y la advertencia de fuera de rango.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared:WaitForChild("utils"):WaitForChild("TeamUtils"))

local WeaponsSystemFolder = script.Parent.Parent.Parent
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local SpringService = require(Libraries:WaitForChild("SpringService"))
local AutoAimSystem = require(Libraries:WaitForChild("AutoAimSystem"))

local CENTER_ANCHOR_V2 = Vector2.new(0.5, 0.5)
local SHOTGUN_RANGE_TICK_INTERVAL = 0.1

local Crosshair = {}
Crosshair.__index = Crosshair

function Crosshair.new(weaponsGui: any)
	local self = setmetatable({}, Crosshair)
	self.weaponsGui = weaponsGui

	self.dampingRatio = 0.9
	self.frequency = 3
	self.scaleTarget = 1
	self.scale = 1
	self.weaponScale = 1
	self.enabled = true
	self.isShotgun = false
	self.isOutOfRange = false

	self.spread = 0
	self.spreadTarget = 0
	self.spreadBase = 30
	self.spreadAim = 20
	self.spreadFireKick = 3
	self.shotgunDefaultOptimalRange = 30

	self._kickCooldownEnd = 0
	self._shotgunRangeLastTickAt = 0

	return self
end

function Crosshair:setup(scalingElementsFolder: Folder)
	self.frame = scalingElementsFolder:WaitForChild("Crosshair") :: GuiObject
	self.bottom = self.frame:WaitForChild("Bottom") :: GuiObject
	self.left = self.frame:WaitForChild("Left") :: GuiObject
	self.right = self.frame:WaitForChild("Right") :: GuiObject
	self.top = self.frame:WaitForChild("Top") :: GuiObject

	self.origScales = {
		[self.bottom] = Vector2.new(self.bottom.Size.X.Scale, self.bottom.Size.Y.Scale),
		[self.left] = Vector2.new(self.left.Size.X.Scale, self.left.Size.Y.Scale),
		[self.right] = Vector2.new(self.right.Size.X.Scale, self.right.Size.Y.Scale),
		[self.top] = Vector2.new(self.top.Size.X.Scale, self.top.Size.Y.Scale),
	}
	self.normalSize = self.frame.AbsoluteSize

	self.shotgunFrame = scalingElementsFolder:FindFirstChild("CrosshairShotgun") :: GuiObject?
	if self.shotgunFrame then
		self.shotgunTopLeft = self.shotgunFrame:WaitForChild("TopLeft") :: GuiObject
		self.shotgunTopRight = self.shotgunFrame:WaitForChild("TopRight") :: GuiObject
		self.shotgunBottomLeft = self.shotgunFrame:WaitForChild("BottomLeft") :: GuiObject
		self.shotgunBottomRight = self.shotgunFrame:WaitForChild("BottomRight") :: GuiObject
		self.shotgunFrame.Visible = false
	end

	self.outOfRangeFrame = scalingElementsFolder:FindFirstChild("OutOfRange") :: GuiObject?
	if self.outOfRangeFrame then
		self.outOfRangeFrame.Visible = false
		self.outOfRangeDistanceLabel = self.outOfRangeFrame:FindFirstChild("Distance") :: TextLabel?
	end
end

function Crosshair:setEnabled(enabled: boolean)
	self.enabled = enabled
	self:refreshVisibility()
end

function Crosshair:refreshVisibility()
	local shouldShow = self.enabled and not self.weaponsGui._isReloadProgressAnimating

	if self.frame then
		self.frame.Visible = shouldShow and not self.isShotgun
	end
	local shotgunInRange = self.isShotgun and not self.isOutOfRange
	if self.shotgunFrame then
		self.shotgunFrame.Visible = shouldShow and shotgunInRange
	end
	if self.outOfRangeFrame then
		self.outOfRangeFrame.Visible = shouldShow and self.isShotgun and self.isOutOfRange
	end
end

function Crosshair:setWeaponScale(scale: number)
	if self.weaponScale == scale then return end
	self.weaponScale = scale
end

function Crosshair:setScaleTarget(target: number, dampingRatio: number?, frequency: number?)
	if typeof(dampingRatio) == "number" then
		self.dampingRatio = dampingRatio
	end
	if typeof(frequency) == "number" then
		self.frequency = frequency
	end
	if self.scaleTarget == target then return end
	self.scaleTarget = target
	SpringService:Target(self, self.dampingRatio, self.frequency, { scale = self.scaleTarget })
end

function Crosshair:setScale(scale: number)
	if self.scale == scale then return end
	self.scale = scale
	SpringService:Target(self, self.dampingRatio, self.frequency, { scale = self.scaleTarget })
end

function Crosshair:setVariant(isShotgun: boolean)
	self.isShotgun = isShotgun
	self.isOutOfRange = false
	self:refreshVisibility()
	if self.isShotgun then
		self.weaponScale = 1
		self.spreadTarget = if self.weaponsGui.isZoomed then self.spreadAim else self.spreadBase
	else
		self.spreadTarget = 0
	end
	SpringService:Target(self, self.dampingRatio, self.frequency, { spread = self.spreadTarget })
end

function Crosshair:layoutShotgunCorners()
	if not (self.shotgunFrame and self.isShotgun) then return end
	local compScale = self.scale * self.weaponScale
	local s = self.spread * compScale
	local size = math.floor(self.normalSize.Y * 0.45 * compScale)
	if not self._shotgunAnchorsSet then
		self.shotgunTopLeft.AnchorPoint = CENTER_ANCHOR_V2
		self.shotgunTopRight.AnchorPoint = CENTER_ANCHOR_V2
		self.shotgunBottomLeft.AnchorPoint = CENTER_ANCHOR_V2
		self.shotgunBottomRight.AnchorPoint = CENTER_ANCHOR_V2
		self._shotgunAnchorsSet = true
	end
	self.shotgunTopLeft.Position = UDim2.new(0.5, -s, 0.5, -s)
	self.shotgunTopLeft.Size = UDim2.new(0, size, 0, size)
	self.shotgunTopRight.Position = UDim2.new(0.5, s, 0.5, -s)
	self.shotgunTopRight.Size = UDim2.new(0, size, 0, size)
	self.shotgunBottomLeft.Position = UDim2.new(0.5, -s, 0.5, s)
	self.shotgunBottomLeft.Size = UDim2.new(0, size, 0, size)
	self.shotgunBottomRight.Position = UDim2.new(0.5, s, 0.5, s)
	self.shotgunBottomRight.Size = UDim2.new(0, size, 0, size)
end

function Crosshair:kickShotgunSpread()
	if not self.isShotgun then return end
	local kick = self.spreadBase + self.spreadFireKick
	self.spreadTarget = kick
	SpringService:Target(self, 0.6, 5, { spread = self.spreadTarget })
	self._kickCooldownEnd = os.clock() + 0.12
	task.delay(0.06, function()
		self.spreadTarget = if self.weaponsGui.isZoomed then self.spreadAim else self.spreadBase
		SpringService:Target(self, 0.85, 4, { spread = self.spreadTarget })
	end)
end

function Crosshair:updateShotgunRangeState()
	if not self.isShotgun or not self.outOfRangeFrame then return end

	if not (UserInputService.TouchEnabled and not UserInputService.MouseEnabled) then
		if self.isOutOfRange then
			self.isOutOfRange = false
			self:refreshVisibility()
		end
		return
	end

	local now = os.clock()
	if now - self._shotgunRangeLastTickAt < SHOTGUN_RANGE_TICK_INTERVAL then return end
	self._shotgunRangeLastTickAt = now

	local camera = workspace.CurrentCamera
	if not camera then return end

	local weapon = self.weaponsGui.weaponsSystem.currentWeapon
	local tool = weapon and weapon.instance
	local optimalRange = self.shotgunDefaultOptimalRange
	if tool then
		local attr = tool:GetAttribute("OptimalRange")
		if type(attr) == "number" and attr > 0 then
			optimalRange = attr
		end
	end

	local outOfRange = false
	local distance: number? = nil

	local cameraCFrame = camera.CFrame
	local cameraOrigin = cameraCFrame.Position
	local cameraDir = cameraCFrame.LookVector

	local rayParams = self.weaponsGui._shotgunRangeParams
	if not rayParams then
		rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.IgnoreWater = true
		self.weaponsGui._shotgunRangeParams = rayParams
	end
	local filter = self.weaponsGui._shotgunRangeFilter
	if not filter then
		filter = table.create(2)
		self.weaponsGui._shotgunRangeFilter = filter
	end
	local n = 0
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		n += 1
		filter[n] = localPlayer.Character
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
			local localChar = localPlayer and localPlayer.Character
			local sameTeam = localChar and TeamUtils.isSameTeam(localChar, hitChar) or false
			if hum and hum.Health > 0 and not sameTeam and hitChar ~= localChar then
				distance = (result.Position - cameraOrigin).Magnitude
				outOfRange = distance > optimalRange
			end
		end
	end

	if outOfRange ~= self.isOutOfRange then
		self.isOutOfRange = outOfRange
		self:refreshVisibility()
	end

	if outOfRange and distance and self.outOfRangeDistanceLabel then
		local remaining = math.max(0, distance - optimalRange)
		local text = tostring(math.floor(remaining + 0.5))
		if text ~= self._lastOutOfRangeDistanceText then
			self._lastOutOfRangeDistanceText = text
			self.outOfRangeDistanceLabel.Text = text
		end
	end
end

function Crosshair:resize(viewportSize: Vector2)
	if not self.frame then return end

	local crosshairAbsoluteSize = self.frame.AbsoluteSize
	if crosshairAbsoluteSize.X <= 0 or crosshairAbsoluteSize.Y <= 0 then
		return
	end

	self.normalSize = crosshairAbsoluteSize
	self.bottom.Size = UDim2.new(0, self.origScales[self.bottom].X * self.normalSize.X, 0, self.origScales[self.bottom].Y * self.normalSize.Y)
	self.left.Size = UDim2.new(0, self.origScales[self.left].X * self.normalSize.X, 0, self.origScales[self.left].Y * self.normalSize.Y)
	self.right.Size = UDim2.new(0, self.origScales[self.right].X * self.normalSize.X, 0, self.origScales[self.right].Y * self.normalSize.Y)
	self.top.Size = UDim2.new(0, self.origScales[self.top].X * self.normalSize.X, 0, self.origScales[self.top].Y * self.normalSize.Y)
	
	if self.shotgunFrame then
		self:layoutShotgunCorners()
	end
end

function Crosshair:update(dt: number)
	if self.isShotgun then
		if os.clock() >= self._kickCooldownEnd then
			local want = if self.weaponsGui.isZoomed then self.spreadAim else self.spreadBase
			if math.abs(self.spreadTarget - want) > 0.1 then
				self.spreadTarget = want
				SpringService:Target(self, self.dampingRatio, self.frequency, { spread = want })
			end
		end
		if self.shotgunFrame and self.enabled then
			local s = self.spread
			local cs = self.scale
			if s ~= self._lastShotgunSpread or cs ~= self._lastShotgunScale then
				self._lastShotgunSpread = s
				self._lastShotgunScale = cs
				self:layoutShotgunCorners()
			end
		end
		self:updateShotgunRangeState()
	else
		if self.frame and self.enabled then
			local cs = self.scale * self.weaponScale
			if cs ~= self._lastCrosshairComputedScale then
				self._lastCrosshairComputedScale = cs
				local crosshairSize = self.normalSize * cs
				self.frame.Size = UDim2.new(0, crosshairSize.X, 0, crosshairSize.Y)
			end
		end
	end
end

return Crosshair
