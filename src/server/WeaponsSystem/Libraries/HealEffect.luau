--!strict
-- "+" verdes que suben desde las esquinas inferiores al ganar salud (lo dispara
-- HealthBarController). El tinte verde de bordes es el Vignette de WeaponsSystemGui
-- (HealAlphaDriver); aquí solo las partículas, parentadas a WeaponsSystemGui. Cada
-- play() corre una envolvente de intensidad que modula el ritmo de spawn; un token
-- invalida el loop viejo si llega otra curación o un respawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

local AssetIds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("AssetIds"))

local IMAGE_ID = AssetIds.Images.HealPlus
local HEAL_COLOR = Color3.fromRGB(120, 255, 150)

local HealEffect = {}

local activeToken = 0

-- WeaponsSystemGui se re-resuelve en cada spawn: la GUI puede recrearse y no
-- queremos quedarnos con una referencia muerta.
local function getGui(): ScreenGui?
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local gui = playerGui and playerGui:FindFirstChild("WeaponsSystemGui")
	if gui and gui:IsA("ScreenGui") then
		return gui
	end
	return nil
end

-- Solo desde las esquinas inferiores, para no tapar la mira ni el HUD. El exponente
-- sesga hacia el vértice; las esquinas se alternan.
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

-- Tamaño relativo a 1080p para que se vea igual en móvil y en 1440p; el clamp evita
-- extremos en resoluciones muy bajas o en 4K.
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

-- Cap de ImageLabels concurrentes: heals encadenados acumulaban cientos de instancias en móvil.
local MAX_ACTIVE_HEAL_IMAGES = 20
local activeHealImages = 0

local function spawnHealImage()
	local gui = getGui()
	if not gui then
		return
	end

	-- Al llegar al cap el efecto degrada en densidad, no en duración.
	if activeHealImages >= MAX_ACTIVE_HEAL_IMAGES then
		return
	end

	-- Tres niveles de tamaño (px a 1080p); los grandes viven más porque recorren más pantalla.
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
	img.Name = "HealPlus"
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

	-- Si la GUI se destruye con partículas en vuelo, los tweens no completan:
	-- liberamos el slot igualmente para no dejar el cap bloqueado.
	local released = false
	local function release()
		if released then
			return
		end
		released = true
		activeHealImages -= 1
	end
	img.Destroying:Once(release)

	local startPos = img.Position
	local driftPos = startPos
		+ UDim2.new(inwardDir * math.random(10, 45) / 1000, 0, -math.random(70, 120) / 1000, 0)
	local endRotation = img.Rotation + math.random(-6, 6)

	local appearInfo = TweenInfo.new(lifetime * 0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local appear = TweenService:Create(img, appearInfo, {
		Size = UDim2.fromOffset(targetSize, targetSize),
		ImageTransparency = maxOpacity,
		Rotation = img.Rotation + (endRotation - img.Rotation) * 0.5,
	})

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

-- Si ya hay un efecto en curso, lo reemplaza.
function HealEffect.play(duration: number?)
	if not getGui() then
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
	end)
end

-- Corta cualquier efecto en curso (p. ej. al respawnear). Las partículas en
-- vuelo se auto-destruyen solas vía sus tweens.
function HealEffect.reset()
	activeToken += 1
end

return HealEffect
