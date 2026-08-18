--!strict
--[[
	Renderer — dibuja marcadores, anillos y spawns de dummies con *HandleAdornment.

	Por qué adornments y no Parts:
	  • No se guardan en el DataModel (no ensucian el .rbxl ni el sourcemap).
	  • No entran en el historial de undo/redo.
	  • No son seleccionables ni chocan con nada.
	Se parentan a un Folder dentro de CoreGui; los adornments renderizan en el
	viewport 3D siempre que tengan Adornee válido. Usamos Terrain como Adornee
	ancla (CFrame identidad en el origen) y colocamos cada adornment por
	worldspace vía su propiedad .CFrame — así no dependemos de que cada punto
	sea el Adornee (si movés un punto, regenerás con un clic; no hay realtime).

	Anillos de alcance: dos discos planos translúcidos (CylinderHandleAdornment)
	de radio RoamMin y RoamMax alrededor del punto seleccionado. El "anillo real"
	de picking es el ANILLO entre ambos radios (RoamGraph:pickRandomNavigablePoint
	elige uniformemente en [minDist, maxDist]). Se dibujan como discos concéntricos
	para que la corona entre ellos sea legible de un vistazo.

	Puntos de spawn: una esfera sobre cada BasePart de <Mapa>/Spawns + una FLECHA
	que apunta hacia donde mirará quien aparezca ahí — jugadores y NPCs de IA por
	igual. Es fiel al juego: SpawnService/AIService colocan el cuerpo en
	spawnPoint.CFrame, y la orientación de aparición es el YAW de la part
	(SpawnService estampa SpawnYaw = atan2(-look.X, -look.Z) y la ShoulderCamera del
	cliente la respeta; los bots la toman vía PivotTo). Por eso aplanamos el
	LookVector al plano XZ (ver drawSpawnPoints): rotar la part en su eje Y controla
	esta flecha Y la orientación real de aparición. Se dibuja con LineHandleAdornment
	(igual que las rutas): se extiende desde su CFrame a lo largo del LookVector, y
	CFrame.lookAt(a,b) orienta ese LookVector de a hacia b — verificado en PathViz.
	AlwaysOnTop para que se lea siempre.

	La apariencia (colores/tamaños) vive en Style.luau; acá solo se dibuja.
]]

local CoreGui = game:GetService("CoreGui")

local Config = require(script.Parent.Config)
local Style = require(script.Parent.Style)

local Renderer = {}
Renderer.__index = Renderer

local CONTAINER_NAME = "RoamViz_Adornments"

export type Renderer = typeof(setmetatable(
	{} :: { _container: Folder },
	Renderer
))

function Renderer.new(): Renderer
	-- reutilizar un contenedor previo si quedó de una sesión anterior
	local existing = CoreGui:FindFirstChild(CONTAINER_NAME)
	if existing and existing:IsA("Folder") then
		existing:ClearAllChildren()
	end
	local container = (existing :: Folder?) or Instance.new("Folder")
	container.Name = CONTAINER_NAME
	container.Parent = CoreGui
	return setmetatable({ _container = container }, Renderer)
end

-- Borra todos los adornments actuales.
function Renderer:clear()
	self._container:ClearAllChildren()
end

local function anchor(): BasePart
	return workspace.Terrain
end

-- Una esfera en worldPos con color/radio/transparencia explícitos.
local function makeSphere(pos: Vector3, radius: number, color: Color3, transparency: number): SphereHandleAdornment
	local sphere = Instance.new("SphereHandleAdornment")
	sphere.Adornee = anchor()
	sphere.Radius = radius
	sphere.Color3 = color
	sphere.Transparency = transparency
	sphere.ZIndex = 1
	sphere.AlwaysOnTop = false
	sphere.CFrame = CFrame.new(pos)
	return sphere
end

-- Un disco plano horizontal de radio `radius` centrado en `pos`.
-- CylinderHandleAdornment se extruye a lo largo de su eje Z local; rotamos
-- 90° en X para que ese eje quede vertical y el disco quede tumbado en el
-- plano XZ (el suelo). Height pequeño = disco fino.
local function makeDisc(pos: Vector3, radius: number, color: Color3, transparency: number): CylinderHandleAdornment
	local disc = Instance.new("CylinderHandleAdornment")
	disc.Adornee = anchor()
	disc.Radius = radius
	disc.Height = 0.2
	disc.Color3 = color
	disc.Transparency = transparency
	disc.ZIndex = 0
	disc.AlwaysOnTop = false
	-- Centrar en Y: el cilindro se extruye desde su CFrame hacia +Z local;
	-- lo bajamos medio Height para que quede centrado en el punto.
	disc.CFrame = CFrame.new(pos) * CFrame.Angles(math.rad(90), 0, 0) * CFrame.new(0, 0, -0.1)
	return disc
