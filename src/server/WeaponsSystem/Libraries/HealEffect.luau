-- HealEffect.luau (Client Library)
-- Efecto visual de curación: "+" verdes que suben desde las dos esquinas
-- inferiores de la pantalla abriéndose hacia dentro + un glow verde sutil en el
-- marco. Se dispara vía HealEffect.play() cuando el jugador gana salud (ver
-- HealthBarController).
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
local GLOW_THICKNESS = 0.19
local GLOW_MAX_OPACITY = 0.13

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

-- Los "+" salen SOLO por las dos esquinas inferiores, nunca por el centro ni por
-- los bordes de arriba: así el efecto no tapa el punto de mira ni el HUD. El
-- exponente sesga la distribución hacia el vértice para que se lea como esquina
-- y no como una banda; las esquinas se alternan para que no se agolpen en una.
local CORNER_SPREAD_X = 0.26 -- fracción de ancho desde el lateral
local CORNER_SPREAD_Y = 0.34 -- fracción de alto desde abajo
local CORNER_BIAS = 1.7      -- >1 concentra hacia el vértice
local _spawnFromLeft = false

-- Devuelve la posición de salida y hacia dónde deriva en horizontal (+1 desde la
-- esquina izquierda, -1 desde la derecha), para que suban abriéndose hacia dentro.
local function getCornerSpawn(): (UDim2, number)
	_spawnFromLeft = not _spawnFromLeft
	local offsetX = (math.random() ^ CORNER_BIAS) * CORNER_SPREAD_X
	local offsetY = (math.random() ^ CORNER_BIAS) * CORNER_SPREAD_Y
	local x = if _spawnFromLeft then offsetX else 1 - offsetX
	return UDim2.fromScale(x, 1 - offsetY), if _spawnFromLeft then 1 else -1
end

-- Tamaño relativo a 1080p: antes eran offsets fijos en px, así que en móvil un
-- "+" grande se comía media pantalla mientras que en 1440p apenas se veía. El
-- clamp evita que desaparezcan en resoluciones muy bajas o crezcan de más en 4K.
local SIZE_REFERENCE_HEIGHT = 1080
local SIZE_SCALE_MIN = 0.55
local SIZE_SCALE_MAX = 1.15

local function getSizeScale(gui: ScreenGui): number
	local height = gui.AbsoluteSize.Y
	if height <= 0 then
		return 1
	end
	return math.clamp(height / SIZE_REFERENCE_HEIGHT, SIZE_SCALE_MIN, SIZE_SCALE_MAX)
end

-- P8: cap duro de ImageLabels concurrentes. Sin esto, un heal genera ~45
-- partículas y heals encadenados podían acumular cientos de instancias en mobile.
local MAX_ACTIVE_HEAL_IMAGES = 20
local activeHealImages = 0

-- Una partícula de curación: aparece creciendo desde una esquina inferior, sube
-- abriéndose hacia dentro girando levemente y se desvanece. Se auto-destruye al
-- terminar.
local function spawnHealImage()
	local gui = screenGui
	if not gui then
		return
	end

	-- P8: no superar el cap concurrente; el efecto degrada en densidad, no en
	-- duración (el loop sigue llamando y respawnea conforme se liberan slots).
	if activeHealImages >= MAX_ACTIVE_HEAL_IMAGES then
		return
	end

	-- Tamaño en tres niveles: pequeños, medianos y grandes. Los px son la
	-- referencia a 1080p; getSizeScale los adapta a la resolución real. Los
	-- grandes viven algo más porque recorren más pantalla.
	local sizeScale = getSizeScale(gui)
	local targetSize, depth, lifetime
	local roll = math.random()
	if roll < 0.10 then
		targetSize, depth, lifetime = math.random(74, 108), "front", 0.95
	elseif roll < 0.30 then
		targetSize, depth, lifetime = math.random(44, 66), "front", 0.8
	else
		targetSize, depth, lifetime = math.random(21, 38), "back", 0.65
	end
	targetSize = math.max(8, math.floor(targetSize * sizeScale))

	-- Profundidad: fondo tenue y detrás, frente nítido y delante.
	local maxOpacity = if depth == "front" then 0.1 else 0.4
	local zIndex = if depth == "front" then 20 else 8

	local spawnPos, inwardDir = getCornerSpawn()

	local img = Instance.new("ImageLabel")
	img.Image = IMAGE_ID
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Size = UDim2.fromOffset(math.floor(targetSize * 0.4), math.floor(targetSize * 0.4))
	img.Position = spawnPos
	img.ImageColor3 = HEAL_COLOR
	img.ImageTransparency = 1
	img.Rotation = math.random(-8, 8)
	img.ZIndex = zIndex
	img.Parent = gui
	activeHealImages += 1

	-- Suben abriéndose hacia el centro (el componente horizontal apunta hacia
	-- dentro desde su esquina), como un pequeño surtidor.
	local startPos = img.Position
	local driftPos = startPos
		+ UDim2.new(inwardDir * math.random(10, 45) / 1000, 0, -math.random(70, 120) / 1000, 0)
	local endRotation = img.Rotation + math.random(-6, 6)

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
		Size = UDim2.fromOffset(math.floor(targetSize * 0.75), math.floor(targetSize * 0.75)),
		Rotation = endRotation,
	})

	appear:Play()
	appear.Completed:Once(function()
		fade:Play()
	end)
	fade.Completed:Once(function()
		img:Destroy()
		activeHealImages -= 1
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
			local spawnRate = 0.17 - (0.05 * intensity)
			spawnHealImage()
			if intensity > 0.6 and math.random() < 0.35 then
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
