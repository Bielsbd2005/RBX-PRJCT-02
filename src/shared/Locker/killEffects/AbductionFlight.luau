--!strict

-- Vuelo del OVNI del kill effect Abduction, compartido: el servidor (Abduction)
-- lo simula para saber hacia dónde tirar del cuerpo y cada cliente
-- (AbductionVisuals) lo pinta. Mismo motor que UFOController, PetController y
-- BodySpinner del juego del OVNI. Se integra a paso FIJO con la semilla y el suelo
-- del servidor: todos sacan la misma trayectoria a cualquier fps, y quien llega
-- tarde se pone al día simulando los pasos perdidos.

local Players = game:GetService("Players")

local AbductionFlight = {}

AbductionFlight.STEP = 1 / 60 -- s por paso de la simulación

AbductionFlight.CONFIG = table.freeze({
	RAY_LENGTH = 200, -- studs de búsqueda de suelo bajo el cuerpo
	RAY_MAX_SKIPS = 8, -- personajes/cadáveres que el raycast puede saltarse

	-- Tamaños a escala 1 (todo se multiplica por la escala del cuerpo)
	UFO_DIAMETER = 12, -- studs de ancho del OVNI
	BELLY_DEPTH = 1.1, -- studs bajo el centro de los que sale el rayo (OVNI procedural)
	HOVER_HEIGHT = 12, -- studs sobre el suelo a los que abduce (HOVER_HEIGHT del juego)

	-- Entrada
	ENTRY_DISTANCE = 65, -- studs horizontales desde los que llega
	ENTRY_HEIGHT = 14, -- studs por encima de su altura de trabajo
	ENTRY_SPEED = 110, -- studs/s con los que ya viene lanzado

	-- Muelle, inclinación y giro del casco: los de GameConfig del juego del OVNI.
	-- APPROACH, MAX_SPEED y ACCEL más vivos que los de la mascota.
	APPROACH = 4, -- ganancia de acercamiento (1/s)
	MAX_SPEED = 130, -- studs/s
	ACCEL = 8, -- inercia (1/s)
	HOVER_RESPONSE = 4,
	HOVER_BOUNCE = 0.55,
	HOVER_MAX_SPEED = 90,
	ROLL_STRENGTH = 0.5,
	MAX_ROLL_DEG = 30,
	PITCH_STRENGTH = 0.4,
	MAX_PITCH_DEG = 20,
	TURN_RESPONSIVENESS = 14, -- suavizado de la orientación (1/s)
	FACE_MIN_SPEED = 2, -- studs/s por debajo de los cuales mantiene el rumbo

	-- Salida: curva de Bézier desde donde abdujo hasta el cielo, recorrida con
	-- aceleración (arranca despacio y sale disparado).
	LEAVE_SPREAD = 0.9, -- rad máx de desvío de la salida respecto a seguir recto
	EXIT_DISTANCE = 140, -- studs horizontales hasta el final de la curva
	EXIT_HEIGHT = 170, -- studs que sube
	EXIT_DIP = 12, -- studs del control de abajo: hace un amago de ~1 stud antes de arrancar
	EXIT_SWAY = 22, -- studs de desvío lateral: la curva no es un plano
	EXIT_EASE = 1.6, -- exponente del avance por la curva (1 = constante, 2 = muy cargado al final)
	EXIT_TILT = 0.35, -- cuánto inclina el disco hacia donde va (0 = plano, 1 = de canto)

	-- Casco (BodySpinner)
	BODY_IDLE_SPIN = 2,
	BODY_SPEED_SPIN = 4,
	BODY_TURN_INFLUENCE = 6,
	BODY_MIN_SPIN = 0.6,
	BODY_MAX_SPIN = 14,
	BODY_SPIN_SMOOTHTIME = 0.35,
	BODY_REF_SPEED = 70, -- MAX_SPEED del jugador en el juego del OVNI
	BODY_TURN_SMOOTH = 10,
	ABDUCT_SPIN_BOOST = 6, -- rad/s extra mientras abduce
})

local CONFIG = AbductionFlight.CONFIG
local STEP = AbductionFlight.STEP

-- Muelle de la suspensión (igual que UFOController)
local HOVER_STIFFNESS = CONFIG.HOVER_RESPONSE * CONFIG.HOVER_RESPONSE
local HOVER_DAMPING = 2 * CONFIG.HOVER_BOUNCE * CONFIG.HOVER_RESPONSE

