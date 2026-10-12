--!strict
--[[
	Cámara del flujo de partida: lobby, gameplay, reintentos con delays y la
	cinemática de la pantalla de Resultados.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local Client = script.Parent.Parent.Parent
local CameraLock = require(Client.core.camera.CameraLock)
local ResultsScene = require(script.Parent.ResultsScene)

local INTRO_DURATION = 1.5           -- duración de la entrada (s)
local DOLLY_BACK = 14                -- studs que arranca por detrás (dolly hacia delante)
local TRUCK_SIDE = 7                 -- studs que arranca a un lado: la entrada describe un arco
local TILT_DEG = 16                  -- pitch inicial que se asienta
local ROLL_DEG = 10                  -- inclinación lateral (dutch) inicial que se endereza
local FOV_PUNCH = 18                 -- FOV extra al inicio → zoom-in que se asienta
-- Tilt y roll terminan antes que el recorrido: el final es solo un empuje recto.
local ROTATION_SETTLE = 0.75         -- fracción de INTRO_DURATION
-- Curva de la entrada: llega rápido y aterriza suave. EASE_IN retrasa el arranque
-- porque el fundido de entrada tapa el principio.
local EASE_IN_POWER = 1.15
local EASE_OUT_POWER = 3
-- Deriva lenta que sigue el mismo arco tras la entrada y se va cerrando sobre el
-- encuadre autorado mientras dura Resultados. Casi toda lateral: orbitar al equipo apenas lo mueve en
-- pantalla, y las tarjetas 2D están alineadas con las réplicas.
local DRIFT_SIDE = 2                 -- studs
local DRIFT_BACK = 0.9
-- Vaivén sobre la deriva, mínimo por el mismo motivo.
local SWAY_YAW_DEG = 0.28
local SWAY_PITCH_DEG = 0.16
local SWAY_YAW_SPEED = 0.35          -- rad/s
local SWAY_PITCH_SPEED = 0.27
-- Punto al que mira la entrada si el mapa no trae anclas de jugador.
local FOCUS_FALLBACK_DISTANCE = 20
local START_WALL_MARGIN = 1          -- studs que se separa el arranque de una pared

-- Las cámaras de Resultados se conducen DESPUÉS del script de cámara de Roblox
-- (Camera), la ShoulderCamera (Camera-1) y la killcam (Camera+1). Con RenderStepped
-- el orden no está garantizado y al reaparecer en el lobby Roblox ganaba algún frame.
local RENDER_STEP_NAME = "MatchResultsCamera"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2

type Held = { cframe: CFrame, fov: number }

local MatchCamera = {}

local _bound = false
local _cinematicCamera: Camera? = nil
local _cinematicOrigFOV = 70
-- Encuadre de la cámara congelada (nil = no hay hold en marcha).
local _held: Held? = nil

local function _stopCinematic()
	if _bound then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		_bound = false
	end
	_held = nil
	if _cinematicCamera then
		_cinematicCamera.FieldOfView = _cinematicOrigFOV
		_cinematicCamera = nil
	end
end

-- Fracción del recorrido que queda (1 → 0) en el instante `t` de 0 a 1.
local function _remaining(t: number): number
	return (1 - math.clamp(t, 0, 1) ^ EASE_IN_POWER) ^ EASE_OUT_POWER
end

-- Centro del equipo en la escena de Resultados.
local function _resultsFocus(finalCFrame: CFrame): Vector3
	local sum = Vector3.zero
	local count = 0
	for _, anchor in ResultsScene.getAnchors() do
		sum += anchor.Position
		count += 1
	end
	if count == 0 then
		return finalCFrame.Position + finalCFrame.LookVector * FOCUS_FALLBACK_DISTANCE
	end
	return sum / count
end

-- Cuánto del desplazamiento de arranque cabe (0..1) antes de topar con geometría
-- desde el encuadre final: la entrada no puede empezar dentro de una pared.
local function _clearFraction(finalPosition: Vector3, offset: Vector3): number
	local params = RaycastParams.new()
	params.RespectCanCollide = true
	local hit = workspace:Raycast(finalPosition, offset, params)
	if not hit then
		return 1
	end
	return math.max(hit.Distance - START_WALL_MARGIN, 0) / offset.Magnitude
end

local function _bind(step: (dt: number) -> ())
	_bound = true
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
end

-- Apunta la cámara (Scriptable) a una parte de Workspace.Cameras.<partName>.
local function _pointAtCameraPart(partName: string)
	if CameraLock.isLocked() then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local camerasFolder = workspace:FindFirstChild("Cameras")
	local part = if camerasFolder then camerasFolder:FindFirstChild(partName) else nil
	if part and part:IsA("BasePart") then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CameraSubject = nil
		camera.CFrame = part.CFrame
	end
end

function MatchCamera.setLobby()
	_pointAtCameraPart("lobby")
	local camera = workspace.CurrentCamera
	if camera then
		camera.FieldOfView = 40
	end
end

function MatchCamera.setGameplay(character: Model?)
	if CameraLock.isLocked() then
		return
	end

	local currentCamera = workspace.CurrentCamera
	if not currentCamera then
		return
	end

	local targetCharacter = character or Players.LocalPlayer.Character
	if not targetCharacter then
		return
	end

	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	currentCamera.CameraType = Enum.CameraType.Custom
	currentCamera.CameraSubject = humanoid
	currentCamera.FieldOfView = 70
end

--- Reintenta en delays para ganar a scripts que sobreescriban la cámara.
--- guardFn debe devolver true mientras los reintentos sigan siendo válidos.
function MatchCamera.forceLobbyWithRetries(guardFn: (() -> boolean)?)
	MatchCamera.setLobby()

	for _, delaySec in { 0.1, 0.2, 0.5 } do
		task.delay(delaySec, function()
			if guardFn and not guardFn() then
				return
			end
			MatchCamera.setLobby()
		end)
	end
end

--- Congela la cámara donde está mientras la pantalla funde a negro al acabar la
--- ronda: el servidor reaparece al jugador en el lobby en ese instante y se vería
--- el salto. Comparte render step con la cinemática (startResultsCinematic la
--- sustituye). Con un hold ya en marcha solo cambia el guard y conserva el encuadre.
function MatchCamera.holdCurrent(guardFn: (() -> boolean)?)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local held: Held = _held or { cframe = camera.CFrame, fov = camera.FieldOfView }

	_stopCinematic()
	_held = held
	_bind(function()
		if guardFn and not guardFn() then
			_stopCinematic()
			return
		end
		if CameraLock.isLocked() then
			return
		end
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CameraSubject = nil
		camera.CFrame = held.cframe
		camera.FieldOfView = held.fov
	end)
end

--- Entrada rápida en arco (dolly + truck + tilt + roll + zoom) con la mirada clavada
--- en el equipo, que al llegar no se para: sigue derivando despacio por el mismo arco
--- hasta el encuadre `Results.Camera` del mapa. Re-afirma Scriptable cada frame para ganar a respawns y
--- setGameplay. Se detiene cuando `guardFn` devuelve false o con stopResultsCinematic.
function MatchCamera.startResultsCinematic(guardFn: (() -> boolean)?)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	-- Results.Camera lo desmonta el servidor al acabar Resultados con su propio reloj:
	-- se lee de la copia de ResultsScene. Sin encuadre no se para el hold: soltarlo
	-- dejaría la cámara siguiendo al personaje, que ya está en el lobby.
	local captured = ResultsScene.getCameraCFrame()
	if not captured then
		warn("[MatchCamera] Sin encuadre de Resultados (falta Results.Camera en el mapa) — la cámara se queda donde está.")
		return
	end
	_stopCinematic()

	local finalCFrame: CFrame = captured
	local finalPosition = finalCFrame.Position

	-- Desplazamiento solo en horizontal (ejes aplanados a XZ): la entrada nunca cambia
	-- la altura y no atraviesa el suelo por inclinada que esté la cámara final.
	local flatLook = Vector3.new(finalCFrame.LookVector.X, 0, finalCFrame.LookVector.Z)
	flatLook = if flatLook.Magnitude > 1e-4 then flatLook.Unit else finalCFrame.LookVector
	local flatRight = Vector3.new(-flatLook.Z, 0, flatLook.X)
	local introOffset = flatRight * TRUCK_SIDE - flatLook * DOLLY_BACK
	local driftOffset = flatRight * DRIFT_SIDE - flatLook * DRIFT_BACK
	local clear = _clearFraction(finalPosition, introOffset + driftOffset)
	introOffset *= clear
	driftOffset *= clear

	-- Mirar al equipo durante el arco da paralaje; `aimCorrection` es lo que separa
	-- "mirar al foco" del encuadre autorado, así que con el recorrido a 0 sale exacto.
	local focus = _resultsFocus(finalCFrame)
	local toFocus = focus - finalPosition
	-- lookAt degenera con el foco encima o debajo de la cámara: ahí no se reorienta.
	local tracksFocus = toFocus.Magnitude > 1 and math.abs(toFocus.Unit.Y) < 0.98
	local aimCorrection = if tracksFocus
		then CFrame.lookAt(finalPosition, focus):ToObjectSpace(finalCFrame)
		else finalCFrame.Rotation

	_cinematicCamera = camera
	_cinematicOrigFOV = camera.FieldOfView
	local finalFOV = _cinematicOrigFOV

	local elapsed = 0
	_bind(function(dt: number)
		if guardFn and not guardFn() then
			_stopCinematic()
			return
		end
		if CameraLock.isLocked() then
			return
		end
		elapsed += dt

		local t = elapsed / INTRO_DURATION
		local travel = _remaining(t)
		local twist = _remaining(t / ROTATION_SETTLE)

		local drift = math.max(1 - elapsed / GameConfig.EndResultsDuration, 0)

		local position = finalPosition + introOffset * travel + driftOffset * drift
		local aim = if tracksFocus then CFrame.lookAt(position, focus) else CFrame.new(position)
		local sway = CFrame.Angles(
			math.rad(SWAY_PITCH_DEG) * math.sin(elapsed * SWAY_PITCH_SPEED),
			math.rad(SWAY_YAW_DEG) * math.sin(elapsed * SWAY_YAW_SPEED),
			0
		)

		camera.CameraType = Enum.CameraType.Scriptable
		camera.CameraSubject = nil
		camera.CFrame = aim
			* aimCorrection
			* CFrame.Angles(math.rad(TILT_DEG * twist), 0, math.rad(ROLL_DEG * twist))
			* sway
		camera.FieldOfView = finalFOV + FOV_PUNCH * travel
	end)
end

function MatchCamera.stopResultsCinematic()
	_stopCinematic()
end

return MatchCamera
