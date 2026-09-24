--!strict
--[[
	Kill effect XpOrbs, parte de cliente: el servidor oculta el cuerpo y deja en el
	cadáver los atributos de XpOrbs.ATTR; aquí salen los orbes y se recogen. Los orbes
	no se atan al contexto: sobreviven al cadáver (el jugador respawnea antes).

	Vida de cada orbe:
	  muerte + i·STAGGER  nace en el torso con un pop (Back Out) y sale disparado en
	                      abanico (semilla del servidor: todos ven el mismo abanico)
	  al tocar suelo      bota, cada bote más bajo, con squash & stretch, y frena
	  en reposo           flota subiendo y bajando, cada uno a su ritmo
	  alguien vivo cerca  (pasado PICKUP_DELAY) vuela hacia su torso, más rápido
	                      cuanto más cerca
	  al llegar           se encoge dentro y suena el "tin" con tono aleatorio. Como en
	                      Minecraft, cada personaje recoge de uno en uno (COLLECT_GAP):
	                      un montón de orbes suena en cascada
	  fin de LIFETIME     parpadea cada vez más rápido y se encoge hasta desaparecer

	En el preview (Locker y pase) no hay nadie vivo cerca que los recoja, así que
	pasado PREVIEW_COLLECT_AT vuelan hacia la CÁMARA y se recogen igual: es lo que
	enseña el efecto entero, sonido incluido.

	Recogen los personajes VIVOS de jugadores y bots (ActiveMap/.../Bots) que ve este
	cliente, cada cliente por su cuenta. No hay nada en red y no da XP.

	Eficiencia:
	  · Un único RenderStepped y sólo mientras haya orbes; se desconecta solo.
	  · Cada orbe es un Attachment de un contenedor anclado en el origen con el
	    BillboardGui de la plantilla, de un pool con tope: moverlo es escribir una
	    posición, sin partes ni física. El tamaño del gui sólo se escribe si cambia.
	  · Suelo con un raycast por orbe al nacer (donde aterriza) y al soltarlo quien lo
	    atraía, nunca por frame.
	  · La lista de quién puede recoger se relee cada COLLECTOR_REFRESH.
	  · Más allá de CULL_DISTANCE no se monta nada.
	  · Sin SoundService.Audio.Gameplay.XpOrb montado es mudo (avisa una vez).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local killEffects = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects")
local XpOrbs = require(killEffects:WaitForChild("XpOrbs"))
local AbductionFlight = require(killEffects:WaitForChild("AbductionFlight"))
local GameSounds = require(script.Parent.Parent.Parent.ui.GameSounds)
local Types = require(script.Parent.Parent.KillEffectTypes)

local ATTR = XpOrbs.ATTR

local CONFIG = {
	CULL_DISTANCE = 300, -- studs desde la cámara
	MAX_ORBS = 90,

	-- Cuántos y de qué tamaño
	COUNT = { 7, 11 },
	SIZES = { { 0.8, 45 }, { 1, 40 }, { 1.35, 15 } }, -- { multiplicador del gui, peso }
	FALLBACK_SIZE = 1.1, -- studs de ancho del orbe sin plantilla

	-- Salida (studs y s a escala 1)
	SPAWN_UP = 0.5, -- sobre el centro del torso
	STAGGER = 0.035, -- s entre orbe y orbe
	POP_TIME = 0.28,
	SPEED_XZ = { 5, 13 },
	SPEED_Y = { 16, 26 },
	FAN_JITTER = 0.35, -- rad de desvío sobre el reparto en ángulo áureo
	GRAVITY = 70,
	LATE_SETTLE = 1.6, -- s de vida a partir de los que quien llega tarde lo ve ya en el suelo

	-- Botes
	HOVER = 0.55, -- studs sobre el suelo en reposo
	BOUNCE = 0.42, -- velocidad vertical que conserva cada bote
	BOUNCE_FRICTION = 0.55, -- velocidad horizontal que conserva cada bote
	REST_SPEED = 3.5, -- studs/s de rebote por debajo de los cuales se queda
	SLIDE_DRAG = 5, -- 1/s
	SQUASH_AMOUNT = 0.3,
	SQUASH_TIME = 0.22,
	SQUASH_FREQ = 30, -- rad/s

	-- Reposo
	BOB_AMPLITUDE = 0.35,
	BOB_FREQ = { 2.6, 3.6 }, -- rad/s

	-- Recogida
	PICKUP_DELAY = 0.7, -- s de vida antes de poder recogerse: que se vea el abanico
	ATTRACT_RADIUS = 18,
	LOSE_RADIUS = 24, -- si quien lo atrae se aleja más, cae
	PICKUP_RADIUS = 1.8,
	ATTRACT_MIN_SPEED = 6,
	ATTRACT_MAX_SPEED = 55,
	ATTRACT_STEER = 9, -- 1/s
	COLLECT_GAP = 0.07, -- s entre dos orbes recogidos por el mismo personaje
	COLLECT_TIME = 0.12,
	COLLECTOR_REFRESH = 0.25,
	BOTS_SEARCH_GAP = 2,
	-- Preview: hacia la cámara, y con más margen de recogida (1.8 studs dejaría el
	-- orbe pegado a la lente antes de que se lo trague).
	PREVIEW_COLLECT_AT = 1.1, -- s de vida antes de salir hacia la cámara
	PREVIEW_PICKUP_RADIUS = 5,
	-- La cámara suele estar más lejos que ATTRACT_RADIUS, así que ahí la velocidad no
	-- sale de la cercanía (se quedaría en la mínima): acelera con el tiempo.
	PREVIEW_ACCEL_TIME = 0.5, -- s de ATTRACT_MIN_SPEED a ATTRACT_MAX_SPEED

	-- Fin
	BLINK_TIME = 2.5,
	BLINK_SHARE = 0.2, -- en vidas cortas (preview) parpadea como mucho esta fracción
	BLINK_FREQ = { 4, 14 }, -- Hz al empezar y al acabar
	DESPAWN_TIME = 0.18,

	-- Sonido: el tono de Minecraft, (rand - rand) · 0.35 + 0.9
	SOUND_POOL = 6,
	SOUND_BUSY = 0.35,
	PITCH_BASE = 0.9,
	PITCH_SPREAD = 0.35,
}

local GOLDEN_ANGLE = math.pi * (3 - math.sqrt(5))

local PHASE = table.freeze({
	WAITING = "waiting",
	FLYING = "flying",
	RESTING = "resting",
	ATTRACTED = "attracted",
	COLLECTING = "collecting",
	DESPAWNING = "despawning",
})

type Slot = {
	attachment: Attachment,
	gui: BillboardGui,
	tint: GuiObject?,
	baseSize: UDim2,
}

type Orb = {
	slot: Slot,
	source: Model,
	phase: string,
	bornAt: number,
	expiresAt: number,
	blinkTime: number,
	canPickup: boolean, -- alguien vivo puede recogerlo (partida)
	toCamera: boolean, -- se lo lleva la cámara (preview)
	scale: number,
	sizeMul: number,
	position: Vector3,
	velocity: Vector3,
	groundY: number,
	restAge: number,
	bobFreq: number,
	squashAge: number,
	squashPower: number,
	phaseAge: number,
	blinkClock: number,
	collectFrom: Vector3,
	target: BasePart?,
	shownX: number,
	shownY: number,
	visible: boolean,
}

type SoundSlot = {
	attachment: Attachment,
	sound: Sound?,
	busyUntil: number,
}

local XpOrbsVisuals = {}

local _stepConn: RBXScriptConnection? = nil
local _holder: Part? = nil

local _orbs: { Orb } = {}
local _freeSlots: { Slot } = {}
local _slotCount = 0
local _soundSlots: { SoundSlot } = {}

local _collectors: { BasePart } = {}
local _collectorSet: { [BasePart]: boolean } = {}
local _nextCollectAt: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any
local _collectorsAt = -math.huge
local _botsFolder: Instance? = nil
local _cameraPart: Part? = nil
local _botsSearchAt = -math.huge
local _warnedTemplate = false

local _rng = Random.new()

local function ease(alpha: number, style: Enum.EasingStyle, direction: Enum.EasingDirection): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style, direction)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function swapRemove<T>(list: { T }, i: number)
	local last = #list
	list[i] = list[last]
	list[last] = nil
end

local function resetPools()
	table.clear(_orbs)
	table.clear(_freeSlots)
	table.clear(_soundSlots)
	_slotCount = 0
	_cameraPart = nil
end

local function getHolder(): Part
	local holder = _holder
	if holder and holder.Parent then
		return holder
	end
	-- Lo que hubiera en los pools murió con el contenedor anterior.
	resetPools()

	-- En el origen y sin girar: la Position de sus attachments ES la posición en el mundo.
	local part = Instance.new("Part")
	part.Name = "XpOrbsVFX"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.identity
	part.Parent = workspace
	_holder = part
	return part
end

local function buildFallbackGui(): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "BillboardGui"
	gui.Size = UDim2.fromScale(CONFIG.FALLBACK_SIZE, CONFIG.FALLBACK_SIZE)
	gui.LightInfluence = 0

	local dot = Instance.new("Frame")
	dot.Name = "Image"
	dot.Size = UDim2.fromScale(1, 1)
	dot.BorderSizePixel = 0
	dot.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = dot

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(90, 120, 20)
	stroke.Thickness = 2
	stroke.Parent = dot
	return gui
end

-- Lo que se tiñe: Xp.BillboardGui.Image, o la primera imagen del gui.
local function findTint(gui: BillboardGui): GuiObject?
	local named = gui:FindFirstChild("Image", true)
	if named and named:IsA("GuiObject") then
		return named
	end
	return gui:FindFirstChildWhichIsA("ImageLabel", true) :: GuiObject?
end

local function acquireSlot(): Slot?
	local free = table.remove(_freeSlots)
	if free then
		return free
	end
	if _slotCount >= CONFIG.MAX_ORBS then
		return nil
	end

	local gui: BillboardGui
	local template = XpOrbs.findTemplate()
	if template then
		gui = template:Clone()
		for _, d in gui:GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			end
		end
	else
		if not _warnedTemplate then
			_warnedTemplate = true
			warn("[XpOrbsVisuals] falta ReplicatedStorage.Xp (con Xp.BillboardGui.Image): se pintan círculos")
		end
		gui = buildFallbackGui()
	end

	_slotCount += 1
	local attachment = Instance.new("Attachment")
	attachment.Name = "XpOrb"
	attachment.Parent = getHolder()

	gui.Adornee = nil
	gui.Enabled = false
	gui.Parent = attachment
	return { attachment = attachment, gui = gui, tint = findTint(gui), baseSize = gui.Size }
end

local function releaseSlot(slot: Slot)
	slot.gui.Enabled = false
	table.insert(_freeSlots, slot)
end

local function setTint(slot: Slot, color: Color3)
	local tint = slot.tint
	if not tint then
		return
	end
	if tint:IsA("ImageLabel") or tint:IsA("ImageButton") then
		(tint :: any).ImageColor3 = color
	else
		tint.BackgroundColor3 = color
	end
end

local function addCollector(model: Instance?)
	if not model or not model:IsA("Model") then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	for _, name in { "UpperTorso", "Torso", "HumanoidRootPart" } do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			table.insert(_collectors, part)
			_collectorSet[part] = true
			return
		end
	end
end

local function refreshCollectors()
	table.clear(_collectors)
	table.clear(_collectorSet)
	for _, player in Players:GetPlayers() do
		addCollector(player.Character)
	end

	-- Los bots viven en <mapa>/Bots dentro de ActiveMap; se busca la carpeta sólo si
	-- no la tenemos y como mucho cada BOTS_SEARCH_GAP (FindFirstChild recursivo).
	local now = os.clock()
	if (not _botsFolder or not _botsFolder:IsDescendantOf(workspace)) and now >= _botsSearchAt then
		_botsSearchAt = now + CONFIG.BOTS_SEARCH_GAP
		local activeMap = workspace:FindFirstChild("ActiveMap")
		_botsFolder = if activeMap then activeMap:FindFirstChild("Bots", true) else nil
	end
	local bots = _botsFolder
	if bots and bots.Parent then
		for _, bot in bots:GetChildren() do
			addCollector(bot)
		end
	end
end

-- El "recolector" del preview: una parte invisible pegada a la cámara. Así la
-- atracción, el cooldown y la cascada son exactamente los mismos que en partida.
local function ensureCameraPart(): Part
	local existing = _cameraPart
	if existing and existing.Parent then
		return existing
	end
	local part = Instance.new("Part")
	part.Name = "XpOrbCameraCollector"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	local camera = workspace.CurrentCamera
	part.Position = if camera then camera.CFrame.Position else Vector3.zero
	part.Parent = getHolder()
	_cameraPart = part
	return part
end

local function nearestCollector(position: Vector3): BasePart?
	local best: BasePart? = nil
	local bestDistSq = CONFIG.ATTRACT_RADIUS * CONFIG.ATTRACT_RADIUS
	for _, part in _collectors do
		local offset = part.Position - position
		local distSq = offset:Dot(offset)
		if distSq < bestDistSq then
			best = part
			bestDistSq = distSq
		end
	end
	return best
end

local function playPickup(position: Vector3)
	local template = GameSounds.resolve(GameSounds.XpOrb)
	if not template or template.SoundId == "" then
		return
	end

	local now = os.clock()
	local slot: SoundSlot? = nil
	for _, candidate in _soundSlots do
		if candidate.busyUntil <= now then
			slot = candidate
			break
		end
	end
	if not slot then
		if #_soundSlots >= CONFIG.SOUND_POOL then
			return
		end
		local attachment = Instance.new("Attachment")
		attachment.Name = "XpOrbSound"
		attachment.Parent = getHolder()
		slot = { attachment = attachment, sound = nil, busyUntil = 0 }
		table.insert(_soundSlots, slot :: SoundSlot)
	end
	local s = slot :: SoundSlot

	local sound = s.sound
	if not sound then
		sound = template:Clone()
		;(sound :: Sound).Parent = s.attachment
		s.sound = sound
	end
	s.busyUntil = now + CONFIG.SOUND_BUSY
	s.attachment.Position = position
	local playing = sound :: Sound
	playing.PlaybackSpeed = CONFIG.PITCH_BASE + (_rng:NextNumber() - _rng:NextNumber()) * CONFIG.PITCH_SPREAD
	playing.TimePosition = 0
	playing:Play()
end

local function setVisible(orb: Orb, visible: boolean)
	if orb.visible ~= visible then
		orb.visible = visible
		orb.slot.gui.Enabled = visible
	end
end

local function writeSize(orb: Orb, scaleX: number, scaleY: number)
	local x = math.max(scaleX, 0) * orb.sizeMul
	local y = math.max(scaleY, 0) * orb.sizeMul
	if math.abs(x - orb.shownX) < 0.004 and math.abs(y - orb.shownY) < 0.004 then
		return
	end
	orb.shownX = x
	orb.shownY = y
	local base = orb.slot.baseSize
	orb.slot.gui.Size = UDim2.new(base.X.Scale * x, base.X.Offset * x, base.Y.Scale * y, base.Y.Offset * y)
end

-- Quien lo atraía se ha ido: vuelve a caer, sobre el suelo que tenga debajo ahora.
local function drop(orb: Orb)
	orb.phase = PHASE.FLYING
	orb.target = nil
	orb.groundY = AbductionFlight.findGroundY(orb.position, orb.source) or orb.groundY
end

local function stepFlying(orb: Orb, dt: number)
	local scale = orb.scale
	local velocity = orb.velocity - Vector3.new(0, CONFIG.GRAVITY * scale * dt, 0)
	local position = orb.position + velocity * dt
	local floor = orb.groundY + CONFIG.HOVER * scale
	if position.Y <= floor and velocity.Y < 0 then
		local impact = -velocity.Y
		local rebound = impact * CONFIG.BOUNCE
		position = Vector3.new(position.X, floor, position.Z)
		orb.squashAge = 0
		orb.squashPower = math.clamp(impact / (CONFIG.SPEED_Y[2] * scale), 0.25, 1)
		if rebound < CONFIG.REST_SPEED * scale then
			velocity = Vector3.new(velocity.X * CONFIG.BOUNCE_FRICTION, 0, velocity.Z * CONFIG.BOUNCE_FRICTION)
			orb.phase = PHASE.RESTING
			orb.restAge = 0
		else
			velocity =
				Vector3.new(velocity.X * CONFIG.BOUNCE_FRICTION, rebound, velocity.Z * CONFIG.BOUNCE_FRICTION)
		end
	end
	orb.velocity = velocity
	orb.position = position
end

local function stepResting(orb: Orb, dt: number)
	orb.restAge += dt
	local keep = math.exp(-CONFIG.SLIDE_DRAG * dt)
	local velocity = Vector3.new(orb.velocity.X * keep, 0, orb.velocity.Z * keep)
	-- (1 - cos)/2: empieza en 0 sin salto y nunca baja del suelo.
	local bob = CONFIG.BOB_AMPLITUDE * orb.scale * 0.5 * (1 - math.cos(orb.restAge * orb.bobFreq))
	local slid = orb.position + velocity * dt
	orb.position = Vector3.new(slid.X, orb.groundY + CONFIG.HOVER * orb.scale + bob, slid.Z)
	orb.velocity = velocity
end

local function stepAttracted(orb: Orb, dt: number, now: number)
	orb.phaseAge += dt
	local target = orb.target
	if not target or not target.Parent then
		drop(orb)
		return
	end
	if not orb.toCamera and not _collectorSet[target] then
		drop(orb)
		return
	end
	local offset = target.Position - orb.position
	local dist = offset.Magnitude
	-- La cámara no lo suelta nunca: en el preview es el único destino que hay.
	if not orb.toCamera and dist > CONFIG.LOSE_RADIUS then
		drop(orb)
		return
	end
	local pickupRadius = if orb.toCamera then CONFIG.PREVIEW_PICKUP_RADIUS else CONFIG.PICKUP_RADIUS
	if dist <= pickupRadius and now >= (_nextCollectAt[target] or 0) then
		_nextCollectAt[target] = now + CONFIG.COLLECT_GAP
		orb.phase = PHASE.COLLECTING
		orb.phaseAge = 0
		orb.collectFrom = orb.position
		setVisible(orb, true)
		playPickup(orb.position)
		return
	end
	local speed: number
	if orb.toCamera then
		local u = ease(orb.phaseAge / CONFIG.PREVIEW_ACCEL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		speed = lerp(CONFIG.ATTRACT_MIN_SPEED, CONFIG.ATTRACT_MAX_SPEED, u)
	else
		local closeness = 1 - math.clamp(dist / CONFIG.ATTRACT_RADIUS, 0, 1)
		speed = lerp(CONFIG.ATTRACT_MIN_SPEED, CONFIG.ATTRACT_MAX_SPEED, closeness * closeness)
	end
	local desired = if dist > 1e-3 then offset.Unit * speed else Vector3.zero
	orb.velocity = orb.velocity:Lerp(desired, 1 - math.exp(-CONFIG.ATTRACT_STEER * dt))
	orb.position += orb.velocity * dt
end

-- Devuelve true cuando el orbe ha terminado y su hueco vuelve al pool.
local function stepOrb(orb: Orb, dt: number, now: number): boolean
	if orb.phase == PHASE.WAITING then
		if now < orb.bornAt then
			return false
		end
		orb.phase = PHASE.FLYING
		setVisible(orb, true)
	end

	if orb.phase ~= PHASE.COLLECTING and orb.phase ~= PHASE.DESPAWNING and now >= orb.expiresAt then
		orb.phase = PHASE.DESPAWNING
		orb.phaseAge = 0
		orb.target = nil
		setVisible(orb, true)
	end

	local phase = orb.phase
	if phase == PHASE.FLYING then
		stepFlying(orb, dt)
	elseif phase == PHASE.RESTING then
		stepResting(orb, dt)
	elseif phase == PHASE.ATTRACTED then
		stepAttracted(orb, dt, now)
	else
		orb.phaseAge += dt
	end
	phase = orb.phase

	if phase == PHASE.FLYING or phase == PHASE.RESTING then
		if orb.toCamera then
			if now - orb.bornAt >= CONFIG.PREVIEW_COLLECT_AT then
				orb.phase = PHASE.ATTRACTED
				orb.target = ensureCameraPart()
				orb.phaseAge = 0
				phase = PHASE.ATTRACTED
			end
		elseif orb.canPickup and now - orb.bornAt >= CONFIG.PICKUP_DELAY then
			local target = nearestCollector(orb.position)
			if target then
				orb.phase = PHASE.ATTRACTED
				orb.target = target
				orb.phaseAge = 0
				phase = PHASE.ATTRACTED
			end
		end
	end

	local scaleX, scaleY = 1, 1
	local popAge = now - orb.bornAt
	if popAge < CONFIG.POP_TIME then
		local pop = ease(popAge / CONFIG.POP_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		scaleX, scaleY = pop, pop
	end

	if orb.squashAge < CONFIG.SQUASH_TIME then
		orb.squashAge += dt
		local fade = 1 - math.clamp(orb.squashAge / CONFIG.SQUASH_TIME, 0, 1)
		-- cos(0) = 1: al tocar suelo se aplasta ancho y bajo, y luego rebota.
		local wobble = CONFIG.SQUASH_AMOUNT * orb.squashPower * fade * fade * math.cos(orb.squashAge * CONFIG.SQUASH_FREQ)
		scaleX *= 1 + wobble
		scaleY *= 1 - wobble
	end

	if phase == PHASE.COLLECTING then
		local alpha = orb.phaseAge / CONFIG.COLLECT_TIME
		local target = orb.target
		local goal = if target and target.Parent then target.Position else orb.collectFrom
		orb.position = orb.collectFrom:Lerp(goal, ease(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In))
		local shrink = 1 - ease(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		scaleX *= shrink
		scaleY *= shrink
		if alpha >= 1 then
			return true
		end
	elseif phase == PHASE.DESPAWNING then
		local alpha = orb.phaseAge / CONFIG.DESPAWN_TIME
		local shrink = 1 - ease(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		scaleX *= shrink
		scaleY *= shrink
		if alpha >= 1 then
			return true
		end
	else
		local left = orb.expiresAt - now
		if left < orb.blinkTime then
			local u = 1 - left / orb.blinkTime
			orb.blinkClock += dt * lerp(CONFIG.BLINK_FREQ[1], CONFIG.BLINK_FREQ[2], u)
			setVisible(orb, orb.blinkClock % 1 < 0.6)
		end
	end

	orb.slot.attachment.Position = orb.position
	writeSize(orb, scaleX, scaleY)
	return false
end

local function step(dt: number)
	local clock = os.clock()
	if clock - _collectorsAt >= CONFIG.COLLECTOR_REFRESH then
		_collectorsAt = clock
		refreshCollectors()
	end

	local cameraPart = _cameraPart
	if cameraPart and cameraPart.Parent then
		local camera = workspace.CurrentCamera
		if camera then
			cameraPart.Position = camera.CFrame.Position
		end
	end

	local now = workspace:GetServerTimeNow()
	for i = #_orbs, 1, -1 do
		local orb = _orbs[i]
		-- Un sonido puede recrear el contenedor (y vaciar la lista) a mitad de vuelta.
		if not orb then
			continue
		end
		if not orb.slot.attachment.Parent then
			swapRemove(_orbs, i)
		elseif stepOrb(orb, dt, now) then
			releaseSlot(orb.slot)
			swapRemove(_orbs, i)
		end
	end
	if #_orbs == 0 and _stepConn then
		_stepConn:Disconnect()
		_stepConn = nil
	end
end

local function ensureStep()
	if not _stepConn then
		_collectorsAt = -math.huge
		_stepConn = RunService.RenderStepped:Connect(step)
	end
end

local function rollSize(rng: Random): number
	local total = 0
	for _, entry in CONFIG.SIZES do
		total += entry[2]
	end
	local roll = rng:NextNumber(0, total)
	for _, entry in CONFIG.SIZES do
		roll -= entry[2]
		if roll <= 0 then
			return entry[1]
		end
	end
	return CONFIG.SIZES[1][1]
end

function XpOrbsVisuals.play(char: Model, ctx: Types.Ctx)
	local startedAt = ctx.startedAt
	local origin = char:GetAttribute(ATTR.ORIGIN)
	local scaleAttr = char:GetAttribute(ATTR.SCALE)
	local seed = char:GetAttribute(ATTR.SEED)
	local lifetimeAttr = char:GetAttribute(ATTR.LIFETIME)
	if typeof(origin) ~= "Vector3" or type(seed) ~= "number" then
		return
	end
	local scale = if type(scaleAttr) == "number" then scaleAttr else 1
	local lifetime = if type(lifetimeAttr) == "number" then lifetimeAttr else XpOrbs.MATCH_LIFETIME
	local canPickup = char:GetAttribute(ATTR.PICKUP) ~= false

	local now = workspace:GetServerTimeNow()
	if now - startedAt >= lifetime then
		return
	end
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - origin).Magnitude > CONFIG.CULL_DISTANCE then
		return
	end

	-- Todo lo que decide la forma del abanico sale de la semilla, en el mismo orden
	-- para todos los clientes.
	local rng = Random.new(seed)
	local count = rng:NextInteger(CONFIG.COUNT[1], CONFIG.COUNT[2])
	local fanOffset = rng:NextNumber(0, 2 * math.pi)
	local spawnAt = origin + Vector3.new(0, CONFIG.SPAWN_UP * scale, 0)
	local hover = CONFIG.HOVER * scale
	local gravity = CONFIG.GRAVITY * scale
	local killGroundY = AbductionFlight.findGroundY(origin, char) or (origin.Y - 3 * scale)
	local blinkTime = math.min(CONFIG.BLINK_TIME, lifetime * CONFIG.BLINK_SHARE)

	for i = 1, count do
		local angle = fanOffset + i * GOLDEN_ANGLE + rng:NextNumber(-CONFIG.FAN_JITTER, CONFIG.FAN_JITTER)
		local speedXZ = rng:NextNumber(CONFIG.SPEED_XZ[1], CONFIG.SPEED_XZ[2]) * scale
		local speedY = rng:NextNumber(CONFIG.SPEED_Y[1], CONFIG.SPEED_Y[2]) * scale
		local sizeMul = rollSize(rng) * scale
		local color = XpOrbs.COLORS[rng:NextInteger(1, #XpOrbs.COLORS)]
		local bobFreq = rng:NextNumber(CONFIG.BOB_FREQ[1], CONFIG.BOB_FREQ[2])

		local slot = acquireSlot()
		if not slot then
			break
		end
		setTint(slot, color)

		local bornAt = startedAt + (i - 1) * CONFIG.STAGGER
		local velocity = Vector3.new(math.cos(angle) * speedXZ, speedY, math.sin(angle) * speedXZ)

		-- Dónde toca suelo por primera vez (contra el suelo bajo el cuerpo) y, ahí, el
		-- suelo real: un solo raycast por orbe.
		local fallHeight = math.max(spawnAt.Y - (killGroundY + hover), 0)
		local hitTime = (speedY + math.sqrt(speedY * speedY + 2 * gravity * fallHeight)) / gravity
		local hitX = spawnAt.X + velocity.X * hitTime
		local hitZ = spawnAt.Z + velocity.Z * hitTime
		local groundY = AbductionFlight.findGroundY(Vector3.new(hitX, spawnAt.Y + 2 * scale, hitZ), char)
			or killGroundY

		local orb: Orb = {
			slot = slot,
			source = char,
			phase = PHASE.WAITING,
			bornAt = bornAt,
			expiresAt = bornAt + lifetime,
			blinkTime = blinkTime,
			canPickup = canPickup,
			toCamera = not canPickup,
			scale = scale,
			sizeMul = sizeMul,
			position = spawnAt,
			velocity = velocity,
			groundY = groundY,
			restAge = 0,
			bobFreq = bobFreq,
			squashAge = math.huge,
			squashPower = 0,
			phaseAge = 0,
			blinkClock = 0,
			collectFrom = spawnAt,
			target = nil,
			shownX = -1,
			shownY = -1,
			visible = false,
		}

		-- Llega tarde (streaming, join a mitad): ya en el suelo donde aterrizó.
		if now - bornAt >= CONFIG.LATE_SETTLE then
			orb.phase = PHASE.RESTING
			orb.position = Vector3.new(hitX, groundY + hover, hitZ)
			orb.velocity = Vector3.zero
			setVisible(orb, true)
		end

		slot.attachment.Position = orb.position
		writeSize(orb, 0, 0)
		table.insert(_orbs, orb)
	end
	ensureStep()
end

function XpOrbsVisuals.stop()
	if _stepConn then
		_stepConn:Disconnect()
		_stepConn = nil
	end
	resetPools()
	table.clear(_collectors)
	table.clear(_collectorSet)
	_botsFolder = nil
	_cameraPart = nil
	if _holder then
		_holder:Destroy()
		_holder = nil
	end
end

return XpOrbsVisuals
