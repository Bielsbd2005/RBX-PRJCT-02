--!strict
--[[
	RoamGraph — pool plano de destinos navegables por mapa.

	NO es un grafo conectado ni una ruta ordenada. Es una lista de Vector3
	sin orden ni numeración. Los bots piden puntos aleatorios cuando
	necesitan un destino.

	Authoring (contractual — todos los mapas en producción deben tenerlo):
	  Workspace/Maps/<MapName>/AINav/RoamPoints/
	  Cada hijo BasePart es un destino. Nombres no importan. Atributos Tags
	  (string) y Weight (number) se leen e ignoran en v1.

	Si la carpeta no existe al construir el RoamGraph, se emite un `warn`
	ruidoso una sola vez y el pool queda vacío — `pickRandomNavigablePoint`
	devolverá `nil` y los bots no recibirán destinos válidos. Es un bug de
	level design, no debe ocurrir en producción.

	Caché por mapRoot Instance. Invalidación explícita:
	  • mapRoot.Parent == nil → entrada descartada (mapa destruido).
	  • AINav/RoamPoints emite ChildAdded/ChildRemoved → rebuild (permite
	    iterar en Studio sin restart de ronda).
	  • Round restart con MISMO mapRoot → NO invalida; reusa pool.

	API:
	  RoamGraph.forMap(mapRoot) → RoamGraph
	  :pickRandomNavigablePoint(originPos, minDist, maxDist) → Vector3?
	  :nearestPoint(pos) → Vector3?
	  :destroy() — libera listeners; el caché se limpia automáticamente
	    cuando mapRoot.Parent == nil.
]]

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
		-- Bug de level design: no debería ocurrir en producción.
		warn(string.format(
			"[RoamGraph] map '%s' no tiene AINav/RoamPoints folder. Los bots no podrán hacer roaming en este mapa. Authoreá la carpeta en Studio (ver Pre-PR1 del plan).",
			self._mapRoot.Name
		))
		self._points = {}
	end
end

local function _wireListeners(self: RoamGraph)
	local folder = _findAINavFolder(self._mapRoot)
	if folder then
		-- Authoring iterable: cualquier add/remove en runtime fuerza rebuild.
		table.insert(self._conns, folder.DescendantAdded:Connect(function()
			_rebuild(self)
		end))
		table.insert(self._conns, folder.DescendantRemoving:Connect(function()
			_rebuild(self)
		end))
	end
	-- mapRoot destruido → limpiar caché y desuscribir.
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

-- Pick algoritmo (4 niveles de relax, sin handwave):
--   1. anillo [minDist, maxDist]
--   2. anillo [minDist * 0.5, maxDist * 2]
--   3. cualquier punto del pool
--   4. nil (pool vacío — mapa sin AINav o todavía no authoreado)
function RoamGraph:pickRandomNavigablePoint(originPos: Vector3, minDist: number, maxDist: number): Vector3?
	local points = self._points
	if #points == 0 then
		return nil
	end

	local function _pickInRing(lo: number, hi: number): Vector3?
		local candidates: { Vector3 } = {}
		local lo2, hi2 = lo * lo, hi * hi
		for _, p in points do
			local d2 = (p - originPos):Dot(p - originPos)
			if d2 >= lo2 and d2 <= hi2 then
				table.insert(candidates, p)
			end
		end
		if #candidates == 0 then
			return nil
		end
		return candidates[math.random(1, #candidates)]
	end

	local pick = _pickInRing(minDist, maxDist)
	if pick then
		return pick
	end

	pick = _pickInRing(minDist * 0.5, maxDist * 2)
	if pick then
		return pick
	end

	-- Full fallback: cualquier punto del pool.
	return points[math.random(1, #points)]
end

function RoamGraph:nearestPoint(pos: Vector3): Vector3?
	local points = self._points
	local best: Vector3? = nil
	local bestD2 = math.huge
	for _, p in points do
		local d2 = (p - pos):Dot(p - pos)
		if d2 < bestD2 then
			bestD2 = d2
			best = p
		end
	end
	return best
end

return RoamGraph
