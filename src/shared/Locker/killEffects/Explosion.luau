--!strict

-- Explosion — kill effect: al morir, el cuerpo ESTALLA. Se ragdollea igual que los
-- demás efectos (Utils comparte la construcción) y cada parte del cuerpo sale
-- disparada RADIALMENTE desde el torso, con sesgo hacia arriba y algo de ruido, para
-- simular la onda expansiva; luego cae con gravedad normal (sin anti-gravedad, a
-- diferencia de Gravity). Se añade una Explosion nativa PURAMENTE COSMÉTICA
-- (BlastPressure = 0, DestroyJointsRadius = 0) para el flash — no empuja a nadie ni
-- rompe el mapa/otros personajes.

local RagdollModule = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Utils = require(script.Parent.Utils)
local CollisionGroups = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CollisionGroups"))

local CONFIG = {
	JOINT_MAX_ANGLE = 55,
	RAGDOLL_HEAD_AS_JOINT = false,
	BLAST_SPEED = 70, -- studs/s radial hacia afuera por parte
	UP_BIAS = 28, -- studs/s extra hacia arriba (arco, no solo lateral)
	JITTER = 12, -- studs/s de ruido por parte para que no salga simétrico
	VISUAL_BLAST_RADIUS = 10, -- solo el tamaño del flash de la Explosion nativa
	VISUAL_CLEANUP = 3, -- s tras los que limpiamos la Explosion por si el engine no la borra
}

local rng = Random.new()

-- Flash cosmético de la explosión. La Explosion nativa da un buen visual sin
-- dependencias de assets. BlastPressure = 0 → no aplica fuerza (la física la
-- hacemos nosotros, radial y controlada); DestroyJointsRadius = 0 → no rompe joints
-- del mapa ni de otros characters. En server replica a todos; en el preview del
-- Locker (cliente) se ve local.
local function spawnBlastVisual(center: Vector3)
	local explosion = Instance.new("Explosion")
	explosion.Position = center
	explosion.BlastPressure = 0
	explosion.BlastRadius = CONFIG.VISUAL_BLAST_RADIUS
	explosion.DestroyJointsRadius = 0
	explosion.Visible = true
	explosion.Parent = workspace
	Debris:AddItem(explosion, CONFIG.VISUAL_CLEANUP)
end

local function applyRagdoll(char: Model, hum: Humanoid)
	-- Solo reconstruimos joints de ragdoll para R15; para no-R15 dejamos el rig
	-- intacto (mismo criterio que Gravity) y aun así aplicamos la onda expansiva.
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
		-- Destruir solo los joints del root (no ClearAllChildren, que borraría los
		-- Sounds de muerte y las Attachments del rig). Skip en no-R15, donde no
		-- reconstruimos y hay que mantener el rig conectado.
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

	-- Centro de la explosión = torso (o HRP como fallback), capturado antes de
	-- desanclar/lanzar.
	local centerPart = parts.LowerTorso or parts.Torso or parts.HumanoidRootPart
	local center = if centerPart then centerPart.Position else char:GetPivot().Position

	-- Onda expansiva: cada parte visible sale disparada radialmente desde el centro,
	-- con sesgo hacia arriba y algo de ruido para que no sea perfectamente simétrico.
	-- applyImpulse difiere un step (fiable frente al cambio de network owner; ver
	-- Utils.applyImpulse). Saltamos el HRP (invisible, massless).
	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			local outward = part.Position - center
			if outward.Magnitude < 0.1 then
				-- Parte justo en el centro: dirección aleatoria hacia arriba.
				outward = Vector3.new(rng:NextNumber(-1, 1), 1, rng:NextNumber(-1, 1))
			end
			outward = outward.Unit
			local vel = outward * CONFIG.BLAST_SPEED
				+ Vector3.new(0, CONFIG.UP_BIAS, 0)
				+ Vector3.new(
					rng:NextNumber(-CONFIG.JITTER, CONFIG.JITTER),
					rng:NextNumber(0, CONFIG.JITTER),
					rng:NextNumber(-CONFIG.JITTER, CONFIG.JITTER)
				)
			Utils.applyImpulse(part, vel)
		end
	end

	spawnBlastVisual(center)
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
