-- HealEffect.luau (Client Library)
-- Efecto visual de curación: partículas verdes que suben desde los bordes de la
-- pantalla + un glow verde sutil en el marco. Se dispara vía HealEffect.play()
-- cuando el jugador gana salud (ver HealthBarController).
--
-- El ScreenGui es persistente (ResetOnSpawn=false) y se construye una sola vez
-- de forma lazy. Cada play() corre una "envolvente" de intensidad (entra,
-- sostiene, sale) durante `duration` segundos, modulando el glow y el ritmo de
-- spawn de partículas. Un token invalida el loop viejo si llega otra curación o
-- un respawn antes de terminar.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

local IMAGE_ID = "rbxassetid://117688967482768"
local HEAL_COLOR = Color3.fromRGB(120, 255, 150)
local GLOW_THICKNESS = 0.22
local GLOW_MAX_OPACITY = 0.18

local HealEffect = {}

local screenGui: ScreenGui? = nil
local glows: { Frame } = {}
local activeToken = 0

local function createEdgeGlow(parent: ScreenGui, rotation: number, anchor: Vector2, pos: UDim2, size: UDim2): Frame
	local frame = Instance.new("Frame")
	frame.AnchorPoint = anchor
	frame.Position = pos
	frame.Size = size
	frame.BackgroundColor3 = HEAL_COLOR
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = 1
	frame.Parent = parent

	local grad = Instance.new("UIGradient")
	grad.Rotation = rotation
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Parent = frame
	return frame
end

local function setGlow(alpha: number)
	for _, g in ipairs(glows) do
		g.BackgroundTransparency = 1 - (GLOW_MAX_OPACITY * alpha)
	end
end

-- Construye el ScreenGui + los 4 glows de borde la primera vez. Devuelve false
-- si todavía no hay PlayerGui.
local function ensureGui(): boolean
	if screenGui and screenGui.Parent then
		return true
	end

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "HealEffect"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = playerGui

	glows = {
		createEdgeGlow(gui, 90, Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0), UDim2.fromScale(1, GLOW_THICKNESS)), -- arriba
		createEdgeGlow(gui, 270, Vector2.new(0.5, 1), UDim2.fromScale(0.5, 1), UDim2.fromScale(1, GLOW_THICKNESS)), -- abajo
		createEdgeGlow(gui, 0, Vector2.new(0, 0.5), UDim2.fromScale(0, 0.5), UDim2.fromScale(GLOW_THICKNESS, 1)), -- izquierda
		createEdgeGlow(gui, 180, Vector2.new(1, 0.5), UDim2.fromScale(1, 0.5), UDim2.fromScale(GLOW_THICKNESS, 1)), -- derecha
	}

	screenGui = gui
	setGlow(0)
	return true
end

-- Posición aleatoria SOLO en los bordes (nunca el centro).
local function getEdgePosition(): UDim2
	local edge = math.random(1, 4)
	local margin = 0.13
	local x, y
	if edge == 1 then
		x, y = math.random(), math.random() * margin
	elseif edge == 2 then
		x, y = math.random(), 1 - (math.random() * margin)
	elseif edge == 3 then
		x, y = math.random() * margin, math.random()
	else
		x, y = 1 - (math.random() * margin), math.random()
	end
	return UDim2.new(x, 0, y, 0)
end

-- Una partícula de curación: aparece creciendo desde un borde, deriva hacia
-- arriba girando levemente y se desvanece. Se auto-destruye al terminar.
local function spawnHealImage()
	local gui = screenGui
	if not gui then
		return
	end

	-- Tamaño en tres niveles: normales, grandes y enormes.
	local targetSize, depth
	local roll = math.random()
	if roll < 0.10 then
		targetSize = math.random(160, 230)
		depth = "front"
	elseif roll < 0.30 then
		targetSize = math.random(95, 140)
		depth = "front"
	else
		targetSize = math.random(45, 80)
		depth = "back"
	end

	-- Profundidad: fondo tenue y detrás, frente nítido y delante.
	local maxOpacity = if depth == "front" then 0 else 0.35
	local zIndex = if depth == "front" then 20 else 8

	local img = Instance.new("ImageLabel")
	img.Image = IMAGE_ID
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Size = UDim2.fromOffset(targetSize * 0.4, targetSize * 0.4)
	img.Position = getEdgePosition()
	img.ImageColor3 = HEAL_COLOR
	img.ImageTransparency = 1
	img.Rotation = math.random(-8, 8)
	img.ZIndex = zIndex
	img.Parent = gui

	local startPos = img.Position
	local driftPos = startPos + UDim2.new(math.random(-35, 35) / 1000, 0, -math.random(60, 100) / 1000, 0)
	local endRotation = img.Rotation + math.random(-6, 6)

	-- Tiempos de vida cortos = movimiento rápido.
	local lifetime
	if targetSize > 150 then
		lifetime = 0.95
	elseif targetSize > 90 then
		lifetime = 0.8
	else
		lifetime = 0.65
	end

	-- Fase 1: aparición suave (crece + se hace visible + gira un poco).
	local appearInfo = TweenInfo.new(lifetime * 0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local appear = TweenService:Create(img, appearInfo, {
		Size = UDim2.fromOffset(targetSize, targetSize),
		ImageTransparency = maxOpacity,
		Rotation = img.Rotation + (endRotation - img.Rotation) * 0.5,
	})

	-- Fase 2: deriva + desvanecimiento continuo.
	local fadeInfo = TweenInfo.new(lifetime * 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	local fade = TweenService:Create(img, fadeInfo, {
		Position = driftPos,
		ImageTransparency = 1,
		Size = UDim2.fromOffset(targetSize * 0.75, targetSize * 0.75),
		Rotation = endRotation,
	})

	appear:Play()
	appear.Completed:Once(function()
		fade:Play()
	end)
	fade.Completed:Once(function()
		img:Destroy()
	end)
end

-- Envolvente de intensidad: rampa de entrada, sostenido, rampa de salida.
local function envelope(t: number): number
	if t < 0.18 then
		return t / 0.18
	elseif t > 0.75 then
		return (1 - t) / 0.25
	else
		return 1
	end
end

-- Dispara el efecto completo durante `duration` segundos (default 5). Si ya hay
-- uno en curso, lo reemplaza (el token invalida el loop viejo).
function HealEffect.play(duration: number?)
	if not ensureGui() then
		return
	end

	local total = duration or 5
	activeToken += 1
	local myToken = activeToken

	task.spawn(function()
		local elapsed = 0
		while elapsed < total do
			if activeToken ~= myToken then
				return
			end

			local t = elapsed / total
			local intensity = math.clamp(envelope(t), 0, 1)
			setGlow(intensity)

			-- Más items en el pico de intensidad: ritmo más corto + extra.
			local spawnRate = 0.13 - (0.06 * intensity)
			spawnHealImage()
			if intensity > 0.6 and math.random() < 0.6 then
				spawnHealImage()
			end

			local waitTime = spawnRate + (math.random(-15, 15) / 1000)
			task.wait(waitTime)
			elapsed += waitTime
		end

		if activeToken ~= myToken then
			return
		end
		setGlow(0)
	end)
end

-- Corta cualquier efecto en curso y apaga el glow (p. ej. al respawnear). Las
-- partículas en vuelo se auto-destruyen solas vía sus tweens.
function HealEffect.reset()
	activeToken += 1
	if screenGui and screenGui.Parent then
		setGlow(0)
	end
end

return HealEffect
