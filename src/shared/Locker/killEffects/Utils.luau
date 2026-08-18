--!strict

local RunService = game:GetService("RunService")

local KillEffectUtils = {}

-- Roblox's internal character controller forces CanCollide = false on dead
-- humanoid parts every physics step. This helper re-enforces CanCollide = true
-- each Stepped frame so the ragdoll doesn't clip through the floor.
-- Auto-disconnects after `duration` seconds or when the character is destroyed.
local ENFORCE_DURATION = 12

function KillEffectUtils.enforceCanCollide(parts: { BasePart }, char: Model)
	local conn: RBXScriptConnection? = nil
	local startAt = time()

	conn = RunService.Stepped:Connect(function()
		if time() - startAt > ENFORCE_DURATION or not char.Parent then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			return
		end
		for _, part in parts do
			if part.Parent and part.Name ~= "HumanoidRootPart" and not part.CanCollide then
				part.CanCollide = true
			end
		end
	end)
end

function KillEffectUtils.createBallJoint(att0: Attachment?, att1: Attachment?, limits: { UpperAngle: number }?)
	if not att0 or not att1 then
		return
	end

	local joint = Instance.new("BallSocketConstraint")
	joint.Attachment0 = att0
	joint.Attachment1 = att1
	joint.LimitsEnabled = true
	joint.UpperAngle = limits and limits.UpperAngle or 45
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

-- Lanza la parte fijando su AssemblyLinearVelocity, pero UN STEP DESPUÉS. Hacerlo
-- en el mismo frame que el desanclado + setServerOwnership hace que el handoff de
-- física del cambio de dueño a veces descarte la velocidad y el cuerpo se quede en
-- el suelo (muy visible con Gravity, que debe salir volando; con Default pasa
-- desapercibido porque cae igual). Diferir al siguiente Heartbeat garantiza que el
-- desanclado y el ownership ya estén asentados y el empujón prenda de forma fiable.
-- El guard de Parent evita tocar un cadáver ya destruido antes del step.
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

-- Fuerza propiedad de red del SERVIDOR sobre las partes del ragdoll. Sin esto,
-- Roblox auto-asigna la propiedad de las partes sueltas al cliente más cercano;
-- cuando ese cliente deja de simularlas (el jugador muerto pasa a killcam /
-- pantalla de muerte, o se reasigna la propiedad) el cuerpo se CONGELA rígido en
-- su pose actual para TODOS los observadores — el "cadáver tieso / de maniquí"
-- que aparecía a ~1s. Con propiedad del servidor la caída se simula de forma
-- autoritativa y consistente hasta que el cadáver se destruye.
--
-- Server-only: SetNetworkOwner es exclusivo del servidor (en el preview del
-- Locker, que corre en cliente, es un no-op). Cada parte en pcall porque
-- SetNetworkOwner lanza sobre partes ancladas o fuera de Workspace. Se llama
-- DESPUÉS de desanclar y ANTES del impulso para que el empujón sea autoritativo.
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

-- Quita el arma del personaje al ragdollear, para que el cadáver no quede
-- sujetando el Tool en el aire. Cubre players y bots: ambos equipan la weapon como
-- un Tool hijo directo del character (players vía loadout; bots vía BotAI). Se
-- llama ANTES de construir el ragdoll para que las partes del Tool (Handle) no
-- entren en el procesado de partes del cadáver. En el preview del Locker es no-op
-- (el maniquí no lleva Tool).
function KillEffectUtils.stripWeapons(char: Model)
	for _, child in char:GetChildren() do
		if child:IsA("Tool") then
			child:Destroy()
		end
	end
end

-- Destroy only joint-type children of an instance (Motor6D, Weld, WeldConstraint,
-- and the various Constraints). Used instead of ClearAllChildren on the
-- HumanoidRootPart so death Sounds / rig Attachments survive ragdolling.
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

