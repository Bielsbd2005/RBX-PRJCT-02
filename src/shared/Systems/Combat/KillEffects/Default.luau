local RagdollModule = {}

local Utils = require(script.Parent.Utils)

-- Configuration
local CONFIG = {
	JOINT_MAX_ANGLE = 55,
	THROW_FORCE = 50,
	THROW_FORCE_UP_MULT = 1.5,
	RAGDOLL_HEAD_AS_JOINT = false,
}

local rng = Random.new()

-- Data abstraction for R15 joints
local R15_JOINTS = {
	-- Shoulders
	{ Part0 = "UpperTorso", Part1 = "RightUpperArm", Att0 = "RightShoulderRigAttachment", Att1 = "RightShoulderRigAttachment" },
	{ Part0 = "UpperTorso", Part1 = "LeftUpperArm", Att0 = "LeftShoulderRigAttachment", Att1 = "LeftShoulderRigAttachment" },
	-- Hips
	{ Part0 = "LowerTorso", Part1 = "RightUpperLeg", Att0 = "RightHipRigAttachment", Att1 = "RightHipRigAttachment" },
	{ Part0 = "LowerTorso", Part1 = "LeftUpperLeg", Att0 = "LeftHipRigAttachment", Att1 = "LeftHipRigAttachment" },
	-- Elbows
	{ Part0 = "RightUpperArm", Part1 = "RightLowerArm", Att0 = "RightElbowRigAttachment", Att1 = "RightElbowRigAttachment" },
	{ Part0 = "LeftUpperArm", Part1 = "LeftLowerArm", Att0 = "LeftElbowRigAttachment", Att1 = "LeftElbowRigAttachment" },
	-- Knees
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

local function buildRagdoll(char: Model)
	-- Head Logic
	local head = char:FindFirstChild("Head")
	local upperTorso = char:FindFirstChild("UpperTorso")

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

	-- Joints
	for _, jointData in ipairs(R15_JOINTS) do
		local part0 = char:FindFirstChild(jointData.Part0)
		local part1 = char:FindFirstChild(jointData.Part1)

		if part0 and part1 then
			local att0 = part0:FindFirstChild(jointData.Att0)
			local att1 = part1:FindFirstChild(jointData.Att1)

			if att0 and att1 then
				Utils.createBallJoint(att0, att1, { UpperAngle = CONFIG.JOINT_MAX_ANGLE })
			end
		end
	end

	-- Welds
	for _, weldData in ipairs(R15_WELDS) do
		local part0 = char:FindFirstChild(weldData.Part0)
		local part1 = char:FindFirstChild(weldData.Part1)

		if part0 and part1 then
			Utils.createWeld(part0, part1)
		end
	end
end

function RagdollModule.applyDefaultRagdoll(char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.RigType ~= Enum.HumanoidRigType.R15 then return end

	hum.BreakJointsOnDeath = false

	-- Setup death listener
	hum.Died:Connect(function()
		-- 1. Prepare for physics
		Utils.anchor(char, true) -- Briefly anchor to prevent glitching during setup
		Utils.destroyMotors(char)

		-- 2. Clean up
		local root = char:FindFirstChild("HumanoidRootPart")
		if root then root:ClearAllChildren() end -- Clears sounds/scripts in root

		hum:ChangeState(Enum.HumanoidStateType.Dead)
		hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

		-- 3. Build Ragdoll
		-- Intentionally removed task.wait() for instant response, unless physics instability occurs
		buildRagdoll(char)

		-- 4. Apply Force & Release
		Utils.anchor(char, false)

		local lowerTorso = char:FindFirstChild("LowerTorso")
		if lowerTorso then
			local vx = rng:NextInteger(-CONFIG.THROW_FORCE, CONFIG.THROW_FORCE)
			local vy = rng:NextInteger(0, CONFIG.THROW_FORCE) * CONFIG.THROW_FORCE_UP_MULT
			local vz = rng:NextInteger(-CONFIG.THROW_FORCE, CONFIG.THROW_FORCE)

			Utils.applyImpulse(lowerTorso, Vector3.new(vx, vy, vz))
		end
	end)
end

return RagdollModule
