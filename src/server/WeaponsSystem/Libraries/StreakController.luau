local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local STREAK_DURATION = 7

local TITLES = {
	[1] = "FIRST KO",
	[2] = "DOUBLE",
	[3] = "TRIPLE",
	[4] = "QUAD",
	[5] = "DOMINATING",
	[6] = "LEGENDARY",
	[7] = "UNSTOPPABLE",
}

local STREAK_COLORS = {
	[1] = { title = Color3.fromRGB(255, 210, 50), text = Color3.fromRGB(255, 255, 200) },
	[2] = { title = Color3.fromRGB(255, 160, 0), text = Color3.fromRGB(255, 230, 100) },
	[3] = { title = Color3.fromRGB(255, 80, 0), text = Color3.fromRGB(255, 190, 80) },
	[4] = { title = Color3.fromRGB(255, 30, 30), text = Color3.fromRGB(255, 130, 130) },
	[5] = { title = Color3.fromRGB(220, 0, 255), text = Color3.fromRGB(255, 140, 255) },
	[6] = { title = Color3.fromRGB(0, 180, 255), text = Color3.fromRGB(120, 220, 255) },
	[7] = { title = Color3.fromRGB(255, 255, 0), text = Color3.fromRGB(255, 255, 180) },
}

local TI_BAR_DRAIN = TweenInfo.new(STREAK_DURATION, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)

local StreakController = {}

local currentStreak = 0
local barTween: Tween? = nil

local streakFrame: Frame? = nil
local titleFrame: Frame? = nil
local fillBar: Frame? = nil
local valueLabel: TextLabel? = nil

-- ═══════════════════════════════════════════════════
-- FX STATE
-- ═══════════════════════════════════════════════════
local frameUIScale: UIScale? = nil
local originalPosition: UDim2? = nil
local shakeConnection: RBXScriptConnection? = nil
local pulseConnection: RBXScriptConnection? = nil
local punchTween: Tween? = nil

local function getColorTier(streak: number): number
	return math.min(streak, 7)
end

local function resolveUI(): Frame?
	if streakFrame then return streakFrame end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil end
	local gui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not gui then return nil end
	local streak = gui:FindFirstChild("Streak")
	if not streak then return nil end

	streakFrame = streak :: Frame
	local bar = streak:FindFirstChild("Bar")
	if bar then
		fillBar = bar:FindFirstChild("Fill") :: Frame?
	end
	titleFrame = streak:FindFirstChild("Title") :: Frame?
	if titleFrame then
		valueLabel = titleFrame:FindFirstChild("Value") :: TextLabel?
	end

	return streakFrame
end

local function stopBarTween()
	if barTween then
		barTween:Cancel()
		barTween = nil
	end
end

local function setTitleText(streak: number)
	if not valueLabel then
		return
	end

	local tier = getColorTier(streak)
	valueLabel.Text = TITLES[tier] .. " X" .. tostring(streak)
end

local function setStreakColors(streak: number)
	local tier = getColorTier(streak)
	local colors = STREAK_COLORS[tier]
	if not colors then
		return
	end

	if titleFrame then
		titleFrame.BackgroundColor3 = colors.title
	end

	if fillBar then
		fillBar.BackgroundColor3 = colors.title
	end

	if valueLabel then
		valueLabel.TextColor3 = colors.text
	end
end

local function restartBarDrainTween()
	if not fillBar then
		return
	end

	stopBarTween()
	fillBar.Size = UDim2.new(1, 0, 1, 0)
	barTween = TweenService:Create(fillBar, TI_BAR_DRAIN, { Size = UDim2.new(0, 0, 1, 0) })
	barTween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed then
			StreakController.reset()
		end
	end)
	barTween:Play()
end

-- ═══════════════════════════════════════════════════
-- UIScale setup
-- ═══════════════════════════════════════════════════
local function ensureUIScale()
	if not streakFrame then return end
	if frameUIScale then return end

	frameUIScale = streakFrame:FindFirstChildOfClass("UIScale")
	if not frameUIScale then
		frameUIScale = Instance.new("UIScale")
		frameUIScale.Scale = 1
		frameUIScale.Parent = streakFrame
	end
end

-- ═══════════════════════════════════════════════════
-- FX 1: Scale punch on kill
-- Snappy pop that bounces back. Moderate intensity.
-- ═══════════════════════════════════════════════════
local function playScalePunch(streak: number)
	ensureUIScale()
	if not frameUIScale then return end

	if punchTween then
		punchTween:Cancel()
	end

	-- Moderate punch: 1.12 → 1.25 max
	local intensity = math.clamp(1.12 + (streak - 1) * 0.025, 1.12, 1.25)
	frameUIScale.Scale = intensity

	punchTween = TweenService:Create(
		frameUIScale,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	)
	punchTween:Play()
end



