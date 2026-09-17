--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CollisionGroups = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CollisionGroups"))

local KillEffectUtils = {}

-- Aun muerto, el Humanoid evalúa su máquina de estados cada step (recoloca el root,
-- apaga CanCollide de extremidades): EvaluateStateMachine = false la congela. Estado
-- Dead y no Physics: WeaponsSystem distingue cadáveres por GetState() == Dead.
-- Llamar ANTES de construir joints.
function KillEffectUtils.releaseHumanoid(hum: Humanoid)
	hum.BreakJointsOnDeath = false
	hum.AutoRotate = false
	hum.RequiresNeck = false
	-- En los previews el maniquí llega VIVO y ChangeState(Dead) no cuaja sobre un
	-- Humanoid con vida. BreakJointsOnDeath ya es false; en partida es no-op.
	if hum.Health > 0 then
		hum.Health = 0
	end
	hum:ChangeState(Enum.HumanoidStateType.Dead)
	hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	-- Congelar la máquina mantiene CanCollide en brazos y piernas (si no, el cuerpo
	-- atraviesa el suelo apoyado solo en el torso). pcall por si la propiedad no existe.
	pcall(function()
		(hum :: any).EvaluateStateMachine = false
	end)
end

export type BallLimits = { UpperAngle: number, Twist: number? }

function KillEffectUtils.createBallJoint(att0: Attachment?, att1: Attachment?, limits: BallLimits?)
	if not att0 or not att1 then
		return
	end

	local joint = Instance.new("BallSocketConstraint")
	joint.Attachment0 = att0
	joint.Attachment1 = att1
	joint.LimitsEnabled = true
	joint.UpperAngle = limits and limits.UpperAngle or 45
	-- Sin rebote: cada choque contra el tope devolvería energía y la extremidad aletearía.
	joint.Restitution = 0
	local twist = limits and limits.Twist
	if twist then
		-- Sin límite de torsión codos y rodillas giran "de goma".
		joint.TwistLimitsEnabled = true
		joint.TwistLowerAngle = -twist
		joint.TwistUpperAngle = twist
	end
	joint.Parent = att0
end

function KillEffectUtils.createWeld(p0: BasePart?, p1: BasePart?)
	if not p0 or not p1 then
		return
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = p0
	weld.Part1 = p1
	weld.Parent = p0
end

-- UN STEP DESPUÉS: en el mismo frame que desanclar + setServerOwnership, el handoff
-- de física del cambio de dueño a veces descarta la velocidad y el cuerpo no sale.
function KillEffectUtils.applyImpulse(part: BasePart, force: Vector3)
	if not part then
		return
	end
	RunService.Heartbeat:Once(function()
		if part.Parent then
			part.AssemblyLinearVelocity = force
		end
	end)
end

-- Todas las partes con la misma velocidad (un step después, como applyImpulse):
-- empujar solo el torso arrastra las extremidades por los joints (latigazo). Salta
-- el HRP, anclado en el punto de muerte.
function KillEffectUtils.launchBody(parts: { [string]: BasePart }, velocity: Vector3)
	RunService.Heartbeat:Once(function()
		for name, part in parts do
			if name ~= "HumanoidRootPart" and part.Parent and not part.Anchored then
				part.AssemblyLinearVelocity = velocity
				part.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end)
end

-- Sin propiedad de red del servidor, Roblox asigna las partes sueltas al cliente
-- más cercano y, cuando deja de simularlas, el cuerpo se congela rígido para todos.
-- No-op en cliente; pcall porque SetNetworkOwner lanza sobre partes ancladas o fuera
-- de Workspace. Llamar DESPUÉS de desanclar y ANTES del impulso.
function KillEffectUtils.setServerOwnership(parts: { BasePart })
	if not RunService:IsServer() then
		return
	end
	for _, part in parts do
		if part.Parent and not part.Anchored then
			pcall(function()
				part:SetNetworkOwner(nil)
			end)
		end
	end
end

-- Players (loadout) y bots (BotAI) equipan el arma como Tool hijo directo del
-- character. Llamar ANTES de construir el ragdoll para que el Handle no entre en
-- el procesado de partes.
function KillEffectUtils.stripWeapons(char: Model)
	for _, child in char:GetChildren() do
		if child:IsA("Tool") then
			child:Destroy()
		end
	end
