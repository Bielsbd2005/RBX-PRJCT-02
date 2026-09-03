--!strict

-- Tornado — kill effect: el cuerpo sale despedido hacia ARRIBA girando sobre sí
-- mismo como un torbellino; los ball joints del ragdoll dejan que las extremidades
-- aleteen con el giro. Misma construcción de ragdoll que Default (Utils comparte
-- joints/welds/ownership); la única diferencia es el empujón final: vertical
-- fuerte + velocidad angular alta en el torso, sin fuerzas persistentes (cae con
-- gravedad normal, a diferencia de Gravity).

local RagdollModule = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Utils = require(script.Parent.Utils)
local CollisionGroups = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CollisionGroups"))

local CONFIG = {
	JOINT_MAX_ANGLE = 55,
	LAUNCH_UP = 55, -- studs/s hacia arriba (el "despegue" del torbellino)
	LAUNCH_DRIFT = 12, -- studs/s máx de deriva lateral aleatoria
	SPIN_SPEED = 22, -- rad/s alrededor del eje Y (el giro)
	SPIN_TILT = 4, -- rad/s máx de ruido en X/Z para que no gire como una peonza perfecta
	RAGDOLL_HEAD_AS_JOINT = false,
}

local rng = Random.new()

-- Empujón lineal + angular en un único step diferido. Mismo motivo que
-- Utils.applyImpulse (ver comentario allí): fijar velocidades en el mismo frame
-- que el desanclado + setServerOwnership hace que el handoff de física a veces
-- las descarte. Se difieren juntas para que el despegue y el giro prendan a la vez.
local function applySpinLaunch(part: BasePart, linear: Vector3, angular: Vector3)
	RunService.Heartbeat:Once(function()
		if part.Parent then
			part.AssemblyLinearVelocity = linear
			part.AssemblyAngularVelocity = angular
		end
	end)
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

	local impulsePart = parts.LowerTorso or parts.Torso or parts.HumanoidRootPart
	if impulsePart then
		local linear = Vector3.new(
			rng:NextInteger(-CONFIG.LAUNCH_DRIFT, CONFIG.LAUNCH_DRIFT),
			CONFIG.LAUNCH_UP,
			rng:NextInteger(-CONFIG.LAUNCH_DRIFT, CONFIG.LAUNCH_DRIFT)
		)
		local spinDirection = if rng:NextNumber() < 0.5 then -1 else 1
		local angular = Vector3.new(
			rng:NextNumber(-CONFIG.SPIN_TILT, CONFIG.SPIN_TILT),
			CONFIG.SPIN_SPEED * spinDirection,
			rng:NextNumber(-CONFIG.SPIN_TILT, CONFIG.SPIN_TILT)
		)
		applySpinLaunch(impulsePart, linear, angular)
	end

	return true
end

return RagdollModule
