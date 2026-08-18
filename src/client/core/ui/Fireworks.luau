--!strict
--[[
	Fireworks.luau
	Fuegos artificiales fullscreen: unos cuantos cohetes suben desde la parte baja
	de la pantalla y, al agotarse su mecha, revientan en un anillo circular de
	chispas que se expanden, frenan por rozamiento y caen apagándose.

	Complementa a Confetti (cañón de rectángulos desde las esquinas): aquí las
	partículas son puntos redondos, el reparto es radial y el efecto se estira
	varios segundos encadenando estallidos. Los dos se pueden lanzar a la vez
	sobre el mismo ScreenGui.

	Uso:
		Fireworks.Burst(parentScreenGui, { colors = { ... } })
]]

local RunService = game:GetService("RunService")

local Fireworks = {}

-- Duración total ≈ spawnDuration + FUSE_MAX + SPARK_LIFETIME_MAX. Con los
-- valores de abajo son ~4.05 s, calibrados contra el hold del popup de level up
-- (ver la coreografía en MatchNotificationsQueue): los estallidos se encadenan
-- durante casi toda la ventana y queda un beat de calma antes de que salga.
local SHELL_COUNT = 5                 -- cohetes por tanda
local SPARKS_PER_SHELL = 18           -- puntos del anillo (18 ya se lee redondo)
local SPAWN_DURATION = 1.5            -- s repartiendo las salidas de los cohetes

-- Igual criterio que Confetti: velocidades y gravedades se escalan por el alto de
-- pantalla para que el efecto se vea idéntico en cualquier resolución (móvil
-- incluido), y los tamaños en px por la resolución respecto a 1080p.
local SHELL_GRAVITY_FACTOR = 1.6      -- × alto/s² durante la subida del cohete
local SPARK_GRAVITY_FACTOR = 0.42     -- × alto/s² tras estallar (cuelga en el aire)
local SPARK_SPEED_FACTOR_MIN = 0.34   -- × alto/s con el que se abre el anillo
local SPARK_SPEED_FACTOR_MAX = 0.52
local SPARK_SPEED_JITTER = 0.25       -- ± por chispa: el anillo no sale de compás
local SPARK_DRAG = 1.9                -- frenada de la expansión (1/s)
local FUSE_MIN = 0.55                 -- s de subida antes de estallar
local FUSE_MAX = 0.85
local BURST_X_MIN = 0.18              -- franja donde estallan (fracción de pantalla)
local BURST_X_MAX = 0.82
local BURST_Y_MIN = 0.14              -- 0 = borde superior
local BURST_Y_MAX = 0.42
local LAUNCH_X_JITTER = 0.06          -- desvío de la salida respecto al estallido
local SHELL_SIZE = 6                  -- px del cohete a 1080p
local SPARK_SIZE_MIN = 6              -- px de la chispa a 1080p
local SPARK_SIZE_MAX = 9
local SPARK_LIFETIME_MIN = 1.1
local SPARK_LIFETIME_MAX = 1.7
local FADE_START_RATIO = 0.5          -- fracción de vida tras la que empieza el fade
local SHRINK_END_SCALE = 0.35         -- la chispa se encoge hasta esto al morir
local OFFSCREEN_MARGIN = 100          -- px bajo la pantalla a los que se recicla

-- Paleta llamativa y saturada: el efecto es el momento "fiesta" de la partida y
-- se lee mejor si no se camufla con la paleta del popup que lo lanza (de eso ya
-- se encarga el confeti, azul en level up y verde en pase).
local DEFAULT_COLORS = {
	Color3.fromRGB(255, 60, 120),   -- magenta
	Color3.fromRGB(255, 190, 40),   -- ámbar
	Color3.fromRGB(60, 255, 210),   -- turquesa
	Color3.fromRGB(140, 90, 255),   -- violeta
	Color3.fromRGB(120, 240, 50),   -- lima
	Color3.fromRGB(0, 190, 255),    -- cian
}
-- Cada cohete se queda con un color de la paleta y casi todas sus chispas son de
-- ese color, con alguna suelta del siguiente: así cada estallido se lee como un
-- fuego de verdad (monocromo) y la tanda entera sí sale multicolor.
local SPARK_ACCENT_CHANCE = 0.25

