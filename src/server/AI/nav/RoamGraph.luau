--!strict
--[[
	RoamGraph — pool plano de destinos navegables por mapa.

	NO es un grafo conectado ni una ruta ordenada. Es una lista de Vector3
	sin orden ni numeración. Los bots piden puntos aleatorios cuando
	necesitan un destino.

	Authoring (mapas de producción):
	  Workspace/Maps/<MapName>/AINav/RoamPoints/
	  Cada hijo BasePart es un destino. Nombres no importan. Atributos Tags
	  (string) y Weight (number) se leen e ignoran en v1.

	Fallback automático (prototipo/WIP):
	  Si no existe la carpeta AINav, genera puntos por raycast top-down
	  multinivel — cubre suelo + plataformas hasta 30 studs por encima.

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

local SCAN_STEP = 8              -- separación XZ entre rayos
local SCAN_HEIGHT = 200          -- altura desde la que cae el rayo
local FALLBACK_MAX_LIFT = 30     -- studs sobre el suelo donde aún consideramos hits (plataformas)

local RoamGraph = {}
RoamGraph.__index = RoamGraph

export type RoamGraph = typeof(setmetatable({} :: {
	_mapRoot: Instance,
	_points: { Vector3 },
	_conns: { RBXScriptConnection },
	_isFallback: boolean,
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

local function _computeMapBounds(mapRoot: Instance): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	for _, d in mapRoot:GetDescendants() do
		if d:IsA("BasePart") then
			local p = d.Position
			if not minV then
				minV = p
				maxV = p
			else
				minV = Vector3.new(math.min((minV :: Vector3).X, p.X), math.min((minV :: Vector3).Y, p.Y), math.min((minV :: Vector3).Z, p.Z))
				maxV = Vector3.new(math.max((maxV :: Vector3).X, p.X), math.max((maxV :: Vector3).Y, p.Y), math.max((maxV :: Vector3).Z, p.Z))
			end
		end
	end
	return minV, maxV
end

-- Fallback: raycast top-down a una grid XZ. Captura el primer hit (suelo) y
-- también hits a hasta FALLBACK_MAX_LIFT studs por encima del suelo (plataformas
-- intermedias). No es perfecto en escaleras complejas pero da pool aceptable
-- para mapas en prototipo.
local function _generateFallbackPoints(mapRoot: Instance): { Vector3 }
	local lo, hi = _computeMapBounds(mapRoot)
	local points: { Vector3 } = {}
	if not lo or not hi then
		return points
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { mapRoot }

	for x = lo.X, hi.X, SCAN_STEP do
		for z = lo.Z, hi.Z, SCAN_STEP do
			local origin = Vector3.new(x, hi.Y + SCAN_HEIGHT, z)
			local result = workspace:Raycast(origin, Vector3.new(0, -(SCAN_HEIGHT + (hi.Y - lo.Y) + 50), 0), params)
			if result then
				table.insert(points, result.Position + Vector3.new(0, 2, 0))
				-- Multinivel: dispara desde la altura del primer hit + FALLBACK_MAX_LIFT
				-- hacia arriba, buscando plataformas encima.
				local liftOrigin = result.Position + Vector3.new(0, FALLBACK_MAX_LIFT + 0.1, 0)
				local liftResult = workspace:Raycast(liftOrigin, Vector3.new(0, -(FALLBACK_MAX_LIFT - 1), 0), params)
				if liftResult and (liftResult.Position - result.Position).Magnitude > 4 then
					table.insert(points, liftResult.Position + Vector3.new(0, 2, 0))
				end
			end
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
		self._isFallback = false
	else
		print(string.format(
			"[RoamGraph] fallback raycast generation for map '%s' — no AINav/RoamPoints folder; only acceptable for prototype/WIP",
			self._mapRoot.Name
		))
		self._points = _generateFallbackPoints(self._mapRoot)
		self._isFallback = true
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
		_isFallback = false,
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

function RoamGraph:isFallback(): boolean
	return self._isFallback
end

-- Pick algoritmo (4 niveles de relax, sin handwave):
--   1. anillo [minDist, maxDist]
--   2. anillo [minDist * 0.5, maxDist * 2]
--   3. cualquier punto del pool
--   4. nil (pool vacío o RoamGraph mal construido)
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
