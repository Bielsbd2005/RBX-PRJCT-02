--!strict

-- Abduction — kill effect: un OVNI frena encima del cadáver (ragdoll real) y se lo
-- lleva con un rayo tractor: lo despega, flota girando y sale succionado hacia la panza.
--
-- REPARTO:
--   · Aquí (servidor, o el cliente en los previews): ragdoll + tractor FÍSICO
--     (AlignPosition/AlignOrientation en el torso, antigravedad parcial por parte y
--     arrastre de extremidades). Propiedad de red del servidor, como el resto de ragdolls.
--   · visuals/killEffects/Abduction (cliente): el OVNI, el rayo y los efectos.
--   · Los dos simulan el MISMO vuelo (AbductionFlight: paso fijo + `ATTR.SEED` +
--     `ATTR.GROUND_Y`), así el servidor sabe dónde está la panza sin replicar el OVNI.
--
-- En `TIMING.BODY_HIDE` el cuerpo se oculta y se ancla, pero no se destruye:
-- MatchService, AIService (RagdollCleanup), el Locker y ScenePreview ya lo hacen, y lo
-- que aún mire al HumanoidRootPart del muerto sigue teniéndolo.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Utils = require(script.Parent.Utils)
local AbductionFlight = require(script.Parent.AbductionFlight)

local Abduction = {}

-- Contrato con el cliente (visuals/killEffects/Abduction). Cambiar aquí, no en literales.
Abduction.ATTR = table.freeze({
	-- Hora EXACTA con la que el servidor simula el vuelo (no la del registry, que se
	-- toma después): el cliente debe volar el mismo AbductionFlight.
	STARTED_AT = "AbductionStartedAt",
	ORIGIN = "AbductionOrigin", -- CFrame del HumanoidRootPart al morir
	SCALE = "AbductionScale", -- 1 = cuerpo normal (ScenePreview escala el maniquí)
	SEED = "AbductionSeed", -- dirección de llegada/salida, igual para todos
	GROUND_Y = "AbductionGroundY", -- suelo que midió el servidor: todos vuelan a la misma altura
})
-- Segundos desde la muerte.
Abduction.TIMING = table.freeze({
	BEAM_ON = 0.5, -- se abre el rayo y despega el cuerpo del suelo (el OVNI está casi encima)
	SUCK = 1.2, -- deja de flotar: amago y succión hacia la panza
	BODY_GONE = 1.75, -- el cuerpo llega a la panza: el cliente lo funde y el OVNI traga
	BODY_HIDE = 1.95, -- se oculta y se congela
	LEAVE = 2, -- el OVNI se va: amago, curva hacia el cielo y encoge
	END = 3.1, -- el OVNI ha desaparecido
})
-- El preview (Locker, pase) enseña hasta que el OVNI se ha ido.
Abduction.previewTime = Abduction.TIMING.END
-- Plantilla OPCIONAL: ReplicatedStorage.UFO o ReplicatedStorage.Templates.UFO.
Abduction.TEMPLATE_NAME = "UFO"

local TIMING = Abduction.TIMING

local CONFIG = {
	RAGDOLL_HEAD_AS_JOINT = true,

	-- Tirón al abrirse el rayo
	HOP_SPEED = 16, -- studs/s hacia arriba a todo el cuerpo

	-- Flotar (BEAM_ON → SUCK)
	FLOAT_RISE = 0.4, -- fracción del hueco hasta la panza que sube flotando
	FLOAT_FOLLOW = 0.5, -- fracción del desplazamiento horizontal hacia el OVNI
	FLOAT_BOB = 0.35, -- studs de vaivén vertical
	FLOAT_BOB_FREQ = 7, -- rad/s
	FLOAT_TILT = math.rad(65), -- se tumba boca arriba
	FLOAT_SPIN = 1.4, -- rad/s de giro
	FLOAT_LIFT = 0.9, -- fracción del peso que anula la antigravedad (1 = ingrávido)
	FLOAT_LIMB_DRAG = 3.5, -- 1/s: cuánto frenan las extremidades respecto al torso
	FLOAT_RESPONSIVENESS = 9,
	FLOAT_TURN_RESPONSIVENESS = 4,

	-- Succión (SUCK → BODY_GONE; después sigue pegado a la panza)
	SUCK_TARGET_UP = 0.6, -- studs por encima de la panza: acaba dentro del casco
	SUCK_UPRIGHT = 0.4, -- fracción de la succión en la que se endereza
	SUCK_SPIN = 11, -- rad/s al final
	SUCK_LIFT = 0.45, -- menos antigravedad: las piernas cuelgan y se quedan atrás
	SUCK_LIMB_DRAG = 1.2,
	SUCK_RESPONSIVENESS = 35,
	SUCK_TURN_RESPONSIVENESS = 12,

	-- Constraints
	PULL_FORCE = 12, -- × peso del cuerpo
	PULL_MAX_SPEED = 150, -- studs/s
	TURN_TORQUE = 400, -- × masa del cuerpo
	ANGULAR_DRAG = 2.5, -- 1/s sobre el giro de las extremidades respecto al torso
}

