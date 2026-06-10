--!strict

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

-- Travelling entre cámaras del locker (entrada, cambio de pestaña y salida): la
-- cámara se desplaza desde su posición actual hasta el target con ease-in-out.
local MOVE_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local WRAP_ZOOM_TWEEN_INFO = TweenInfo.new(0.85, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

export type LockerCameraController = {
	_camera: Camera,
	_targetPart: BasePart,
	_isApplied: boolean,
	_savedCameraType: Enum.CameraType?,
	_savedCameraSubject: Instance?,
	_savedCFrame: CFrame?,
	_savedFieldOfView: number?,
	_cameraApproachTween: Tween?,
	_fovTween: Tween?,
	_cameraApproachCompletedConnection: RBXScriptConnection?,
	setTargetPartName: (self: LockerCameraController, targetPartName: string) -> (),
	zoomOnPosition: (self: LockerCameraController, targetPosition: Vector3) -> (),
	unzoom: (self: LockerCameraController) -> (),
	apply: (self: LockerCameraController) -> (),
	restore: (self: LockerCameraController, animated: boolean?) -> (),
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

	local self = setmetatable({}, LockerCameraController) :: any
	self._camera = camera :: Camera
	self._targetPart = resolveTargetPart(targetPartName or "locker")
	self._isApplied = false
	self._savedCameraType = nil
	self._savedCameraSubject = nil
	self._savedCFrame = nil
	self._savedFieldOfView = nil
	self._cameraApproachTween = nil
	self._fovTween = nil
	self._cameraApproachCompletedConnection = nil

	return self
end

function LockerCameraController:_cancelActiveTweens()
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

-- Cambia la cámara objetivo. Si el locker ya está aplicado, hace un travelling
-- desde la posición actual hasta el nuevo target (mismo movimiento que la entrada).
function LockerCameraController:setTargetPartName(targetPartName: string)
	local nextTargetPart = resolveTargetPart(targetPartName)
	if self._targetPart == nextTargetPart then
		return
	end

	self._targetPart = nextTargetPart

	if self._isApplied then
		self:apply()
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

	local finalFov = self._savedFieldOfView or self._camera.FieldOfView
	self._fovTween = TweenService:Create(self._camera, WRAP_ZOOM_TWEEN_INFO, {
		FieldOfView = math.clamp(finalFov - 6, 20, 90)
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

	local finalFov = self._savedFieldOfView or 70
	self._fovTween = TweenService:Create(self._camera, WRAP_ZOOM_TWEEN_INFO, {
		FieldOfView = finalFov
	})

	self._cameraApproachTween:Play()
	self._fovTween:Play()
end

-- Desplaza la cámara (travelling) hasta el target actual. La primera vez (al abrir)
-- guarda el estado de cámara previo y enciende la DOF; en llamadas posteriores
-- (cambio de pestaña) solo desplaza, sin re-tocar la DOF para que no parpadee.
function LockerCameraController:apply()
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

	self._cameraApproachTween = TweenService:Create(self._camera, MOVE_TWEEN_INFO, {
		CFrame = self._targetPart.CFrame,
	})
	self._cameraApproachTween:Play()
end

-- Restaura el estado de cámara previo a entrar al locker. Con `animated`, la cámara
-- hace un travelling de vuelta hasta la posición guardada y solo al terminar se
-- restaura el tipo/subject de cámara; sin él, la restauración es instantánea.
function LockerCameraController:restore(animated: boolean?)
	if not self._isApplied then
		return
	end

	self:_cancelActiveTweens()

	local savedCFrame = self._savedCFrame
	local savedFieldOfView = self._savedFieldOfView

	-- Restaura tipo/subject de cámara y limpia el estado guardado. `_isApplied` se
	-- mantiene true hasta aquí para que el estado guardado (la cámara del lobby) no
	-- se pierda si algo re-aplica durante el travelling.
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
		self._camera.CameraType = Enum.CameraType.Scriptable
		if savedFieldOfView ~= nil then
			self._fovTween = TweenService:Create(self._camera, MOVE_TWEEN_INFO, {
				FieldOfView = savedFieldOfView,
			})
			self._fovTween:Play()
		end
		self._cameraApproachTween = TweenService:Create(self._camera, MOVE_TWEEN_INFO, {
			CFrame = savedCFrame,
		})
		self._cameraApproachCompletedConnection = self._cameraApproachTween.Completed:Connect(function(playbackState)
			-- `Cancel()` también dispara Completed (estado Cancelled). Si el travelling
			-- se interrumpe NO finalizamos: el estado guardado (la cámara del menú) debe
			-- conservarse para quien retome el control, y no restauramos tipo/subject a
			-- medias.
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
