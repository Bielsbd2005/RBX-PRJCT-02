local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
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

local TI_BAR_DRAIN = TweenInfo.new(STREAK_DURATION, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)

local StreakController = {}

local currentStreak = 0
local barTween: Tween? = nil

local streakFrame: Frame? = nil
local fillBar: Frame? = nil
local valueLabel: TextLabel? = nil

local function getStreakFrame(): Frame?
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
	local title = streak:FindFirstChild("Title")
	if title then
		valueLabel = title:FindFirstChild("Value") :: TextLabel?
	end

	return streakFrame
end

function StreakController.reset()
	currentStreak = 0
	if barTween then
		barTween:Cancel()
		barTween = nil
	end
	if streakFrame then
		streakFrame.Visible = false
	end
end

function StreakController.onKill()
	local frame = getStreakFrame()
	if not frame then return end

	currentStreak += 1

	-- Update title text
	local titleKey = math.min(currentStreak, 7)
	local titleText = TITLES[titleKey] .. " X" .. tostring(currentStreak)
	if valueLabel then
		valueLabel.Text = titleText
	end

	-- Show frame
	frame.Visible = true

	-- Cancel previous tween
	if barTween then
		barTween:Cancel()
		barTween = nil
	end

	-- Reset fill bar to full and start drain
	if fillBar then
		fillBar.Size = UDim2.new(1, 0, 1, 0)
		barTween = TweenService:Create(fillBar, TI_BAR_DRAIN, { Size = UDim2.new(0, 0, 1, 0) })
		barTween.Completed:Connect(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed then
				StreakController.reset()
			end
		end)
		barTween:Play()
	end
end

return StreakController