type Body = {
	parts: { [string]: BasePart }, -- hijos directos del char por nombre
	simulated: { BasePart }, -- lo que se desancló (sin el HRP)
}

type Lift = { force: VectorForce, weight: number }

local rng = Random.new()

function Abduction.findTemplate(): Model?
	local direct = ReplicatedStorage:FindFirstChild(Abduction.TEMPLATE_NAME)
	if direct and direct:IsA("Model") then
		return direct
	end
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	local nested = if templates then templates:FindFirstChild(Abduction.TEMPLATE_NAME) else nil
	if nested and nested:IsA("Model") then
		return nested
	end
	return nil
end

local function ease(alpha: number, style: Enum.EasingStyle, direction: Enum.EasingDirection): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style, direction)
end

-- Todo transparente y apagado, en su sitio (mismo criterio que Tombstone).
local function hideBody(char: Model)
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then -- Texture hereda de Decal
			(d :: any).Transparency = 1
		elseif
			d:IsA("ParticleEmitter")
			or d:IsA("Trail")
			or d:IsA("Beam")
			or d:IsA("Light")
			or d:IsA("Fire")
			or d:IsA("Smoke")
			or d:IsA("Sparkles")
			or d:IsA("LayerCollector")
			or d:IsA("Highlight")
		then
			(d :: any).Enabled = false
		end
	end
end

-- Mismo ragdoll que Balloons: joints propios en R15; en otros rigs se deja el rig
-- entero y el rayo se lo lleva rígido.
local function ragdoll(char: Model, hum: Humanoid): Body
	local isR15 = hum.RigType == Enum.HumanoidRigType.R15

	local simulated: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			table.insert(simulated, desc)
		elseif isR15 and Utils.isRigJoint(desc) then
			desc:Destroy()
		end
	end

	local parts = Utils.buildPartLookup(char)

	local root = parts.HumanoidRootPart
	if root then
		if isR15 then
			Utils.destroyJoints(root)
		end
		root.CanCollide = false
		root.Massless = true
	end

	Utils.releaseHumanoid(hum)

	if isR15 then
		Utils.buildRagdoll(parts, CONFIG.RAGDOLL_HEAD_AS_JOINT, simulated)
	end

	Utils.makeCorpseInert(char)

	for _, part in simulated do
		part.Anchored = false
	end

	-- Servidor simula el ragdoll (evita el congelamiento por network-ownership;
	-- ver Utils.setServerOwnership). No-op en el preview del Locker (cliente).
	Utils.setServerOwnership(simulated)

	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			part.CanCollide = true
		end
	end

	return { parts = parts, simulated = simulated }
end

local function bodyMass(simulated: { BasePart }): number
	local mass = 0
	for _, part in simulated do
		if not part.Massless then
			mass += part:GetMass()
		end
	end
	return math.max(mass, 1)
end

local function setLift(lifts: { Lift }, fraction: number)
	local gravity = workspace.Gravity
	for _, lift in lifts do
		if lift.force.Parent then
			lift.force.Force = Vector3.new(0, lift.weight * gravity * fraction, 0)
			lift.force.Enabled = true
		end
	end
end

