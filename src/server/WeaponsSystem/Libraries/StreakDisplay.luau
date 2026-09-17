-- HUD de racha de bajas SIN MORIR (cliente) en WeaponSystemInsets.Streak (con
-- fallback a WeaponsSystemGui.Streak):
--   • Streak.Value (texto): DOUBLE, TRIPLE, QUAD!, QUINTUPLE!!, "<N> KILLSTREAK!"
--   • Streak.Image (ImageLabel): spritesheet animado en bucle mientras es visible.
--
-- La racha la dirige el cliente: cada PlayerEliminated dirigido al killer local
-- incrementa el contador (NetworkingCallbacks.PlayerEliminated); morir la resetea.
-- Es independiente del packet PlayerStreakState del marcador (server-authoritative).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local AssetIds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("AssetIds"))

-- Parámetros del spritesheet: deben coincidir con el asset.
local SHEET_IMAGE = AssetIds.Images.StreakSheet
local FPS = 12
local COLUMNS = 4
local FRAME_WIDTH = 128
local FRAME_HEIGHT = 128
local TOTAL_FRAMES = 12
local FRAME_TIME = 1 / FPS

local MIN_STREAK = 2

local TI_PUNCH = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local PUNCH_SCALE = 1.35

local TI_FADE_IN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_FADE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local StreakDisplay = {}

local _count = 0
local _shown = false

-- Token del bucle de animación activo: resetear/ocultar lo incrementa y el bucle
-- en curso sale en su siguiente iteración. Nunca corre más de un bucle.
local _animToken = 0
local _animating = false

-- Token análogo para el fade-out: si una nueva racha empieza mientras el HUD se
-- desvanece, el "ocultar al terminar" diferido se invalida.
local _fadeToken = 0

-- Se re-resuelve en cada uso (como PersonalKillFeed): la GUI se clona de forma
-- asíncrona y puede no existir al requerir. WeaponsSystemGui es el fallback del
-- asset antiguo.
local HUD_GUI_NAMES = { "WeaponSystemInsets", "WeaponsSystemGui" }

local function getStreakFrame(): GuiObject?
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil end
	for _, guiName in HUD_GUI_NAMES do
		local gui = playerGui:FindFirstChild(guiName)
		if gui then
			-- Hijo directo o anidado (p. ej. bajo ScalingElements).
			local streak = gui:FindFirstChild("Streak") or gui:FindFirstChild("Streak", true)
			if streak and streak:IsA("GuiObject") then
				return streak
			end
		end
	end
	return nil
end

local function getImageLabel(streak: GuiObject): ImageLabel?
	local img = streak:FindFirstChild("Image")
	if img and img:IsA("ImageLabel") then
		return img
	end
	local found = streak:FindFirstChildWhichIsA("ImageLabel", true)
	return found
end

local function labelForStreak(n: number): string
	if n == 2 then
		return "DOUBLE"
	elseif n == 3 then
		return "TRIPLE"
	elseif n == 4 then
		return "QUAD!"
	elseif n == 5 then
		return "QUINTUPLE!!"
	end
	return tostring(n) .. " KILLSTREAK!"
end

local function setStreakText(streak: GuiObject, text: string)
	local valueObj = streak:FindFirstChild("Value")
	if not valueObj then return end
	if valueObj:IsA("TextLabel") or valueObj:IsA("TextButton") or valueObj:IsA("TextBox") then
		valueObj.Text = text
	elseif valueObj:IsA("StringValue") then
		valueObj.Value = text
	else
		local textNode = valueObj:FindFirstChildWhichIsA("TextLabel", true)
			or valueObj:FindFirstChildWhichIsA("TextButton", true)
		if textNode then
			(textNode :: any).Text = text
		end
	end
end

local function startAnimation(imageLabel: ImageLabel)
	if _animating then return end -- no reiniciar: evitaría el salto a frame 0
	_animating = true
	_animToken += 1
	local myToken = _animToken

	imageLabel.Image = SHEET_IMAGE
	imageLabel.ImageRectSize = Vector2.new(FRAME_WIDTH, FRAME_HEIGHT)
	imageLabel.BackgroundTransparency = 1

	task.spawn(function()
		local index = 0
		while _animToken == myToken do
			if not imageLabel.Parent then
				if _animToken == myToken then
					_animating = false
				end
				return
			end
			local col = index % COLUMNS
			local row = math.floor(index / COLUMNS)
			imageLabel.ImageRectOffset = Vector2.new(col * FRAME_WIDTH, row * FRAME_HEIGHT)
			index = (index + 1) % TOTAL_FRAMES
			task.wait(FRAME_TIME)
		end
	end)
