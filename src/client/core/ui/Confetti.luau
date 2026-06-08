--!strict
--[[
	Confetti.luau
	Cañón fullscreen de partículas rectangulares (Frames): salen disparadas con
	fuerza desde las dos esquinas inferiores de la pantalla hacia arriba y el
	centro, arquean por gravedad y se desvanecen al caer.

	Uso:
		Confetti.Rain(parentScreenGui)
]]

local RunService = game:GetService("RunService")

local Confetti = {}

-- Parámetros del cañón. Velocidad de lanzamiento y gravedad se escalan por la
-- altura de pantalla para que el arco se vea igual en cualquier resolución
-- (importante en móvil): apex ≈ alto * factor² / (2 * factorGravedad).
local LAUNCH_SPEED_FACTOR_MIN = 1.5 -- × alto de pantalla / s
local LAUNCH_SPEED_FACTOR_MAX = 2.4
local GRAVITY_FACTOR = 2.3 -- × alto de pantalla / s²
local LAUNCH_ANGLE_MIN = 55 -- grados sobre la horizontal (hacia el centro)
local LAUNCH_ANGLE_MAX = 85
local CORNER_SPREAD = 48 -- px de dispersión del punto de salida en cada esquina
local HORIZONTAL_DRAG = 0.35 -- amortiguación del componente horizontal (1/s)
local FADE_START_RATIO = 0.6 -- fracción de vida tras la que empieza el fade out
local OFFSCREEN_MARGIN = 100 -- px bajo la pantalla a los que se recicla la pieza
local SPIN_SPEED = 420 -- grados/s máx de giro 2D
-- Aleteo y volteo: confeti real cabecea y se mece al caer. Se simula con un
-- coseno que estrecha el ancho (volteo 3D) y un seno que mece en horizontal.
-- Son 2 trig por pieza/frame — coste despreciable incluso en móvil.
local TUMBLE_FREQ_MIN = 6 -- rad/s del volteo (flip del ancho)
local TUMBLE_FREQ_MAX = 13
local MIN_FLIP_SCALE = 0.12 -- ancho mínimo al voltear de canto (no desaparece)
local FLUTTER_FREQ_MIN = 2 -- rad/s del meceo lateral
local FLUTTER_FREQ_MAX = 5
local FLUTTER_AMP_MIN = 60 -- px/s de meceo a 1080p (se escala por resolución)
local FLUTTER_AMP_MAX = 170
local STREAMER_CHANCE = 0.25 -- proporción de piezas alargadas tipo serpentina

local DEFAULT_COLORS = {
	Color3.fromRGB(255, 80, 80),
	Color3.fromRGB(255, 165, 60),
	Color3.fromRGB(255, 222, 60),
	Color3.fromRGB(80, 220, 120),
	Color3.fromRGB(80, 170, 255),
	Color3.fromRGB(200, 100, 255),
	Color3.fromRGB(255, 130, 220),
}

-- ────────────────────────────────────────────────────────────────
-- Sprint 3: pool de Frames.
--
-- Antes cada Burst (32) y Rain (80) hacía Instance.new + Destroy. Triggered
-- desde MatchHud (level-up + bp-level-up + challenge-complete = 3×60 frames),
-- Locker on buy, Rewards confetti, etc. — fácilmente cientos de instancias
-- por minuto en momentos de actividad.
--
-- Ahora: pool con Parent=nil para piezas en reposo. Al acquire se reparenta
-- al container; al complete del tween, _releaseFrame las devuelve al pool.
-- POOL_CAP limita la huella en memoria (256 × ~Frame ≈ pocos KB).
-- ────────────────────────────────────────────────────────────────

-- Audit mobile: cap reducido de 256 a 80. Una Rain típica usa 80 piezas y
-- las llamadas sucesivas no se solapan (la siguiente Rain empieza después
-- de la anterior). 256 × Frame quietos ocupaban ~400 KB residente; 80
-- son ~125 KB.
local POOL_CAP = 80
local _pool: { Frame } = {}

