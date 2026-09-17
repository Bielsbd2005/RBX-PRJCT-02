--!strict
--[[
	Cámara del flujo de partida: lobby, gameplay, reintentos con delays y la
	cinemática de la pantalla de Resultados.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent.Parent
local CameraLock = require(Client.core.camera.CameraLock)
local ResultsScene = require(script.Parent.ResultsScene)

local INTRO_DURATION = 1.0           -- duración del movimiento dramático (s)
local TILT_DEG = 32                  -- pitch inicial (negativo = empieza mirando arriba)
local ROLL_DEG = 8                   -- inclinación lateral (dutch) inicial que se endereza
local DOLLY_BACK = 12                -- studs que arranca por detrás (dolly hacia delante)
local FOV_PUNCH = 14                 -- FOV extra al inicio → zoom-in sutil que se asienta

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

--- Intro rápido (tilt + roll + zoom + dolly) que entra al encuadre `Results.Camera`
--- del mapa y se sostiene. Re-afirma Scriptable cada frame para ganar a respawns y
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
	local finalRotation = finalCFrame.Rotation

	-- Dolly solo en horizontal (look aplanado a XZ): la entrada nunca cambia la altura
	-- y no atraviesa el suelo por inclinada que esté la cámara final.
	local flatLook = Vector3.new(finalCFrame.LookVector.X, 0, finalCFrame.LookVector.Z)
	flatLook = if flatLook.Magnitude > 1e-4 then flatLook.Unit else finalCFrame.LookVector

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

		local it = math.clamp(elapsed / INTRO_DURATION, 0, 1)
		local intro = (1 - it) ^ 4

		local pos = finalCFrame.Position - flatLook * (DOLLY_BACK * intro)
		local targetCFrame = CFrame.new(pos)
			* finalRotation
			* CFrame.Angles(math.rad(TILT_DEG * intro), 0, math.rad(ROLL_DEG * intro))

		camera.CameraType = Enum.CameraType.Scriptable
		camera.CameraSubject = nil
		camera.CFrame = targetCFrame
		camera.FieldOfView = finalFOV + FOV_PUNCH * intro
	end)
end

function MatchCamera.stopResultsCinematic()
	_stopCinematic()
end

return MatchCamera
