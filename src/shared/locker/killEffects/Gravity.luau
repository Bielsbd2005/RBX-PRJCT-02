local RagdollModule = {}

local Utils = require(script.Parent.Utils)

-- Configuration
local CONFIG = {
	JOINT_MAX_ANGLE = 55,
	THROW_FORCE_XZ = 20,
	THROW_FORCE_Y = 35,
	RAGDOLL_HEAD_AS_JOINT = false,
	BOUNCE_ELASTICITY = 0.85, -- Reducido un poquito de 1 a 0.85 para dar mayor estabilidad física
}

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

local function getImpulsePart(char: Model): BasePart?
	local lowerTorso = char:FindFirstChild("LowerTorso", true)
	if lowerTorso and lowerTorso:IsA("BasePart") then
		return lowerTorso
	end

	local torso = char:FindFirstChild("Torso", true)
	if torso and torso:IsA("BasePart") then
		return torso
	end

	local root = char:FindFirstChild("HumanoidRootPart", true)
	if root and root:IsA("BasePart") then
		return root
	end

	return nil
end

local function buildRagdoll(char: Model)
	local head = char:FindFirstChild("Head", true)
	local upperTorso = char:FindFirstChild("UpperTorso", true)

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
		local part0 = char:FindFirstChild(jointData.Part0, true)
		local part1 = char:FindFirstChild(jointData.Part1, true)

		if part0 and part1 then
			local att0 = part0:FindFirstChild(jointData.Att0)
			local att1 = part1:FindFirstChild(jointData.Att1)

			if att0 and att1 then
				Utils.createBallJoint(att0, att1, { UpperAngle = CONFIG.JOINT_MAX_ANGLE })
			end
		end
	end

	for _, weldData in ipairs(R15_WELDS) do
		local part0 = char:FindFirstChild(weldData.Part0, true)
		local part1 = char:FindFirstChild(weldData.Part1, true)

		if part0 and part1 then
			Utils.createWeld(part0, part1)
		end
	end
end

-- NUEVA FUNCIÓN: Evita que las partes del cuerpo choquen entre sí
local function preventInternalCollisions(char: Model)
	local parts = {}
	for _, obj in ipairs(char:GetDescendants()) do
		if obj:IsA("BasePart") then
			table.insert(parts, obj)
		end
	end

	for i = 1, #parts do
		for j = i + 1, #parts do
			local noCollision = Instance.new("NoCollisionConstraint")
			noCollision.Part0 = parts[i]
			noCollision.Part1 = parts[j]
			noCollision.Parent = parts[i]
		end
	end
end

local function applyRagdoll(char: Model, hum: Humanoid)
	Utils.anchor(char, true)
	Utils.destroyMotors(char)

	local root = char:FindFirstChild("HumanoidRootPart", true)
	if root then
		root:ClearAllChildren()
		root.CanCollide = false
		root.Massless = true
	end

	hum:ChangeState(Enum.HumanoidStateType.Dead)
	hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	if hum.RigType == Enum.HumanoidRigType.R15 then
		buildRagdoll(char)
		preventInternalCollisions(char)
	end

	local currentGravity = workspace.Gravity
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
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

	local impulsePart = getImpulsePart(char)
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
