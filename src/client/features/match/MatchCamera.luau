--!strict
--[[
	MatchCamera.luau
	Gestión centralizada de la cámara para el flujo de partida.
	Encapsula lobby camera, gameplay camera, retries con delays, y la cámara
	cinemática de la pantalla de Resultados (orbit suave alrededor del podio).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = script.Parent.Parent.Parent
local CameraLock = require(Client.core.camera.CameraLock)

-- Cinemática de Resultados: intro dramático (tilt + roll/dutch + zoom + dolly)
-- que entra al encuadre de Workspace.Cameras.results, y después un push-in/zoom
-- lento continuo para que no se quede congelado.
local INTRO_DURATION = 1.0           -- duración del movimiento dramático (s)
local TILT_DEG = 32                  -- pitch inicial (negativo = empieza mirando arriba)
local ROLL_DEG = 8                   -- inclinación lateral (dutch) inicial que se endereza
local DOLLY_BACK = 12                -- studs que arranca por detrás (dolly hacia delante)
local FOV_PUNCH = 14                 -- FOV extra al inicio → zoom-in sutil que se asienta

local MatchCamera = {}

local _cinematicConn: RBXScriptConnection? = nil
local _cinematicCamera: Camera? = nil
local _cinematicOrigFOV = 70

local function _stopCinematic()
	if _cinematicConn then
		_cinematicConn:Disconnect()
		_cinematicConn = nil
	end
	-- Restaurar el FOV que tenía la cámara antes del zoom cinemático.
	if _cinematicCamera then
		_cinematicCamera.FieldOfView = _cinematicOrigFOV
		_cinematicCamera = nil
	end
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
end

--- Fuerza cámara de lobby con reintentos en delays para ganar a scripts que la sobreescriban.
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

-- ── Cinemática de Resultados ─────────────────────────────────

--- Arranca la cámara cinemática de Resultados: un intro dramático rápido (tilt +
--- zoom + pequeño dolly) que entra al encuadre de Workspace.Cameras.results y se
--- sostiene ahí el resto de la pantalla. Conduce la cámara CADA frame (re-afirma
--- Scriptable), así es autoritaria: gana a respawns/setGameplay/scripts. Se
--- auto-detiene cuando `guardFn` devuelve false (p. ej. al salir de ShowingResults)
--- o vía stopResultsCinematic, restaurando el FOV.
function MatchCamera.startResultsCinematic(guardFn: (() -> boolean)?)
	_stopCinematic()

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local camerasFolder = workspace:FindFirstChild("Cameras")
	local base = if camerasFolder then camerasFolder:FindFirstChild("results") else nil
	if not (base and base:IsA("BasePart")) then
		return
	end

	-- Encuadre final = la parte (Workspace.Cameras.results) con el FOV actual:
	-- el intro acaba exactamente aquí y se queda quieto (movimiento finito).
	local finalCFrame = (base :: BasePart).CFrame
	local finalRotation = finalCFrame.Rotation

	-- Dirección de dolly puramente HORIZONTAL (look aplanado al plano XZ): así el
	-- desplazamiento de entrada nunca cambia la altura → no atraviesa el suelo,
	-- por más inclinada que esté la cámara final.
	local flatLook = Vector3.new(finalCFrame.LookVector.X, 0, finalCFrame.LookVector.Z)
	flatLook = if flatLook.Magnitude > 1e-4 then flatLook.Unit else finalCFrame.LookVector

	_cinematicCamera = camera
	_cinematicOrigFOV = camera.FieldOfView
	local finalFOV = _cinematicOrigFOV

	local elapsed = 0
	_cinematicConn = RunService.RenderStepped:Connect(function(dt: number)
		-- Auto-stop cuando el guard deja de ser válido (salimos de Results).
		if guardFn and not guardFn() then
			_stopCinematic()
			return
		end
		if CameraLock.isLocked() then
			return
		end
		elapsed += dt

		-- Offset del intro: arranca a 1 y decae rápido (^4) a 0 → tilt/roll/dolly
		-- y un poco de zoom que se asientan al encuadre final y se detienen.
		local it = if INTRO_DURATION > 0 then math.clamp(elapsed / INTRO_DURATION, 0, 1) else 1
		local intro = (1 - it) ^ 4

		-- Posición: encuadre final retrocedido en horizontal (nunca cambia altura).
		-- Orientación: rotación final + tilt/roll en sitio (no mueve la cámara).
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
