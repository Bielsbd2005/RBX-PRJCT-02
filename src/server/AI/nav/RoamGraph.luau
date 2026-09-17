--!strict
--[[
	Pool plano de destinos navegables por mapa: NO es un grafo conectado ni una
	ruta, solo Vector3 sin orden.

	Requisito de Studio (todo mapa en producción): Workspace/Maps/<MapName>/AINav/RoamPoints/
	con BaseParts (cualquier nombre, cualquier profundidad). Sin esa carpeta el
	pool queda vacío y los bots no tienen destinos.

	Caché por mapRoot: se descarta al destruirse el mapa; un reinicio de ronda con
	el mismo mapRoot reusa el pool. En Studio se reconstruye al añadir/quitar puntos.
]]

local RunService = game:GetService("RunService")
local IS_STUDIO = RunService:IsStudio()

local RoamGraph = {}
RoamGraph.__index = RoamGraph

export type RoamGraph = typeof(setmetatable({} :: {
	_mapRoot: Instance,
	_points: { Vector3 },
	_conns: { RBXScriptConnection },
	_destroyed: boolean,
}, RoamGraph))

local _cache: { [Instance]: RoamGraph } = {}

local function _findAINavFolder(mapRoot: Instance): Instance?
	local aiNav = mapRoot:FindFirstChild("AINav")
	if not aiNav then
		return nil
	end
	local roamPoints = aiNav:FindFirstChild("RoamPoints")
	return roamPoints
end

local function _readAuthoredPoints(folder: Instance): { Vector3 }
	local points: { Vector3 } = {}
	for _, child in folder:GetDescendants() do
		if child:IsA("BasePart") then
			table.insert(points, child.Position)
		end
	end
	return points
end

local function _rebuild(self: RoamGraph)
	if self._destroyed then
		return
	end
	local folder = _findAINavFolder(self._mapRoot)
	if folder then
		self._points = _readAuthoredPoints(folder)
	else
		warn(string.format(
			"[RoamGraph] map '%s' no tiene AINav/RoamPoints folder. Los bots no podrán hacer roaming en este mapa. Authoreá la carpeta en Studio (ver Pre-PR1 del plan).",
			self._mapRoot.Name
		))
		self._points = {}
	end
end

local function _wireListeners(self: RoamGraph)
	local folder = _findAINavFolder(self._mapRoot)
	-- Solo en Studio, para iterar puntos sin reiniciar ronda; en producción son estáticos.
	if folder and IS_STUDIO then
		local rebuildScheduled = false
		local function scheduleRebuild()
			if rebuildScheduled then return end
			rebuildScheduled = true
			task.defer(function()
				rebuildScheduled = false
				_rebuild(self)
			end)
		end
		table.insert(self._conns, folder.DescendantAdded:Connect(function()
			scheduleRebuild()
		end))
		table.insert(self._conns, folder.DescendantRemoving:Connect(function()
			scheduleRebuild()
		end))
	end
	table.insert(self._conns, self._mapRoot.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			self:destroy()
		end
	end))
end

function RoamGraph.forMap(mapRoot: Instance): RoamGraph
	local cached = _cache[mapRoot]
	if cached and not cached._destroyed then
		return cached
	end

	local self = setmetatable({
		_mapRoot = mapRoot,
		_points = {},
		_conns = {},
		_destroyed = false,
	}, RoamGraph) :: RoamGraph

	_rebuild(self)
	_wireListeners(self)
	_cache[mapRoot] = self
	return self
end

function RoamGraph:destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	if _cache[self._mapRoot] == self then
		_cache[self._mapRoot] = nil
	end
end

function RoamGraph:size(): number
	return #self._points
end

function RoamGraph:pickRandomNavigablePoint(originPos: Vector3, minDist: number, maxDist: number): Vector3?
	local points = self._points
	if #points == 0 then
		return nil
	end

	local function _pickInRing(lo: number, hi: number): Vector3?
		local lo2, hi2 = lo * lo, hi * hi
		local pick: Vector3? = nil
		local count = 0
		for _, p in points do
			local delta = p - originPos
			local d2 = delta:Dot(delta)
			if d2 >= lo2 and d2 <= hi2 then
				count += 1
				if math.random(1, count) == 1 then
					pick = p
				end
			end
		end
		return pick
	end

	local pick = _pickInRing(minDist, maxDist)
	if pick then
		return pick
	end

	pick = _pickInRing(minDist * 0.5, maxDist * 2)
	if pick then
		return pick
	end

	return points[math.random(1, #points)]
end

function RoamGraph:nearestPoint(pos: Vector3): Vector3?
	local points = self._points
	local best: Vector3? = nil
	local bestD2 = math.huge
	for _, p in points do
		local delta = p - pos
		local d2 = delta:Dot(delta)
		if d2 < bestD2 then
			bestD2 = d2
			best = p
		end
	end
	return best
end

return RoamGraph