local TAU = 2 * math.pi

export type Params = {
	spot: Vector3, -- punto de muerte (sólo cuentan X y Z)
	groundY: number,
	scale: number,
	seed: number,
	leaveAt: number, -- s desde la muerte en que se va
	exitTime: number, -- s que tarda en recorrer la curva de salida
	spinBoostFrom: number, -- ventana en la que el casco gira más (abduciendo)
	spinBoostTo: number,
}

export type Flight = {
	-- Fijo
	scale: number,
	spotX: number,
	spotZ: number,
	hoverY: number,
	leaveDirX: number,
	leaveDirZ: number,
	swaySign: number,
	leaveAt: number,
	exitTime: number,
	spinBoostFrom: number,
	spinBoostTo: number,
	-- Estado
	exitFrom: Vector3?, -- dónde estaba al empezar a irse
	t: number, -- s simulados
	x: number,
	y: number,
	z: number,
	velX: number,
	velZ: number,
	vy: number,
	faceX: number,
	faceZ: number,
	rot: CFrame,
	spin: number, -- sin envolver: se interpola sin saltos
	w: number,
	spinVel: number,
	turn: number,
	lastYaw: number,
	-- Paso anterior, para interpolar
	px: number,
	py: number,
	pz: number,
	prot: CFrame,
	pspin: number,
}

-- SmoothDamp (muelle críticamente amortiguado), copiado de BodySpinner.
local function smoothDamp(current: number, target: number, vel: number, smoothTime: number, dt: number): (number, number)
	smoothTime = math.max(0.0001, smoothTime)
	local omega = 2 / smoothTime
	local x = omega * dt
	local expo = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = current - target
	local temp = (vel + omega * change) * dt
	vel = (vel - omega * temp) * expo
	return target + (change + temp) * expo, vel
end

local function yawOf(cf: CFrame): number
	local look = cf.LookVector
	return math.atan2(look.X, look.Z)
end

function AbductionFlight.new(params: Params): Flight
	local rng = Random.new(params.seed)
	local scale = params.scale
	local spotX, spotZ = params.spot.X, params.spot.Z
	local hoverY = params.groundY + CONFIG.HOVER_HEIGHT * scale

	local angle = rng:NextNumber(0, TAU)
	local dirX, dirZ = math.cos(angle), math.sin(angle)
	local x = spotX + dirX * CONFIG.ENTRY_DISTANCE * scale
	local z = spotZ + dirZ * CONFIG.ENTRY_DISTANCE * scale
	local y = hoverY + CONFIG.ENTRY_HEIGHT * scale

	local leaveAngle = angle + math.pi + rng:NextNumber(-CONFIG.LEAVE_SPREAD, CONFIG.LEAVE_SPREAD)

	local rot = CFrame.lookAt(Vector3.zero, Vector3.new(-dirX, 0, -dirZ))
	local spin = rng:NextNumber(0, TAU)
	return {
		scale = scale,
		spotX = spotX,
		spotZ = spotZ,
		hoverY = hoverY,
		leaveDirX = math.cos(leaveAngle),
		leaveDirZ = math.sin(leaveAngle),
		swaySign = if rng:NextNumber() < 0.5 then -1 else 1,
		leaveAt = params.leaveAt,
		exitTime = math.max(params.exitTime, 0.1),
		spinBoostFrom = params.spinBoostFrom,
		spinBoostTo = params.spinBoostTo,
		exitFrom = nil,
		t = 0,
		x = x,
		y = y,
		z = z,
		velX = -dirX * CONFIG.ENTRY_SPEED * scale,
		velZ = -dirZ * CONFIG.ENTRY_SPEED * scale,
		vy = 0,
		faceX = -dirX,
		faceZ = -dirZ,
		rot = rot,
		spin = spin,
		w = CONFIG.BODY_IDLE_SPIN,
		spinVel = 0,
		turn = 0,
		lastYaw = yawOf(rot),
		px = x,
		py = y,
		pz = z,
		prot = rot,
		pspin = spin,
	}
end