end

-- CanQuery = false es imprescindible: `Roblox.penetrateCast` solo atraviesa partes
-- sin colisión que NO cuelgan de un modelo con Humanoid, así que el cadáver (y su
-- HRP invisible anclado) pararía balas aunque sea CanCollide = false.
-- RAGDOLL va a TODAS las partes (HRP incluido) salvo las cajas RAGDOLL_INNER, que
-- deben seguir chocando entre sí. El billboard de vida lo crea cada cliente y lo
-- retira HealthBillboardController.
function KillEffectUtils.makeCorpseInert(char: Model)
	local hum = char:FindFirstChildWhichIsA("Humanoid", true)
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end

	local parts: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.CanQuery = false
			desc.CanTouch = false
			if desc.CollisionGroup ~= CollisionGroups.RAGDOLL_INNER then
				table.insert(parts, desc)
			end
		end
	end

	-- También marca el atributo de ragdoll (lo leen los watchers DescendantAdded de
	-- MatchService/AIService y el billboard): una parte que llegue tarde nace en RAGDOLL.
	CollisionGroups.setGroupForParts(char, parts, CollisionGroups.RAGDOLL)
end

-- En vez de ClearAllChildren en el HumanoidRootPart, para que Sounds de muerte y
-- Attachments del rig sobrevivan.
function KillEffectUtils.destroyJoints(part: Instance)
	for _, child in part:GetChildren() do
		if
			child:IsA("Motor6D")
			or child:IsA("Weld")
			or child:IsA("WeldConstraint")
			or child:IsA("Constraint")
		then
			child:Destroy()
		end
	end
end

-- Builder de ragdoll R15 compartido por todos los kill effects; estos solo deciden
-- impulso y VFX.
-- Dos tipos de rig conviven: Motor6D (personajes de partida) y AnimationConstraint
-- con sus propios BallSocketConstraint (Shared.Bodies). Se destruyen todos para
-- que los únicos joints sean los nuestros.
function KillEffectUtils.isRigJoint(inst: Instance): boolean
	return inst:IsA("Motor6D") or inst:IsA("AnimationConstraint") or inst:IsA("BallSocketConstraint")
end

-- `UpperAngle` = cono respecto a la dirección de reposo; `Twist` = ±giro sobre el
-- hueso. `Roll` orienta el eje X del joint a lo largo del hueso (-Y para huesos que
-- cuelgan, +Y para los que suben): BallSocketConstraint mide sobre el X de sus
-- attachments y los RigAttachment R15 tienen orientación identidad (X de lado).
-- Los conos deben contener la pose de muerte (apuntando, corriendo): si la violan,
-- el solver la corrige de golpe en los primeros frames.
local DOWN = -90
local UP = 90

KillEffectUtils.R15_BALL_JOINTS = {
	{ Part0 = "LowerTorso", Part1 = "UpperTorso", Att = "WaistRigAttachment", Roll = UP, Limits = { UpperAngle = 15, Twist = 10 } },
	{ Part0 = "UpperTorso", Part1 = "RightUpperArm", Att = "RightShoulderRigAttachment", Roll = DOWN, Limits = { UpperAngle = 95, Twist = 40 } },
	{ Part0 = "UpperTorso", Part1 = "LeftUpperArm", Att = "LeftShoulderRigAttachment", Roll = DOWN, Limits = { UpperAngle = 95, Twist = 40 } },
	{ Part0 = "LowerTorso", Part1 = "RightUpperLeg", Att = "RightHipRigAttachment", Roll = DOWN, Limits = { UpperAngle = 60, Twist = 15 } },
	{ Part0 = "LowerTorso", Part1 = "LeftUpperLeg", Att = "LeftHipRigAttachment", Roll = DOWN, Limits = { UpperAngle = 60, Twist = 15 } },
}

KillEffectUtils.NECK_JOINT = { Part0 = "UpperTorso", Part1 = "Head", Att = "NeckRigAttachment", Roll = UP, Limits = { UpperAngle = 25, Twist = 30 } }

