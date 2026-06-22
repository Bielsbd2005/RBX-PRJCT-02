local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local ActionRewards = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ActionRewards"))

local DISPLAY_TIME = 3.5
-- Lee de ActionRewards para que la UI no mienta si el valor cambia (es la
-- misma cifra que MatchService concede vía RewardService.Award(_, "Headshot")).
local HEADSHOT_BONUS_XP = ActionRewards.GetXP("Headshot")
local MAX_NOTIFS = 5

-- Count-up animado del XP del KO ("+ X" con los números subiendo hasta el
-- objetivo). Para cifras grandes no se cuenta desde 0: se anima sólo el último
-- tramo (XP_COUNT_UP_MAX_SPAN), así no tarda eternamente ni salta de golpe.
local XP_COUNT_UP_TIME = 0.45
local XP_COUNT_UP_MAX_SPAN = 200

local currentNotificationOrder = 0

-- ==============================================================================
-- Tiempos de Animación HEAVY
-- ==============================================================================
-- Entrada "juicy": slam con overshoot + punch elástico + flash de impacto.
local TI_SLAM_IN    = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out)    -- posición (se pasa de 0 y vuelve)
local TI_PUNCH_IN   = TweenInfo.new(0.55, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out) -- escala (rebota alrededor de 1)
local TI_WOBBLE_IN  = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)      -- rotación settle (wobble)
local TI_CONTENT_IN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)     -- contenido aparece casi instantáneo

