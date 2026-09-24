--!strict
--[[
	Kill effect BlockBlast, parte de cliente (el servidor solo congela el cuerpo): el
	cuerpo estalla en cubos de tamaños variados. Cada pieza visible (ropa y accesorios
	incluidos) se trocea en una rejilla de cubos de su color con variación de tono; salen
	despedidos desde el torso (más rápido cuanto más lejos), se amontonan y, al final, se
	encogen escalonados hasta desaparecer: con el fundido del cadáver, al borrarse este o
	a los LIFETIME s, lo que llegue antes.

	Física solo en este cliente: sin red, y cada uno ve su propio reparto. Los cubos van en
	CollisionGroups.DEBRIS: chocan con el mapa y entre sí, no con personajes (el jugador
	local no puede subirse a ellos ni empujarlos).

	Barato a propósito: pocos cubos (MAX_BLOCKS; si un cuerpo daría más, primero se
	agrandan y lo que siga sobrando se descarta al azar) y sin sombras.

	Plantilla OPCIONAL: ReplicatedStorage.Templates.Block (BasePart): cada cubo la clona
	con su aspecto (color, material, texturas) y el tamaño del cubo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CollisionGroups = require(Shared:WaitForChild("CollisionGroups"))
local Utils = require(Shared:WaitForChild("Locker"):WaitForChild("killEffects"):WaitForChild("Utils"))
local Types = require(script.Parent.Parent.KillEffectTypes)

-- Distancias y velocidades para un cuerpo normal; se escalan con él.
local CONFIG = {
	TEMPLATE_NAME = "Block",
	CUBE_SIZE = 1, -- studs de lado de la rejilla
	-- Cada cubo sale con su propio lado: CUBE_SIZE por un factor al azar en este rango.
	SIZE_MIN = 0.55,
	SIZE_MAX = 1.35,
	MAX_BLOCKS = 28, -- tope duro: si sobran, se descartan al azar
	MAX_PER_PART = 4, -- accesorios con caja grande (pelo) no llenan de cubos el aire
	SHADE = 0.08, -- variación de brillo de cada cubo (±)

	SPEED_OUT = 5, -- studs/s hacia fuera por cada stud de distancia al torso
	SPEED_OUT_MAX = 14,
	SPEED_UP_MIN = 7,
	SPEED_UP_MAX = 13,
	SPIN = 10, -- rad/s máx por eje

	FLASH_SIZE = 4, -- diámetro final del destello
	FLASH_TIME = 0.18,

	LIFETIME = 6, -- s como mucho en el suelo
	SHRINK_TIME = 0.25, -- s que tarda cada cubo en encogerse
	SHRINK_STAGGER = 0.3, -- s de retraso máximo entre cubos al encogerse
	LATE_TOLERANCE = 0.5, -- quien llega más tarde no ve la explosión
}

type Cell = { cf: CFrame, color: Color3 }

local BlockBlast = {}

local _folder: Folder? = nil
local _rng = Random.new()

local function getFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "BlockBlastVisuals"
	folder.Parent = workspace
	_folder = folder
	return folder
end

local function findTemplate(): BasePart?
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	local template = if templates then templates:FindFirstChild(CONFIG.TEMPLATE_NAME) else nil
	return if template and template:IsA("BasePart") then template else nil
end

local function hideLocally(char: Model)
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") or desc:IsA("Decal") then -- Texture hereda de Decal
			desc.Transparency = 1
		end
	end
end

-- Cubos por eje de una pieza: al menos 1, y las piezas finas no se multiplican.
local function gridOf(size: Vector3, cube: number): (number, number, number)
	return math.max(1, math.round(size.X / cube)), math.max(1, math.round(size.Y / cube)), math.max(1, math.round(size.Z / cube))
end

local function countCells(sources: { BasePart }, cube: number): number
	local total = 0
	for _, source in sources do
		local nx, ny, nz = gridOf(source.Size, cube)
		total += math.min(nx * ny * nz, CONFIG.MAX_PER_PART)
	end
	return total
end

-- Centros de la rejilla de cada pieza, en su propio espacio (giran con ella).
local function buildCells(sources: { BasePart }, cube: number): { Cell }
	local cells: { Cell } = {}
	for _, source in sources do
		local size = source.Size
		local nx, ny, nz = gridOf(size, cube)
		local stepX, stepY, stepZ = size.X / nx, size.Y / ny, size.Z / nz
		local offsets: { Vector3 } = {}
		for ix = 1, nx do
			for iy = 1, ny do
				for iz = 1, nz do
					table.insert(offsets, Vector3.new(
						-size.X / 2 + (ix - 0.5) * stepX,
						-size.Y / 2 + (iy - 0.5) * stepY,
						-size.Z / 2 + (iz - 0.5) * stepZ
					))
				end
			end
		end
		-- Si pasa del tope por pieza, se queda con un muestreo repartido de la rejilla.
		local take = math.min(#offsets, CONFIG.MAX_PER_PART)
		local stride = #offsets / take
		for i = 0, take - 1 do
			local offset = offsets[math.floor(i * stride) + 1]
			table.insert(cells, { cf = source.CFrame * CFrame.new(offset), color = source.Color })
		end
	end
	return cells
end

local function shade(color: Color3): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, s, math.clamp(v * (1 + _rng:NextNumber(-CONFIG.SHADE, CONFIG.SHADE)), 0, 1))
end

local function makeCube(cell: Cell, cube: number, template: BasePart?): BasePart
	local block: BasePart
	if template then
		block = template:Clone()
	else
		local part = Instance.new("Part")
		part.Material = Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Color = shade(cell.color)
		block = part
	end
	block.Name = "Block"
	block.Size = Vector3.one * cube * _rng:NextNumber(CONFIG.SIZE_MIN, CONFIG.SIZE_MAX)
	block.CFrame = cell.cf
	block.Anchored = false
	block.CanCollide = true
	block.CanQuery = false
	block.CanTouch = false
	block.CastShadow = false
	-- Sin el grupo (registro fallido) chocaría con los jugadores: mejor el de cadáver.
	local grouped = pcall(function()
		block.CollisionGroup = CollisionGroups.DEBRIS
	end)
	if not grouped then
		block.CollisionGroup = CollisionGroups.RAGDOLL
	end
	return block
end

local function flash(center: Vector3, scale: number)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.Neon
	ball.Color = Color3.new(1, 1, 1)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Size = Vector3.one * 0.5 * scale
	ball.CFrame = CFrame.new(center)
	ball.Transparency = 0.2
	ball.Parent = getFolder()
	local tween = TweenService:Create(
		ball,
		TweenInfo.new(CONFIG.FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * CONFIG.FLASH_SIZE * scale, Transparency = 1 }
	)
	tween.Completed:Once(function()
		ball:Destroy()
	end)
	tween:Play()
end

function BlockBlast.play(char: Model, ctx: Types.Ctx)
	if not ctx.isFresh(CONFIG.LATE_TOLERANCE) then
		hideLocally(char)
		return
	end

	-- ANTES de ocultar: qué se ve y dónde.
	local sources: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") and desc.Transparency < 1 and desc.Name ~= "HumanoidRootPart" then
			table.insert(sources, desc)
		end
	end
	local center = Utils.bodyCenter(char)
	local scale = Utils.bodyScale(char)

	-- Cubos más grandes hasta caber en el tope.
	local cube = CONFIG.CUBE_SIZE * scale
	for _ = 1, 4 do
		local total = countCells(sources, cube)
		if total <= CONFIG.MAX_BLOCKS then
			break
		end
		cube *= (total / CONFIG.MAX_BLOCKS) ^ (1 / 3)
	end
	local cells = buildCells(sources, cube)
	-- Con muchas piezas (outfits con muchos accesorios) ni agrandando se baja del tope.
	while #cells > CONFIG.MAX_BLOCKS do
		local i = _rng:NextInteger(1, #cells)
		cells[i] = cells[#cells]
		cells[#cells] = nil
	end
	hideLocally(char)

	local template = findTemplate()
	local folder = getFolder()
	local blocks: { BasePart } = {}
	for _, cell in cells do
		local block = makeCube(cell, cube, template)
		block.Parent = folder
		table.insert(blocks, block)

		local out = cell.cf.Position - center
		local flat = Vector3.new(out.X, 0, out.Z)
		local dir = if flat.Magnitude > 1e-3
			then flat.Unit
			else Vector3.new(_rng:NextNumber(-1, 1), 0, _rng:NextNumber(-1, 1)).Unit
		local speedOut = math.min(out.Magnitude / scale * CONFIG.SPEED_OUT, CONFIG.SPEED_OUT_MAX) + _rng:NextNumber(0, 2)
		block.AssemblyLinearVelocity = (
			dir * speedOut + Vector3.yAxis * _rng:NextNumber(CONFIG.SPEED_UP_MIN, CONFIG.SPEED_UP_MAX)
		) * scale
		block.AssemblyAngularVelocity = Vector3.new(
			_rng:NextNumber(-CONFIG.SPIN, CONFIG.SPIN),
			_rng:NextNumber(-CONFIG.SPIN, CONFIG.SPIN),
			_rng:NextNumber(-CONFIG.SPIN, CONFIG.SPIN)
		)
	end
	flash(center, scale)

	-- Una sola vez: con el fundido del cadáver, al borrarse o al agotar LIFETIME. Cada
	-- cubo se encoge con su propio retraso, dentro de `duration`.
	local gone = false
	local function shrinkAway(duration: number)
		if gone then
			return
		end
		gone = true
		local shrink = math.min(CONFIG.SHRINK_TIME, duration)
		local stagger = math.max(duration - shrink, 0)
		for _, block in blocks do
			local delay = _rng:NextNumber(0, math.min(stagger, CONFIG.SHRINK_STAGGER))
			local tween = TweenService:Create(
				block,
				TweenInfo.new(shrink, Enum.EasingStyle.Back, Enum.EasingDirection.In, 0, false, delay),
				{ Size = Vector3.one * 0.05 }
			)
			tween.Completed:Once(function()
				block:Destroy()
			end)
			tween:Play()
		end
	end
	ctx.onFadeOut(shrinkAway)
	ctx.add(task.delay(CONFIG.LIFETIME, shrinkAway, CONFIG.SHRINK_TIME + CONFIG.SHRINK_STAGGER))
	ctx.add(function()
		shrinkAway(CONFIG.SHRINK_TIME + CONFIG.SHRINK_STAGGER)
	end)
end

function BlockBlast.stop()
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

return BlockBlast
