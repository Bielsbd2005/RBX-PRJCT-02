--!strict
--[[
	Marca en el mapa dónde se atascan los bots. Se activa con el BoolValue
	ServerStorage.ShowStuckMarkers; ponerlo a false limpia Workspace.BotStuckDebug.

	Markers persistentes y agregados por celda de GRID_SIZE para ver zonas
	problemáticas tras una partida. No dejar on en producción: las Parts replican.
]]

local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local FLAG_NAME = "ShowStuckMarkers"

local FOLDER_NAME = "BotStuckDebug"
local COLOR_PINK = Color3.fromRGB(255, 0, 170)
-- Stalls del walk loop: fallo distinto al del StuckDetector. Ver KIND_*.
local COLOR_ORANGE = Color3.fromRGB(255, 140, 0)
local GRID_SIZE = 8 -- studs por celda de agregación
local MAX_MARKERS = 250

--   STUCK — el StuckDetector escaló: el bot está quieto. `level` = peldaño
--           (2 repath / 3 jump / 4 teleport).
--   STALL — el walk loop abandonó un waypoint: el bot se mueve pero no progresa
--           (el StuckDetector solo mira velocidad). `level` no aplica.
local KIND_STUCK = "stuck"
local KIND_STALL = "stall"

-- Los empujones entre bots en el pad de spawn no son defecto de geometría.
-- Complementa la gracia temporal de StuckDetector (bots que salen tarde).
local SPAWN_IGNORE_RADIUS = 16
local SPAWN_IGNORE_RADIUS2 = SPAWN_IGNORE_RADIUS * SPAWN_IGNORE_RADIUS

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

-- Bool cacheado: mark() se llama desde el tick del StuckDetector.
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

-- AIService la llama en OnRoundStart. Se guardan posiciones y no Parts porque
-- el mapa se destruye al acabar la ronda.
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
	-- STALL no lleva "lvl" para distinguirlo de un vistazo de una escalada.
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

-- Llamado por StuckDetector en cada escalada de nivel >= 2. En nivel 4 `pos`
-- debe ser la posición ANTES del teleport.
function StuckViz.mark(pos: Vector3, level: number, botName: string, kind: string?)
	if not _enabled then
		return
	end

	if _isNearSpawn(pos) then
		return
	end

	local markKind = kind or KIND_STUCK

	-- `kind` va en la clave: STALL y STUCK en la misma celda son markers distintos.
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

	-- AlwaysOnTop: el marker suele quedar medio enterrado en geometría.
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

-- Para Command Bar: borra los markers sin tocar el BoolValue.
function StuckViz.clear()
	_clearAll()
end

return StuckViz
