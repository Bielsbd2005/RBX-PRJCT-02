local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local DISPLAY_TIME = 3.5
local HEADSHOT_BONUS_XP = 50
local MAX_NOTIFS = 5

local currentNotificationOrder = 0

-- ==============================================================================
-- Tiempos de Animación HEAVY
-- ==============================================================================
-- Entrada
local TI_HEAVY_MOVE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
local TI_HEAVY_PUNCH_IN = TweenInfo.new(0.6, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local TI_HEAVY_COLOR_FLASH = TweenInfo.new(0.15, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

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
	local gui = playerGui:FindFirstChild("PersonalKillFeed")
	if not gui then return nil end
	return gui:FindFirstChild("KillFeed")
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

local function tweenChildrenTransparency(parent, info, target)
	applyTransparency(parent, info, target)
	for _, d in ipairs(parent:GetDescendants()) do
		applyTransparency(d, info, target)
	end
end

local function setInitialTransparency(parent)
	setObjTransparency(parent, 1)
	for _, d in ipairs(parent:GetDescendants()) do
		setObjTransparency(d, 1)
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

	local uiScale = Instance.new("UIScale")
	uiScale.Parent = frame

	frame.Position = UDim2.new(0, 80, 0, 0)
	uiScale.Scale = isHeadshot and 1.6 or 1.4
	frame.Rotation = isHeadshot and 10 or 6

	local originalColor = frame.BackgroundColor3
	if isHeadshot then
		frame.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	else
		frame.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	end

	setInitialTransparency(frame)
	frame.Visible = true

	frame.Parent = wrapper
	wrapper.Parent = container

	TweenService:Create(frame, TI_HEAVY_MOVE_IN, {Position = UDim2.new(0, 0, 0, 0), Rotation = 0}):Play()
	TweenService:Create(uiScale, TI_HEAVY_PUNCH_IN, {Scale = 1}):Play()

	tweenChildrenTransparency(frame, TI_HEAVY_COLOR_FLASH, 0)
	TweenService:Create(frame, TI_HEAVY_COLOR_FLASH, {BackgroundColor3 = originalColor}):Play()

	return wrapper
end

function PersonalKillFeed.showKill(victimName, xpGained, wasHeadshot)
	local container = getContainer()
	if not container then return end

	local function spawnKO()
		local koTemplate = script:FindFirstChild("KO")
		if koTemplate then
			local koFrame = koTemplate:Clone()
			local victimLabel = koFrame:FindFirstChild("Victim")
			local koXpLabel = koFrame:FindFirstChild("XP")

			if victimLabel then victimLabel.Text = victimName end
			if koXpLabel then koXpLabel.Text = tostring(xpGained) end

			local koWrapper = slideInFromRight(koFrame, container, false)
			manageQueue(koFrame, koWrapper)
		end
	end

	if wasHeadshot then
		local headshotTemplate = script:FindFirstChild("Headshot")
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

return PersonalKillFeed