local function _acquireFrame(): Frame
	local n = #_pool
	if n > 0 then
		local piece = _pool[n]
		_pool[n] = nil
		return piece
	end
	local piece = Instance.new("Frame")
	piece.BorderSizePixel = 0
	piece.AnchorPoint = Vector2.new(0.5, 0.5)
	return piece
end

local function _releaseFrame(piece: Frame)
	-- Si el pool está lleno, destroy en lugar de stashear (limita la huella).
	if #_pool >= POOL_CAP then
		piece:Destroy()
		return
	end
	piece.Parent = nil
	piece.BackgroundTransparency = 0
	piece.Visible = true
	table.insert(_pool, piece)
end

local function resolveScreenContainer(parent: Instance): Instance
	if parent:IsA("ScreenGui") then
		return parent
	end

	local ancestor = parent:FindFirstAncestorWhichIsA("ScreenGui")
	if ancestor then
		return ancestor
	end

	return parent
end

export type RainOptions = {
	count: number?,
	colors: { Color3 }?,
	minLifetime: number?,
	maxLifetime: number?,
	spawnDuration: number?,
	zIndex: number?,
}

type Particle = {
	x: number,
	y: number,
	vx: number,
	vy: number,
	rot: number,
	rotVel: number,
	age: number,
	lifetime: number,
	spawnAt: number,
	color: Color3,
	w: number,
	h: number,
	tumblePhase: number,
	tumbleFreq: number,
	flutterPhase: number,
	flutterFreq: number,
	flutterAmp: number,
	piece: Frame?,
	spawned: boolean,
	done: boolean,
}

