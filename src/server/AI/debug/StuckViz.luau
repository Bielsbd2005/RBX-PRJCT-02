--!strict
--[[
	StuckViz — marca en el mapa los puntos donde los bots se quedan atascados.

	Toggle con el BoolValue ServerStorage.ShowStuckMarkers:
	  ServerStorage.ShowStuckMarkers.Value = true

	Mientras está enabled, cada escalada de StuckDetector a partir del nivel 2
	(repath, 2s sin progreso) deja una esfera neon rosa en la posición del bot,
	dentro de Workspace/BotStuckDebug. Los markers son PERSISTENTES (no Debris):
	la idea es dejar correr una partida entera y luego mirar el mapa para ver
	qué zonas concentran atascos.

	No se marca dentro de SPAWN_IGNORE_RADIUS de un spawn point (AIService pasa
	la lista en OnRoundStart): los bots recién spawneados se empujan entre ellos
	sobre el pad, y eso no es geometría a arreglar.

	Agregación por celda de 8 studs: dos bots atascados en el mismo sitio
	reutilizan el mismo marker, que crece con el nivel máximo alcanzado y lleva
	un contador. Así una esquina mala se ve como UN marker grande con "x14" en
	vez de 14 esferas solapadas.

	Poner el BoolValue a false limpia la carpeta entera. También desde Command
	Bar:
	  require(...ServerScriptService.Server.AI.debug.StuckViz).clear()

	Coste: cero cuando está off (early return sobre un bool cacheado). Enabled,
	como mucho MAX_MARKERS Parts ancladas sin colisión ni query — despreciable,
	pero NO dejarlo on en producción: las Parts replican a todos los clientes.
]]

local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local FLAG_NAME = "ShowStuckMarkers"

local FOLDER_NAME = "BotStuckDebug"
local COLOR_PINK = Color3.fromRGB(255, 0, 170)
-- Naranja para los stalls del walk loop: son un fallo DISTINTO al del
-- StuckDetector y confundirlos hace imposible diagnosticar. Ver KIND_*.
local COLOR_ORANGE = Color3.fromRGB(255, 140, 0)
local GRID_SIZE = 8       -- studs por celda de agregación
local MAX_MARKERS = 250   -- techo duro para no llenar el DataModel

-- Dos fallos con síntomas opuestos, mismo mapa de calor:
--   STUCK — el StuckDetector escaló: el bot está QUIETO (velocidad neta por
--           debajo de StuckMoveEpsilon) el tiempo suficiente. `level` es el
--           peldaño de la escalada (2 repath / 3 jump / 4 teleport).
--   STALL — el walk loop abandonó un waypoint: el bot SE MUEVE pero no se
--           acerca al waypoint. El StuckDetector es ciego a esto porque solo
--           mira velocidad, no progreso hacia el destino. `level` no aplica.
local KIND_STUCK = "stuck"
local KIND_STALL = "stall"

-- Radio alrededor de cada spawn point donde NO se marca. Los amontonamientos
-- en el pad (varios bots spawneando a la vez, empujándose) no son un defecto
-- de geometría, y sin el filtro cada spawn acaba con un marker gigante que
-- tapa la señal real. Complementa la gracia temporal de StuckDetector: cubre
-- al bot que sale del spawn tarde, cuando la gracia ya expiró.
local SPAWN_IGNORE_RADIUS = 16
local SPAWN_IGNORE_RADIUS2 = SPAWN_IGNORE_RADIUS * SPAWN_IGNORE_RADIUS

-- Tamaño de la esfera según el nivel de escalada más alto visto en la celda.
local SIZE_BY_LEVEL: { [number]: number } = {
	[2] = 2.5,
	[3] = 4,
	[4] = 6,
}

local StuckViz = {}

StuckViz.KIND_STUCK = KIND_STUCK
StuckViz.KIND_STALL = KIND_STALL

type Marker = {
	part: BasePart,
	label: TextLabel,
	count: number,
	maxLevel: number,
	kind: string,
}

local _markers: { [string]: Marker } = {}
local _markerCount = 0
local _capWarned = false
local _folder: Folder? = nil
local _enabled = false
local _spawnPositions: { Vector3 } = {}

local function _clearAll()
	local folder = _folder
	if folder then
		folder:Destroy()
	end
	_folder = nil
	table.clear(_markers)
	_markerCount = 0
	_capWarned = false
end

local function _ensureFolder(): Folder
	local existing = _folder
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace
	_folder = folder
	return folder
end

-- Bool cacheado (mismo patrón que RaycastViz): mark() se llama desde el tick
-- del StuckDetector, así que no queremos leer el BoolValue cada vez.
local function _bindFlag(flag: BoolValue)
	_enabled = flag.Value
	flag.Changed:Connect(function(value: boolean)
		_enabled = value
		if not value then
			_clearAll()
		end
	end)
end

