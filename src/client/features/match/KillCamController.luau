--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local KillCamController = {}
KillCamController.__index = KillCamController

local CONFIG = {
	duration = 6,
	fadeInTime = 0.3,
	fadeOutTime = 0.35,
	initialHeight = 3,
	finalHeight = 6,
	rotationSpeed = 0.55,
	zoomDistance = 15,
	finalZoomDistance = 10,
	smoothness = 0.12,
	lookOffsetY = 2,
}

local function _resolveRootPartFromCharacter(character: Model?): BasePart?
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function _resolveCharacterRootByUserId(userId: number?): BasePart?
	if not userId then
		return nil
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return nil
	end
	return _resolveRootPartFromCharacter(player.Character)
end

local function _createFadeGui(playerGui: PlayerGui): (ScreenGui, Frame)
	local existing = playerGui:FindFirstChild("KillCamFade")
	if existing and existing:IsA("ScreenGui") then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "KillCamFade"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 10000
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Fade"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.ZIndex = 10000
	frame.Parent = screenGui

	return screenGui, frame
end

function KillCamController.new(playerGui: PlayerGui): any
	local self = setmetatable({}, KillCamController)
	self._player = Players.LocalPlayer
	self._playerGui = playerGui
	self._active = false
	self._renderConn = nil :: RBXScriptConnection?
	self._charConn = nil :: RBXScriptConnection?
	self._fadeGui = nil :: ScreenGui?
	self._fadeFrame = nil :: Frame?
	self._originalCameraType = nil :: Enum.CameraType?
	self._originalCameraSubject = nil :: Instance?
	return self
end

function KillCamController:_ensureFade()
	if self._fadeGui and self._fadeFrame and self._fadeGui.Parent then
		return
	end
	local gui, frame = _createFadeGui(self._playerGui)
	self._fadeGui = gui
	self._fadeFrame = frame
end

function KillCamController:_playFade(toTransparency: number, duration: number)
	self:_ensureFade()
	if not self._fadeFrame then
		return
	end
	local tween = TweenService:Create(self._fadeFrame, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = toTransparency,
	})
	tween:Play()
end

function KillCamController:start(data: { killerUserId: string, killerName: string, weaponName: string }?)
	if self._active then
		self:stop()
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	self._active = true
	self._originalCameraType = camera.CameraType
	self._originalCameraSubject = camera.CameraSubject

	local killerUserId = if data and data.killerUserId ~= "" then tonumber(data.killerUserId) else nil
	local focusRoot = _resolveCharacterRootByUserId(killerUserId)
	if not focusRoot then
		focusRoot = _resolveRootPartFromCharacter(self._player.Character)
	end
	if not focusRoot then
		self._active = false
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	self:_playFade(0, CONFIG.fadeInTime)
	task.delay(CONFIG.fadeInTime, function()
		if not self._active then
			return
		end
		self:_playFade(1, CONFIG.fadeOutTime)
	end)

	local startAt = time()
	local angle = 0
	local currentCameraPos = camera.CFrame.Position

	if self._charConn then
		self._charConn:Disconnect()
		self._charConn = nil
	end
	self._charConn = self._player.CharacterAdded:Connect(function()
		self:stop()
	end)

	self._renderConn = RunService.RenderStepped:Connect(function(dt)
		if not self._active then
			return
		end

		if focusRoot and focusRoot.Parent == nil then
			focusRoot = _resolveRootPartFromCharacter(self._player.Character)
			if not focusRoot then
				self:stop()
				return
			end
		end

		local elapsed = time() - startAt
		local progress = math.clamp(elapsed / CONFIG.duration, 0, 1)
		local currentHeight = CONFIG.initialHeight + (CONFIG.finalHeight - CONFIG.initialHeight) * progress
		local currentZoom = CONFIG.zoomDistance + (CONFIG.finalZoomDistance - CONFIG.zoomDistance) * progress
		angle += CONFIG.rotationSpeed * dt

		local pivot = focusRoot.Position
		local targetPos = pivot + Vector3.new(math.sin(angle) * currentZoom, currentHeight, math.cos(angle) * currentZoom)
		currentCameraPos = currentCameraPos:Lerp(targetPos, CONFIG.smoothness)
		camera.CFrame = CFrame.lookAt(currentCameraPos, pivot + Vector3.new(0, CONFIG.lookOffsetY, 0))

		if elapsed >= CONFIG.duration then
			self:stop()
		end
	end)
end

function KillCamController:stop()
	if not self._active then
		return
	end

	self._active = false

	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end
	if self._charConn then
		self._charConn:Disconnect()
		self._charConn = nil
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = self._originalCameraType or Enum.CameraType.Custom
		local character = self._player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid then
			camera.CameraSubject = humanoid
		elseif self._originalCameraSubject then
			camera.CameraSubject = self._originalCameraSubject
		end
	end

	if self._fadeGui then
		self._fadeGui:Destroy()
		self._fadeGui = nil
		self._fadeFrame = nil
	end
end

function KillCamController:Destroy()
	self:stop()
end

return KillCamController