function Confetti.Rain(parent: Instance, options: RainOptions?)
	local opts = options or {}
	local count = opts.count or 80
	local colors = opts.colors or DEFAULT_COLORS
	local minLifetime = opts.minLifetime or 1.6
	local maxLifetime = opts.maxLifetime or 2.8
	-- spawnDuration escalona el disparo; por defecto un burst casi instantáneo
	-- para que se sienta el "pop" desde las esquinas.
	local spawnDuration = opts.spawnDuration or 0.18
	local zIndex = opts.zIndex or 100

	if count <= 0 then
		return
	end

	local container = resolveScreenContainer(parent)
	local containerInstance = container :: any
	local viewportSize: Vector2
	if containerInstance:IsA("GuiBase2d") then
		viewportSize = containerInstance.AbsoluteSize
	else
		local Camera = workspace.CurrentCamera
		viewportSize = if Camera then Camera.ViewportSize else Vector2.new(1920, 1080)
	end

	local screenWidth = math.max(1, viewportSize.X)
	local screenHeight = math.max(1, viewportSize.Y)
	local gravity = screenHeight * GRAVITY_FACTOR

	-- Cada partícula sale de una esquina (alternadas) con velocidad hacia arriba y
	-- el centro. El ángulo se mide sobre la horizontal; el componente horizontal
	-- apunta hacia dentro (derecha desde la esquina izquierda y viceversa).
	local particles: { Particle } = table.create(count)
	for i = 1, count do
		local fromLeft = (i % 2) == 1
		local speed = screenHeight * (LAUNCH_SPEED_FACTOR_MIN + math.random() * (LAUNCH_SPEED_FACTOR_MAX - LAUNCH_SPEED_FACTOR_MIN))
		local angle = math.rad(LAUNCH_ANGLE_MIN + math.random() * (LAUNCH_ANGLE_MAX - LAUNCH_ANGLE_MIN))
		local horizontalDir = if fromLeft then 1 else -1
		local margin = math.random(0, CORNER_SPREAD)

		-- Variedad de formas: la mayoría cuadraditos; algunas serpentinas alargadas.
		local isStreamer = math.random() < STREAMER_CHANCE
		local w = if isStreamer then math.random(16, 26) else math.random(8, 14)
		local h = if isStreamer then math.random(3, 5) else math.random(5, 9)

		particles[i] = {
			x = if fromLeft then margin else screenWidth - margin,
			y = screenHeight - math.random(0, 24),
			vx = math.cos(angle) * speed * horizontalDir,
			vy = -math.sin(angle) * speed,
			rot = math.random(0, 360),
			rotVel = math.random(-SPIN_SPEED, SPIN_SPEED),
			age = 0,
			lifetime = minLifetime + math.random() * (maxLifetime - minLifetime),
			spawnAt = if spawnDuration > 0 then math.random() * spawnDuration else 0,
			color = colors[((i - 1) % #colors) + 1],
			w = w,
			h = h,
			tumblePhase = math.random() * math.pi * 2,
			tumbleFreq = TUMBLE_FREQ_MIN + math.random() * (TUMBLE_FREQ_MAX - TUMBLE_FREQ_MIN),
			flutterPhase = math.random() * math.pi * 2,
			flutterFreq = FLUTTER_FREQ_MIN + math.random() * (FLUTTER_FREQ_MAX - FLUTTER_FREQ_MIN),
			flutterAmp = (screenHeight / 1080) * (FLUTTER_AMP_MIN + math.random() * (FLUTTER_AMP_MAX - FLUTTER_AMP_MIN)),
			piece = nil,
			spawned = false,
			done = false,
		}
	end

	local elapsed = 0
	local remaining = count
	local fadeSpan = math.max(0.0001, 1 - FADE_START_RATIO)
	local connection: RBXScriptConnection? = nil

	local function releaseAll()
		for _, p in particles do
			if p.piece then
				_releaseFrame(p.piece)
				p.piece = nil
			end
		end
	end

	connection = RunService.Heartbeat:Connect(function(dt)
		if not container.Parent then
			releaseAll()
			if connection then
				connection:Disconnect()
			end
			return
		end

		elapsed += dt

		for _, p in particles do
			if p.done then
				continue
			end

			if not p.spawned then
				if elapsed < p.spawnAt then
					continue
				end
				local piece = _acquireFrame()
				piece.BackgroundColor3 = p.color
				piece.BackgroundTransparency = 0
				piece.Size = UDim2.fromOffset(p.w, p.h)
				piece.Position = UDim2.fromOffset(p.x, p.y)
				piece.Rotation = p.rot
				piece.ZIndex = zIndex
				piece.Parent = container
				p.piece = piece
				p.spawned = true
			end

			-- Integración: gravedad + leve arrastre horizontal + meceo lateral (sway).
			p.age += dt
			p.vy += gravity * dt
			p.vx -= p.vx * HORIZONTAL_DRAG * dt
			p.x += p.vx * dt
			p.x += math.sin(elapsed * p.flutterFreq + p.flutterPhase) * p.flutterAmp * dt
			p.y += p.vy * dt
			p.rot += p.rotVel * dt

			local piece = p.piece
			if piece then
				piece.Position = UDim2.fromOffset(p.x, p.y)
				piece.Rotation = p.rot
				-- Volteo 3D simulado: el ancho se estrecha al ponerse "de canto".
				local flip = math.max(MIN_FLIP_SCALE, math.abs(math.cos(p.tumblePhase + elapsed * p.tumbleFreq)))
				piece.Size = UDim2.fromOffset(math.max(2, math.floor(p.w * flip)), p.h)
				local lifeRatio = p.age / p.lifetime
				if lifeRatio > FADE_START_RATIO then
					piece.BackgroundTransparency = math.clamp((lifeRatio - FADE_START_RATIO) / fadeSpan, 0, 1)
				end
			end

			if p.age >= p.lifetime or p.y > screenHeight + OFFSCREEN_MARGIN then
				if p.piece then
					_releaseFrame(p.piece)
					p.piece = nil
				end
				p.done = true
				remaining -= 1
			end
		end

		if remaining <= 0 and connection then
			connection:Disconnect()
		end
	end)
end

return Confetti
