--!strict

local RagdollModule = {}

local Utils = require(script.Parent.Utils)

local CONFIG = {
	THROW_FORCE_XZ = 20,
	THROW_FORCE_Y = 35,
	RAGDOLL_HEAD_AS_JOINT = true,
	BOUNCE_ELASTICITY = 0.85,
}

local rng = Random.new()

local function getImpulsePart(parts: { [string]: BasePart }): BasePart?
	return parts.LowerTorso or parts.Torso or parts.HumanoidRootPart
end

local function applyRagdoll(char: Model, hum: Humanoid)
	-- Solo se quitan joints si se van a reconstruir (R15); un rig no-R15 debe quedar conectado.
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
		-- No usar ClearAllChildren: borraría los Sounds de muerte y los Attachments
		-- del root de los que dependen otros sistemas.
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

	local impulsePart = getImpulsePart(parts)
	if impulsePart then
		local vx = rng:NextInteger(-CONFIG.THROW_FORCE_XZ, CONFIG.THROW_FORCE_XZ)
		local vy = CONFIG.THROW_FORCE_Y
		local vz = rng:NextInteger(-CONFIG.THROW_FORCE_XZ, CONFIG.THROW_FORCE_XZ)

		Utils.launchBody(parts, Vector3.new(vx, vy, vz))
	end
	Utils.calmRagdoll(parts, char)
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
