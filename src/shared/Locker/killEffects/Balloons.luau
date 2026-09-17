--!strict

-- Kill effect "Up, Up & Away": globos atados a la mano levantan el cadáver y revientan en cadena.
--
-- Aquí solo va lo que debe ser igual para todos (ragdoll y física de los globos);
-- lo cosmético (inflado, estallido, sonido) lo pinta cada cliente en
-- BalloonPopVisuals a partir del tag y los atributos.
--
-- Todo cuelga dentro del cadáver, así que se limpia con él. La cadena debe acabar
-- antes de 2 s: el preview del Locker borra el cuerpo a los 2 s.

local Debris = game:GetService("Debris")

local Utils = require(script.Parent.Utils)

local CONFIG = {
	RAGDOLL_HEAD_AS_JOINT = true,

	-- Ramillete: { nº de globos, peso relativo }.
	COUNT_WEIGHTS = { { 3, 50 }, { 4, 35 }, { 5, 15 } },
	GOLDEN_CHANCE = 1 / 15, -- probabilidad de un globo dorado extra
	ROPE_LENGTH = { 6, 10 }, -- studs, repartidos entre los globos (dorado = el más largo)
	ROPE_SLACK = 1.5, -- studs que le faltan a cada cuerda para tensarse al soltarlos
	ROPE_THICKNESS = 0.05,
	ROPE_COLOR = Color3.fromRGB(245, 245, 245),
	FAN_RADIUS = 1.4, -- studs de separación horizontal inicial respecto a la mano

	BALLOON_SIZE = Vector3.new(2.4, 3, 2.4),
	BALLOON_REFLECTANCE = 0.12,
	GOLDEN_SIZE = Vector3.new(3.4, 4.2, 3.4),
	GOLDEN_COLOR = Color3.fromRGB(255, 196, 40),
	GOLDEN_REFLECTANCE = 0.35,

	RISE_SPEED = 22, -- studs/s hacia arriba
	SPREAD_SPEED = 2.5, -- studs/s hacia fuera de cada globo (abre el ramillete)
	DRIFT_SPEED = 3, -- studs/s máx de deriva lateral común (el "viento")
	LIFT_RATIO = 1.8, -- fuerza total / peso del cuerpo (> 1 para que despegue)

	POP_AT = 1.35, -- s desde la muerte hasta el primero
	POP_GAP = 0.2, -- s entre el primero y el segundo
	POP_GAP_DECAY = 0.7, -- cada hueco es este factor del anterior: la cadena acelera
	POP_LINGER = 0.1, -- s que el globo reventado sigue existiendo (el cliente lee su posición)
}

local COLORS = {
	Color3.fromRGB(235, 64, 52),
	Color3.fromRGB(40, 140, 255),
	Color3.fromRGB(70, 200, 90),
	Color3.fromRGB(230, 90, 200),
	Color3.fromRGB(255, 140, 30),
}

local Balloons = {}

-- Contrato con el cliente (BalloonPopVisuals). Cambiar aquí, no en literales.
Balloons.TAG = "KillEffectBalloon"
Balloons.ATTR = table.freeze({
	SPAWNED_AT = "BalloonSpawnedAt", -- GetServerTimeNow() al crearlo: sincroniza el inflado
	POP_INDEX = "BalloonPopIndex", -- posición en la cadena (1..POP_COUNT)
	POP_COUNT = "BalloonPopCount",
	GOLDEN = "BalloonGolden",
	POPPED = "BalloonPopped", -- pasa a true al reventar
})
-- Se crean anclados y a tamaño completo; el cliente los infla durante este tiempo y luego el servidor los suelta.
Balloons.INFLATE_TIME = 0.3

type Balloon = {
	part: Part,
	rope: RopeConstraint,
	lift: LinearVelocity,
}

local rng = Random.new()

local function rollCount(): number
	local total = 0
	for _, entry in CONFIG.COUNT_WEIGHTS do
		total += entry[2]
	end
	local roll = rng:NextNumber(0, total)
	for _, entry in CONFIG.COUNT_WEIGHTS do
		roll -= entry[2]
		if roll <= 0 then
			return entry[1]
		end
	end
	return CONFIG.COUNT_WEIGHTS[1][1]
end