end

local function stopAnimation()
	_animToken += 1
	_animating = false
end

-- Punch de escala reutilizando/creando una UIScale (no apilar varias: Roblox
-- sólo aplica una y el punch no se vería).
local function punch(streak: GuiObject)
	local uiScale = streak:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = streak
	end
	uiScale.Scale = PUNCH_SCALE
	TweenService:Create(uiScale, TI_PUNCH, { Scale = 1 }):Play()
end

local function setObjTransparency(obj: Instance, t: number)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		obj.TextTransparency = t
	elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		obj.ImageTransparency = t
	elseif obj:IsA("UIStroke") then
		obj.Transparency = t
	elseif obj:IsA("Frame") and obj.BackgroundTransparency < 1 then
		obj.BackgroundTransparency = t
	end
end

local function tweenObjTransparency(obj: Instance, info: TweenInfo, t: number)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		TweenService:Create(obj, info, { TextTransparency = t }):Play()
	elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		TweenService:Create(obj, info, { ImageTransparency = t }):Play()
	elseif obj:IsA("UIStroke") then
		TweenService:Create(obj, info, { Transparency = t }):Play()
	elseif obj:IsA("Frame") and obj.BackgroundTransparency < 1 then
		TweenService:Create(obj, info, { BackgroundTransparency = t }):Play()
	end
end

local function fadeIn(streak: GuiObject)
	setObjTransparency(streak, 1)
	for _, obj in streak:GetDescendants() do
		setObjTransparency(obj, 1)
	end
	streak.Visible = true
	tweenObjTransparency(streak, TI_FADE_IN, 0)
	for _, obj in streak:GetDescendants() do
		tweenObjTransparency(obj, TI_FADE_IN, 0)
	end
end

local function fadeOut(streak: GuiObject)
	tweenObjTransparency(streak, TI_FADE_OUT, 1)
	for _, obj in streak:GetDescendants() do
		tweenObjTransparency(obj, TI_FADE_OUT, 1)
	end
end

function StreakDisplay.onKill()
	_count += 1
	if _count < MIN_STREAK then
		return
	end

	local streak = getStreakFrame()
	if not streak then return end

	setStreakText(streak, labelForStreak(_count))

	local imageLabel = getImageLabel(streak)
	if imageLabel then
		startAnimation(imageLabel)
	end

	if not _shown then
		_shown = true
		_fadeToken += 1
		fadeIn(streak)
	else
		streak.Visible = true
	end

	punch(streak)
end

function StreakDisplay.reset()
	_count = 0

	local streak = getStreakFrame()
	if not streak then
		_shown = false
		stopAnimation()
		return
	end

	if not _shown then
		streak.Visible = false
		stopAnimation()
		return
	end

	_shown = false
	_fadeToken += 1
	local myToken = _fadeToken
	fadeOut(streak)

	task.delay(TI_FADE_OUT.Time, function()
		if myToken ~= _fadeToken then
			return
		end
		streak.Visible = false
		stopAnimation()
	end)
end

function StreakDisplay.getStreak(): number
	return _count
end

-- Oculta el HUD en cuanto la GUI exista, por si la plantilla viene Visible=true
-- desde Studio.
task.spawn(function()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 30)
	-- WeaponsGui parenta WeaponSystemInsets antes que WeaponsSystemGui, así que
	-- cuando existe la principal ya se puede resolver la de insets sin esperar.
	local mainGui = playerGui and playerGui:WaitForChild("WeaponsSystemGui", 30)
	if not mainGui then return end
	local host = playerGui:FindFirstChild("WeaponSystemInsets") or mainGui
	local streak = host:WaitForChild("Streak", 30)
	if streak and streak:IsA("GuiObject") then
		streak.Visible = false
	end
end)

return StreakDisplay
