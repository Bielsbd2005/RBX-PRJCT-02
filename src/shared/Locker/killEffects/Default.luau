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

-- R15_JOINTS / R15_WELDS / buildPartLookup / buildRagdoll were copy-pasted between
-- Default.luau and Gravity.luau; hoisted into Utils.luau to prevent drift.

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

	local parts = Utils.buildPartLookup(char)

	local root = parts.HumanoidRootPart
	if root then
		-- Destroy only joint instances on the root (Motor6D RootJoint, Welds,
		-- Constraints) — NOT ClearAllChildren, which also wipes death Sounds and
		-- the root rig Attachments that other systems rely on.
		Utils.destroyJoints(root)
		root.CanCollide = false
		root.Massless = true
	end

	hum:ChangeState(Enum.HumanoidStateType.Dead)
	hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	Utils.buildRagdoll(parts, CONFIG.JOINT_MAX_ANGLE, CONFIG.RAGDOLL_HEAD_AS_JOINT)

	CollisionGroups.setGroupForParts(char, allBaseParts, CollisionGroups.RAGDOLL)

	for _, part in allBaseParts do
		part.Anchored = false
	end

	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			part.CanCollide = true
		end
	end

	-- Roblox forces CanCollide=false on dead humanoid parts every frame.
	-- Re-enforce each Stepped so the ragdoll doesn't clip through the floor.
	Utils.enforceCanCollide(allBaseParts, char)

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