local function shuffledColors(): { Color3 }
	local colors = table.clone(COLORS)
	for i = #colors, 2, -1 do
		local j = rng:NextInteger(1, i)
		colors[i], colors[j] = colors[j], colors[i]
	end
	return colors
end

local function handAttachment(parts: { [string]: BasePart }): Attachment?
	local hand = parts.RightHand or parts["Right Arm"]
	if hand then
		local grip = hand:FindFirstChild("RightGripAttachment")
		if grip and grip:IsA("Attachment") then
			return grip
		end
	end
	local holder = hand or parts.UpperTorso or parts.Torso or parts.HumanoidRootPart
	if not holder then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Name = "BalloonHandAttachment"
	att.Position = if hand then Vector3.new(0, -hand.Size.Y / 2, 0) else Vector3.zero
	att.Parent = holder
	return att
end

local function bodyMass(allBaseParts: { BasePart }): number
	local mass = 0
	for _, part in allBaseParts do
		if not part.Massless then
			mass += part:GetMass()
		end
	end
	return mass
end

type BalloonSpec = {
	color: Color3,
	size: Vector3,
	reflectance: number,
	ropeLength: number,
	fanDir: Vector3,
	golden: boolean,
	popIndex: number,
	popCount: number,
}

local function spawnBalloon(parent: Instance, handAtt: Attachment, spec: BalloonSpec, drift: Vector3, force: number): Balloon
	local size = spec.size

	local part = Instance.new("Part")
	part.Name = "Balloon"
	part.Size = size
	part.Color = spec.color
	part.Material = if spec.golden then Enum.Material.Foil else Enum.Material.SmoothPlastic
	part.Reflectance = spec.reflectance
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Anchored = true
	-- Densidad mínima o cada globo pesaría casi como el cuerpo entero.
	part.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0, 0)
	part.CFrame = CFrame.new(
		handAtt.WorldPosition + spec.fanDir * CONFIG.FAN_RADIUS + Vector3.new(0, spec.ropeLength - CONFIG.ROPE_SLACK, 0)
	)

	-- SpecialMesh y no Part Ball: Ball fuerza ejes iguales.
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part

	local knotAtt = Instance.new("Attachment")
	knotAtt.Name = "KnotAttachment"
	knotAtt.Position = Vector3.new(0, -size.Y / 2, 0)
	knotAtt.Parent = part

	local rope = Instance.new("RopeConstraint")
	rope.Attachment0 = handAtt
	rope.Attachment1 = knotAtt
	rope.Length = spec.ropeLength
	rope.Visible = true
	rope.Color = BrickColor.new(CONFIG.ROPE_COLOR)
	rope.Thickness = CONFIG.ROPE_THICKNESS
	rope.Parent = part

	local liftAtt = Instance.new("Attachment")
	liftAtt.Name = "LiftAttachment"
	liftAtt.Parent = part

	local lift = Instance.new("LinearVelocity")
	lift.Attachment0 = liftAtt
	lift.VectorVelocity = Vector3.new(0, CONFIG.RISE_SPEED, 0) + spec.fanDir * CONFIG.SPREAD_SPEED + drift
	lift.MaxForce = force
	lift.Enabled = false
	lift.Parent = part

	part:SetAttribute(Balloons.ATTR.SPAWNED_AT, workspace:GetServerTimeNow())
	part:SetAttribute(Balloons.ATTR.POP_INDEX, spec.popIndex)
	part:SetAttribute(Balloons.ATTR.POP_COUNT, spec.popCount)
	part:SetAttribute(Balloons.ATTR.GOLDEN, spec.golden)
	part:AddTag(Balloons.TAG)
	part.Parent = parent

	return { part = part, rope = rope, lift = lift }
end

local function release(balloons: { Balloon })
	local parts: { BasePart } = {}
	for _, balloon in balloons do
		if balloon.part.Parent then
			balloon.part.Anchored = false
			balloon.lift.Enabled = true
			table.insert(parts, balloon.part)
		end
	end
	-- Sin propiedad del servidor los globos pueden congelarse en el aire.
	Utils.setServerOwnership(parts)
end

