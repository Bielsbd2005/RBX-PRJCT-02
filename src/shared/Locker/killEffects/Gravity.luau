local RagdollModule = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Utils = require(script.Parent.Utils)
local CollisionGroups = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CollisionGroups"))

-- Configuration
local CONFIG = {
	JOINT_MAX_ANGLE = 55,
	THROW_FORCE_XZ = 20,
	THROW_FORCE_Y = 35,
	RAGDOLL_HEAD_AS_JOINT = false,
	BOUNCE_ELASTICITY = 0.85, -- Reducido un poquito de 1 a 0.85 para dar mayor estabilidad física
}

-- Registro de grupos + reglas cruzadas en CollisionGroups (server-side init).
-- Ahora el grupo RagdollBodyParts también es no-collidable contra Characters,
-- así jugadores vivos no chocan con cadáveres.

local rng = Random.new()

-- Data abstraction for R15 joints
local R15_JOINTS = {
	{ Part0 = "UpperTorso", Part1 = "RightUpperArm", Att0 = "RightShoulderRigAttachment", Att1 = "RightShoulderRigAttachment" },
	{ Part0 = "UpperTorso", Part1 = "LeftUpperArm", Att0 = "LeftShoulderRigAttachment", Att1 = "LeftShoulderRigAttachment" },
	{ Part0 = "LowerTorso", Part1 = "RightUpperLeg", Att0 = "RightHipRigAttachment", Att1 = "RightHipRigAttachment" },
	{ Part0 = "LowerTorso", Part1 = "LeftUpperLeg", Att0 = "LeftHipRigAttachment", Att1 = "LeftHipRigAttachment" },
	{ Part0 = "RightUpperArm", Part1 = "RightLowerArm", Att0 = "RightElbowRigAttachment", Att1 = "RightElbowRigAttachment" },
	{ Part0 = "LeftUpperArm", Part1 = "LeftLowerArm", Att0 = "LeftElbowRigAttachment", Att1 = "LeftElbowRigAttachment" },
	{ Part0 = "RightUpperLeg", Part1 = "RightLowerLeg", Att0 = "RightKneeRigAttachment", Att1 = "RightKneeRigAttachment" },
	{ Part0 = "LeftUpperLeg", Part1 = "LeftLowerLeg", Att0 = "LeftKneeRigAttachment", Att1 = "LeftKneeRigAttachment" },
}

local R15_WELDS = {
	{ Part0 = "LowerTorso", Part1 = "UpperTorso" },
	{ Part0 = "RightLowerArm", Part1 = "RightHand" },
	{ Part0 = "LeftLowerArm", Part1 = "LeftHand" },
	{ Part0 = "RightLowerLeg", Part1 = "RightFoot" },
	{ Part0 = "LeftLowerLeg", Part1 = "LeftFoot" },
}

-- Construye un lookup name→BasePart para los hijos directos del personaje.
-- En rigs R15/R6 todas las partes del cuerpo son hijos directos del Model;
-- no hace falta FindFirstChild(name, true) recursivo (que escanea todo el
-- subárbol — incluyendo accesorios, tools y particles).
local function buildPartLookup(char: Model): { [string]: BasePart }
	local map = {}
	for _, child in ipairs(char:GetChildren()) do
		if child:IsA("BasePart") then
			map[child.Name] = child
		end
	end
	return map
end

local function getImpulsePart(parts: { [string]: BasePart }): BasePart?
	return parts.LowerTorso or parts.Torso or parts.HumanoidRootPart
end