end

-- Un segmento de línea de `a` a `b` (grosor en px, screen-space). AlwaysOnTop
-- para que la flecha de orientación se lea aunque haya geometría delante.
local function makeLine(a: Vector3, b: Vector3, thickness: number, color: Color3): LineHandleAdornment
	local line = Instance.new("LineHandleAdornment")
	line.Adornee = anchor()
	line.Length = (b - a).Magnitude
	line.Thickness = thickness
	line.Color3 = color
	line.Transparency = 0
	line.ZIndex = 3
	line.AlwaysOnTop = true
	line.CFrame = CFrame.lookAt(a, b)
	return line
end

-- Dibuja marcadores para todos los RoamPoints.
function Renderer:drawMarkers(points: { BasePart }, _state: Config.State)
	for _, part in points do
		local marker = makeSphere(part.Position, Style.markerRadius, Style.markerColor, Style.markerTransparency)
		marker.Parent = self._container
	end
end

-- Dibuja los dos discos de alcance (min/max) alrededor de un centro.
-- El disco exterior (max) va más transparente para que el interior (min) y la
-- corona entre ambos se distingan.
function Renderer:drawRings(center: Vector3, state: Config.State)
	local outer = makeDisc(center, state.roamMaxDist, Style.ringColor, Style.ringTransparency)
	outer.Parent = self._container

	-- interior: mismo color, un punto menos transparente y ligeramente elevado
	-- para evitar z-fighting con el exterior.
	local innerCenter = center + Vector3.new(0, 0.05, 0)
	local inner = makeDisc(innerCenter, state.roamMinDist, Style.ringColor, math.min(1, Style.ringTransparency + 0.1))
	inner.Parent = self._container
end

-- Flecha HORIZONTAL que sale de `origin` y apunta hacia `forward` (que ya viene
-- aplanado al plano XZ, ver drawSpawnPoints). Se compone de un cuerpo + dos barbas
-- que forman la punta en V, abiertas sobre el eje Y del mundo para que la flecha
-- quede tumbada y se lea como un "hacia dónde mira" sobre el suelo.
function Renderer:_drawArrow(origin: Vector3, forward: Vector3)
	if forward.Magnitude < 1e-4 then
		return
	end
	local f = forward.Unit
	local tip = origin + f * Style.spawnArrowLength

	-- cuerpo
	makeLine(origin, tip, Style.spawnArrowThickness, Style.spawnArrowColor).Parent = self._container

	-- barbas: desde la punta hacia atrás y hacia afuera (±ángulo respecto de -f),
	-- girando sobre el eje Y del mundo (flecha horizontal).
	local back = -f
	local ang = math.rad(Style.spawnArrowHeadAngle)
	local left = CFrame.fromAxisAngle(Vector3.yAxis, ang):VectorToWorldSpace(back)
	local right = CFrame.fromAxisAngle(Vector3.yAxis, -ang):VectorToWorldSpace(back)
	makeLine(tip, tip + left * Style.spawnArrowHeadLength, Style.spawnArrowThickness, Style.spawnArrowColor).Parent = self._container
	makeLine(tip, tip + right * Style.spawnArrowHeadLength, Style.spawnArrowThickness, Style.spawnArrowColor).Parent = self._container
end

-- Dibuja, por cada punto de spawn del mapa, una esfera + la flecha de orientación.
--
-- La dirección aplanada (yaw) coincide EXACTAMENTE con la orientación real de
-- aparición: SpawnService estampa SpawnYaw = atan2(-look.X, -look.Z) y el juego la
-- aplica tanto a jugadores (ShoulderCamera) como a bots (PivotTo). Aplanamos el
-- LookVector a XZ porque el personaje aparece ERGUIDO (solo cuenta el yaw): así, si
-- una part de Spawns está inclinada, la flecha coincide con el personaje; el
-- LookVector 3D crudo se iría hacia arriba/abajo y no cuadraría. Rotar la part en
-- su eje Y controla esta flecha y la orientación real por igual.
function Renderer:drawSpawnPoints(spawns: { BasePart })
	for _, part in spawns do
		local sphere = makeSphere(part.Position, Style.spawnRadius, Style.spawnColor, Style.spawnTransparency)
		sphere.Parent = self._container

		local look = part.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 1e-4 then
			-- Spawn mirando casi recto arriba/abajo: sin yaw definido; sin flecha.
			continue
		end
		self:_drawArrow(part.Position, flat.Unit)
	end
end

-- Libera el contenedor por completo (al descargar el plugin).
function Renderer:destroy()
	if self._container then
		self._container:Destroy()
	end
end

return Renderer
