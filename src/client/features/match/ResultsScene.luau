--!strict
--[[
	Podio de Resultados, autorado por cada mapa:
	    Workspace.ActiveMap.<mapa>.Results.Player1..4 y .Results.Camera
	Fallback para mapas que no lo traen: Workspace.Results y Workspace.Cameras.results.

	Guarda CFrames, no instancias: el servidor desmonta el mapa al expirar la
	ventana de Resultados con su propio reloj, y puede ganarle por unos frames al
	cierre de la pantalla en el cliente. El snapshot solo lo pisa otra lectura buena.
]]

local Workspace = game:GetService("Workspace")

local FOLDER_NAME = "Results"
local CAMERA_NAME = "Camera"
local MAP_CONTAINER_NAME = "ActiveMap"
local SLOT_COUNT = 4
local LEGACY_CAMERAS_FOLDER = "Cameras"
local LEGACY_CAMERA_NAME = "results"
-- El mapa replica un poco después del cambio de fase: reintentos acotados.
local CAPTURE_TIMEOUT = 10
local CAPTURE_INTERVAL = 0.2

export type Snapshot = {
	anchors: { [number]: CFrame }, -- por slot 1..SLOT_COUNT, puede tener huecos
	camera: CFrame?,
}

local ResultsScene = {}

local _snapshot: Snapshot? = nil
-- Cancela reintentos obsoletos (cambio de partida o teardown del feature).
local _generation = 0

local function _cframeOf(node: Instance?): CFrame?
	if not node then
		return nil
	end
	if node:IsA("BasePart") then
		return (node :: BasePart).CFrame
	end
	if node:IsA("Attachment") then
		return (node :: Attachment).WorldCFrame
	end
	if node:IsA("Camera") then
		return (node :: Camera).CFrame
	end
	if node:IsA("PVInstance") then
		return (node :: PVInstance):GetPivot()
	end
	return nil
end

local function _findFolder(): Instance?
	local activeMap = Workspace:FindFirstChild(MAP_CONTAINER_NAME)
	if activeMap then
		local direct = activeMap:FindFirstChild(FOLDER_NAME)
		if direct then
			return direct
		end
		for _, child in activeMap:GetChildren() do
			local nested = child:FindFirstChild(FOLDER_NAME)
			if nested then
				return nested
			end
		end
	end
	return Workspace:FindFirstChild(FOLDER_NAME)
end

local function _legacyCameraCFrame(): CFrame?
	local folder = Workspace:FindFirstChild(LEGACY_CAMERAS_FOLDER)
	return _cframeOf(if folder then folder:FindFirstChild(LEGACY_CAMERA_NAME) else nil)
end

--- false si no hay nada que copiar; el snapshot anterior queda intacto.
function ResultsScene.capture(): boolean
	local folder = _findFolder()
	local anchors: { [number]: CFrame } = {}
	local found = 0
	if folder then
		for i = 1, SLOT_COUNT do
			local cframe = _cframeOf(folder:FindFirstChild("Player" .. tostring(i)))
			if cframe then
				anchors[i] = cframe
				found += 1
			end
		end
	end

	local camera = _cframeOf(if folder then folder:FindFirstChild(CAMERA_NAME) else nil) or _legacyCameraCFrame()
	if found == 0 and not camera then
		return false
	end

	_snapshot = { anchors = anchors, camera = camera }
	return true
end

function ResultsScene.captureWithRetries()
	_generation += 1
	local myGeneration = _generation

	if ResultsScene.capture() then
		return
	end

	task.spawn(function()
		local deadline = os.clock() + CAPTURE_TIMEOUT
		while os.clock() < deadline do
			task.wait(CAPTURE_INTERVAL)
			if _generation ~= myGeneration then
				return
			end
			if ResultsScene.capture() then
				return
			end
		end
		warn(
			`[ResultsScene] El mapa no trae carpeta {FOLDER_NAME} (Player1..{SLOT_COUNT} / {CAMERA_NAME}) — la pantalla de Resultados saldrá sin réplicas.`
		)
	end)
end

function ResultsScene.get(): Snapshot?
	ResultsScene.capture()
	return _snapshot
end

function ResultsScene.getAnchors(): { [number]: CFrame }
	local snapshot = ResultsScene.get()
	return if snapshot then snapshot.anchors else {}
end

function ResultsScene.getCameraCFrame(): CFrame?
	local snapshot = ResultsScene.get()
	return if snapshot then snapshot.camera else nil
end

function ResultsScene.clear()
	_generation += 1
	_snapshot = nil
end

return ResultsScene