-- ═══════════════════════════════════════════════════
-- FX 3: Shake burst
-- Short vibration that decays. Controlled magnitude.
-- ═══════════════════════════════════════════════════
local function playShakeBurst(streak: number)
	if not streakFrame then return end

	if shakeConnection then
		shakeConnection:Disconnect()
		shakeConnection = nil
	end

	if not originalPosition then
		originalPosition = streakFrame.Position
	end

	local origin = originalPosition :: UDim2

	-- Duration: 0.2s → 0.45s | Offset: 2px → 10px
	local shakeDuration = math.clamp(0.2 + streak * 0.04, 0.2, 0.45)
	local maxOffset = math.clamp(2 + streak * 1.5, 2, 10)
	local elapsed = 0

	shakeConnection = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= shakeDuration then
			streakFrame.Position = origin
			if shakeConnection then
				shakeConnection:Disconnect()
				shakeConnection = nil
			end
			return
		end

		local progress = elapsed / shakeDuration
		local decay = (1 - progress) ^ 2
		local magnitude = maxOffset * decay

		local offsetX = (math.random() * 2 - 1) * magnitude
		local offsetY = (math.random() * 2 - 1) * magnitude

		streakFrame.Position = UDim2.new(
			origin.X.Scale, origin.X.Offset + offsetX,
			origin.Y.Scale, origin.Y.Offset + offsetY
		)
	end)
end

-- ═══════════════════════════════════════════════════
-- FX 4: Idle pulse — subtle breathing + micro-sway
-- Scale breathes and frame gently rocks side to side.
-- Gets slightly faster/stronger with streak.
-- ═══════════════════════════════════════════════════
local function startIdlePulse(streak: number)
	ensureUIScale()
	if not frameUIScale then return end

	if pulseConnection then
		pulseConnection:Disconnect()
		pulseConnection = nil
	end

	-- Pulse speed: 1.8 → 4.0 Hz | Scale delta: 0.01 → 0.035
	local pulseSpeed = math.clamp(1.8 + streak * 0.4, 1.8, 4.0)
	local pulseAmount = math.clamp(0.01 + streak * 0.005, 0.01, 0.035)



	local accumulated = 0

	pulseConnection = RunService.Heartbeat:Connect(function(dt)
		accumulated += dt

		local scaleWave = math.sin(accumulated * pulseSpeed * math.pi * 2)

		-- Scale breathes
		if frameUIScale then
			frameUIScale.Scale = 1 + scaleWave * pulseAmount
		end

	end)
end

-- ═══════════════════════════════════════════════════
-- FX 5: Title slam — text pops in with scale bounce
-- ═══════════════════════════════════════════════════
local function playTitleSlam(streak: number)
	if not valueLabel then return end

	local slamScale = valueLabel:FindFirstChildOfClass("UIScale")
	if not slamScale then
		slamScale = Instance.new("UIScale")
		slamScale.Parent = valueLabel
	end

	-- Start slightly oversized: 1.4 → 1.7
	slamScale.Scale = math.clamp(1.4 + math.min(streak, 5) * 0.06, 1.4, 1.7)
	valueLabel.TextTransparency = 0.2

	local scaleTween = TweenService:Create(
		slamScale,
		TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	)

	local alphaTween = TweenService:Create(
		valueLabel,
		TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 0 }
	)

	scaleTween:Play()
	alphaTween:Play()
end

-- ═══════════════════════════════════════════════════
-- CLEANUP
-- ═══════════════════════════════════════════════════
local function stopAllFX()
	if shakeConnection then
		shakeConnection:Disconnect()
		shakeConnection = nil
	end
	if pulseConnection then
		pulseConnection:Disconnect()
		pulseConnection = nil
	end
	if punchTween then
		punchTween:Cancel()
		punchTween = nil
	end


	-- Reset position
	if streakFrame and originalPosition then
		streakFrame.Position = originalPosition
	end

	-- Reset scale
	if frameUIScale then
		frameUIScale.Scale = 1
	end


end

-- ═══════════════════════════════════════════════════
-- CONTROLLER API
-- ═══════════════════════════════════════════════════
function StreakController.reset()
	currentStreak = 0
	stopBarTween()
	stopAllFX()
	if streakFrame then
		streakFrame.Visible = false
	end
end

function StreakController.onKill()
	local frame = resolveUI()
	if not frame then return end

	currentStreak += 1
	setTitleText(currentStreak)
	setStreakColors(currentStreak)

	-- Show frame
	frame.Visible = true
	restartBarDrainTween()

	-- ══ DOPAMINE FX ══
	playScalePunch(currentStreak)     -- Pop + bounce back
	playShakeBurst(currentStreak)     -- Short vibration burst
	playTitleSlam(currentStreak)      -- Text enters with scale bounce
	startIdlePulse(currentStreak)     -- Breathing + gentle rotation sway (continuous)
end

return StreakController
