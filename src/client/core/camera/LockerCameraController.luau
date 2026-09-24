--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

-- Seguimiento del cuerpo en el preview de kill effects: la cámara cabecea hacia
-- arriba una fracción de lo que sube el cuerpo, con tope; nunca baja del encuadre base.
local FOLLOW_RENDER_STEP_NAME = "LockerCameraSubjectFollow"
local FOLLOW_RATIO = 0.55 -- fracción del ángulo que sube el cuerpo que acompaña la cámara
local FOLLOW_MAX_PITCH = math.rad(16) -- tope de cabeceo hacia arriba
local FOLLOW_SMOOTHING = 5 -- 1/s; más alto = sigue más pegado
local FOLLOW_REST_EPSILON = math.rad(0.05)

local function getElevation(from: Vector3, to: Vector3): number
	local offset = to - from
	return math.atan2(offset.Y, Vector3.new(offset.X, 0, offset.Z).Magnitude)
end

local MOVE_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local WRAP_ZOOM_TWEEN_INFO = TweenInfo.new(0.85, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local LOCKER_FIELD_OF_VIEW = 70

-- Claves = nombres de las Parts en Workspace.Cameras.
local TARGET_CONFIG: {
	[string]: {
		fov: number,
	},
} = {
	character = {
		fov = 40,
	},
	killEffects = {
		fov = 66,
	},
}

local function getTargetFov(targetPartName: string?): number
	if targetPartName then
		local config = TARGET_CONFIG[targetPartName]
		if config then
			return config.fov
		end
	end
	return LOCKER_FIELD_OF_VIEW
end

export type LockerCameraController = {
	_camera: Camera,
	_targetPart: BasePart,
	_targetPartName: string,
	_isApplied: boolean,
	_savedCameraType: Enum.CameraType?,
	_savedCameraSubject: Instance?,
	_savedCFrame: CFrame?,
	_savedFieldOfView: number?,
	_cameraApproachTween: Tween?,
	_fovTween: Tween?,
	_cameraApproachCompletedConnection: RBXScriptConnection?,
	_followSubject: BasePart?,
	_followStartElevation: number,
	_followPitch: number,
	_followBound: boolean,
	followSubject: (self: LockerCameraController, subject: BasePart?) -> (),
	setTargetPartName: (
		self: LockerCameraController,
		targetPartName: string,
		instant: boolean?,
		tweenInfo: TweenInfo?
	) -> (),
	zoomOnPosition: (self: LockerCameraController, targetPosition: Vector3) -> (),
	unzoom: (self: LockerCameraController) -> (),
	apply: (self: LockerCameraController, instant: boolean?, tweenInfo: TweenInfo?) -> (),
	restore: (self: LockerCameraController, animated: boolean?, tweenInfo: TweenInfo?) -> (),
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

function LockerCameraController.new(targetPartName: string?): LockerCameraController
	local camera = Workspace.CurrentCamera
	assert(camera ~= nil, "CurrentCamera is not available")

	local actualTargetName = targetPartName or "locker"
	local self = setmetatable({}, LockerCameraController) :: any
	self._camera = camera :: Camera
	self._targetPart = resolveTargetPart(actualTargetName)
	self._targetPartName = actualTargetName
	self._isApplied = false
	self._savedCameraType = nil
	self._savedCameraSubject = nil
	self._savedCFrame = nil
	self._savedFieldOfView = nil
	self._cameraApproachTween = nil
	self._fovTween = nil
	self._cameraApproachCompletedConnection = nil
	self._followSubject = nil
	self._followStartElevation = 0
	self._followPitch = 0
	self._followBound = false

	return self
end

function LockerCameraController:_stopFollow()
	if self._followBound then
		RunService:UnbindFromRenderStep(FOLLOW_RENDER_STEP_NAME)
		self._followBound = false
	end
	self._followSubject = nil
	self._followPitch = 0
end

function LockerCameraController:_stepFollow(dt: number)
	-- Travelling en curso (p. ej. clic durante la entrada a esta cámara): no se
	-- pisa; el seguimiento retoma cuando termina.
	local approach = self._cameraApproachTween
	if approach and approach.PlaybackState == Enum.PlaybackState.Playing then
		return
	end

	local base = self._targetPart.CFrame
	local subject = self._followSubject
	local hasSubject = subject ~= nil and subject.Parent ~= nil

	local targetPitch = 0
	if hasSubject then
		local rise = getElevation(base.Position, (subject :: BasePart).Position) - self._followStartElevation
		targetPitch = math.clamp(rise * FOLLOW_RATIO, 0, FOLLOW_MAX_PITCH)
	end

	self._followPitch += (targetPitch - self._followPitch) * (1 - math.exp(-FOLLOW_SMOOTHING * dt))

	if not hasSubject and self._followPitch < FOLLOW_REST_EPSILON then
		self._camera.CFrame = base
		self:_stopFollow()
		return
	end

	self._camera.CFrame = base * CFrame.Angles(self._followPitch, 0, 0)
end

-- La cámara acompaña ligeramente hacia arriba a `subject` (el cuerpo del kill
-- effect), tomando como referencia su altura en el momento de la llamada: hay que
-- llamarla ANTES de que el efecto lo mueva. `nil` suelta el sujeto y la cámara
-- vuelve suave a su encuadre. Cualquier travelling (apply/zoom/restore) corta el
-- seguimiento en seco.
function LockerCameraController:followSubject(subject: BasePart?)
	if not self._isApplied then
		return
	end

	self._followSubject = subject
	if not subject then
		return
	end

	self._followStartElevation = getElevation(self._targetPart.Position, subject.Position)
	if self._followBound then
		return
	end
	self._followBound = true
	RunService:BindToRenderStep(FOLLOW_RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_stepFollow(dt)
	end)
end

function LockerCameraController:_cancelActiveTweens()
	self:_stopFollow()

	if self._cameraApproachTween then
		self._cameraApproachTween:Cancel()
		self._cameraApproachTween = nil
	end

	if self._cameraApproachCompletedConnection then
		self._cameraApproachCompletedConnection:Disconnect()
		self._cameraApproachCompletedConnection = nil
	end

	if self._fovTween then
		self._fovTween:Cancel()
		self._fovTween = nil
	end
end

-- `instant`: salto de golpe, para quien tape el corte con un fundido a negro.
-- `tweenInfo` sustituye al travelling por defecto.
function LockerCameraController:setTargetPartName(targetPartName: string, instant: boolean?, tweenInfo: TweenInfo?)
	local nextTargetPart = resolveTargetPart(targetPartName)
	if self._targetPart == nextTargetPart and self._targetPartName == targetPartName then
		return
	end

	self._targetPart = nextTargetPart
	self._targetPartName = targetPartName

	if self._isApplied then
		self:apply(instant, tweenInfo)
	end
end

function LockerCameraController:zoomOnPosition(targetPosition: Vector3)
	if not self._isApplied then return end

	self:_cancelActiveTweens()

	local currentBase = self._targetPart.CFrame
	local lookCFrame = CFrame.lookAt(currentBase.Position, targetPosition)
	local distance = (currentBase.Position - targetPosition).Magnitude
	local zoomCFrame = lookCFrame + lookCFrame.LookVector * (distance * 0.3)
	zoomCFrame = zoomCFrame + lookCFrame.RightVector * 2

	self._cameraApproachTween = TweenService:Create(self._camera, WRAP_ZOOM_TWEEN_INFO, {
		CFrame = zoomCFrame
	})

	local baseFov = getTargetFov(self._targetPartName)
	self._fovTween = TweenService:Create(self._camera, WRAP_ZOOM_TWEEN_INFO, {
		FieldOfView = math.clamp(baseFov - 6, 20, 90)
	})

	self._cameraApproachTween:Play()
	self._fovTween:Play()
end

function LockerCameraController:unzoom()
	if not self._isApplied then return end

	self:_cancelActiveTweens()

	local targetCFrame = self._targetPart.CFrame

	self._cameraApproachTween = TweenService:Create(self._camera, WRAP_ZOOM_TWEEN_INFO, {
		CFrame = targetCFrame
	})

	local baseFov = getTargetFov(self._targetPartName)
	self._fovTween = TweenService:Create(self._camera, WRAP_ZOOM_TWEEN_INFO, {
		FieldOfView = baseFov
	})

	self._cameraApproachTween:Play()
	self._fovTween:Play()
end

-- Solo la primera llamada guarda el estado de cámara previo. `instant` es para quien
-- tapa el corte con un fundido a negro (un travelling ahí sería espera en negro).
function LockerCameraController:apply(instant: boolean?, tweenInfo: TweenInfo?)
	self:_cancelActiveTweens()

	if not self._isApplied then
		self._savedCameraType = self._camera.CameraType
		self._savedCameraSubject = self._camera.CameraSubject
		self._savedCFrame = self._camera.CFrame
		self._savedFieldOfView = self._camera.FieldOfView
		self._isApplied = true
	end

	-- Siempre (no solo la primera vez): si una restauración anterior quedó a medias
	-- la cámara podría seguir en Custom y el tween de CFrame no movería nada.
	self._camera.CameraType = Enum.CameraType.Scriptable

	local targetFov = getTargetFov(self._targetPartName)

	if instant then
		self._camera.CFrame = self._targetPart.CFrame
		self._camera.FieldOfView = targetFov
		return
	end

	local info = tweenInfo or MOVE_TWEEN_INFO
	self._cameraApproachTween = TweenService:Create(self._camera, info, {
		CFrame = self._targetPart.CFrame,
	})
	self._fovTween = TweenService:Create(self._camera, info, {
		FieldOfView = targetFov,
	})

	self._cameraApproachTween:Play()
	self._fovTween:Play()
end

-- Con `animated`, el tipo/subject de cámara solo se restaura al terminar el travelling.
function LockerCameraController:restore(animated: boolean?, tweenInfo: TweenInfo?)
	if not self._isApplied then
		return
	end

	self:_cancelActiveTweens()

	local savedCFrame = self._savedCFrame
	local savedFieldOfView = self._savedFieldOfView

	-- `_isApplied` sigue true hasta aquí para que el estado guardado (la cámara del
	-- lobby) no se pierda si algo re-aplica durante el travelling.
	local function finalizeRestore()
		local player = Players.LocalPlayer
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil

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

	if animated and savedCFrame ~= nil then
		local info = tweenInfo or MOVE_TWEEN_INFO
		self._camera.CameraType = Enum.CameraType.Scriptable
		if savedFieldOfView ~= nil then
			self._fovTween = TweenService:Create(self._camera, info, {
				FieldOfView = savedFieldOfView,
			})
			self._fovTween:Play()
		end
		self._cameraApproachTween = TweenService:Create(self._camera, info, {
			CFrame = savedCFrame,
		})
		self._cameraApproachCompletedConnection = self._cameraApproachTween.Completed:Connect(function(playbackState)
			-- `Cancel()` también dispara Completed: si se interrumpe NO finalizamos, el
			-- estado guardado debe conservarse para quien retome el control.
			if playbackState ~= Enum.PlaybackState.Completed then
				return
			end
			self._cameraApproachCompletedConnection = nil
			finalizeRestore()
		end)
		self._cameraApproachTween:Play()
		return
	end

	if savedFieldOfView ~= nil then
		self._camera.FieldOfView = savedFieldOfView
	end
	if savedCFrame ~= nil then
		self._camera.CFrame = savedCFrame
	end
	finalizeRestore()
end

function LockerCameraController:Destroy()
	self:_cancelActiveTweens()

	self:restore()
end

return LockerCameraController
