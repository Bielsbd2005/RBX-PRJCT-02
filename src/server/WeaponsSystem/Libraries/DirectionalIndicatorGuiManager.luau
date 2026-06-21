local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DirectionalIndicatorGuiManager = {}
DirectionalIndicatorGuiManager.__index = DirectionalIndicatorGuiManager

-- W11: bucle único compartido para actualizar la rotación de todos los DIs
-- activos. Antes cada activación creaba su propio coroutine con
-- RenderStepped:Wait() (4 atacantes simultáneos = 4 loops paralelos en mobile).
-- Ahora un sólo RenderStepped:Connect itera _activeDIs y los retira cuando
-- la imagen alcanza ImageTransparency=1.
type ActiveDI = {
	manager: any,
	diInfo: any,
	otherPosition: Vector3,
}
local _activeDIs: { ActiveDI } = {}
local _diLoopConn: RBXScriptConnection? = nil

local function _diLoopTick()
	local i = 1
	while i <= #_activeDIs do
		local entry = _activeDIs[i]
		local diInfo = entry.diInfo
		local image = diInfo and diInfo.image
		if not image or image.ImageTransparency >= 1 or not diInfo.frame.Parent then
			if diInfo then
				diInfo.active = false
				if diInfo.dieOnFade and diInfo.frame and diInfo.frame.Parent then
					diInfo.frame:Destroy()
				end
			end
			local n = #_activeDIs
			_activeDIs[i] = _activeDIs[n]
			_activeDIs[n] = nil
		else
			diInfo.frame.Rotation = entry.manager:CalculateDIRotation(entry.otherPosition)
			i += 1
		end
	end

	if #_activeDIs == 0 and _diLoopConn then
		_diLoopConn:Disconnect()
		_diLoopConn = nil
	end
end

local function _ensureDILoop()
	if _diLoopConn then return end
	_diLoopConn = RunService.RenderStepped:Connect(_diLoopTick)
end

local function GetConfigValue(config, propertyName, default)
	if config then
		local property = config:FindFirstChild(propertyName)
		if property then
			return property.Value
		end
	end
	return default
end

function DirectionalIndicatorGuiManager.new(weaponsGui)
	local self = setmetatable({}, DirectionalIndicatorGuiManager)
	self.weaponsGui = weaponsGui
	self.connections = {}
	self.enabled = false

	-- Note DI is an abbreviation for DirectionalIndicator
	self.DIFolder = self.weaponsGui.scalingElementsFolder:WaitForChild("DirectionalIndicators")
	self.DIInfo = {}

	for _, DIFrame in ipairs(self.DIFolder:GetChildren()) do
		if DIFrame:IsA("Frame") and DIFrame:FindFirstChildOfClass("ImageLabel") then
			local config = DIFrame:FindFirstChildOfClass("Configuration")
			local name = GetConfigValue(config, "Name", DIFrame.Name)
			self.DIInfo[name] = self:GetDIInfoFromFrame(DIFrame)

			DIFrame.Visible = true
			self.DIInfo[name].image.ImageTransparency = 1
		end
	end

	return self
end

function DirectionalIndicatorGuiManager:GetDIInfoFromFrame(frame)
	local diInfo = {}
	diInfo.frame = frame
	diInfo.image = frame:FindFirstChildOfClass("ImageLabel")
	diInfo.config = frame:FindFirstChildOfClass("Configuration")
	diInfo.active = false
	diInfo.dieOnFade = false -- will only be true for copies of original DIs
	return diInfo
end