-- El tractor. Todo se crea apagado y se enciende en BEAM_ON; hasta entonces el
-- cadáver cae como cualquier ragdoll. Un Heartbeat por abducción (dura < 2 s):
-- escribe el objetivo del AlignPosition/AlignOrientation cada frame y el resto de
-- propiedades sólo al cambiar de fase, para no replicar de más.
local function runTractor(char: Model, body: Body, flight: AbductionFlight.Flight, startedAt: number)
	local parts = body.parts
	local grab = parts.UpperTorso or parts.Torso or parts.LowerTorso
	if not grab then
		task.delay(TIMING.BODY_HIDE, function()
			if char.Parent then
				hideBody(char)
			end
		end)
		return
	end
	local grabPart = grab :: BasePart
	local scale = flight.scale
	local mass = bodyMass(body.simulated)

	local attachment = Instance.new("Attachment")
	attachment.Name = "TractorAttachment"
	attachment.Parent = grabPart

	local pull = Instance.new("AlignPosition")
	pull.Name = "TractorPull"
	pull.Mode = Enum.PositionAlignmentMode.OneAttachment
	pull.Attachment0 = attachment
	pull.ApplyAtCenterOfMass = true
	pull.MaxForce = mass * workspace.Gravity * CONFIG.PULL_FORCE
	pull.MaxVelocity = CONFIG.PULL_MAX_SPEED * scale
	pull.Responsiveness = CONFIG.FLOAT_RESPONSIVENESS
	pull.Enabled = false
	pull.Parent = grabPart

	local turn = Instance.new("AlignOrientation")
	turn.Name = "TractorTurn"
	turn.Mode = Enum.OrientationAlignmentMode.OneAttachment
	turn.Attachment0 = attachment
	turn.MaxTorque = mass * CONFIG.TURN_TORQUE * scale * scale
	turn.Responsiveness = CONFIG.FLOAT_TURN_RESPONSIVENESS
	turn.Enabled = false
	turn.Parent = grabPart

	local lifts: { Lift } = {}
	for _, part in body.simulated do
		if not part.Massless then
			local liftAttachment = Instance.new("Attachment")
			liftAttachment.Name = "TractorLiftAttachment"
			liftAttachment.Parent = part
			local force = Instance.new("VectorForce")
			force.Name = "TractorLift"
			force.Attachment0 = liftAttachment
			force.RelativeTo = Enum.ActuatorRelativeTo.World
			force.ApplyAtCenterOfMass = true
			force.Enabled = false
			force.Parent = part
			table.insert(lifts, { force = force, weight = part:GetMass() })
		end
	end

	local spinSign = if rng:NextNumber() < 0.5 then -1 else 1
	local started = false
	local sucking = false
	local limbs: { BasePart } = {}
	local liftFrom = grabPart.Position
	local suckFrom = liftFrom
	local baseYaw = 0
	local yaw = 0
	local target = liftFrom

	local conn: RBXScriptConnection? = nil
	local function stop(hide: boolean)
		if conn then
			conn:Disconnect()
			conn = nil
		end
		pull:Destroy()
		turn:Destroy()
		for _, lift in lifts do
			lift.force:Destroy()
		end
		if hide and char.Parent then
			hideBody(char)
			for _, part in body.simulated do
				if part.Parent then
					part.Anchored = true
				end
			end
		end
	end

	conn = RunService.Heartbeat:Connect(function(dt: number)
		if not char.Parent or not grabPart.Parent then
			stop(false)
			return
		end
		local elapsed = workspace:GetServerTimeNow() - startedAt
		if elapsed < TIMING.BEAM_ON then
			return
		end
		if elapsed >= TIMING.BODY_HIDE then
			stop(true)
			return
		end

		AbductionFlight.advance(flight, elapsed)
		local ufoCF = AbductionFlight.sample(flight, elapsed)
		local belly = AbductionFlight.bellyOf(flight, ufoCF)

		if not started then
			started = true
			liftFrom = grabPart.Position
			target = liftFrom
			local look = grabPart.CFrame.LookVector
			baseYaw = math.atan2(-look.X, -look.Z)
			-- Una parte por assembly (mano y antebrazo van soldados) y sin la del torso.
			local seen: { [BasePart]: boolean } = { [grabPart.AssemblyRootPart or grabPart] = true }
			for _, part in body.simulated do
				local assemblyRoot = part.AssemblyRootPart or part
				if not part.Massless and not seen[assemblyRoot] then
					seen[assemblyRoot] = true
					table.insert(limbs, part)
				end
			end
			pull.Position = liftFrom
			pull.Enabled = true
			turn.CFrame = CFrame.Angles(0, baseYaw, 0)
			turn.Enabled = true
			setLift(lifts, CONFIG.FLOAT_LIFT)
			Utils.launchBody(parts, Vector3.new(0, CONFIG.HOP_SPEED * scale, 0))
		end

		local spinRate: number
		local tilt: number
		local limbDrag: number
		if elapsed < TIMING.SUCK then
			local u = (elapsed - TIMING.BEAM_ON) / (TIMING.SUCK - TIMING.BEAM_ON)
			-- Sube rápido al principio (acompaña el tirón) y se queda flotando bajo el
			-- OVNI, siguiéndolo a medias cuando se mueve.
			local rise = ease(u, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
			local floatPoint = Vector3.new(
				liftFrom.X + (belly.X - liftFrom.X) * CONFIG.FLOAT_FOLLOW,
				liftFrom.Y + (belly.Y - liftFrom.Y) * CONFIG.FLOAT_RISE,
				liftFrom.Z + (belly.Z - liftFrom.Z) * CONFIG.FLOAT_FOLLOW
			)
			local bob = CONFIG.FLOAT_BOB * scale * math.sin((elapsed - TIMING.BEAM_ON) * CONFIG.FLOAT_BOB_FREQ) * rise
			target = liftFrom:Lerp(floatPoint, rise) + Vector3.new(0, bob, 0)
			tilt = CONFIG.FLOAT_TILT * ease(u, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			spinRate = CONFIG.FLOAT_SPIN * ease(u * 3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			limbDrag = CONFIG.FLOAT_LIMB_DRAG
		else
			if not sucking then
				sucking = true
				suckFrom = target
				pull.Responsiveness = CONFIG.SUCK_RESPONSIVENESS
				turn.Responsiveness = CONFIG.SUCK_TURN_RESPONSIVENESS
				setLift(lifts, CONFIG.SUCK_LIFT)
			end
			local u = (elapsed - TIMING.SUCK) / (TIMING.BODY_GONE - TIMING.SUCK)
			-- Back In: baja un pelín antes del tirón (anticipación) y acelera hasta
			-- dentro. Pasado BODY_GONE el objetivo sigue a la panza.
			local goal = belly + Vector3.new(0, CONFIG.SUCK_TARGET_UP * scale, 0)
			target = suckFrom:Lerp(goal, ease(u, Enum.EasingStyle.Back, Enum.EasingDirection.In))
			tilt = CONFIG.FLOAT_TILT
				* (1 - ease(u / CONFIG.SUCK_UPRIGHT, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
			spinRate = CONFIG.FLOAT_SPIN
				+ (CONFIG.SUCK_SPIN - CONFIG.FLOAT_SPIN) * ease(u, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			limbDrag = CONFIG.SUCK_LIMB_DRAG
		end

		yaw += spinSign * spinRate * dt
		pull.Position = target
		turn.CFrame = CFrame.Angles(0, baseYaw + yaw, 0) * CFrame.Angles(tilt, 0, 0)

		-- Arrastre respecto al torso: las extremidades lo siguen con suavidad en vez
		-- de aletear. Sólo tiene efecto donde se simula (servidor o preview).
		local grabVel = grabPart.AssemblyLinearVelocity
		local grabSpin = grabPart.AssemblyAngularVelocity
		local keep = math.exp(-limbDrag * dt)
		local keepSpin = math.exp(-CONFIG.ANGULAR_DRAG * dt)
		for _, part in limbs do
			if part.Parent and not part.Anchored then
				part.AssemblyLinearVelocity = grabVel + (part.AssemblyLinearVelocity - grabVel) * keep
				part.AssemblyAngularVelocity = grabSpin + (part.AssemblyAngularVelocity - grabSpin) * keepSpin
			end
		end
	end)
end

function Abduction.apply(char: Model): boolean
	local hum = char:FindFirstChildWhichIsA("Humanoid", true)
	if not hum then
		return false
	end
	hum.BreakJointsOnDeath = false
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	-- ANTES del ragdoll: dónde estaba el cuerpo al morir.
	local origin = Utils.deathCFrame(char)
	local scale = Utils.bodyScale(char)
	local groundY = AbductionFlight.findGroundY(origin.Position, char) or (origin.Position.Y - 3 * scale)
	local seed = rng:NextInteger(1, 2 ^ 30)
	local startedAt = workspace:GetServerTimeNow()

	local body = ragdoll(char, hum)

	-- KillEffectsRegistry pone el tag después: llegan juntos y el cliente los lee ya.
	char:SetAttribute(Abduction.ATTR.ORIGIN, origin)
	char:SetAttribute(Abduction.ATTR.SCALE, scale)
	char:SetAttribute(Abduction.ATTR.SEED, seed)
	char:SetAttribute(Abduction.ATTR.GROUND_Y, groundY)
	char:SetAttribute(Abduction.ATTR.STARTED_AT, startedAt)

	runTractor(
		char,
		body,
		AbductionFlight.new({
			spot = origin.Position,
			groundY = groundY,
			scale = scale,
			seed = seed,
			leaveAt = TIMING.LEAVE,
			exitTime = TIMING.END - TIMING.LEAVE,
			spinBoostFrom = TIMING.BEAM_ON,
			spinBoostTo = TIMING.BODY_GONE,
		}),
		startedAt
	)

	return true
end

return Abduction
