--!strict

local RagdollModule = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Utils = require(script.Parent.Utils)
local CollisionGroups = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CollisionGroups"))

local CONFIG = {
	JOINT_MAX_ANGLE = 55,
	THROW_FORCE_XZ = 20,
	THROW_FORCE_Y = 35,
	RAGDOLL_HEAD_AS_JOINT = false,
	BOUNCE_ELASTICITY = 0.85,
}

local rng = Random.new()

-- R15_JOINTS / R15_WELDS / buildPartLookup / buildRagdoll were copy-pasted between
-- Default.luau and Gravity.luau; hoisted into Utils.luau to prevent drift.

local function getImpulsePart(parts: { [string]: BasePart }): BasePart?
	return parts.LowerTorso or parts.Torso or parts.HumanoidRootPart
end

local function applyRagdoll(char: Model, hum: Humanoid)
	-- Only rebuild ragdoll joints for R15 rigs. Previously this destroyed ALL
	-- Motor6Ds unconditionally, so a non-R15 rig lost every joint with no
	-- replacement (drifted from Default, which early-returns for non-R15). Only
	-- strip Motor6Ds when we're going to rebuild, so non-R15 rigs stay intact.
	local isR15 = hum.RigType == Enum.HumanoidRigType.R15

	local allBaseParts: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			table.insert(allBaseParts, desc)
		elseif isR15 and desc:IsA("Motor6D") then
			desc:Destroy()
		end
	end

	local parts = Utils.buildPartLookup(char)

	local root = parts.HumanoidRootPart
	if root then
		-- Destroy only joint instances on the root (Motor6D RootJoint, Welds,
		-- Constraints) — NOT ClearAllChildren, which also wipes death Sounds and
		-- the root rig Attachments that other systems rely on. Skip on non-R15
		-- rigs, where we don't rebuild joints and must keep the rig connected.
		if isR15 then
			Utils.destroyJoints(root)
		end
		root.CanCollide = false
		root.Massless = true
	end

	hum:ChangeState(Enum.HumanoidStateType.Dead)
	hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	if isR15 then
		Utils.buildRagdoll(parts, CONFIG.JOINT_MAX_ANGLE, CONFIG.RAGDOLL_HEAD_AS_JOINT)
	end

	CollisionGroups.setGroupForParts(char, allBaseParts, CollisionGroups.RAGDOLL)

	local currentGravity = workspace.Gravity
	for _, part in parts do
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

	for _, part in allBaseParts do
		part.Anchored = false
	end

	-- Servidor simula el ragdoll (evita el congelamiento por network-ownership;
	-- ver Utils.setServerOwnership). No-op en el preview del Locker (cliente).
	Utils.setServerOwnership(allBaseParts)

	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			part.CanCollide = true
		end
	end

	-- Roblox forces CanCollide=false on dead humanoid parts every frame.
	-- Re-enforce each Stepped so the ragdoll doesn't clip through the floor.
	Utils.enforceCanCollide(allBaseParts, char)

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