-- Salida (NUEVA: Directa a la Izquierda, sin rebote)
-- Usamos Exponential.In: Acelera brutalmente hacia la izquierda de forma limpia.
local TI_SWIPE_OUT_LEFT = TweenInfo.new(0.3, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
local TI_FADE_OUT_LEFT = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- ==============================================================================

local PersonalKillFeed = {}
local activeNotifications = {}

local function getContainer()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil end
	local gui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not gui then return nil end
	local killFeed = gui:FindFirstChild("KillFeed")
	if not killFeed or not killFeed:IsA("GuiObject") then return nil end
	return killFeed
end

local function getTemplate(templateName)
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		local gui = playerGui:FindFirstChild("WeaponsSystemGui")
		if gui then
			local templatesFolder = gui:FindFirstChild("KillFeedTemplates")
			if templatesFolder then
				local template = templatesFolder:FindFirstChild(templateName)
				if template and template:IsA("GuiObject") then
					return template
				end
			end

			local killFeed = gui:FindFirstChild("KillFeed")
			if killFeed then
				local template = killFeed:FindFirstChild(templateName)
				if template and template:IsA("GuiObject") then
					return template
				end
			end
		end
	end

	local localTemplate = script:FindFirstChild(templateName)
	if localTemplate and localTemplate:IsA("GuiObject") then
		return localTemplate
	end

	return nil
end

local function setObjTransparency(obj, target)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then obj.TextTransparency = target
	elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then obj.ImageTransparency = target
	elseif obj:IsA("UIStroke") then obj.Transparency = target
	elseif obj:IsA("Frame") and obj.BackgroundTransparency < 1 then obj.BackgroundTransparency = target end
end

local function applyTransparency(obj, info, target)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		TweenService:Create(obj, info, { TextTransparency = target }):Play()
	elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		TweenService:Create(obj, info, { ImageTransparency = target }):Play()
	elseif obj:IsA("UIStroke") then
		TweenService:Create(obj, info, { Transparency = target }):Play()
	elseif obj:IsA("Frame") and obj.BackgroundTransparency < 1 then
		TweenService:Create(obj, info, { BackgroundTransparency = target }):Play()
	end
end

-- Audit mobile: cache de descendants por instancia (frame de notification).
-- tweenChildrenTransparency se invoca 2× por notification (fade-in + fade-out),
-- antes hacía GetDescendants() en cada llamada → 2× iter por notification.
-- Con KO/Headshot/Assist en cadena el cost se acumula.
local _descendantsCache: { [Instance]: { Instance } } = setmetatable({}, { __mode = "k" }) :: any

local function _getCachedDescendants(parent: Instance): { Instance }
	local cached = _descendantsCache[parent]
	if cached then
		return cached
	end
	local list: { Instance } = { parent }
	for _, d in parent:GetDescendants() do
		table.insert(list, d)
	end
	_descendantsCache[parent] = list
	return list
end

local function tweenChildrenTransparency(parent, info, target)
	for _, obj in _getCachedDescendants(parent) do
		applyTransparency(obj, info, target)
	end
end

local function setInitialTransparency(parent)
	for _, obj in _getCachedDescendants(parent) do
		setObjTransparency(obj, 1)
	end
end

local function slideOutAndDestroy(notificationData)
	local frame = notificationData.frame
	local wrapper = notificationData.wrapper

	if not frame or not wrapper or notificationData.isDestroying then return end
	notificationData.isDestroying = true

	local uiScale = frame:FindFirstChildOfClass("UIScale")

	-- SALIDA LIMPIA Y DIRECTA
	-- Va recto a X = -600. Quitamos cualquier rotación para que sea rígido y limpio.
	local exitMove = TweenService:Create(frame, TI_SWIPE_OUT_LEFT, {
		Position = UDim2.new(0, -600, 0, 0),
		Rotation = 0
	})

	tweenChildrenTransparency(frame, TI_FADE_OUT_LEFT, 1)

	-- Se reduce ligeramente mientras se va para dar sensación de velocidad
	if uiScale then
		TweenService:Create(uiScale, TI_SWIPE_OUT_LEFT, {Scale = 0.8}):Play()
	end

	exitMove:Play()

	exitMove.Completed:Once(function()
		if wrapper then wrapper:Destroy() end
	end)
end

local function manageQueue(newFrame, newWrapper)
	local notificationData = {
		frame = newFrame,
		wrapper = newWrapper,
		isDestroying = false
	}

	table.insert(activeNotifications, notificationData)

	if #activeNotifications > MAX_NOTIFS then
		local oldestNotification = table.remove(activeNotifications, 1)
		slideOutAndDestroy(oldestNotification)
	end

	task.delay(DISPLAY_TIME, function()
		local index = table.find(activeNotifications, notificationData)
		if index then
			table.remove(activeNotifications, index)
			slideOutAndDestroy(notificationData)
		end
	end)
end

local function slideInFromRight(frame, container, isHeadshot)
	local wrapper = Instance.new("Frame")
	wrapper.Name = frame.Name .. "_Wrapper"
	wrapper.BackgroundTransparency = 1

	currentNotificationOrder -= 1
	wrapper.LayoutOrder = currentNotificationOrder

	local camera = workspace.CurrentCamera
	local screenY = camera and camera.ViewportSize.Y or 600
	if container.Parent and container.Parent:IsA("ScreenGui") then
		screenY = container.Parent.AbsoluteSize.Y
	end

	local fixedY = frame.Size.Y.Offset
	if frame.Size.Y.Scale > 0 then
		local baseContainerScaleY = container.Size.Y.Scale
		if baseContainerScaleY == 0 then baseContainerScaleY = 0.3 end
		local baseContainerHeight = (baseContainerScaleY * screenY) + container.Size.Y.Offset
		fixedY = math.floor(frame.Size.Y.Scale * baseContainerHeight) + frame.Size.Y.Offset
	end

	wrapper.Size = UDim2.new(0, 0, 0, fixedY)
	wrapper.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.new(0, 0, 1, 0)

	-- Reusar la UIScale de la plantilla si la trae (las templates nuevas KO/
	-- Headshot ya incluyen una). Crear una nueva además dejaría dos UIScale en
	-- el mismo frame y Roblox sólo aplica una → el punch-in no se vería.
	local uiScale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	uiScale.Parent = frame

	-- ── Estado inicial (pre-animación) ─────────────────────────────────────
	-- Entra desde la derecha, sobredimensionado e inclinado. El headshot pega
	-- más fuerte. El fondo del frame es transparente (el look viene del
	-- contenido), así que NO tocamos BackgroundTransparency/Color: la juice es
	-- puro movimiento.
	local startOffsetX = isHeadshot and 130 or 110
	local startScale = isHeadshot and 1.95 or 1.5
	local startRot = isHeadshot and 13 or 7

	frame.Position = UDim2.new(0, startOffsetX, 0, 0)
	uiScale.Scale = startScale
	frame.Rotation = startRot

	setInitialTransparency(frame)
	frame.Visible = true

	frame.Parent = wrapper
	wrapper.Parent = container

	-- ── Animaciones de entrada (en paralelo) ───────────────────────────────
	TweenService:Create(frame, TI_SLAM_IN, { Position = UDim2.new(0, 0, 0, 0) }):Play() -- slam con overshoot
	TweenService:Create(frame, TI_WOBBLE_IN, { Rotation = 0 }):Play()                    -- rotación con wobble propio
	TweenService:Create(uiScale, TI_PUNCH_IN, { Scale = 1 }):Play()                      -- punch elástico
	tweenChildrenTransparency(frame, TI_CONTENT_IN, 0)                                   -- contenido aparece rápido

	return wrapper
end

-- Anima el texto de `label` como "+ N" subiendo desde un valor inicial hasta
-- `target` con easing. Cifras pequeñas cuentan desde 0; las grandes empiezan en
-- target - XP_COUNT_UP_MAX_SPAN. Aborta solo si la etiqueta se destruye antes.
local function animateXpCountUp(label, xpGained)
	local target = tonumber(xpGained) or 0
	local startValue = if target > XP_COUNT_UP_MAX_SPAN then target - XP_COUNT_UP_MAX_SPAN else 0
	local span = target - startValue
	if span <= 0 then
		label.Text = "+ " .. tostring(target)
		return
	end

	label.Text = "+ " .. tostring(startValue)
	local startClock = os.clock()
	task.spawn(function()
		while true do
			if not label.Parent then return end -- notificación expirada/expulsada
			local t = (os.clock() - startClock) / XP_COUNT_UP_TIME
			if t >= 1 then
				label.Text = "+ " .. tostring(target)
				return
			end
			-- easeOutCubic: arranca rápido y desacelera al llegar al objetivo.
			local eased = 1 - (1 - t) ^ 3
			label.Text = "+ " .. tostring(math.floor(startValue + span * eased + 0.5))
			task.wait()
		end
	end)
end

function PersonalKillFeed.showKill(victimName, xpGained, wasHeadshot)
	local container = getContainer()
	if not container then return end

	local function spawnKO()
		local koTemplate = getTemplate("KO")
		if koTemplate then
			local koFrame = koTemplate:Clone()
			local victimLabel = koFrame:FindFirstChild("Victim")
			local koXpLabel = koFrame:FindFirstChild("XP")

			if victimLabel then victimLabel.Text = victimName end
			if koXpLabel then animateXpCountUp(koXpLabel, xpGained) end

			local koWrapper = slideInFromRight(koFrame, container, false)
			manageQueue(koFrame, koWrapper)
		end
	end

	if wasHeadshot then
		local headshotTemplate = getTemplate("Headshot")
		if headshotTemplate then
			local headshotFrame = headshotTemplate:Clone()
			local hsXpLabel = headshotFrame:FindFirstChild("XP")

			if hsXpLabel then hsXpLabel.Text = tostring(HEADSHOT_BONUS_XP) end

			local headshotWrapper = slideInFromRight(headshotFrame, container, true)
			manageQueue(headshotFrame, headshotWrapper)
		end

		task.delay(0.18, function()
			if not container or not container.Parent then return end
			spawnKO()
		end)
	else
		spawnKO()
	end
end

function PersonalKillFeed.showAssist()
	local container = getContainer()
	if not container then return end

	local assistTemplate = getTemplate("Assist")
	if not assistTemplate then return end

	local assistFrame = assistTemplate:Clone()

	local assistWrapper = slideInFromRight(assistFrame, container, false)
	manageQueue(assistFrame, assistWrapper)
end

return PersonalKillFeed