-- Bézier cúbica en `tau` (0..1 del tiempo de salida): el primer control está
-- DEBAJO (amago hacia abajo), el segundo abre la curva hacia un lado.
local function exitPoint(f: Flight, from: Vector3, tau: number): Vector3
	local s = f.scale
	local dir = Vector3.new(f.leaveDirX, 0, f.leaveDirZ)
	local side = Vector3.new(-f.leaveDirZ, 0, f.leaveDirX) * f.swaySign
	local p1 = from + Vector3.new(0, -CONFIG.EXIT_DIP * s, 0)
	local p2 = from
		+ dir * (CONFIG.EXIT_DISTANCE * 0.25 * s)
		+ side * (CONFIG.EXIT_SWAY * s)
		+ Vector3.new(0, CONFIG.EXIT_HEIGHT * 0.35 * s, 0)
	local p3 = from + dir * (CONFIG.EXIT_DISTANCE * s) + Vector3.new(0, CONFIG.EXIT_HEIGHT * s, 0)

	local u = tau ^ CONFIG.EXIT_EASE
	local v = 1 - u
	return from * (v * v * v) + p1 * (3 * v * v * u) + p2 * (3 * v * u * u) + p3 * (u * u * u)
end

local function step(f: Flight, dt: number)
	local scale = f.scale
	f.px, f.py, f.pz, f.prot, f.pspin = f.x, f.y, f.z, f.rot, f.spin

	local leaving = f.t >= f.leaveAt
	if leaving then
		-- Curva de salida: la velocidad sale de la propia curva para que la
		-- orientación y el giro del casco reaccionen igual que en vuelo libre.
		local from = f.exitFrom
		if not from then
			from = Vector3.new(f.x, f.y, f.z)
			f.exitFrom = from
		end
		local tau = math.clamp((f.t + dt - f.leaveAt) / f.exitTime, 0, 1)
		local pos = exitPoint(f, from :: Vector3, tau)
		f.velX, f.vy, f.velZ = (pos.X - f.x) / dt, (pos.Y - f.y) / dt, (pos.Z - f.z) / dt
		f.x, f.y, f.z = pos.X, pos.Y, pos.Z
	else
		-- Steering "arrive" (PetController)
		local dx, dz = f.spotX - f.x, f.spotZ - f.z
		local dist = math.sqrt(dx * dx + dz * dz)
		local desX, desZ = 0, 0
		if dist > 1e-3 then
			local speed = math.min(dist * CONFIG.APPROACH, CONFIG.MAX_SPEED * scale)
			desX, desZ = dx / dist * speed, dz / dist * speed
		end
		local a = 1 - math.exp(-CONFIG.ACCEL * dt)
		f.velX += (desX - f.velX) * a
		f.velZ += (desZ - f.velZ) * a

		-- Suspensión de muelle (UFOController)
		local accelY = (f.hoverY - f.y) * HOVER_STIFFNESS - f.vy * HOVER_DAMPING
		local maxVy = CONFIG.HOVER_MAX_SPEED * scale
		f.vy = math.clamp(f.vy + accelY * dt, -maxVy, maxVy)

		f.x += f.velX * dt
		f.y += f.vy * dt
		f.z += f.velZ * dt
	end

	-- Velocidades a escala 1 para que un OVNI pequeño se incline igual.
	local speed2 = f.velX * f.velX + f.velZ * f.velZ
	local minSpeed = CONFIG.FACE_MIN_SPEED * scale
	if speed2 > minSpeed * minSpeed then
		local inv = 1 / math.sqrt(speed2)
		f.faceX, f.faceZ = f.velX * inv, f.velZ * inv
	end
	local baseCF = CFrame.lookAt(Vector3.zero, Vector3.new(f.faceX, 0, f.faceZ))
	local goal: CFrame
	local velocity = Vector3.new(f.velX, f.vy, f.velZ)
	if leaving and velocity.Magnitude > minSpeed then
		-- Al irse el disco se inclina hacia su trayectoria (también hacia arriba),
		-- en vez del cabeceo por velocidad, que a estas velocidades se satura.
		local up = Vector3.new(0, 1, 0):Lerp(velocity.Unit, CONFIG.EXIT_TILT).Unit
		local right = baseCF.LookVector:Cross(up)
		goal = if right.Magnitude > 1e-3 then CFrame.fromMatrix(Vector3.zero, right.Unit, up) else baseCF
	else
		local rv, lv = baseCF.RightVector, baseCF.LookVector
		local localRight = (f.velX * rv.X + f.velZ * rv.Z) / scale
		local localFwd = (f.velX * lv.X + f.velZ * lv.Z) / scale
		local rollDeg = math.clamp(-localRight * CONFIG.ROLL_STRENGTH, -CONFIG.MAX_ROLL_DEG, CONFIG.MAX_ROLL_DEG)
		local pitchDeg = math.clamp(-localFwd * CONFIG.PITCH_STRENGTH, -CONFIG.MAX_PITCH_DEG, CONFIG.MAX_PITCH_DEG)
		goal = baseCF * CFrame.Angles(math.rad(pitchDeg), 0, math.rad(rollDeg))
	end
	f.rot = f.rot:Lerp(goal, 1 - math.exp(-CONFIG.TURN_RESPONSIVENESS * dt))

	-- Casco (BodySpinner): base por velocidad + influencia del giro de rumbo
	local yaw = yawOf(f.rot)
	local dyaw = yaw - f.lastYaw
	if dyaw > math.pi then
		dyaw -= TAU
	elseif dyaw < -math.pi then
		dyaw += TAU
	end
	f.lastYaw = yaw
	f.turn += (dyaw / dt - f.turn) * (1 - math.exp(-CONFIG.BODY_TURN_SMOOTH * dt))

	local observed = math.sqrt(speed2 + f.vy * f.vy) / scale
	local baseMag = CONFIG.BODY_IDLE_SPIN + math.min(observed / CONFIG.BODY_REF_SPEED, 1.4) * CONFIG.BODY_SPEED_SPIN
	if f.t >= f.spinBoostFrom and f.t < f.spinBoostTo then
		baseMag += CONFIG.ABDUCT_SPIN_BOOST
	end
	local targetW = math.clamp(baseMag + f.turn * CONFIG.BODY_TURN_INFLUENCE, CONFIG.BODY_MIN_SPIN, CONFIG.BODY_MAX_SPIN)
	f.w, f.spinVel = smoothDamp(f.w, targetW, f.spinVel, CONFIG.BODY_SPIN_SMOOTHTIME, dt)
	f.spin += f.w * dt

	f.t += dt