function DirectionalIndicatorGuiManager:ActivateDirectionalIndicator(DIName, otherPosition)
	-- Use original DI, or make a copy if it's already active
	local diInfo = self.DIInfo[DIName]
	if not diInfo then
		warn("Warning: invalid name given to ActivateDirectionalIndicator")
		return
	end

	if diInfo.active then
		local newFrame = diInfo.frame:Clone()
		newFrame.Parent = diInfo.frame.Parent
		diInfo = self:GetDIInfoFromFrame(newFrame)
		diInfo.dieOnFade = true
	end
	diInfo.active = true

	-- Update distance from center
	local distanceLevel = GetConfigValue(diInfo.config, "DistanceLevelFromCenter", 6)
	local widthLevel = GetConfigValue(diInfo.config, "WidthLevel", distanceLevel)
	local levelMultiplier = 0.03
	self.weaponsGui.originalScaleAmounts[diInfo.frame] = Vector2.new(widthLevel * levelMultiplier, distanceLevel * levelMultiplier * 2)
	self.weaponsGui:updateScale(diInfo.frame, workspace.CurrentCamera.ViewportSize)

	-- Set initial indicator rotation and transparency
	diInfo.frame.Rotation = self:CalculateDIRotation(otherPosition)
	diInfo.image.ImageTransparency = GetConfigValue(diInfo.config, "TransparencyBeforeFade", 0)

	-- W11: push al bucle único. La rotación se actualiza junto con todos los
	-- otros DIs activos en un solo RenderStepped global; cleanup ocurre cuando
	-- ImageTransparency llega a 1.
	_ensureDILoop()
	table.insert(_activeDIs, {
		manager = self,
		diInfo = diInfo,
		otherPosition = otherPosition,
	})

	-- Show indicator for a bit, then fade out
	coroutine.wrap(function()
		-- P8: task.wait en lugar del legacy wait() (era el único w() restante del repo).
		task.wait(GetConfigValue(diInfo.config, "TimeBeforeFade", 1))
		local tweenInfo = TweenInfo.new(GetConfigValue(diInfo.config, "FadeTime", 1))
		local goal = {}
		goal.ImageTransparency = 1
		local tween = TweenService:Create(diInfo.image, tweenInfo, goal)
		-- P8: destruir el clon en Tween.Completed en vez de depender solo del poll
		-- de transparencia. Si el frame se ocultara antes de que el loop lo viera
		-- (o el loop dejara de correr), el clon quedaría huérfano. dieOnFade marca
		-- los clones; los DIs originales se mantienen y solo se ocultan.
		tween.Completed:Once(function()
			diInfo.active = false
			if diInfo.dieOnFade and diInfo.frame and diInfo.frame.Parent then
				diInfo.frame:Destroy()
			end
		end)
		tween:Play()
	end)()
end

function DirectionalIndicatorGuiManager:CalculateDIRotation(otherPosition)
	if not otherPosition then
		return 0
	end

	local shoulderCamera = self.weaponsGui and self.weaponsGui.weaponsSystem and self.weaponsGui.weaponsSystem.camera
	local liveCamera = workspace.CurrentCamera
	local focusCFrame = nil
	local lookCFrame = nil

	if shoulderCamera then
		focusCFrame = shoulderCamera.currentCamera and shoulderCamera.currentCamera.Focus or nil
		lookCFrame = shoulderCamera.currentCFrame or nil
	end

	if not focusCFrame and liveCamera then
		focusCFrame = liveCamera.Focus
	end
	if not lookCFrame and liveCamera then
		lookCFrame = liveCamera.CFrame
	end

	if not focusCFrame or not lookCFrame then
		return 0
	end

	local localPlayerOffsetPositionXZ = Vector3.new(focusCFrame.X, 0, focusCFrame.Z)
	local otherPlayerPositionXZ = Vector3.new(otherPosition.X, 0, otherPosition.Z)
	local toOtherVector = localPlayerOffsetPositionXZ - otherPlayerPositionXZ
	local forwardVector = Vector3.new(lookCFrame.LookVector.X, 0, lookCFrame.LookVector.Z)

	local forward = if forwardVector.Magnitude > 0 then forwardVector.Unit else Vector3.new(0, 0, -1)
	local toOtherPlayer = if toOtherVector.Magnitude > 0 then toOtherVector.Unit else forward

	local dotProduct = math.clamp(forward:Dot(toOtherPlayer), -1, 1)
	local crossProduct = forward:Cross(toOtherPlayer)
	local acosAngle = math.deg(math.acos(dotProduct))
	local asinAngle = math.deg(math.asin(math.clamp(crossProduct.Y, -1, 1)))
	if asinAngle >= 0 then
		acosAngle = 360 - acosAngle
	end
	return acosAngle
end

return DirectionalIndicatorGuiManager
