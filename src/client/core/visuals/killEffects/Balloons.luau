--!strict
--[[
	Kill effect Balloons, parte de cliente. El servidor sólo simula la física y marca
	cada GLOBO (no el cadáver) con `Balloons.TAG` y sus atributos (ATTR); aquí se infla
	y se revienta. Por eso no usa `play`: KillEffectVisuals solo llama a start/stop y
	este módulo escucha su propio tag.

	Flashes y trozos son partes ANCLADAS de un pool con tope movidas analíticamente;
	al agotarse el pool se omiten, nunca se crean de más.
	Sin SoundService.Audio.Gameplay.BalloonPop montado es mudo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Balloons = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects"):WaitForChild("Balloons")
)
local GameSounds = require(script.Parent.Parent.Parent.ui.GameSounds)

local ATTR = Balloons.ATTR

local CONFIG = {
	-- El inflado dura Balloons.INFLATE_TIME
	INFLATE_FROM = 0.15, -- escala inicial
	WOBBLE_TIME = 0.35, -- s de rebote tras inflarse
	WOBBLE_AMOUNT = 0.14, -- estiramiento máx (0.14 = ±14 %)
	WOBBLE_FREQ = 28, -- rad/s
	WOBBLE_DECAY = 9,

	FLASH_TIME = 0.12,
	FLASH_START_TRANSPARENCY = 0.2,
	FLASH_GROWTH = 1.8, -- tamaño final respecto al globo
	FLASH_GROWTH_FINALE = 2.4,

	SHREDS = 5, -- por globo
	SHREDS_FINALE = 9,
	GOLDEN_MULT = 2,
	SHRED_SIZE = Vector3.new(0.5, 0.06, 0.35),
	SHRED_SPEED = { 8, 18 }, -- studs/s
	SHRED_SPIN = 20, -- rad/s máx por eje
	SHRED_LIFE = 0.6,

	MAX_FLASHES = 12,
	MAX_SHREDS = 60,
	CULL_DISTANCE = 300, -- studs desde la cámara
	MOBILE_SCALE = 0.5,

	-- PITCH_STEPS: escala mayor (do re mi sol la), uno por estallido de la cadena.
	SOUND_POOL = 6,
	SOUND_BUSY = 0.6, -- s que un hueco de sonido queda reservado
	PITCH_STEPS = { 1, 1.122, 1.26, 1.498, 1.682 },
	PITCH_FINALE = 2,
	PITCH_JITTER = 0.03,
}

type Inflating = {
	mesh: SpecialMesh,
	halfHeight: number,
	spawnedAt: number,
}

type Flash = {
	part: Part,
	age: number,
	fromSize: number,
	toSize: number,
}

type Shred = {
	part: Part,
	age: number,
	origin: Vector3,
	velocity: Vector3,
	rotation: CFrame,
	spinAxis: Vector3,
	spinRate: number,
	gravity: number,
}

type SoundSlot = {
	attachment: Attachment,
	sound: Sound?,
	busyUntil: number,
}

local BalloonPopVisuals = {}

local _addedConn: RBXScriptConnection? = nil
local _removedConn: RBXScriptConnection? = nil
local _stepConn: RBXScriptConnection? = nil
local _poppedConns: { [Instance]: RBXScriptConnection } = {}
local _holder: Part? = nil

local _inflating: { Inflating } = {}
local _flashes: { Flash } = {}
local _shreds: { Shred } = {}
local _freeFlashParts: { Part } = {}
local _freeShredParts: { Part } = {}
local _flashPartCount = 0
local _shredPartCount = 0
local _soundSlots: { SoundSlot } = {}

local _shredScale = if UserInputService.TouchEnabled then CONFIG.MOBILE_SCALE else 1
local _rng = Random.new()

local function ease(alpha: number, style: Enum.EasingStyle, direction: Enum.EasingDirection): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style, direction)
end

local function swapRemove<T>(list: { T }, i: number)
	local last = #list
	list[i] = list[last]
	list[last] = nil
end

local function resetPools()
	table.clear(_inflating)
	table.clear(_flashes)
	table.clear(_shreds)
	table.clear(_freeFlashParts)
	table.clear(_freeShredParts)
	table.clear(_soundSlots)
	_flashPartCount = 0
	_shredPartCount = 0
end

local function getHolder(): Part
	local holder = _holder
	if holder and holder.Parent then
		return holder
	end
	-- Lo que hubiera en los pools murió con el contenedor anterior.
	local inflating = table.clone(_inflating)
	resetPools()
	for _, entry in inflating do
		table.insert(_inflating, entry)
	end

	local part = Instance.new("Part")
	part.Name = "BalloonPopVFX"
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

local function newVfxPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Transparency = 1
	part.Parent = getHolder()
	return part
end

local function acquireFlashPart(): Part?
	local part = table.remove(_freeFlashParts)
	if part then
		return part
	end
	if _flashPartCount >= CONFIG.MAX_FLASHES then
		return nil
	end
	_flashPartCount += 1
	local flash = newVfxPart("PopFlash")
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	return flash
end