-- Pool de puntos redondos (Frame + UICorner al 100%). Mismo criterio que el pool
-- de Confetti: las piezas en reposo viven con Parent=nil en vez de destruirse.
-- El cap cubre el peor caso de una tanda (que los 5 cohetes estallen a la vez),
-- así que en el uso normal no hay ni un Destroy. Un caller que pida más cohetes
-- o chispas por opts degrada a destruir las sobrantes, como hace Confetti.
local POOL_CAP = SHELL_COUNT * (SPARKS_PER_SHELL + 1)
local _pool: { Frame } = {}

local function _acquireDot(): Frame
	local n = #_pool
	if n > 0 then
		local dot = _pool[n]
		_pool[n] = nil
		return dot
	end
	local dot = Instance.new("Frame")
	dot.BorderSizePixel = 0
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot
	return dot
end

local function _releaseDot(dot: Frame)
	if #_pool >= POOL_CAP then
		dot:Destroy()
		return
	end
	dot.Parent = nil
	dot.BackgroundTransparency = 0
	dot.Visible = true
	table.insert(_pool, dot)
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

export type BurstOptions = {
	shells: number?,
	sparksPerShell: number?,
	colors: { Color3 }?,
	spawnDuration: number?,
	zIndex: number?,
}

-- Cohetes y chispas comparten lista: el cohete es el que lleva `isShell`, y sus
-- chispas ya nacen con `spawnAt` = salida + mecha y su origen en el punto de
-- estallido. La subida se resuelve analíticamente al crear la partícula, así que
-- el bucle no tiene que encadenar nada en runtime ni crear partículas a mitad.
type Particle = {
	x: number,
	y: number,
	vx: number,
	vy: number,
	gravity: number,
	drag: number,
	age: number,
	lifetime: number,
	spawnAt: number,
	color: Color3,
	size: number,
	isShell: boolean,
	piece: Frame?,
	spawned: boolean,
	done: boolean,
}

