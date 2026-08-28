-- StreakDisplay.luau
-- HUD de racha de bajas SIN MORIR (cliente). Cuenta las eliminaciones
-- consecutivas del jugador local y las muestra en WeaponsSystemGui.Streak:
--   • Streak.Value (texto): DOUBLE, TRIPLE, QUAD!, QUINTUPLE!!, "<N> KILLSTREAK!"
--   • Streak.Image (ImageLabel): spritesheet animado en bucle mientras es visible.
--
-- La racha la dirige el cliente: cada PlayerEliminated dirigido al killer local
-- incrementa el contador (ver NetworkingCallbacks.PlayerEliminated); morir lo
-- resetea (Humanoid.Died / respawn). Es un popup puramente local — no toca el
-- packet PlayerStreakState del marcador (server-authoritative, otro concepto).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local AssetIds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("AssetIds"))

-- ── Spritesheet (parámetros del asset) ────────────────────────────────────────
local SHEET_IMAGE = AssetIds.Images.StreakSheet
local FPS = 12
local COLUMNS = 4
local FRAME_WIDTH = 128
local FRAME_HEIGHT = 128
local TOTAL_FRAMES = 12
local FRAME_TIME = 1 / FPS

-- La racha empieza a mostrarse en la 2ª baja (DOUBLE). 1 baja no es racha.
local MIN_STREAK = 2

-- Punch elástico de escala en cada nueva baja (juice, en línea con el killfeed).
local TI_PUNCH = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local PUNCH_SCALE = 1.35

-- Fade de entrada (al abrir la racha) y de salida (al morir): el HUD no aparece
-- ni desaparece de golpe.
local TI_FADE_IN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_FADE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local StreakDisplay = {}

local _count = 0
local _shown = false -- ¿el HUD está actualmente visible (post fade-in)?

-- Token monotónico que identifica el bucle de animación activo. Resetear/ocultar
-- lo incrementa, y el bucle en curso sale en su siguiente iteración (su token
-- deja de coincidir). Garantiza que nunca corra más de un bucle a la vez.
local _animToken = 0
local _animating = false

-- Token análogo para el fade-out: si una nueva racha empieza mientras el HUD se
-- desvanece, el "ocultar al terminar" diferido se invalida.
local _fadeToken = 0

-- ── Resolución de la GUI ──────────────────────────────────────────────────────
-- Se re-resuelve en cada uso (como PersonalKillFeed): la WeaponsSystemGui se
-- clona/parchea de forma asíncrona y puede no existir todavía al requerir.
local function getStreakFrame(): GuiObject?
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil end
	local gui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not gui then return nil end
	-- Primero hijo directo (estructura esperada: WeaponsSystemGui.Streak); si no,
	-- búsqueda recursiva por si vive anidado bajo ScalingElements u otro contenedor.
	local streak = gui:FindFirstChild("Streak") or gui:FindFirstChild("Streak", true)
	if streak and streak:IsA("GuiObject") then
		return streak
	end
	return nil
end

local function getImageLabel(streak: GuiObject): ImageLabel?
	local img = streak:FindFirstChild("Image")
	if img and img:IsA("ImageLabel") then
		return img
	end
	-- Fallback: cualquier ImageLabel descendiente.
	local found = streak:FindFirstChildWhichIsA("ImageLabel", true)
	return found
end

-- Texto de la racha según el número de bajas consecutivas.
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

-- Escribe el texto en Streak.Value, sea TextLabel/TextButton/TextBox o un *Value.
local function setStreakText(streak: GuiObject, text: string)
	local valueObj = streak:FindFirstChild("Value")
	if not valueObj then return end
	if valueObj:IsA("TextLabel") or valueObj:IsA("TextButton") or valueObj:IsA("TextBox") then
		valueObj.Text = text
	elseif valueObj:IsA("StringValue") then
		valueObj.Value = text
	else
		-- Value es un contenedor: busca un nodo de texto dentro.
		local textNode = valueObj:FindFirstChildWhichIsA("TextLabel", true)
			or valueObj:FindFirstChildWhichIsA("TextButton", true)
		if textNode then
			(textNode :: any).Text = text
		end
	end
end

-- ── Animación del spritesheet ─────────────────────────────────────────────────
local function startAnimation(imageLabel: ImageLabel)
	if _animating then return end -- ya hay un bucle vivo; no reiniciar (evita salto a frame 0)
	_animating = true
	_animToken += 1
	local myToken = _animToken

	imageLabel.Image = SHEET_IMAGE
	imageLabel.ImageRectSize = Vector2.new(FRAME_WIDTH, FRAME_HEIGHT)
	imageLabel.BackgroundTransparency = 1

	task.spawn(function()
		local index = 0
		while _animToken == myToken do
			-- Si el label desaparece (GUI re-clonada), abandona el bucle.
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
	_animToken += 1 -- invalida el bucle en curso
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

-- ── Fade in/out de transparencia ──────────────────────────────────────────────
-- Aplica/anima la transparencia según el tipo de elemento (mismo criterio que
-- PersonalKillFeed): texto, imagen, stroke o fondo de frame.
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

-- Estado opaco inicial + tween a 0 (visible). El frame entra desde transparente.
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

-- ── API pública ───────────────────────────────────────────────────────────────

-- Una eliminación del jugador local. Incrementa la racha y refresca el HUD.
function StreakDisplay.onKill()
	_count += 1
	if _count < MIN_STREAK then
		return -- 1 baja todavía no es racha visible
	end

	local streak = getStreakFrame()
	if not streak then return end

	setStreakText(streak, labelForStreak(_count))

	local imageLabel = getImageLabel(streak)
	if imageLabel then
		startAnimation(imageLabel)
	end

	if not _shown then
		-- Primera baja de la racha → fade-in (cancela cualquier fade-out pendiente).
		_shown = true
		_fadeToken += 1
		fadeIn(streak)
	else
		streak.Visible = true
	end

	punch(streak)
end

-- Morir / respawnear: corta la racha y oculta el HUD (con fade-out si estaba visible).
function StreakDisplay.reset()
	_count = 0

	local streak = getStreakFrame()
	if not streak then
		_shown = false
		stopAnimation()
		return
	end

	if not _shown then
		-- No estaba visible: oculta directo, sin fade.
		streak.Visible = false
		stopAnimation()
		return
	end

	_shown = false
	_fadeToken += 1
	local myToken = _fadeToken
	fadeOut(streak)

	-- Oculta y detiene el spritesheet al terminar el fade — salvo que una nueva
	-- racha lo haya retomado entretanto (token cambiado).
	task.delay(TI_FADE_OUT.Time, function()
		if myToken ~= _fadeToken then
			return
		end
		streak.Visible = false
		stopAnimation()
	end)
end

-- Estado actual (por si algún otro sistema lo quiere consultar).
function StreakDisplay.getStreak(): number
	return _count
end

-- Al cargar: oculta el HUD en cuanto la GUI exista, por si la plantilla viene
-- Visible=true desde Studio. Espera una sola vez (no es un bucle de polling).
task.spawn(function()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 30)
	local gui = playerGui and playerGui:WaitForChild("WeaponsSystemGui", 30)
	local streak = gui and gui:WaitForChild("Streak", 30)
	if streak and streak:IsA("GuiObject") then
		streak.Visible = false
	end
end)

return StreakDisplay
