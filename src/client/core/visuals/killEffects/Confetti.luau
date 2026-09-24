--!strict
--[[
	Kill effect Confetti, parte de cliente (el servidor solo hace el ragdoll): al
	morir sale del torso una ráfaga de papelitos que planean, se posan en el suelo y se
	desvanecen. Brillan (Neon) y destellan al girar, como papel metalizado. El confeti no
	se ata al contexto: sigue cayendo aunque el cadáver se limpie.

	Sin arte: son Parts anclados movidos a mano con BulkMoveTo, sin física, así que no
	chocan con nada y el suelo es un único raycast bajo el punto de muerte.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Utils = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects"):WaitForChild("Utils")
)
local GameSounds = require(script.Parent.Parent.Parent.ui.GameSounds)
local Types = require(script.Parent.Parent.KillEffectTypes)

-- Velocidades, gravedad y tamaños son para un cuerpo normal; se multiplican por su escala.
local CONFIG = {
	COUNT = 70,
	SIZE = Vector3.new(0.3, 0.03, 0.45), -- studs
	SPEED_UP_MIN = 22,
	SPEED_UP_MAX = 38,
	SPEED_SIDE_MIN = 4,
	SPEED_SIDE_MAX = 16,
	GRAVITY = 40, -- studs/s²; muy por debajo de la del mundo para que planee
	FALL_SPEED_MIN = 4, -- studs/s de caída máxima (cada papelito la suya)
	FALL_SPEED_MAX = 7,
	SIDE_DRAG = 1.5, -- 1/s de frenado horizontal
	SWAY = 0.6, -- studs de vaivén lateral
	SWAY_FREQ_MIN = 3, -- rad/s
	SWAY_FREQ_MAX = 6,
	SPIN_MIN = 4, -- rad/s
	SPIN_MAX = 12,
	LIFETIME_MIN = 2.5, -- s
	LIFETIME_MAX = 3.5,
	FADE_TIME = 0.6, -- s de desvanecido al final de su vida
	RAY_LENGTH = 50, -- studs de búsqueda de suelo bajo el torso
	LATE_TOLERANCE = 0.3, -- s de retraso máximo con el que aún se lanza
	CULL_DISTANCE = 300, -- studs desde la cámara
	-- Destello: al quedar de cara a la cámara el color se acerca a blanco. SHARPNESS
	-- alto = destellos más cortos.
	SHIMMER = 0.7, -- 0-1, cuánto blanco en el pico del destello
	SHIMMER_SHARPNESS = 6,
	PITCH_MIN = 1,
	PITCH_MAX = 1.2,
	SOUND_LIFETIME = 5, -- s hasta limpiar el emisor
	COLORS = {
		Color3.fromRGB(255, 72, 96),
		Color3.fromRGB(255, 196, 40),
		Color3.fromRGB(70, 210, 120),
		Color3.fromRGB(60, 160, 255),
		Color3.fromRGB(190, 90, 255),
		Color3.fromRGB(255, 130, 220),
	},
}

type Piece = {
	part: Part,
	color: Color3,
	position: Vector3,
	velocity: Vector3,
	axis: Vector3,
	angle: number,
	spin: number,
	phase: number,
	swayFreq: number,
	fallSpeed: number,
	scale: number,
	groundY: number,
	age: number,
	life: number,
	landed: boolean,
}

local Confetti = {}

local _stepConn: RBXScriptConnection? = nil
local _pieces: { Piece } = {}
local _folder: Folder? = nil
local _rng = Random.new()

local function getFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "ConfettiVisuals"
	folder.Parent = workspace
	_folder = folder
	return folder
end

-- Ignora agua, partes sin colisión y personajes (los cadáveres ya son CanQuery = false).
local function findGroundY(origin: Vector3, char: Model): number?
	local exclude: { Instance } = { char, getFolder() }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true
	local result = workspace:Raycast(origin, Vector3.new(0, -CONFIG.RAY_LENGTH, 0), params)
	return if result then result.Position.Y else nil
end

local function randomAxis(): Vector3
	local axis = Vector3.new(_rng:NextNumber(-1, 1), _rng:NextNumber(-1, 1), _rng:NextNumber(-1, 1))
	return if axis.Magnitude > 1e-3 then axis.Unit else Vector3.yAxis
end

local function removeAt(i: number)
	_pieces[i].part:Destroy()
	_pieces[i] = _pieces[#_pieces]
	_pieces[#_pieces] = nil
end

local WHITE = Color3.new(1, 1, 1)

local function step(dt: number)
	local camera = workspace.CurrentCamera
	local cameraPos = if camera then camera.CFrame.Position else nil
	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}
	local i = 1
	while i <= #_pieces do
		local p = _pieces[i]
		p.age += dt
		if p.age >= p.life then
			removeAt(i)
			continue
		end

		if not p.landed then
			local damp = math.exp(-CONFIG.SIDE_DRAG * dt)
			local v = p.velocity
			v = Vector3.new(v.X * damp, math.max(v.Y - CONFIG.GRAVITY * p.scale * dt, -p.fallSpeed), v.Z * damp)
			p.velocity = v
			p.position += v * dt
			p.angle += p.spin * dt

			local t = p.age * p.swayFreq + p.phase
			local sway = Vector3.new(math.sin(t), 0, math.cos(t)) * (CONFIG.SWAY * p.scale)
			local cframe: CFrame
			if p.position.Y <= p.groundY then
				-- Posado: plano sobre el suelo, conserva solo el giro vertical.
				p.landed = true
				cframe = CFrame.new(p.position.X + sway.X, p.groundY, p.position.Z + sway.Z) * CFrame.Angles(0, p.angle, 0)
			else
				cframe = CFrame.new(p.position + sway) * CFrame.fromAxisAngle(p.axis, p.angle)
			end
			if cameraPos then
				-- La cara ancha del papelito es su eje Y.
				local facing = math.abs(cframe.UpVector:Dot((cameraPos - cframe.Position).Unit))
				p.part.Color = p.color:Lerp(WHITE, CONFIG.SHIMMER * facing ^ CONFIG.SHIMMER_SHARPNESS)
			end
			table.insert(parts, p.part)
			table.insert(cframes, cframe)
		end

		local fadeStart = p.life - CONFIG.FADE_TIME
		if p.age > fadeStart then
			p.part.Transparency = (p.age - fadeStart) / CONFIG.FADE_TIME
		end
		i += 1
	end

	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if #_pieces == 0 and _stepConn then
		_stepConn:Disconnect()
		_stepConn = nil
	end
end

local function makePart(scale: number, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = "Confetti"
	part.Size = CONFIG.SIZE * scale
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

local function burst(origin: Vector3, scale: number, char: Model)
	local ground = findGroundY(origin, char)
	-- Media altura del papelito para que no quede enterrado.
	local groundY = if ground then ground + CONFIG.SIZE.Y * scale / 2 else -math.huge
	local folder = getFolder()

	for _ = 1, CONFIG.COUNT do
		local heading = _rng:NextNumber(0, 2 * math.pi)
		local side = _rng:NextNumber(CONFIG.SPEED_SIDE_MIN, CONFIG.SPEED_SIDE_MAX)
		local up = _rng:NextNumber(CONFIG.SPEED_UP_MIN, CONFIG.SPEED_UP_MAX)
		local color = CONFIG.COLORS[_rng:NextInteger(1, #CONFIG.COLORS)]
		local part = makePart(scale, color)
		local piece: Piece = {
			part = part,
			color = color,
			position = origin,
			velocity = Vector3.new(math.cos(heading) * side, up, math.sin(heading) * side) * scale,
			axis = randomAxis(),
			angle = _rng:NextNumber(0, 2 * math.pi),
			spin = _rng:NextNumber(CONFIG.SPIN_MIN, CONFIG.SPIN_MAX),
			phase = _rng:NextNumber(0, 2 * math.pi),
			swayFreq = _rng:NextNumber(CONFIG.SWAY_FREQ_MIN, CONFIG.SWAY_FREQ_MAX),
			fallSpeed = _rng:NextNumber(CONFIG.FALL_SPEED_MIN, CONFIG.FALL_SPEED_MAX) * scale,
			scale = scale,
			groundY = groundY,
			age = 0,
			life = _rng:NextNumber(CONFIG.LIFETIME_MIN, CONFIG.LIFETIME_MAX),
			landed = false,
		}
		part.CFrame = CFrame.new(origin) * CFrame.fromAxisAngle(piece.axis, piece.angle)
		part.Parent = folder
		table.insert(_pieces, piece)
	end

	if not _stepConn then
		_stepConn = RunService.RenderStepped:Connect(step)
	end
end

local function playSound(position: Vector3)
	-- En Terrain: el sonido no se corta si el cadáver se limpia.
	local emitter = Instance.new("Attachment")
	emitter.Name = "ConfettiSound"
	emitter.Parent = workspace.Terrain
	emitter.WorldPosition = position
	GameSounds.playAt(GameSounds.Confetti, emitter, _rng:NextNumber(CONFIG.PITCH_MIN, CONFIG.PITCH_MAX))
	Debris:AddItem(emitter, CONFIG.SOUND_LIFETIME)
end

function Confetti.play(char: Model, ctx: Types.Ctx)
	if not ctx.isFresh(CONFIG.LATE_TOLERANCE) then
		return
	end
	local origin = Utils.bodyCenter(char)
	playSound(origin)
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - origin).Magnitude > CONFIG.CULL_DISTANCE then
		return
	end
	burst(origin, Utils.bodyScale(char), char)
end

function Confetti.stop()
	if _stepConn then
		_stepConn:Disconnect()
		_stepConn = nil
	end
	table.clear(_pieces)
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

return Confetti