function Fireworks.Burst(parent: Instance, options: BurstOptions?)
	local opts = options or {}
	local shells = opts.shells or SHELL_COUNT
	local sparksPerShell = opts.sparksPerShell or SPARKS_PER_SHELL
	local colors = opts.colors or DEFAULT_COLORS
	-- spawnDuration escalona la salida de los cohetes para que no suban en bloque:
	-- es lo que estira el efecto, porque cada uno estalla a su ritmo.
	local spawnDuration = opts.spawnDuration or SPAWN_DURATION
	local zIndex = opts.zIndex or 100

	if shells <= 0 or sparksPerShell <= 0 then
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
	local shellGravity = screenHeight * SHELL_GRAVITY_FACTOR
	local sparkGravity = screenHeight * SPARK_GRAVITY_FACTOR
	local sizeScale = screenHeight / 1080

	local particles: { Particle } = table.create(shells * (sparksPerShell + 1))

	for shellIndex = 1, shells do
		local slot = spawnDuration / shells
		local launchAt = if spawnDuration > 0 then (shellIndex - 1) * slot + math.random() * slot else 0
		local fuse = FUSE_MIN + math.random() * (FUSE_MAX - FUSE_MIN)
		local burstX = screenWidth * (BURST_X_MIN + math.random() * (BURST_X_MAX - BURST_X_MIN))
		local burstY = screenHeight * (BURST_Y_MIN + math.random() * (BURST_Y_MAX - BURST_Y_MIN))
		local launchX = math.clamp(
			burstX + screenWidth * (math.random() - 0.5) * 2 * LAUNCH_X_JITTER,
			0,
			screenWidth
		)

		local shellColor = colors[((shellIndex - 1) % #colors) + 1]
		local accentColor = colors[(shellIndex % #colors) + 1]

		-- Velocidad de salida que deja el cohete justo en (burstX, burstY) al
		-- cumplirse la mecha, despejando vy de y(t) = y0 + vy·t + ½·g·t².
		table.insert(particles, {
			x = launchX,
			y = screenHeight,
			vx = (burstX - launchX) / fuse,
			vy = (burstY - screenHeight) / fuse - 0.5 * shellGravity * fuse,
			gravity = shellGravity,
			drag = 0,
			age = 0,
			lifetime = fuse,
			spawnAt = launchAt,
			color = shellColor,
			size = SHELL_SIZE * sizeScale,
			isShell = true,
			piece = nil,
			spawned = false,
			done = false,
		})

		-- Anillo: ángulos a partes iguales con un desfase por cohete y jitter de
		-- velocidad, para que se lea como círculo sin parecer hecho con compás.
		local angleOffset = math.random() * math.pi * 2
		for sparkIndex = 1, sparksPerShell do
			local angle = angleOffset + ((sparkIndex - 1) / sparksPerShell) * math.pi * 2
			local speed = screenHeight
				* (SPARK_SPEED_FACTOR_MIN + math.random() * (SPARK_SPEED_FACTOR_MAX - SPARK_SPEED_FACTOR_MIN))
				* (1 + (math.random() - 0.5) * 2 * SPARK_SPEED_JITTER)

			table.insert(particles, {
				x = burstX,
				y = burstY,
				vx = math.cos(angle) * speed,
				vy = math.sin(angle) * speed,
				gravity = sparkGravity,
				drag = SPARK_DRAG,
				age = 0,
				lifetime = SPARK_LIFETIME_MIN + math.random() * (SPARK_LIFETIME_MAX - SPARK_LIFETIME_MIN),
				spawnAt = launchAt + fuse,
				color = if math.random() < SPARK_ACCENT_CHANCE then accentColor else shellColor,
				size = (SPARK_SIZE_MIN + math.random() * (SPARK_SIZE_MAX - SPARK_SIZE_MIN)) * sizeScale,
				isShell = false,
				piece = nil,
				spawned = false,
				done = false,
			})
		end
	end

	local elapsed = 0
	local remaining = #particles
	local fadeSpan = math.max(0.0001, 1 - FADE_START_RATIO)
	local connection: RBXScriptConnection? = nil

	local function releaseAll()
		for _, p in particles do
			if p.piece then
				_releaseDot(p.piece)
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
				local piece = _acquireDot()
				piece.BackgroundColor3 = p.color
				piece.BackgroundTransparency = 0
				piece.Size = UDim2.fromOffset(p.size, p.size)
				piece.Position = UDim2.fromOffset(p.x, p.y)
				piece.ZIndex = zIndex
				piece.Parent = container
				p.piece = piece
				p.spawned = true
			end

			-- Integración: rozamiento (solo las chispas) + gravedad.
			p.age += dt
			if p.drag > 0 then
				p.vx -= p.vx * p.drag * dt
				p.vy -= p.vy * p.drag * dt
			end
			p.vy += p.gravity * dt
			p.x += p.vx * dt
			p.y += p.vy * dt

			local piece = p.piece
			if piece then
				piece.Position = UDim2.fromOffset(p.x, p.y)
				-- El cohete sube entero y a plena luz; solo la chispa se encoge y
				-- se apaga (el cohete "desaparece" al estallar, no al desvanecerse).
				if not p.isShell then
					local lifeRatio = p.age / p.lifetime
					local shrink = 1 - (1 - SHRINK_END_SCALE) * lifeRatio
					local px = math.max(2, math.floor(p.size * shrink))
					piece.Size = UDim2.fromOffset(px, px)
					if lifeRatio > FADE_START_RATIO then
						piece.BackgroundTransparency = math.clamp((lifeRatio - FADE_START_RATIO) / fadeSpan, 0, 1)
					end
				end
			end

			if p.age >= p.lifetime or p.y > screenHeight + OFFSCREEN_MARGIN then
				if p.piece then
					_releaseDot(p.piece)
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

return Fireworks