-- Codos y rodillas: bisagra de un eje (X del RigAttachment). `Flex` = lado natural
-- de flexión en espacio del padre (antebrazo -Z, espinilla +Z). Centrada a `Center`
-- con límites ±`Half`, calculado por geometría y no por el signo del HingeConstraint.
KillEffectUtils.R15_HINGE_JOINTS = {
	{ Part0 = "RightUpperArm", Part1 = "RightLowerArm", Att = "RightElbowRigAttachment", Flex = -1, Center = 45, Half = 50 },
	{ Part0 = "LeftUpperArm", Part1 = "LeftLowerArm", Att = "LeftElbowRigAttachment", Flex = -1, Center = 45, Half = 50 },
	{ Part0 = "RightUpperLeg", Part1 = "RightLowerLeg", Att = "RightKneeRigAttachment", Flex = 1, Center = 45, Half = 50 },
	{ Part0 = "LeftUpperLeg", Part1 = "LeftLowerLeg", Att = "LeftKneeRigAttachment", Flex = 1, Center = 45, Half = 50 },
}

-- Manos y pies soldados: un joint más solo añade ruido al solver.
KillEffectUtils.R15_WELDS = {
	{ Part0 = "RightLowerArm", Part1 = "RightHand" },
	{ Part0 = "LeftLowerArm", Part1 = "LeftHand" },
	{ Part0 = "RightLowerLeg", Part1 = "RightFoot" },
	{ Part0 = "LeftLowerLeg", Part1 = "LeftFoot" },
}

-- Fricción alta y elasticidad cero con peso máximo para ganar a las del material del
-- mapa; la densidad es la de la parte. Gravity sobreescribe después su rebote.
local BODY_FRICTION = 1
local BODY_ELASTICITY = 0

function KillEffectUtils.buildPartLookup(char: Model): { [string]: BasePart }
	local map: { [string]: BasePart } = {}
	for _, child in char:GetChildren() do
		if child:IsA("BasePart") then
			map[child.Name] = child :: BasePart
		end
	end
	return map
end

-- Partes del cadáver que reciben caja interna de autocolisión.
KillEffectUtils.R15_INNER_PARTS = {
	"Head",
	"UpperTorso",
	"LowerTorso",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"LeftUpperLeg",
	"LeftLowerLeg",
	"LeftFoot",
	"RightUpperLeg",
	"RightLowerLeg",
	"RightFoot",
}

-- Pares vecinos cuyas cajas internas pueden tocarse aun reducidas. Manos y pies van
-- soldados (mismo assembly → nunca colisionan).
KillEffectUtils.R15_NO_COLLISION_PAIRS = {
	{ "UpperTorso", "Head" },
	{ "LowerTorso", "UpperTorso" },
	{ "UpperTorso", "RightUpperArm" },
	{ "UpperTorso", "LeftUpperArm" },
	{ "RightUpperArm", "RightLowerArm" },
	{ "LeftUpperArm", "LeftLowerArm" },
	{ "LowerTorso", "RightUpperLeg" },
	{ "LowerTorso", "LeftUpperLeg" },
	{ "RightUpperLeg", "RightLowerLeg" },
	{ "LeftUpperLeg", "LeftLowerLeg" },
	{ "RightUpperLeg", "LeftUpperLeg" },
}

local INNER_COLLIDER_NAME = "RagdollInner"
-- Holgura para que en reposo las cajas no se toquen, y tope para que una extremidad
-- no se hunda demasiado en otra parte.
local INNER_COLLIDER_SCALE = 0.7