-- El globo se queda un instante anclado e invisible para que el cliente lea dónde estaba.
local function pop(balloon: Balloon)
	local part = balloon.part
	if not part.Parent then
		return
	end
	balloon.rope:Destroy()
	balloon.lift:Destroy()
	part.Anchored = true
	part.Transparency = 1
	part:SetAttribute(Balloons.ATTR.POPPED, true)
	Debris:AddItem(part, CONFIG.POP_LINGER)
end

local function attachBalloons(char: Model, parts: { [string]: BasePart }, allBaseParts: { BasePart })
	local handAtt = handAttachment(parts)
	if not handAtt then
		return
	end

	local golden = rng:NextNumber() < CONFIG.GOLDEN_CHANCE
	local plain = rollCount()
	local count = plain + (if golden then 1 else 0)
	local force = bodyMass(allBaseParts) * workspace.Gravity * CONFIG.LIFT_RATIO / count
	local colors = shuffledColors()
	local driftAngle = rng:NextNumber(0, 2 * math.pi)
	local drift = Vector3.new(math.cos(driftAngle), 0, math.sin(driftAngle)) * rng:NextNumber(0, CONFIG.DRIFT_SPEED)
	local fanOffset = rng:NextNumber(0, 2 * math.pi)
	local minRope, maxRope = CONFIG.ROPE_LENGTH[1], CONFIG.ROPE_LENGTH[2]

	local balloons: { Balloon } = {}
	for i = 1, plain do
		local angle = fanOffset + (i / plain) * 2 * math.pi
		local ropeAlpha = if plain > 1 then (i - 1) / (plain - 1) else 0.5
		table.insert(balloons, spawnBalloon(char, handAtt, {
			color = colors[(i - 1) % #colors + 1],
			size = CONFIG.BALLOON_SIZE,
			reflectance = CONFIG.BALLOON_REFLECTANCE,
			ropeLength = minRope + (maxRope - minRope) * ropeAlpha * (if golden then 0.8 else 1),
			fanDir = Vector3.new(math.cos(angle), 0, math.sin(angle)),
			golden = false,
			popIndex = i,
			popCount = count,
		}, drift, force))
	end
	if golden then
		table.insert(balloons, spawnBalloon(char, handAtt, {
			color = CONFIG.GOLDEN_COLOR,
			size = CONFIG.GOLDEN_SIZE,
			reflectance = CONFIG.GOLDEN_REFLECTANCE,
			ropeLength = maxRope,
			fanDir = Vector3.zero,
			golden = true,
			popIndex = count,
			popCount = count,
		}, drift, force))
	end

	task.delay(Balloons.INFLATE_TIME, release, balloons)

	local at = CONFIG.POP_AT
	local gap = CONFIG.POP_GAP
	for _, balloon in balloons do
		task.delay(at, pop, balloon)
		at += gap
		gap *= CONFIG.POP_GAP_DECAY
	end
end

local function applyRagdoll(char: Model, hum: Humanoid)
	-- Solo R15 recibe joints de ragdoll; otros rigs suben rígidos (como en Gravity).
	local isR15 = hum.RigType == Enum.HumanoidRigType.R15

	local allBaseParts: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			table.insert(allBaseParts, desc)
		elseif isR15 and Utils.isRigJoint(desc) then
			desc:Destroy()
		end
	end

	local parts = Utils.buildPartLookup(char)

	local root = parts.HumanoidRootPart
	if root then
		if isR15 then
			Utils.destroyJoints(root)
		end
		root.CanCollide = false
		root.Massless = true
	end

	Utils.releaseHumanoid(hum)

	if isR15 then
		Utils.buildRagdoll(parts, CONFIG.RAGDOLL_HEAD_AS_JOINT, allBaseParts)
	end

	Utils.makeCorpseInert(char)

	for _, part in allBaseParts do
		part.Anchored = false
	end

	-- No-op en el preview del Locker (cliente).
	Utils.setServerOwnership(allBaseParts)

	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			part.CanCollide = true
		end
	end

	-- Después del ragdoll: la masa se mide con el Massless del root ya aplicado.
	attachBalloons(char, parts, allBaseParts)
end

function Balloons.apply(char: Model): boolean
	local hum = char:FindFirstChildWhichIsA("Humanoid", true)
	if not hum then
		return false
	end

	hum.BreakJointsOnDeath = false
	applyRagdoll(char, hum)

	return true
end

return Balloons