local function buildRagdoll(char: Model, parts: { [string]: BasePart })
	local head = parts.Head
	local upperTorso = parts.UpperTorso

	if CONFIG.RAGDOLL_HEAD_AS_JOINT then
		if head and upperTorso then
			Utils.createBallJoint(
				upperTorso:FindFirstChild("NeckRigAttachment"),
				head:FindFirstChild("NeckRigAttachment"),
				{ UpperAngle = CONFIG.JOINT_MAX_ANGLE }
			)
		end
	else
		Utils.createWeld(upperTorso, head)
	end

	for _, jointData in ipairs(R15_JOINTS) do
		local part0 = parts[jointData.Part0]
		local part1 = parts[jointData.Part1]

		if part0 and part1 then
			local att0 = part0:FindFirstChild(jointData.Att0)
			local att1 = part1:FindFirstChild(jointData.Att1)

			if att0 and att1 then
				Utils.createBallJoint(att0, att1, { UpperAngle = CONFIG.JOINT_MAX_ANGLE })
			end
		end
	end

	for _, weldData in ipairs(R15_WELDS) do
		local part0 = parts[weldData.Part0]
		local part1 = parts[weldData.Part1]

		if part0 and part1 then
			Utils.createWeld(part0, part1)
		end
	end
end

local function applyRagdoll(char: Model, hum: Humanoid)
	Utils.anchor(char, true)
	Utils.destroyMotors(char)

	local parts = buildPartLookup(char)

	local root = parts.HumanoidRootPart
	if root then
		root:ClearAllChildren()
		root.CanCollide = false
		root.Massless = true
	end

	hum:ChangeState(Enum.HumanoidStateType.Dead)
	hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	-- Recolectamos UNA sola vez todos los BaseParts del char para evitar múltiples
	-- iteraciones O(N) de GetDescendants() y para minimizar GC pressure.
	local baseParts: { BasePart } = {}
	for _, descendant in ipairs(char:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(baseParts, descendant)
		end
	end

	if hum.RigType == Enum.HumanoidRigType.R15 then
		buildRagdoll(char, parts)
	end

	-- Mover todos los baseparts al grupo RAGDOLL: no colisionan ni entre sí
	-- ni contra jugadores vivos (CHARACTERS), pero sí contra el mundo (Default).
	CollisionGroups.setGroupForParts(char, baseParts, CollisionGroups.RAGDOLL)

	-- AntiGravityForce solo en body parts (hijos directos del Model), no en
	-- accesorios/tools/decoraciones que estarían soldadas y no necesitan
	-- compensación gravitatoria individual.
	local currentGravity = workspace.Gravity
	for _, part in pairs(parts) do
		if part.Name ~= "HumanoidRootPart" then
			local att = Instance.new("Attachment")
			att.Name = "AntiGravityAtt"
			att.Parent = part

			local antiGravityForce = Instance.new("VectorForce")
			antiGravityForce.Name = "ZeroGravityForce"
			antiGravityForce.Attachment0 = att
			antiGravityForce.Force = Vector3.new(0, part:GetMass() * currentGravity, 0)
			antiGravityForce.RelativeTo = Enum.ActuatorRelativeTo.World
			antiGravityForce.Parent = part

			local density = part.CurrentPhysicalProperties and part.CurrentPhysicalProperties.Density or 0.7
			part.CustomPhysicalProperties = PhysicalProperties.new(
				density,
				0,
				CONFIG.BOUNCE_ELASTICITY,
				0,
				100
			)
		end
	end

	Utils.anchor(char, false)

	local impulsePart = getImpulsePart(parts)
	if impulsePart then
		local vx = rng:NextInteger(-CONFIG.THROW_FORCE_XZ, CONFIG.THROW_FORCE_XZ)
		local vy = CONFIG.THROW_FORCE_Y
		local vz = rng:NextInteger(-CONFIG.THROW_FORCE_XZ, CONFIG.THROW_FORCE_XZ)

		Utils.applyImpulse(impulsePart, Vector3.new(vx, vy, vz))
	end
end

function RagdollModule.apply(char: Model): boolean
	local hum = char:FindFirstChildWhichIsA("Humanoid", true)
	if not hum then
		return false
	end

	hum.BreakJointsOnDeath = false
	applyRagdoll(char, hum)

	return true
end

return RagdollModule
