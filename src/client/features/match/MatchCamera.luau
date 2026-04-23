--!strict
--[[
	MatchCamera.luau
	Gestión centralizada de la cámara para el flujo de partida.
	Encapsula la lógica de lobby camera, gameplay camera, y retries con delays.
]]

local Players = game:GetService("Players")

local Client = script.Parent.Parent.Parent
local CameraLock = require(Client.core.camera.CameraLock)

local MatchCamera = {}

function MatchCamera.setLobby()
	if CameraLock.isLocked() then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local camerasFolder = workspace:FindFirstChild("Cameras")
	local lobbyPart = if camerasFolder then camerasFolder:FindFirstChild("lobby") else nil
	if lobbyPart and lobbyPart:IsA("BasePart") then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CameraSubject = nil
		camera.CFrame = lobbyPart.CFrame
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

--- Fuerza la cámara a Scriptable (para kill cam o transiciones).
function MatchCamera.forceScriptable()
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
	end
end

return MatchCamera