end

-- Ponerse al día a paso fijo. Tras la llamada: f.t - STEP <= elapsed < f.t.
function AbductionFlight.advance(f: Flight, elapsed: number)
	while f.t <= elapsed do
		step(f, STEP)
	end
end

-- CFrame del OVNI y giro del casco en `elapsed`, interpolando entre el paso
-- anterior y el actual. Llamar después de `advance`.
function AbductionFlight.sample(f: Flight, elapsed: number): (CFrame, number)
	local alpha = math.clamp((elapsed - f.t) / STEP + 1, 0, 1)
	local pos = Vector3.new(f.px + (f.x - f.px) * alpha, f.py + (f.y - f.py) * alpha, f.pz + (f.z - f.pz) * alpha)
	return CFrame.new(pos) * f.prot:Lerp(f.rot, alpha), f.pspin + (f.spin - f.pspin) * alpha
end

-- Punto de la panza del OVNI procedural (del que sale el rayo) para un CFrame del OVNI.
function AbductionFlight.bellyOf(f: Flight, ufoCF: CFrame): Vector3
	return ufoCF * Vector3.new(0, -CONFIG.BELLY_DEPTH * f.scale, 0)
end

local function characterModelOf(part: BasePart): Model?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- Suelo bajo el cuerpo (mismo criterio que Tombstone): ignora agua, partes sin
-- colisión y cualquier personaje o cadáver.
function AbductionFlight.findGroundY(origin: Vector3, char: Model, extraExclude: { Instance }?): number?
	local exclude: { Instance } = { char }
	if extraExclude then
		table.move(extraExclude, 1, #extraExclude, #exclude + 1, exclude)
	end
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true

	local direction = Vector3.new(0, -CONFIG.RAY_LENGTH, 0)
	for _ = 1, CONFIG.RAY_MAX_SKIPS do
		params.FilterDescendantsInstances = exclude
		local result = workspace:Raycast(origin, direction, params)
		if not result then
			return nil
		end
		local hit = result.Instance
		local characterModel = if hit:IsA("BasePart") then characterModelOf(hit) else nil
		if characterModel then
			table.insert(exclude, characterModel)
		else
			return result.Position.Y
		end
	end
	return nil
end

return AbductionFlight
