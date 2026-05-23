local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local CONFIG = {
	TWEEN_SPEED    = 0.4,
	FADE_SPEED     = 0.3,
	MAX_BADGES     = 3,
	BADGE_LIFESPAN = 2,

	SIDE_SIZE      = UDim2.fromScale(0.0828125, 0.183984),
	CENTER_SIZE    = UDim2.fromScale(0.102604,  0.241082),

	SPAWN_ROTATION = -15,
	EXIT_ROTATION  = 15,
}

local BADGE_MAP = {
	Kill        = "rbxassetid://130873581439859",
	DoubleKill  = "rbxassetid://130873581439859",
	TripleKill  = "rbxassetid://130873581439859",
	Rampage     = "rbxassetid://130873581439859",
	Godlike     = "rbxassetid://130873581439859",
}

local function buildGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("PersonalKillFeed")
	if existing then
		local bf = existing:FindFirstChild("BadgeFrame")
		if bf then return bf end
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name            = "PersonalKillFeed"
	screenGui.IgnoreGuiInset  = true
	screenGui.ResetOnSpawn    = false
	screenGui.ScreenInsets    = Enum.ScreenInsets.DeviceSafeInsets
	screenGui.Parent          = playerGui

	local badgeFrame = Instance.new("Frame")
	badgeFrame.Name                = "BadgeFrame"
	badgeFrame.AutomaticSize       = Enum.AutomaticSize.XY
	badgeFrame.BackgroundTransparency = 1
	badgeFrame.AnchorPoint         = Vector2.new(0.5, 0)
	badgeFrame.Position            = UDim2.fromScale(0.5, 0.08)
	badgeFrame.Size                = UDim2.fromOffset(0, 0)
	badgeFrame.Parent              = screenGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection        = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment  = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment    = Enum.VerticalAlignment.Center
	layout.Padding              = UDim.new(0.02, 0)
	layout.SortOrder            = Enum.SortOrder.LayoutOrder
	layout.Parent               = badgeFrame

	return badgeFrame
end

local activeBadges  = {}
local pendingQueue  = {}
local isProcessing  = false
local badgeFrame    = nil
-- Audit mobile: generation token. Antes los task.delay(BADGE_LIFESPAN, ...)
-- programados antes de clear() seguían disparándose y manipulaban activeBadges
-- (que clear acababa de vaciar). El token corta esos delays + el processQueue
-- en curso si clear() entra a mitad del drenado.
local runId = 0

local function sizeForIndex(index: number, total: number): UDim2
	if total == 1 then
		return CONFIG.CENTER_SIZE
	elseif total == 2 then
		return CONFIG.SIDE_SIZE
	else
		return (index == 2) and CONFIG.CENTER_SIZE or CONFIG.SIDE_SIZE
	end
end

local function tweenSizeAndEnter(label: ImageLabel, targetSize: UDim2): Tween
	local t = TweenService:Create(
		label,
		TweenInfo.new(CONFIG.TWEEN_SPEED, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{
			Size = targetSize,
			ImageTransparency = 0,
			Rotation = 0
		}
	)
	t:Play()
	return t
end

local function fadeOutAndDestroy(label: ImageLabel)
	local t = TweenService:Create(
		label,
		TweenInfo.new(CONFIG.FADE_SPEED, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{
			ImageTransparency = 1,
			Size = UDim2.fromScale(0, 0),
			Rotation = CONFIG.EXIT_ROTATION
		}
	)
	t:Play()
	t.Completed:Once(function()
		label:Destroy()
	end)
end

local function refreshBadgeSizes()
	local count = #activeBadges
	for i, badge in activeBadges do
		badge.LayoutOrder = i
		tweenSizeAndEnter(badge, sizeForIndex(i, count))
	end
end

local function processQueue()
	if isProcessing then return end
	isProcessing = true
	local startRun = runId

	while #pendingQueue > 0 do
		-- Si clear() bumpea runId en medio del drenado, abortamos.
		if runId ~= startRun then
			break
		end
		local actionName = table.remove(pendingQueue, 1)
		local imageId    = BADGE_MAP[actionName]

		if not imageId then
			warn("[BadgeSystem] Unknown ActionName: " .. tostring(actionName))
			continue
		end

		if #activeBadges >= CONFIG.MAX_BADGES then
			local oldest = table.remove(activeBadges, 1)
			fadeOutAndDestroy(oldest)
		end

		local badge = Instance.new("ImageLabel")
		badge.Name                = actionName
		badge.BackgroundTransparency = 1
		badge.Image               = imageId
		badge.ScaleType           = Enum.ScaleType.Fit

		badge.ImageTransparency   = 1
		badge.Size                = UDim2.fromScale(0, 0)
		badge.Rotation            = CONFIG.SPAWN_ROTATION
		badge.LayoutOrder         = #activeBadges + 1
		badge.Parent              = badgeFrame

		table.insert(activeBadges, badge)

		refreshBadgeSizes()

		local badgeRun = startRun
		task.delay(CONFIG.BADGE_LIFESPAN, function()
			-- Token guard: si hubo clear() entre el insert y este disparo,
			-- el badge ya fue destruido por clear → no tocar activeBadges.
			if runId ~= badgeRun then return end
			local index = table.find(activeBadges, badge)
			if index then
				table.remove(activeBadges, index)
				fadeOutAndDestroy(badge)
				refreshBadgeSizes()
			end
		end)

		task.wait(CONFIG.TWEEN_SPEED * 0.5)
	end

	isProcessing = false
end

local BadgeSystem = {}

function BadgeSystem.showBadge(actionName: string)
	if not badgeFrame or not badgeFrame.Parent then
		badgeFrame = buildGui()
	end

	table.insert(pendingQueue, actionName)
	task.spawn(processQueue)
end

function BadgeSystem.clear()
	-- Bump del token corta task.delay tardías y el while de processQueue.
	runId += 1
	for _, badge in activeBadges do
		badge:Destroy()
	end
	table.clear(activeBadges)
	table.clear(pendingQueue)
	isProcessing = false
end

return BadgeSystem
