--!strict
--[[
	Confetti.luau
	Lluvia fullscreen de partículas rectangulares (Frames) animadas que caen
	desde fuera de la pantalla y se desvanecen.

	Uso:
		Confetti.Rain(parentScreenGui)
]]

local TweenService = game:GetService("TweenService")

local Confetti = {}

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
	horizontalDrift: number?,
	zIndex: number?,
}

function Confetti.Rain(parent: Instance, options: RainOptions?)
	local opts = options or {}
	local count = opts.count or 80
	local colors = opts.colors or DEFAULT_COLORS
	local minLifetime = opts.minLifetime or 1.6
	local maxLifetime = opts.maxLifetime or 2.8
	local spawnDuration = opts.spawnDuration or 0.6
	local horizontalDrift = opts.horizontalDrift or 120
	local zIndex = opts.zIndex or 100

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
	local fallTargetY = screenHeight + 60

	for i = 1, count do
		task.delay((i - 1) / count * spawnDuration, function()
			if not container.Parent then
				return
			end

			local piece = _acquireFrame()
			piece.BackgroundColor3 = colors[((i - 1) % #colors) + 1]
			piece.BackgroundTransparency = 0
			piece.Size = UDim2.fromOffset(math.random(8, 14), math.random(4, 8))
			local startX = math.random(0, math.floor(screenWidth))
			local startY = math.random(-80, -20)
			piece.Position = UDim2.fromOffset(startX, startY)
			piece.Rotation = math.random(0, 360)
			piece.ZIndex = zIndex
			piece.Parent = container

			local drift = math.random(-horizontalDrift, horizontalDrift)
			local targetX = startX + drift
			local targetRotation = piece.Rotation + math.random(-720, 720)
			local lifetime = minLifetime + math.random() * (maxLifetime - minLifetime)

			local tween = TweenService:Create(piece, TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.fromOffset(targetX, fallTargetY),
				Rotation = targetRotation,
				BackgroundTransparency = 1,
			})
			tween:Play()
			tween.Completed:Once(function()
				_releaseFrame(piece)
			end)
		end)
	end
end

return Confetti
