--!strict

local RagdollModule = {}

local Utils = require(script.Parent.Utils)

local CONFIG = {
	-- studs/s. Horizontal: magnitud en rango y ángulo aleatorio (no azar por eje) para
	-- que todas las muertes se vean parecidas.
	THROW_SPEED_XZ_MIN = 24,
	THROW_SPEED_XZ_MAX = 30,
	THROW_SPEED_UP_MIN = 7,
	THROW_SPEED_UP_MAX = 10,
	RAGDOLL_HEAD_AS_JOINT = true,
}

local rng = Random.new()

-- Ragdoll sin lanzamiento ni calmRagdoll, para efectos que mueven el cuerpo a su manera.
-- Devuelve las partes del cuerpo por nombre, o nil si el rig no es R15.
function RagdollModule.ragdoll(char: Model): { [string]: BasePart }?
	local hum = char:FindFirstChildWhichIsA("Humanoid", true)
	if not hum or hum.RigType ~= Enum.HumanoidRigType.R15 then
		return nil
	end

	hum.BreakJointsOnDeath = false

	local allBaseParts: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			table.insert(allBaseParts, desc)
		elseif Utils.isRigJoint(desc) then
			desc:Destroy()
		end
	end

	local parts = Utils.buildPartLookup(char)

	local root = parts.HumanoidRootPart
	if root then
		-- Solo joints, NO ClearAllChildren: borraría los Sounds de muerte y los
		-- Attachments del rig de los que dependen otros sistemas.
		Utils.destroyJoints(root)
		root.CanCollide = false
		root.Massless = true
	end

	Utils.releaseHumanoid(hum)

	Utils.buildRagdoll(parts, CONFIG.RAGDOLL_HEAD_AS_JOINT, allBaseParts)

	Utils.makeCorpseInert(char)

	for _, part in allBaseParts do
		part.Anchored = false
	end

	-- Evita el congelamiento por network ownership. No-op en el preview del Locker (cliente).
	Utils.setServerOwnership(allBaseParts)

	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			part.CanCollide = true
		end
	end

	return parts
end

function RagdollModule.apply(char: Model): boolean
	local parts = RagdollModule.ragdoll(char)
	if not parts then
		return false
	end

	local impulsePart = parts.LowerTorso or parts.Torso or parts.HumanoidRootPart
	if impulsePart then
		local angle = rng:NextNumber(0, 2 * math.pi)
		local speedXZ = rng:NextNumber(CONFIG.THROW_SPEED_XZ_MIN, CONFIG.THROW_SPEED_XZ_MAX)
		local vy = rng:NextNumber(CONFIG.THROW_SPEED_UP_MIN, CONFIG.THROW_SPEED_UP_MAX)

		Utils.launchBody(parts, Vector3.new(math.cos(angle) * speedXZ, vy, math.sin(angle) * speedXZ))
	end
	Utils.calmRagdoll(parts, char)

	return true
end

return RagdollModule