-- Las MeshParts (RAGDOLL) NO colisionan entre sí: sus hulls ya se solapan en reposo
-- y el cuerpo temblaría. Cada parte lleva una caja invisible reducida y soldada en
-- RAGDOLL_INNER, que solo choca con otras cajas. No entran en `allBaseParts` y su
-- grupo se fija DESPUÉS de parentarlas para pisar el del watcher DescendantAdded de MatchService.
function KillEffectUtils.addInnerColliders(parts: { [string]: BasePart }): { [string]: BasePart }
	local inner: { [string]: BasePart } = {}
	for _, name in KillEffectUtils.R15_INNER_PARTS do
		local part = parts[name]
		if part then
			local box = Instance.new("Part")
			box.Name = INNER_COLLIDER_NAME
			box.Size = part.Size * INNER_COLLIDER_SCALE
			box.CFrame = part.CFrame
			box.Transparency = 1
			box.CastShadow = false
			box.Massless = true
			box.CanCollide = true
			box.CanQuery = false
			box.CanTouch = false
			box.Anchored = false
			box.CustomPhysicalProperties = PhysicalProperties.new(0.7, BODY_FRICTION, BODY_ELASTICITY, 100, 100)
			box.Parent = part
				-- Sin el grupo (registro fallido en server) la caja chocaría con el
				-- mundo y los jugadores: mejor sin colisión.
			local grouped = pcall(function()
				box.CollisionGroup = CollisionGroups.RAGDOLL_INNER
			end)
			if not grouped or box.CollisionGroup ~= CollisionGroups.RAGDOLL_INNER then
				box.CanCollide = false
			end
			KillEffectUtils.createWeld(part, box)
			inner[name] = box
		end
	end
	for _, pair in KillEffectUtils.R15_NO_COLLISION_PAIRS do
		local b0 = inner[pair[1]]
		local b1 = inner[pair[2]]
		if b0 and b1 then
			local nc = Instance.new("NoCollisionConstraint")
			nc.Part0 = b0
			nc.Part1 = b1
			nc.Parent = b0
		end
	end
	return inner
end

-- Amortigua la velocidad angular y limita velocidades los primeros segundos:
-- evita el latigazo de extremidades al frenar el torso y la expulsión de partes
-- clavadas en el suelo. Solo tiene efecto donde se simula la física (servidor o
-- preview del cliente). Opcional: los efectos que quieren giro no lo llaman.
local CALM_DURATION = 4 -- s; debe cubrir el minTime de RagdollCleanup
local CALM_ANGULAR_PER_SEC = 0.15 -- fracción de velocidad angular que queda tras 1 s
local CALM_MAX_ANGULAR = 12 -- rad/s
local CALM_ANGULAR_REST = 0.5 -- rad/s; por debajo no se toca la parte
local CALM_MAX_LINEAR = 60 -- studs/s

function KillEffectUtils.calmRagdoll(parts: { [string]: BasePart }, char: Model)
	local conn: RBXScriptConnection? = nil
	local startAt = os.clock()
	conn = RunService.Heartbeat:Connect(function(dt: number)
		if os.clock() - startAt > CALM_DURATION or char.Parent == nil then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			return
		end
		local damp = CALM_ANGULAR_PER_SEC ^ dt
		for name, part in parts do
			if name ~= "HumanoidRootPart" and part.Parent and not part.Anchored then
					-- Solo escribir si hay algo que frenar: fijar la velocidad de una parte
					-- quieta la despierta cada frame y nunca llega a dormirse.
				local av = part.AssemblyAngularVelocity
				if av.Magnitude > CALM_ANGULAR_REST then
					av *= damp
					if av.Magnitude > CALM_MAX_ANGULAR then
						av = av.Unit * CALM_MAX_ANGULAR
					end
					part.AssemblyAngularVelocity = av
				end
				local lv = part.AssemblyLinearVelocity
				if lv.Magnitude > CALM_MAX_LINEAR then
					part.AssemblyLinearVelocity = lv.Unit * CALM_MAX_LINEAR
				end
			end
		end
	end)
end

type BallJointDef = { Part0: string, Part1: string, Att: string, Roll: number, Limits: BallLimits }
type HingeJointDef = { Part0: string, Part1: string, Att: string, Flex: number, Center: number, Half: number }

-- Par de RigAttachment de un joint, o nil si al rig le falta alguno.
local function rigAttachments(parts: { [string]: BasePart }, def: { Part0: string, Part1: string, Att: string }): (BasePart?, Attachment?, BasePart?, Attachment?)
	local part0 = parts[def.Part0]
	local part1 = parts[def.Part1]
	if not part0 or not part1 then
		return nil, nil, nil, nil
	end
	local rig0 = part0:FindFirstChild(def.Att)
	local rig1 = part1:FindFirstChild(def.Att)
	if not (rig0 and rig0:IsA("Attachment") and rig1 and rig1:IsA("Attachment")) then
		return nil, nil, nil, nil
	end
	return part0, rig0, part1, rig1
