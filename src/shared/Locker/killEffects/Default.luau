--!strict

local RagdollModule = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Utils = require(script.Parent.Utils)
local CollisionGroups = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CollisionGroups"))

local CONFIG = {
	JOINT_MAX_ANGLE = 55,
	THROW_FORCE = 50,
	THROW_FORCE_UP_MULT = 1.5,
	RAGDOLL_HEAD_AS_JOINT = false,
}

local rng = Random.new()

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

local function buildPartLookup(char: Model): { [string]: BasePart }
	local map: { [string]: BasePart } = {}
	for _, child in char:GetChildren() do
		if child:IsA("BasePart") then
			map[child.Name] = child :: BasePart
		end
	end
	return map
end

local function buildRagdoll(parts: { [string]: BasePart })
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
		Utils.createWeld(parts[weldData.Part0], parts[weldData.Part1])
	end
end

function RagdollModule.apply(char: Model): boolean
	local hum = char:FindFirstChildWhichIsA("Humanoid", true)
	if not hum or hum.RigType ~= Enum.HumanoidRigType.R15 then
		return false
	end

	hum.BreakJointsOnDeath = false

	local allBaseParts: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			table.insert(allBaseParts, desc)
		elseif desc:IsA("Motor6D") then
			desc:Destroy()
		end
	end

	local parts = buildPartLookup(char)

	local root = parts.HumanoidRootPart
	if root then
		root:ClearAllChildren()
		root.CanCollide = false
		root.Massless = true
	end

	hum:ChangeState(Enum.HumanoidStateType.Dead)
	hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	buildRagdoll(parts)

	CollisionGroups.setGroupForParts(char, allBaseParts, CollisionGroups.RAGDOLL)

	for _, part in allBaseParts do
		part.Anchored = false
	end

	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			part.CanCollide = true
		end
	end

	local impulsePart = parts.LowerTorso or parts.Torso or parts.HumanoidRootPart
	if impulsePart then
		local vx = rng:NextInteger(-CONFIG.THROW_FORCE, CONFIG.THROW_FORCE)
		local vy = rng:NextInteger(0, CONFIG.THROW_FORCE) * CONFIG.THROW_FORCE_UP_MULT
		local vz = rng:NextInteger(-CONFIG.THROW_FORCE, CONFIG.THROW_FORCE)

		Utils.applyImpulse(impulsePart, Vector3.new(vx, vy, vz))
	end

	return true
end

return RagdollModule
