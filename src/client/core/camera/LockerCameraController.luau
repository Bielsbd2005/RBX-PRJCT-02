--!strict

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local APPROACH_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local DOF_APPLY_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DOF_RESET_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FOV_APPLY_TWEEN_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TRANSITION_OFFSET = CFrame.new(0, -2.25, 1.5)
local DEFAULT_FOCUS_DISTANCE = 16.66
local TARGET_DOF_FAR_INTENSITY = 0.55
local TARGET_DOF_IN_FOCUS_RADIUS = 9
local FOV_ENTRY_OFFSET = 8

export type LockerCameraController = {
	_camera: Camera,
	_targetPart: BasePart,
	_dof: DepthOfFieldEffect,
	_isApplied: boolean,
	_savedCameraType: Enum.CameraType?,
	_savedCameraSubject: Instance?,
	_savedCFrame: CFrame?,
	_savedFieldOfView: number?,
	_cameraApproachTween: Tween?,
	_dofTween: Tween?,
	_fovTween: Tween?,
	_dofFadeOutConnection: RBXScriptConnection?,
	apply: (self: LockerCameraController) -> (),
	restore: (self: LockerCameraController) -> (),
	Destroy: (self: LockerCameraController) -> (),
}

local LockerCameraController = {}
LockerCameraController.__index = LockerCameraController

local function resolveTargetPart(targetPartName: string): BasePart
	local camerasFolder = Workspace:WaitForChild("Cameras")
	local target = camerasFolder:WaitForChild(targetPartName)

	assert(target:IsA("BasePart"), string.format("Workspace.Cameras.%s must be a BasePart", targetPartName))
	return target
end

local function resolveDepthOfField(): DepthOfFieldEffect
	local existing = Lighting:FindFirstChild("ShowcaseDOF")
	if existing and existing:IsA("DepthOfFieldEffect") then
		return existing
	end

	local dof = Instance.new("DepthOfFieldEffect")
	dof.Name = "ShowcaseDOF"
	dof.Enabled = false
	dof.FarIntensity = 1
	dof.FocusDistance = DEFAULT_FOCUS_DISTANCE
	dof.InFocusRadius = 0
	dof.NearIntensity = 0
	dof.Parent = Lighting

	return dof
end

function LockerCameraController.new(targetPartName: string?): LockerCameraController
	local camera = Workspace.CurrentCamera
	assert(camera ~= nil, "CurrentCamera is not available")

	local self = setmetatable({}, LockerCameraController) :: any
	self._camera = camera :: Camera
	self._targetPart = resolveTargetPart(targetPartName or "locker")
	self._dof = resolveDepthOfField()
	self._isApplied = false
	self._savedCameraType = nil
	self._savedCameraSubject = nil
	self._savedCFrame = nil
	self._savedFieldOfView = nil
	self._cameraApproachTween = nil
	self._dofTween = nil
	self._fovTween = nil
	self._dofFadeOutConnection = nil

	return self
end

function LockerCameraController:_cancelActiveTweens()
	if self._cameraApproachTween then
		self._cameraApproachTween:Cancel()
		self._cameraApproachTween = nil
	end

	if self._dofTween then
		self._dofTween:Cancel()
		self._dofTween = nil
	end

	if self._fovTween then
		self._fovTween:Cancel()
		self._fovTween = nil
	end

	if self._dofFadeOutConnection then
		self._dofFadeOutConnection:Disconnect()
		self._dofFadeOutConnection = nil
	end
end

function LockerCameraController:_playEntryTweenSequence(targetCFrame: CFrame)
	self._camera.CFrame = targetCFrame * TRANSITION_OFFSET
	self._cameraApproachTween = TweenService:Create(self._camera, APPROACH_TWEEN_INFO, {
		CFrame = targetCFrame,
	})

	self._cameraApproachTween:Play()
end

function LockerCameraController:apply()
	self:_cancelActiveTweens()

	local targetCFrame = self._targetPart.CFrame
	local finalFov = self._savedFieldOfView or self._camera.FieldOfView
	local entryFov = math.min(finalFov + FOV_ENTRY_OFFSET, 90)

	self._dof.Enabled = true
	self._dof.FocusDistance = DEFAULT_FOCUS_DISTANCE
	self._dof.FarIntensity = 0
	self._dof.InFocusRadius = 0
	self._dof.NearIntensity = 0
	self._dofTween = TweenService:Create(self._dof, DOF_APPLY_TWEEN_INFO, {
		FarIntensity = TARGET_DOF_FAR_INTENSITY,
		InFocusRadius = TARGET_DOF_IN_FOCUS_RADIUS,
	})
	self._dofTween:Play()

	if self._isApplied then
		self._camera.CameraType = Enum.CameraType.Scriptable
		self._camera.FieldOfView = entryFov
		self._fovTween = TweenService:Create(self._camera, FOV_APPLY_TWEEN_INFO, {
			FieldOfView = finalFov,
		})
		self._fovTween:Play()
		self:_playEntryTweenSequence(targetCFrame)
		return
	end

	self._savedCameraType = self._camera.CameraType
	self._savedCameraSubject = self._camera.CameraSubject
	self._savedCFrame = self._camera.CFrame
	self._savedFieldOfView = self._camera.FieldOfView

	self._camera.CameraType = Enum.CameraType.Scriptable
	self._camera.FieldOfView = entryFov
	self._fovTween = TweenService:Create(self._camera, FOV_APPLY_TWEEN_INFO, {
		FieldOfView = finalFov,
	})
	self._fovTween:Play()
	self:_playEntryTweenSequence(targetCFrame)

	self._isApplied = true
end

function LockerCameraController:restore()
	if not self._isApplied then
		return
	end

	self:_cancelActiveTweens()

	self._dofTween = TweenService:Create(self._dof, DOF_RESET_TWEEN_INFO, {
		FarIntensity = 0,
		InFocusRadius = 0,
	})
	self._dofFadeOutConnection = self._dofTween.Completed:Connect(function()
		self._dof.Enabled = false
		self._dofFadeOutConnection = nil
	end)
	self._dofTween:Play()

	local player = Players.LocalPlayer
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil

	if self._savedFieldOfView ~= nil then
		self._camera.FieldOfView = self._savedFieldOfView
	end

	if self._savedCFrame ~= nil then
		self._camera.CFrame = self._savedCFrame
	end

	if self._savedCameraType ~= nil then
		self._camera.CameraType = self._savedCameraType
	else
		self._camera.CameraType = Enum.CameraType.Custom
	end

	if self._savedCameraSubject and self._savedCameraSubject.Parent then
		self._camera.CameraSubject = self._savedCameraSubject
	elseif humanoid then
		self._camera.CameraSubject = humanoid
	end

	self._savedCameraType = nil
	self._savedCameraSubject = nil
	self._savedCFrame = nil
	self._savedFieldOfView = nil
	self._isApplied = false
end

function LockerCameraController:Destroy()
	self:_cancelActiveTweens()

	self:restore()
end

return LockerCameraController