do
	local flag = ServerStorage:FindFirstChild(FLAG_NAME)
	if flag and flag:IsA("BoolValue") then
		_bindFlag(flag)
	else
		if flag then
			warn(string.format(
				"[StuckViz] ServerStorage.%s existe pero no es BoolValue (%s) — markers desactivados.",
				FLAG_NAME,
				flag.ClassName
			))
		end
		-- Si el BoolValue se añade en caliente (o el place lo crea tarde),
		-- engancharlo sin necesidad de reiniciar el servidor.
		local conn: RBXScriptConnection
		conn = ServerStorage.ChildAdded:Connect(function(child)
			if child.Name == FLAG_NAME and child:IsA("BoolValue") then
				conn:Disconnect()
				_bindFlag(child)
			end
		end)
	end
end

function StuckViz.isEnabled(): boolean
	return _enabled
end

-- AIService la llama en OnRoundStart con los spawn points del mapa. Se guardan
-- las posiciones (no las Parts) porque el mapa se destruye al acabar la ronda
-- y no queremos mantener referencias vivas a instancias borradas.
function StuckViz.setSpawnPoints(points: { BasePart })
	table.clear(_spawnPositions)
	for _, part in points do
		table.insert(_spawnPositions, part.Position)
	end
end

local function _isNearSpawn(pos: Vector3): boolean
	for _, spawnPos in _spawnPositions do
		local d = pos - spawnPos
		if d:Dot(d) < SPAWN_IGNORE_RADIUS2 then
			return true
		end
	end
	return false
end

local function _labelText(marker: Marker): string
	-- STALL no lleva "lvl": no hay escalada, es un evento binario del walk loop.
	-- Ponerle un número lo haría indistinguible de una escalada del
	-- StuckDetector, que es justo lo que hay que poder separar de un vistazo.
	local head = if marker.kind == KIND_STALL
		then "STALL"
		else string.format("STUCK · lvl %d", marker.maxLevel)
	if marker.count > 1 then
		return string.format("%s x%d", head, marker.count)
	end
	return head
end

local function _applyLevelVisuals(marker: Marker)
	local size = SIZE_BY_LEVEL[marker.maxLevel] or SIZE_BY_LEVEL[2]
	marker.part.Size = Vector3.new(size, size, size)
	marker.label.Text = _labelText(marker)
end

-- Llamado por StuckDetector en cada escalada de nivel >= 2. `pos` es la
-- posición del rootPart en el momento del atasco (en nivel 4, ANTES del
-- teleport — si no, marcaríamos el destino en vez del problema).
function StuckViz.mark(pos: Vector3, level: number, botName: string, kind: string?)
	if not _enabled then
		return
	end

	if _isNearSpawn(pos) then
		return
	end

	local markKind = kind or KIND_STUCK

	-- El `kind` entra en la clave de agregación: un STALL y un STUCK en la misma
	-- celda son dos diagnósticos distintos y tienen que salir como dos markers.
	local key = string.format(
		"%s|%d,%d,%d",
		markKind,
		math.floor(pos.X / GRID_SIZE),
		math.floor(pos.Y / GRID_SIZE),
		math.floor(pos.Z / GRID_SIZE)
	)

	local existing = _markers[key]
	if existing and existing.part.Parent then
		existing.count += 1
		if level > existing.maxLevel then
			existing.maxLevel = level
		end
		_applyLevelVisuals(existing)
		return
	end

	if _markerCount >= MAX_MARKERS then
		if not _capWarned then
			_capWarned = true
			warn(string.format(
				"[StuckViz] Límite de %d markers alcanzado — no se añaden más. StuckViz.clear() para reiniciar.",
				MAX_MARKERS
			))
		end
		return
	end

	local part = Instance.new("Part")
	part.Name = "StuckMarker"
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = if markKind == KIND_STALL then COLOR_ORANGE else COLOR_PINK
	part.Transparency = 0.3
	part.Position = pos
	part:SetAttribute("Bot", botName)

	-- AlwaysOnTop: el punto interesante suele estar pegado a geometría (esquina,
	-- rampa, hueco), así que el marker queda medio enterrado. El billboard se ve
	-- a través de las paredes para poder localizarlo desde lejos.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "StuckLabel"
	billboard.Size = UDim2.fromScale(8, 1.6)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 300

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = if markKind == KIND_STALL then COLOR_ORANGE else COLOR_PINK
	label.TextStrokeTransparency = 0.4
	label.Parent = billboard

	billboard.Parent = part
	part.Parent = _ensureFolder()

	local marker: Marker = {
		part = part,
		label = label,
		count = 1,
		maxLevel = level,
		kind = markKind,
	}
	_markers[key] = marker
	_markerCount += 1
	_applyLevelVisuals(marker)
end

-- Para Command Bar: borra todos los markers sin tocar el attribute.
function StuckViz.clear()
	_clearAll()
end

return StuckViz
