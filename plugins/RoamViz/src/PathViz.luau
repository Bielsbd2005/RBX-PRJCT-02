--!strict
--[[
	PathViz — preview de rutas REALES entre RoamPoints usando PathfindingService.

	A diferencia de los marcadores/anillos (que son geometría estática), esto
	corre el MISMO pathfinder que usa el bot en runtime (Navigator.luau) con los
	MISMOS agent params (mirror de BotConfig.Pathfinding). Así la línea dibujada
	es el camino que realmente caminaría el bot — no una recta.

	Este módulo solo sabe: calcular UNA ruta y dibujarla. La orquestación (qué
	pares, cuántos, con yield y tope) vive en init.server.luau, porque de eso
	depende no congelar Studio.

	Cada ComputeAsync CEDE (yield) y es caro — por eso el runtime lo throttlea
	con PathfindingQueue/QueueRequestsPerHeartbeat=2. En el editor lo acotamos
	con caps + task.wait entre computes.
]]

local PathfindingService = game:GetService("PathfindingService")
local CoreGui = game:GetService("CoreGui")

local Config = require(script.Parent.Config)
local Style = require(script.Parent.Style)

-- Mirror de src/shared/constants/BotConfig.luau · Pathfinding.
-- Si cambian ahí, actualizá acá (el plugin corre en el editor, no puede
-- require de BotConfig).
local AGENT_PARAMS = {
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
	AgentMaxSlope = 45,
	WaypointSpacing = 4,
}

-- Alza las líneas del suelo para que no hagan z-fighting con el piso.
local DRAW_Y_OFFSET = Vector3.new(0, 0.5, 0)

local PathViz = {}
PathViz.__index = PathViz

local CONTAINER_NAME = "RoamViz_Paths"

export type PathViz = typeof(setmetatable(
	{} :: {
		_container: Folder,
		_path: Path,
	},
	PathViz
))

function PathViz.new(): PathViz
	local existing = CoreGui:FindFirstChild(CONTAINER_NAME)
	if existing and existing:IsA("Folder") then
		existing:ClearAllChildren()
	end
	local container = (existing :: Folder?) or Instance.new("Folder")
	container.Name = CONTAINER_NAME
	container.Parent = CoreGui
	return setmetatable({
		_container = container,
		_path = PathfindingService:CreatePath(AGENT_PARAMS),
	}, PathViz)
end

function PathViz:clear()
	self._container:ClearAllChildren()
end

-- Calcula la ruta real from→to. Devuelve las posiciones de los waypoints, o
-- nil si el path falla (inalcanzable, sin NavMesh, etc). YIELDS.
function PathViz:computePath(fromPos: Vector3, toPos: Vector3): { Vector3 }?
	local ok = pcall(function()
		self._path:ComputeAsync(fromPos, toPos)
	end)
	if not ok or self._path.Status ~= Enum.PathStatus.Success then
		return nil
	end
	local positions: { Vector3 } = {}
	for _, wp in self._path:GetWaypoints() do
		table.insert(positions, wp.Position)
	end
	if #positions < 2 then
		return nil
	end
	return positions
end

-- Dibuja una polilínea (waypoint→waypoint) con LineHandleAdornment.
-- LineHandleAdornment traza desde su CFrame a lo largo del LookVector por
-- `Length` studs; CFrame.lookAt(a,b) apunta el LookVector de a hacia b.
-- Apariencia (color/grosor/transparencia) desde Style.luau.
function PathViz:drawPath(waypoints: { Vector3 }, _state: Config.State)
	for i = 1, #waypoints - 1 do
		local a = waypoints[i] + DRAW_Y_OFFSET
		local b = waypoints[i + 1] + DRAW_Y_OFFSET
		local len = (b - a).Magnitude
		if len > 1e-3 then
			local seg = Instance.new("LineHandleAdornment")
			seg.Adornee = workspace.Terrain
			seg.Length = len
			seg.Thickness = Style.pathThickness
			seg.Color3 = Style.pathColor
			seg.Transparency = Style.pathTransparency
			seg.ZIndex = 2
			seg.AlwaysOnTop = false
			seg.CFrame = CFrame.lookAt(a, b)
			seg.Parent = self._container
		end
	end
end

function PathViz:destroy()
	if self._container then
		self._container:Destroy()
	end
end

return PathViz