end

local function makeAttachment(parent: BasePart, cframe: CFrame): Attachment
	local att = Instance.new("Attachment")
	att.Name = "RagdollAtt"
	att.CFrame = cframe
	att.Parent = parent
	return att
end

local function ballJointFor(parts: { [string]: BasePart }, def: BallJointDef)
	local part0, rig0, part1, rig1 = rigAttachments(parts, def)
	if not (part0 and rig0 and part1 and rig1) then
		return
	end
	-- Los dos RigAttachment coinciden en reposo: girarlos igual mantiene la rotación
	-- relativa en identidad y pone el eje X a lo largo del hueso.
	local roll = CFrame.Angles(0, 0, math.rad(def.Roll))
	KillEffectUtils.createBallJoint(
		makeAttachment(part0, rig0.CFrame * roll),
		makeAttachment(part1, rig1.CFrame * roll),
		def.Limits
	)
end

local function hingeFor(parts: { [string]: BasePart }, def: HingeJointDef)
	local part0, rig0, part1, rig1 = rigAttachments(parts, def)
	if not (part0 and rig0 and part1 and rig1) then
		return
	end
	-- Rotación de `Center` alrededor de X hacia el lado `Flex`. Si -Y acaba en el lado
	-- contrario se usa el otro signo: no se asume la convención de CFrame.Angles.
	local center = CFrame.Angles(math.rad(def.Center), 0, 0)
	if math.sign(center:VectorToWorldSpace(Vector3.new(0, -1, 0)).Z) ~= def.Flex then
		center = CFrame.Angles(-math.rad(def.Center), 0, 0)
	end
	-- El attachment del padre lleva la rotación: el ángulo 0 es la pose flexionada
	-- `Center` y la recta queda a -Center, dentro de ±Half.
	local hinge = Instance.new("HingeConstraint")
	hinge.Attachment0 = makeAttachment(part0, rig0.CFrame * center)
	hinge.Attachment1 = makeAttachment(part1, rig1.CFrame)
	hinge.LimitsEnabled = true
	hinge.LowerAngle = -def.Half
	hinge.UpperAngle = def.Half
	hinge.Restitution = 0
	hinge.Parent = part0
end

-- `parts`: hijos directos del char por nombre, con los joints del rig ya destruidos.
-- Quita el HRP de `allBaseParts` (el caller los desancla después) porque se queda anclado.
function KillEffectUtils.buildRagdoll(parts: { [string]: BasePart }, headAsJoint: boolean, allBaseParts: { BasePart })
	-- El HRP NO va unido al cuerpo: el Humanoid sigue aplicando fuerzas de equilibrio
	-- sobre él y soldado deja el cadáver de pie. Anclado marca el punto de muerte que
	-- leen KillCam y Tombstone.
	local root = parts.HumanoidRootPart
	if root then
		root.Anchored = true
		local i = table.find(allBaseParts, root)
		if i then
			table.remove(allBaseParts, i)
		end
	end

	for name, part in parts do
		if name ~= "HumanoidRootPart" then
			local density = part.CurrentPhysicalProperties.Density
			part.CustomPhysicalProperties = PhysicalProperties.new(density, BODY_FRICTION, BODY_ELASTICITY, 100, 100)
		end
	end

	KillEffectUtils.addInnerColliders(parts)

	if headAsJoint then
		ballJointFor(parts, KillEffectUtils.NECK_JOINT)
	else
		KillEffectUtils.createWeld(parts.UpperTorso, parts.Head)
	end

	for _, def in KillEffectUtils.R15_BALL_JOINTS do
		ballJointFor(parts, def)
	end

	for _, def in KillEffectUtils.R15_HINGE_JOINTS do
		hingeFor(parts, def)
	end

	for _, weldData in KillEffectUtils.R15_WELDS do
		KillEffectUtils.createWeld(parts[weldData.Part0], parts[weldData.Part1])
	end
end

return KillEffectUtils