-- ── Shared R15 ragdoll builder ──────────────────────────────────────────────
-- Hoisted from Default.luau / Gravity.luau (were identical copy-pastes). Both
-- callers pass jointMaxAngle = 55 and headAsJoint = false today, but the params
-- keep the helper config-driven so a future tweak in one effect can't silently
-- diverge the joint tables.

KillEffectUtils.R15_JOINTS = {
	{ Part0 = "UpperTorso", Part1 = "RightUpperArm", Att0 = "RightShoulderRigAttachment", Att1 = "RightShoulderRigAttachment" },
	{ Part0 = "UpperTorso", Part1 = "LeftUpperArm", Att0 = "LeftShoulderRigAttachment", Att1 = "LeftShoulderRigAttachment" },
	{ Part0 = "LowerTorso", Part1 = "RightUpperLeg", Att0 = "RightHipRigAttachment", Att1 = "RightHipRigAttachment" },
	{ Part0 = "LowerTorso", Part1 = "LeftUpperLeg", Att0 = "LeftHipRigAttachment", Att1 = "LeftHipRigAttachment" },
	{ Part0 = "RightUpperArm", Part1 = "RightLowerArm", Att0 = "RightElbowRigAttachment", Att1 = "RightElbowRigAttachment" },
	{ Part0 = "LeftUpperArm", Part1 = "LeftLowerArm", Att0 = "LeftElbowRigAttachment", Att1 = "LeftElbowRigAttachment" },
	{ Part0 = "RightUpperLeg", Part1 = "RightLowerLeg", Att0 = "RightKneeRigAttachment", Att1 = "RightKneeRigAttachment" },
	{ Part0 = "LeftUpperLeg", Part1 = "LeftLowerLeg", Att0 = "LeftKneeRigAttachment", Att1 = "LeftKneeRigAttachment" },
}

KillEffectUtils.R15_WELDS = {
	{ Part0 = "LowerTorso", Part1 = "UpperTorso" },
	{ Part0 = "RightLowerArm", Part1 = "RightHand" },
	{ Part0 = "LeftLowerArm", Part1 = "LeftHand" },
	{ Part0 = "RightLowerLeg", Part1 = "RightFoot" },
	{ Part0 = "LeftLowerLeg", Part1 = "LeftFoot" },
}

function KillEffectUtils.buildPartLookup(char: Model): { [string]: BasePart }
	local map: { [string]: BasePart } = {}
	for _, child in char:GetChildren() do
		if child:IsA("BasePart") then
			map[child.Name] = child :: BasePart
		end
	end
	return map
end

function KillEffectUtils.buildRagdoll(parts: { [string]: BasePart }, jointMaxAngle: number, headAsJoint: boolean)
	local head = parts.Head
	local upperTorso = parts.UpperTorso

	if headAsJoint then
		if head and upperTorso then
			KillEffectUtils.createBallJoint(
				upperTorso:FindFirstChild("NeckRigAttachment") :: Attachment?,
				head:FindFirstChild("NeckRigAttachment") :: Attachment?,
				{ UpperAngle = jointMaxAngle }
			)
		end
	else
		KillEffectUtils.createWeld(upperTorso, head)
	end

	for _, jointData in ipairs(KillEffectUtils.R15_JOINTS) do
		local part0 = parts[jointData.Part0]
		local part1 = parts[jointData.Part1]

		if part0 and part1 then
			local att0 = part0:FindFirstChild(jointData.Att0)
			local att1 = part1:FindFirstChild(jointData.Att1)

			if att0 and att1 then
				KillEffectUtils.createBallJoint(att0 :: Attachment, att1 :: Attachment, { UpperAngle = jointMaxAngle })
			end
		end
	end

	for _, weldData in ipairs(KillEffectUtils.R15_WELDS) do
		KillEffectUtils.createWeld(parts[weldData.Part0], parts[weldData.Part1])
	end
end

return KillEffectUtils