local function acquireShredPart(): Part?
	local part = table.remove(_freeShredParts)
	if part then
		return part
	end
	if _shredPartCount >= CONFIG.MAX_SHREDS then
		return nil
	end
	_shredPartCount += 1
	local shred = newVfxPart("Shred")
	shred.Size = CONFIG.SHRED_SIZE
	shred.Material = Enum.Material.SmoothPlastic
	return shred
end

-- Escala del globo con el nudo fijo: el mesh crece desde abajo, no desde el centro.
local function setScale(entry: Inflating, scaleXZ: number, scaleY: number)
	entry.mesh.Scale = Vector3.new(scaleXZ, scaleY, scaleXZ)
	entry.mesh.Offset = Vector3.new(0, -entry.halfHeight * (1 - scaleY), 0)
end

local function stepInflating()
	local now = workspace:GetServerTimeNow()
	for i = #_inflating, 1, -1 do
		local entry = _inflating[i]
		local age = now - entry.spawnedAt
		if entry.mesh.Parent == nil or age >= Balloons.INFLATE_TIME + CONFIG.WOBBLE_TIME then
			setScale(entry, 1, 1)
			swapRemove(_inflating, i)
		elseif age < Balloons.INFLATE_TIME then
			local grow = CONFIG.INFLATE_FROM
				+ (1 - CONFIG.INFLATE_FROM) * ease(age / Balloons.INFLATE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			setScale(entry, grow, grow)
		else
			local u = age - Balloons.INFLATE_TIME
			local wobble = CONFIG.WOBBLE_AMOUNT * math.exp(-CONFIG.WOBBLE_DECAY * u) * math.sin(CONFIG.WOBBLE_FREQ * u)
			setScale(entry, 1 - wobble * 0.5, 1 + wobble)
		end
	end
end

local function stepFlashes(dt: number)
	for i = #_flashes, 1, -1 do
		local flash = _flashes[i]
		flash.age += dt
		local part = flash.part
		if flash.age >= CONFIG.FLASH_TIME then
			part.Transparency = 1
			table.insert(_freeFlashParts, part)
			swapRemove(_flashes, i)
		else
			local a = ease(flash.age / CONFIG.FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			part.Size = Vector3.one * (flash.fromSize + (flash.toSize - flash.fromSize) * a)
			part.Transparency = CONFIG.FLASH_START_TRANSPARENCY + (1 - CONFIG.FLASH_START_TRANSPARENCY) * a
		end
	end
end

local function stepShreds(dt: number)
	for i = #_shreds, 1, -1 do
		local shred = _shreds[i]
		shred.age += dt
		local part = shred.part
		if shred.age >= CONFIG.SHRED_LIFE then
			part.Transparency = 1
			table.insert(_freeShredParts, part)
			swapRemove(_shreds, i)
		else
			local t = shred.age
			local position = shred.origin + shred.velocity * t - Vector3.new(0, 0.5 * shred.gravity * t * t, 0)
			part.CFrame = CFrame.new(position) * CFrame.fromAxisAngle(shred.spinAxis, shred.spinRate * t) * shred.rotation
			part.Transparency = ease(t / CONFIG.SHRED_LIFE, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end
	end
end

local function step(dt: number)
	stepInflating()
	stepFlashes(dt)
	stepShreds(dt)
	if #_inflating == 0 and #_flashes == 0 and #_shreds == 0 and _stepConn then
		_stepConn:Disconnect()
		_stepConn = nil
	end
end

local function ensureStep()
	if not _stepConn then
		_stepConn = RunService.RenderStepped:Connect(step)
	end
end

local function startInflating(part: BasePart)
	local mesh = part:FindFirstChildOfClass("SpecialMesh")
	local spawnedAt = part:GetAttribute(ATTR.SPAWNED_AT)
	if not mesh or type(spawnedAt) ~= "number" then
		return
	end
	-- Llega tarde (streaming, join a mitad): se queda a tamaño completo.
	if workspace:GetServerTimeNow() - spawnedAt >= Balloons.INFLATE_TIME + CONFIG.WOBBLE_TIME then
		return
	end
	local entry = { mesh = mesh, halfHeight = part.Size.Y / 2, spawnedAt = spawnedAt }
	-- En el mismo handler del tag: nunca llega a verse un frame a tamaño completo.
	setScale(entry, CONFIG.INFLATE_FROM, CONFIG.INFLATE_FROM)
	table.insert(_inflating, entry)
	ensureStep()
end

local function spawnFlash(center: Vector3, color: Color3, diameter: number, growth: number)
	local part = acquireFlashPart()
	if not part then
		return
	end
	part.Color = color
	part.Size = Vector3.one * diameter
	part.CFrame = CFrame.new(center)
	part.Transparency = CONFIG.FLASH_START_TRANSPARENCY
	table.insert(_flashes, { part = part, age = 0, fromSize = diameter, toSize = diameter * growth })
end

local function spawnShred(center: Vector3, color: Color3, gravity: number): boolean
	local part = acquireShredPart()
	if not part then
		return false
	end
	local dir = Vector3.new(_rng:NextNumber(-1, 1), _rng:NextNumber(-0.3, 1), _rng:NextNumber(-1, 1))
	if dir.Magnitude < 1e-3 then
		dir = Vector3.yAxis
	end
	dir = dir.Unit
	local spin = Vector3.new(
		_rng:NextNumber(-CONFIG.SHRED_SPIN, CONFIG.SHRED_SPIN),
		_rng:NextNumber(-CONFIG.SHRED_SPIN, CONFIG.SHRED_SPIN),
		_rng:NextNumber(-CONFIG.SHRED_SPIN, CONFIG.SHRED_SPIN)
	)
	local origin = center + dir * 0.6
	local rotation = CFrame.Angles(_rng:NextNumber(0, math.pi), _rng:NextNumber(0, math.pi), 0)
	part.Color = color
	part.CFrame = CFrame.new(origin) * rotation
	part.Transparency = 0
	table.insert(_shreds, {
		part = part,
		age = 0,
		origin = origin,
		velocity = dir * _rng:NextNumber(CONFIG.SHRED_SPEED[1], CONFIG.SHRED_SPEED[2]),
		rotation = rotation,
		spinAxis = if spin.Magnitude > 1e-3 then spin.Unit else Vector3.yAxis,
		spinRate = spin.Magnitude,
		gravity = gravity,
	})
	return true
end

local function playPop(center: Vector3, pitch: number)
	local template = GameSounds.resolve(GameSounds.BalloonPop)
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
		attachment.Name = "PopSound"
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
	s.attachment.WorldPosition = center
	local playing = sound :: Sound
	playing.PlaybackSpeed = pitch * (1 + _rng:NextNumber(-CONFIG.PITCH_JITTER, CONFIG.PITCH_JITTER))
	playing.TimePosition = 0
	playing:Play()
end

local function burst(part: BasePart)
	local center = part.Position
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - center).Magnitude > CONFIG.CULL_DISTANCE then
		return
	end

	local popIndex = part:GetAttribute(ATTR.POP_INDEX)
	local popCount = part:GetAttribute(ATTR.POP_COUNT)
	local index = if type(popIndex) == "number" then popIndex else 1
	local finale = type(popCount) == "number" and index >= popCount
	local golden = part:GetAttribute(ATTR.GOLDEN) == true
	local color = part.Color

	spawnFlash(center, color, part.Size.X, if finale then CONFIG.FLASH_GROWTH_FINALE else CONFIG.FLASH_GROWTH)

	local shreds = (if finale then CONFIG.SHREDS_FINALE else CONFIG.SHREDS) * (if golden then CONFIG.GOLDEN_MULT else 1)
	local gravity = workspace.Gravity
	for _ = 1, math.max(1, math.floor(shreds * _shredScale)) do
		if not spawnShred(center, color, gravity) then
			break
		end
	end
	ensureStep()

	playPop(center, if finale then CONFIG.PITCH_FINALE else CONFIG.PITCH_STEPS[math.clamp(index, 1, #CONFIG.PITCH_STEPS)])
end

local function track(instance: Instance)
	if not instance:IsA("BasePart") or _poppedConns[instance] then
		return
	end
	local part = instance :: BasePart
	if part:GetAttribute(ATTR.POPPED) == true then
		return
	end
	startInflating(part)
	_poppedConns[part] = part:GetAttributeChangedSignal(ATTR.POPPED):Connect(function()
		if part:GetAttribute(ATTR.POPPED) == true then
			burst(part)
		end
	end)
end

local function untrack(instance: Instance)
	local conn = _poppedConns[instance]
	if conn then
		conn:Disconnect()
		_poppedConns[instance] = nil
	end
end

function BalloonPopVisuals.start()
	if _addedConn then
		return
	end
	for _, instance in CollectionService:GetTagged(Balloons.TAG) do
		track(instance)
	end
	_addedConn = CollectionService:GetInstanceAddedSignal(Balloons.TAG):Connect(track)
	_removedConn = CollectionService:GetInstanceRemovedSignal(Balloons.TAG):Connect(untrack)
end

function BalloonPopVisuals.stop()
	if _addedConn then
		_addedConn:Disconnect()
		_addedConn = nil
	end
	if _removedConn then
		_removedConn:Disconnect()
		_removedConn = nil
	end
	if _stepConn then
		_stepConn:Disconnect()
		_stepConn = nil
	end
	for instance, conn in _poppedConns do
		conn:Disconnect()
		_poppedConns[instance] = nil
	end
	resetPools()
	if _holder then
		_holder:Destroy()
		_holder = nil
	end
end

return BalloonPopVisuals
