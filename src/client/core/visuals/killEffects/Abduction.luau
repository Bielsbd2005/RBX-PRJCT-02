--!strict
--[[
	Kill effect Abduction, parte de cliente: el servidor convierte el cadáver en
	ragdoll y tira de él con física hacia la panza del OVNI; aquí se monta un OVNI
	ligero, se trae volando, se abre el rayo tractor y se le pone todo el jugo. El OVNI
	no se ata al contexto: si el cadáver se destruye, termina de irse igual.

	El vuelo sale de AbductionFlight, el mismo que simula el servidor para saber
	hacia dónde tirar del cuerpo: se pinta interpolando entre pasos fijos, así que
	se ve igual a cualquier fps y quien llega tarde entra a mitad de secuencia.

	Secuencia (s desde la muerte, ver Abduction.TIMING):
	  0          el OVNI aparece lejos y alto, ya lanzado hacia el cuerpo
	  BEAM_ON    se abre el rayo: onda en el suelo y el cuerpo empieza a brillar
	             con el color del rayo
	  SUCK       el rayo se ensancha mientras succiona el cuerpo
	  (entra)    el cuerpo se funde al acercarse a la panza (por distancia real, así
	             sigue a la física replicada con su retraso): destello de luz y el
	             rayo se recoge
	  LEAVE      amago hacia abajo y sale en curva hacia el cielo, acelerando,
	             inclinado hacia donde va y encogiendo hasta perderse
	  END        fuera

	Plantilla OPCIONAL (Abduction.findTemplate): una versión ligera del modelo del
	OVNI. Se escala sola a CONFIG.UFO_DIAMETER, se anclan sus partes y se quitan
	scripts, Humanoid, joints y constraints. Gira como casco lo que va unido a la
	Part1 del Motor6D "BodyMotor" (el rig del OVNI del juego) o, si no hay, lo que se
	llame "Body". Si trae un Sound, suena al aparecer. Sin plantilla se monta un OVNI
	procedural, así el efecto funciona sin arte en el place.

	Eficiencia:
	  · Un único RenderStepped para todas las abducciones y sólo mientras haya
	    alguna; se desconecta solo.
	  · Todo anclado, sin colisión, query, touch ni sombra, y colocado con
	    BulkMoveTo. El tamaño de las partes sólo se escribe mientras encogen.
	  · Más allá de CULL_DISTANCE no se monta nada.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local killEffects = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects")
local Abduction = require(killEffects:WaitForChild("Abduction"))
local AbductionFlight = require(killEffects:WaitForChild("AbductionFlight"))
local Types = require(script.Parent.Parent.KillEffectTypes)

local ATTR = Abduction.ATTR
local TIMING = Abduction.TIMING
local FLIGHT = AbductionFlight.CONFIG

local CONFIG = {
	CULL_DISTANCE = 300, -- studs desde la cámara
	EXIT_SHRINK_DELAY = 0.12, -- s de la salida antes de empezar a encoger (el amago se ve a tamaño completo)

	-- Rayo
	BEAM_GROW_TIME = 0.14,
	BEAM_RETRACT_TIME = 0.16,
	BEAM_TOP_WIDTH = 3,
	BEAM_BOTTOM_WIDTH = 9,
	BEAM_CORE = 0.4, -- ancho del núcleo respecto al cono
	BEAM_PULSE = 0.08, -- fracción de ancho (±)
	BEAM_PULSE_FREQ = 18, -- rad/s
	BEAM_SUCK_FLARE = 0.35, -- fracción extra de ancho mientras succiona
	BEAM_COLOR = Color3.fromRGB(120, 255, 190),
	RING_DIAMETER = 8,
	RING_TRANSPARENCY = { 0.35, 0.6 }, -- latido
	LIGHT_BRIGHTNESS = 3,
	LIGHT_RANGE = 16,

	-- Onda en el suelo al abrirse el rayo
	SHOCK_TIME = 0.4,
	SHOCK_GROWTH = 2.2, -- diámetro final = RING_DIAMETER × (1 + esto)
	SHOCK_TRANSPARENCY = 0.15,

	-- Cuerpo
	GLOW_IN_TIME = 0.25,
	GLOW_FILL = 0.55, -- FillTransparency del brillo a tope
	GLOW_OUTLINE = 0.15,
	FADE_NEAR = 1, -- studs a la panza en los que ya es invisible
	FADE_FAR = 4.5, -- studs a la panza desde los que empieza a fundirse
	FADE_FALLBACK_AT = 0.2, -- s tras BODY_GONE en que se funde sí o sí (lag, techos)
	FADE_FALLBACK_TIME = 0.15,
	GULP_AT_FADE = 0.85, -- fundido a partir del cual el OVNI traga

	-- Trago: destello de luz y se recoge el rayo
	FLASH_TIME = 0.35,
	FLASH_BRIGHTNESS = 8,
	FLASH_RANGE = 22,
}

local TAU = 2 * math.pi
local UPRIGHT_DISC = CFrame.Angles(0, 0, math.pi / 2) -- Cylinder: el eje es X

type UfoPart = {
	part: BasePart,
	offset: CFrame, -- respecto al root del OVNI
	size: Vector3,
	body: boolean, -- gira con el casco
	mesh: SpecialMesh?,
	meshScale: Vector3,
}

type Rig = {
	model: Model,
	parts: { UfoPart },
	spinPivot: CFrame, -- eje del giro del casco, en espacio del root
	belly: Vector3, -- punto del que sale el rayo, en espacio del root
	sound: Sound?,
}

type BodyPart = { part: BasePart, transparency: number }
type BodyDecal = { decal: Decal, transparency: number }

type Abduct = {
	char: Model,
	startedAt: number,
	scale: number,
	origin: CFrame,
	groundY: number,
	rig: Rig,
	flight: AbductionFlight.Flight,
	ufoParts: { BasePart },
	ufoCFrames: { CFrame },
	beamTop: Part,
	beamBottom: Part,
	beamOuter: Beam,
	beamCore: Beam,
	ring: Part,
	shock: Part,
	light: PointLight,
	flash: PointLight,
	beamVisible: boolean,
	shockVisible: boolean,
	soundPlayed: boolean,
	grab: BasePart?,
	bodyParts: { BodyPart },
	bodyDecals: { BodyDecal },
	highlight: Highlight,
	bodyFade: number,
	bodyDone: boolean,
	gulpAt: number?,
}

local AbductionVisuals = {}

local _renderConn: RBXScriptConnection? = nil
local _active: { [Model]: Abduct } = {}
local _folder: Folder? = nil

local function debugWarn(message: string)
	if RunService:IsStudio() then
		warn("[AbductionVisuals] " .. message)
	end
end

local function getFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "AbductionVisuals"
	folder.Parent = workspace
	_folder = folder
	return folder
end

local function ease(alpha: number, style: Enum.EasingStyle, direction: Enum.EasingDirection): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style, direction)
end

local function scaled(cf: CFrame, s: number): CFrame
	return CFrame.new(cf.Position * s) * cf.Rotation
end

local function makeCosmetic(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

local function addUfoPart(rig: Rig, part: BasePart, offset: CFrame, body: boolean)
	makeCosmetic(part)
	local mesh = part:FindFirstChildWhichIsA("SpecialMesh")
	table.insert(rig.parts, {
		part = part,
		offset = offset,
		size = part.Size,
		body = body,
		mesh = mesh,
		meshScale = if mesh then mesh.Scale else Vector3.one,
	})
end

-- OVNI procedural: casco achatado con luces de borde (giran), cápsula de cristal
-- con su aro y un disco de luz en la panza (fijos).
local function buildProceduralRig(scale: number): Rig
	local u = FLIGHT.UFO_DIAMETER * scale / 12
	local model = Instance.new("Model")
	model.Name = "AbductionUFO"
	local rig: Rig = {
		model = model,
		parts = {},
		spinPivot = CFrame.identity,
		belly = Vector3.new(0, -FLIGHT.BELLY_DEPTH * u, 0),
		sound = nil,
	}

	local function make(
		name: string,
		size: Vector3,
		color: Color3,
		material: Enum.Material,
		offset: CFrame,
		body: boolean
	): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size * u
		part.Color = color
		part.Material = material
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		addUfoPart(rig, part, scaled(offset, u), body)
		return part
	end

	local function ellipsoid(part: Part)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
		-- addUfoPart ya pasó: apuntar la malla a mano.
		local entry = rig.parts[#rig.parts]
		entry.mesh = mesh
		entry.meshScale = mesh.Scale
	end

	local hull = make("Hull", Vector3.new(12, 2.2, 12), Color3.fromRGB(165, 172, 184), Enum.Material.Metal, CFrame.identity, true)
	hull.Reflectance = 0.25
	ellipsoid(hull)

	local rim = make("Rim", Vector3.new(12.6, 0.6, 12.6), Color3.fromRGB(62, 68, 84), Enum.Material.SmoothPlastic, CFrame.identity, true)
	ellipsoid(rim)

	local collar = make(
		"Collar",
		Vector3.new(0.5, 6.2, 6.2),
		Color3.fromRGB(90, 96, 112),
		Enum.Material.Metal,
		CFrame.new(0, 0.95, 0) * UPRIGHT_DISC,
		false
	)
	collar.Shape = Enum.PartType.Cylinder

	local dome = make("Dome", Vector3.new(5.4, 4.2, 5.4), Color3.fromRGB(120, 220, 255), Enum.Material.Glass, CFrame.new(0, 1.3, 0), false)
	dome.Transparency = 0.35
	ellipsoid(dome)

	local belly = make("Belly", Vector3.new(0.25, 4, 4), CONFIG.BEAM_COLOR, Enum.Material.Neon, CFrame.new(0, -1.02, 0) * UPRIGHT_DISC, false)
	belly.Shape = Enum.PartType.Cylinder

	local lights = 8
	for i = 1, lights do
		local angle = (i / lights) * TAU
		local color = if i % 2 == 0 then Color3.fromRGB(255, 220, 90) else Color3.fromRGB(110, 240, 255)
		local bulb = make(
			"RimLight",
			Vector3.one * 0.75,
			color,
			Enum.Material.Neon,
			CFrame.new(math.cos(angle) * 6.1, 0.05, math.sin(angle) * 6.1),
			true
		)
		bulb.Shape = Enum.PartType.Ball
	end

	return rig
end

-- Partes unidas rígidamente a `start` sin pasar por `root` (el grafo de joints).
local function rigidGroup(model: Model, start: BasePart, root: BasePart): { [BasePart]: boolean }
	local links: { [BasePart]: { BasePart } } = {}
	local function link(a: Instance?, b: Instance?)
		if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
			local pa, pb = a :: BasePart, b :: BasePart
			links[pa] = links[pa] or {}
			links[pb] = links[pb] or {}
			table.insert(links[pa], pb)
			table.insert(links[pb], pa)
		end
	end
	for _, d in model:GetDescendants() do
		if (d:IsA("JointInstance") and d.Name ~= "BodyMotor") or d:IsA("WeldConstraint") then
			link((d :: any).Part0, (d :: any).Part1)
		end
	end

	local group: { [BasePart]: boolean } = { [start] = true }
	local queue = { start }
	while #queue > 0 do
		local part = table.remove(queue) :: BasePart
		for _, other in links[part] or {} do
			if other ~= root and not group[other] then
				group[other] = true
				table.insert(queue, other)
			end
		end
	end
	return group
end

local function buildTemplateRig(template: Model, scale: number): Rig?
	local model = template:Clone()
	model.Name = "AbductionUFO"

	local rootInstance = model.PrimaryPart
		or model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChildWhichIsA("BasePart", true)
	if not (rootInstance and rootInstance:IsA("BasePart")) then
		model:Destroy()
		return nil
	end
	local root = rootInstance :: BasePart

	-- A tamaño antes de medir nada (ScaleTo escala también los C0/C1 de los joints).
	local extents = model:GetExtentsSize()
	local width = math.max(extents.X, extents.Z)
	if width > 1e-3 then
		pcall(function()
			model:ScaleTo(model:GetScale() * FLIGHT.UFO_DIAMETER * scale / width)
		end)
	end

	-- Casco: lo que cuelga del BodyMotor (rig del juego) o lo que se llame "Body".
	local rootCF = root.CFrame
	local spinPivot = CFrame.identity
	local bodySet: { [BasePart]: boolean } = {}
	local motor = model:FindFirstChild("BodyMotor", true)
	if motor and motor:IsA("Motor6D") and motor.Part1 then
		local part1 = motor.Part1 :: BasePart
		bodySet = rigidGroup(model, part1, root)
		if motor.Part0 == root then
			spinPivot = motor.C0
		else
			spinPivot = CFrame.new(rootCF:PointToObjectSpace(part1.Position))
		end
	else
		local body = model:FindFirstChild("Body", true)
		if body and body:IsA("BasePart") then
			bodySet = rigidGroup(model, body, root)
		elseif body then
			for _, d in body:GetDescendants() do
				if d:IsA("BasePart") then
					bodySet[d] = true
				end
			end
		end
	end

	local boxCF, boxSize = model:GetBoundingBox()
	local rig: Rig = {
		model = model,
		parts = {},
		spinPivot = spinPivot,
		belly = rootCF:PointToObjectSpace(boxCF.Position - Vector3.new(0, boxSize.Y / 2, 0)),
		sound = nil,
	}

	for _, d in model:GetDescendants() do
		if
			d:IsA("BaseScript")
			or d:IsA("Humanoid")
			or d:IsA("JointInstance")
			or d:IsA("WeldConstraint")
			or d:IsA("Constraint")
			or d:IsA("BodyMover")
		then
			d:Destroy()
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			addUfoPart(rig, d, rootCF:ToObjectSpace(d.CFrame), bodySet[d] == true)
		elseif d:IsA("Sound") and not rig.sound then
			rig.sound = d
		end
	end
	return rig
end

local function buildRig(scale: number): Rig
	local template = Abduction.findTemplate()
	if template then
		local ok, rig = pcall(buildTemplateRig, template, scale)
		if ok and rig then
			return rig
		end
		debugWarn("plantilla " .. template:GetFullName() .. " inutilizable, OVNI procedural: " .. tostring(rig))
	end
	return buildProceduralRig(scale)
end

local function makeAnchor(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.one * 0.2
	part.Transparency = 1
	makeCosmetic(part)
	part.Parent = parent
	return part
end

local function makeDisc(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Material = Enum.Material.Neon
	part.Color = CONFIG.BEAM_COLOR
	part.Size = Vector3.new(0.05, 0.05, 0.05)
	part.LocalTransparencyModifier = 1
	makeCosmetic(part)
	part.Parent = parent
	return part
end

local function makeBeam(a0: Attachment, a1: Attachment, transparency: NumberSequence, parent: Instance): Beam
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Segments = 1
	beam.Color = ColorSequence.new(CONFIG.BEAM_COLOR)
	beam.Transparency = transparency
	beam.Width0 = 0
	beam.Width1 = 0
	beam.Enabled = false
	beam.Parent = parent
	return beam
end

-- Encoge durante toda la salida, con la misma curva de aceleración que el vuelo:
-- casi no encoge mientras arranca y se va cerrando según se lanza, así se pierde
-- en el cielo en vez de cortarse de golpe.
local function zipScale(elapsed: number): number
	local from = TIMING.LEAVE + CONFIG.EXIT_SHRINK_DELAY
	local u = (elapsed - from) / (TIMING.END - from)
	if u <= 0 then
		return 1
	end
	return math.max(0, 1 - ease(u, Enum.EasingStyle.Quad, Enum.EasingDirection.In))
end

-- Coloca el OVNI y devuelve su CFrame y la escala del cierre final.
local function renderUfo(abd: Abduct, elapsed: number): (CFrame, number)
	local ufoCF, spin = AbductionFlight.sample(abd.flight, elapsed)
	local rig = abd.rig
	local spinCF = rig.spinPivot * CFrame.Angles(0, spin % TAU, 0) * rig.spinPivot:Inverse()
	local s = zipScale(elapsed)
	local resize = s < 1

	for i, entry in rig.parts do
		local offset = if entry.body then spinCF * entry.offset else entry.offset
		if resize then
			offset = scaled(offset, s)
		end
		abd.ufoCFrames[i] = ufoCF * offset
	end
	-- El ancla del rayo va al final del mismo lote.
	abd.ufoCFrames[#rig.parts + 1] = ufoCF * CFrame.new(rig.belly * s)
	workspace:BulkMoveTo(abd.ufoParts, abd.ufoCFrames, Enum.BulkMoveMode.FireCFrameChanged)

	if resize then
		local tiny = s < 0.02
		for _, entry in rig.parts do
			entry.part.Size = entry.size * math.max(s, 0.01)
			if entry.mesh then
				entry.mesh.Scale = entry.meshScale * math.max(s, 0.01)
			end
			if tiny then
				entry.part.LocalTransparencyModifier = 1
			end
		end
	end

	local sound = rig.sound
	if sound and not abd.soundPlayed then
		abd.soundPlayed = true
		-- Quien llega tarde no oye una llegada que ya pasó.
		if elapsed < TIMING.BEAM_ON then
			sound:Play()
		end
	end

	return ufoCF, s
end

local function renderBeam(abd: Abduct, elapsed: number, bellyPos: Vector3)
	-- Abrir (0→1) y recoger (1→0) tras el trago
	local open = ease((elapsed - TIMING.BEAM_ON) / CONFIG.BEAM_GROW_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local gulpAt = abd.gulpAt
	local retract = if gulpAt
		then ease((elapsed - gulpAt) / CONFIG.BEAM_RETRACT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		else 0
	local visible = elapsed >= TIMING.BEAM_ON and retract < 1

	if visible ~= abd.beamVisible then
		abd.beamVisible = visible
		abd.beamOuter.Enabled = visible
		abd.beamCore.Enabled = visible
		abd.light.Enabled = visible
		abd.ring.LocalTransparencyModifier = if visible then 0 else 1
	end
	if not visible then
		return
	end

	-- El pie del rayo sube hasta la panza al recogerse.
	local groundPos = Vector3.new(bellyPos.X, abd.groundY + 0.05, bellyPos.Z)
	local bottomPos = groundPos:Lerp(bellyPos, retract)
	abd.beamBottom.CFrame = CFrame.new(bottomPos)

	local scale = abd.scale
	local pulse = 1 + CONFIG.BEAM_PULSE * math.sin(elapsed * CONFIG.BEAM_PULSE_FREQ)
	local flare = 1
		+ CONFIG.BEAM_SUCK_FLARE
			* ease((elapsed - TIMING.SUCK) / (TIMING.BODY_GONE - TIMING.SUCK), Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local width = open * (1 - retract) * pulse * flare * scale
	abd.beamOuter.Width0 = CONFIG.BEAM_TOP_WIDTH * width
	abd.beamOuter.Width1 = CONFIG.BEAM_BOTTOM_WIDTH * width
	abd.beamCore.Width0 = CONFIG.BEAM_TOP_WIDTH * CONFIG.BEAM_CORE * width
	abd.beamCore.Width1 = CONFIG.BEAM_BOTTOM_WIDTH * CONFIG.BEAM_CORE * width

	local ringD = CONFIG.RING_DIAMETER * width
	abd.ring.Size = Vector3.new(0.05, math.max(ringD, 0.05), math.max(ringD, 0.05))
	abd.ring.CFrame = CFrame.new(groundPos) * UPRIGHT_DISC
	local beat = 0.5 + 0.5 * math.sin(elapsed * CONFIG.BEAM_PULSE_FREQ * 0.5)
	local tr = CONFIG.RING_TRANSPARENCY
	abd.ring.Transparency = tr[1] + (tr[2] - tr[1]) * beat + (1 - tr[2]) * retract

	abd.light.Brightness = CONFIG.LIGHT_BRIGHTNESS * open * (1 - retract) * flare
end

-- Onda en el suelo cuando el rayo lo toca.
local function renderShock(abd: Abduct, elapsed: number)
	local u = (elapsed - TIMING.BEAM_ON) / CONFIG.SHOCK_TIME
	local active = u >= 0 and u < 1
	if active ~= abd.shockVisible then
		abd.shockVisible = active
		abd.shock.LocalTransparencyModifier = if active then 0 else 1
	end
	if not active then
		return
	end
	local grow = ease(u, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	local diameter = CONFIG.RING_DIAMETER * abd.scale * (1 + CONFIG.SHOCK_GROWTH * grow)
	local origin = abd.origin.Position
	abd.shock.Size = Vector3.new(0.05, diameter, diameter)
	abd.shock.CFrame = CFrame.new(origin.X, abd.groundY + 0.08, origin.Z) * UPRIGHT_DISC
	abd.shock.Transparency = CONFIG.SHOCK_TRANSPARENCY
		+ (1 - CONFIG.SHOCK_TRANSPARENCY) * ease(u, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
end

local function renderFlash(abd: Abduct, elapsed: number)
	local gulpAt = abd.gulpAt
	local u = if gulpAt then (elapsed - gulpAt) / CONFIG.FLASH_TIME else 1
	local active = u >= 0 and u < 1
	abd.flash.Enabled = active
	if active then
		abd.flash.Brightness = CONFIG.FLASH_BRIGHTNESS * (1 - u) * (1 - u)
	end
end

-- El cuerpo lo mueve la física del servidor: aquí sólo brilla con el rayo y se
-- funde al entrar. El fundido se mide por distancia REAL a la panza, así sigue a
-- la posición replicada (con su retraso) y no se desvanece a medio camino; el
-- tiempo es sólo la red por si nunca llega (techo, lag grande).
local function renderBody(abd: Abduct, elapsed: number, bellyPos: Vector3)
	if abd.bodyDone or elapsed < TIMING.BEAM_ON then
		return
	end

	local fade = abd.bodyFade
	if elapsed >= TIMING.SUCK then
		local grab = abd.grab
		if grab and grab.Parent then
			local dist = (grab.Position - bellyPos).Magnitude / abd.scale
			local near = 1 - math.clamp((dist - CONFIG.FADE_NEAR) / (CONFIG.FADE_FAR - CONFIG.FADE_NEAR), 0, 1)
			fade = math.max(fade, near * near * (3 - 2 * near))
		end
		local late = (elapsed - TIMING.BODY_GONE - CONFIG.FADE_FALLBACK_AT) / CONFIG.FADE_FALLBACK_TIME
		fade = math.max(fade, math.clamp(late, 0, 1))
	end

	if fade >= CONFIG.GULP_AT_FADE and not abd.gulpAt then
		abd.gulpAt = elapsed
	end

	local glow = ease((elapsed - TIMING.BEAM_ON) / CONFIG.GLOW_IN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		* (1 - fade)
	local highlight = abd.highlight
	highlight.Enabled = glow > 0.01
	highlight.FillTransparency = 1 - (1 - CONFIG.GLOW_FILL) * glow
	highlight.OutlineTransparency = 1 - (1 - CONFIG.GLOW_OUTLINE) * glow

	if fade > abd.bodyFade then
		abd.bodyFade = fade
		for _, entry in abd.bodyParts do
			if entry.part.Parent then
				entry.part.Transparency = entry.transparency + (1 - entry.transparency) * fade
			end
		end
		for _, entry in abd.bodyDecals do
			if entry.decal.Parent then
				entry.decal.Transparency = entry.transparency + (1 - entry.transparency) * fade
			end
		end
	end
	if fade >= 1 then
		abd.bodyDone = true
		highlight.Enabled = false
	end
end

local function render(abd: Abduct, elapsed: number)
	AbductionFlight.advance(abd.flight, elapsed)
	local ufoCF, s = renderUfo(abd, elapsed)
	local bellyPos = ufoCF * (abd.rig.belly * s)
	renderBody(abd, elapsed, bellyPos)
	renderBeam(abd, elapsed, bellyPos)
	renderShock(abd, elapsed)
	renderFlash(abd, elapsed)
end

local function finish(char: Model)
	local abd = _active[char]
	if not abd then
		return
	end
	_active[char] = nil
	abd.rig.model:Destroy()
	abd.beamTop:Destroy()
	abd.beamBottom:Destroy()
	abd.ring:Destroy()
	abd.shock:Destroy()
	abd.highlight:Destroy()
end

local function onRender()
	local now = workspace:GetServerTimeNow()
	for char, abd in _active do
		local elapsed = now - abd.startedAt
		if elapsed >= TIMING.END or not abd.rig.model.Parent then
			finish(char)
		else
			local ok, err = pcall(render, abd, elapsed)
			if not ok then
				debugWarn(tostring(err))
				finish(char)
			end
		end
	end
	if next(_active) == nil and _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end
end

local function captureBody(abd: Abduct)
	for _, d in abd.char:GetDescendants() do
		-- Las cajas internas del ragdoll ya son invisibles: no hay nada que fundir.
		if d:IsA("BasePart") and d.Transparency < 1 then
			table.insert(abd.bodyParts, { part = d, transparency = d.Transparency })
		elseif d:IsA("Decal") and d.Transparency < 1 then
			table.insert(abd.bodyDecals, { decal = d, transparency = d.Transparency })
		end
	end
end

function AbductionVisuals.play(char: Model, _ctx: Types.Ctx)
	if _active[char] then
		return
	end
	local startedAt = char:GetAttribute(ATTR.STARTED_AT)
	local origin = char:GetAttribute(ATTR.ORIGIN)
	if type(startedAt) ~= "number" or typeof(origin) ~= "CFrame" then
		return
	end
	if workspace:GetServerTimeNow() - startedAt >= TIMING.END then
		return
	end
	local originCF = origin :: CFrame

	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - originCF.Position).Magnitude > CONFIG.CULL_DISTANCE then
		return
	end

	local scaleAttr = char:GetAttribute(ATTR.SCALE)
	local seedAttr = char:GetAttribute(ATTR.SEED)
	local groundAttr = char:GetAttribute(ATTR.GROUND_Y)
	local scale = if type(scaleAttr) == "number" and scaleAttr > 0 then scaleAttr else 1
	local seed = if type(seedAttr) == "number" then seedAttr else 1

	local folder = getFolder()
	-- El suelo del servidor: con otro suelo el OVNI volaría a otra altura que la
	-- panza hacia la que tira la física.
	local groundY = if type(groundAttr) == "number"
		then groundAttr
		else AbductionFlight.findGroundY(originCF.Position, char, { folder }) or (originCF.Position.Y - 3 * scale)
	local rig = buildRig(scale)

	local beamTop = makeAnchor("BeamTop", folder)
	local beamBottom = makeAnchor("BeamBottom", folder)
	local topAtt = Instance.new("Attachment")
	topAtt.Parent = beamTop
	local bottomAtt = Instance.new("Attachment")
	bottomAtt.Parent = beamBottom

	local ring = makeDisc("BeamRing", folder)
	local shock = makeDisc("BeamShock", folder)

	local light = Instance.new("PointLight")
	light.Color = CONFIG.BEAM_COLOR
	light.Range = CONFIG.LIGHT_RANGE * scale
	light.Brightness = 0
	light.Enabled = false
	light.Parent = beamTop

	local flash = Instance.new("PointLight")
	flash.Color = CONFIG.BEAM_COLOR
	flash.Range = CONFIG.FLASH_RANGE * scale
	flash.Brightness = 0
	flash.Enabled = false
	flash.Parent = beamTop

	local highlight = Instance.new("Highlight")
	highlight.Name = "AbductionGlow"
	highlight.Adornee = char
	highlight.FillColor = CONFIG.BEAM_COLOR
	highlight.OutlineColor = CONFIG.BEAM_COLOR
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = folder

	local ufoParts: { BasePart } = {}
	for _, entry in rig.parts do
		table.insert(ufoParts, entry.part)
	end
	table.insert(ufoParts, beamTop)

	local grab = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or char:FindFirstChild("LowerTorso")

	local abd: Abduct = {
		char = char,
		startedAt = startedAt,
		scale = scale,
		origin = originCF,
		groundY = groundY,
		rig = rig,
		flight = AbductionFlight.new({
			spot = originCF.Position,
			groundY = groundY,
			scale = scale,
			seed = seed,
			leaveAt = TIMING.LEAVE,
			exitTime = TIMING.END - TIMING.LEAVE,
			spinBoostFrom = TIMING.BEAM_ON,
			spinBoostTo = TIMING.BODY_GONE,
		}),
		ufoParts = ufoParts,
		ufoCFrames = table.create(#ufoParts, CFrame.identity),
		beamTop = beamTop,
		beamBottom = beamBottom,
		-- Colgados del ancla: se van con ella en finish.
		beamOuter = makeBeam(topAtt, bottomAtt, NumberSequence.new(0.35, 0.8), beamTop),
		beamCore = makeBeam(topAtt, bottomAtt, NumberSequence.new(0.05, 0.55), beamTop),
		ring = ring,
		shock = shock,
		light = light,
		flash = flash,
		beamVisible = false,
		shockVisible = false,
		soundPlayed = false,
		grab = if grab and grab:IsA("BasePart") then grab else nil,
		bodyParts = {},
		bodyDecals = {},
		highlight = highlight,
		bodyFade = 0,
		bodyDone = false,
		gulpAt = nil,
	}
	captureBody(abd)

	rig.model.Parent = folder
	_active[char] = abd
	if not _renderConn then
		_renderConn = RunService.RenderStepped:Connect(onRender)
	end
end

function AbductionVisuals.stop()
	for char in table.clone(_active) do
		finish(char)
	end
	if _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

return AbductionVisuals
