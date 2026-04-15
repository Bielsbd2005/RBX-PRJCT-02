--!strict

local TweenService = game:GetService("TweenService")

local EndResultsView = {}
EndResultsView.__index = EndResultsView

local STYLE = {
	showTween = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	hideTween = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	visibleTransparency = 0,
	hiddenTransparency = 1,
	winnerAColor = Color3.fromRGB(219, 68, 55),
	winnerBColor = Color3.fromRGB(66, 133, 244),
	tieColor = Color3.fromRGB(235, 235, 235),
}

type Refs = {
	root: ScreenGui,
	resultsScreen: GuiObject?,
	container: GuiObject,
	modeLabel: TextLabel?,
	scoreALabel: TextLabel?,
	scoreBLabel: TextLabel?,
	winnerLabel: TextLabel?,
	timerLabel: TextLabel?,
}

type ShowData = {
	winnerTeam: string,
	scoreA: number,
	scoreB: number,
	duration: number,
	modeLabelText: string?,
}

local function _resolveContainer(gui: ScreenGui): (GuiObject?, GuiObject?)
	local resultsScreen = gui:FindFirstChild("ResultsScreen", true)
	if resultsScreen and resultsScreen:IsA("GuiObject") then
		local containerNode = resultsScreen:FindFirstChild("Container", true)
		if containerNode and containerNode:IsA("GuiObject") then
			return containerNode, resultsScreen
		end
	end

	local directContainer = gui:FindFirstChild("Container", true)
	if directContainer and directContainer:IsA("GuiObject") then
		return directContainer, nil
	end

	return nil, nil
end

local function _resolveRefs(gui: ScreenGui): Refs?
	local containerNode, resultsScreenNode = _resolveContainer(gui)
	if not containerNode then
		return nil
	end

	local modeNode = containerNode:FindFirstChild("ModeLabel", true)
	local scoreANode = containerNode:FindFirstChild("ScoreA", true)
	local scoreBNode = containerNode:FindFirstChild("ScoreB", true)
	local winnerNode = containerNode:FindFirstChild("Winner", true)
	local timerNode = containerNode:FindFirstChild("Timer", true)

	return {
		root = gui,
		resultsScreen = resultsScreenNode,
		container = containerNode,
		modeLabel = if modeNode and modeNode:IsA("TextLabel") then modeNode else nil,
		scoreALabel = if scoreANode and scoreANode:IsA("TextLabel") then scoreANode else nil,
		scoreBLabel = if scoreBNode and scoreBNode:IsA("TextLabel") then scoreBNode else nil,
		winnerLabel = if winnerNode and winnerNode:IsA("TextLabel") then winnerNode else nil,
		timerLabel = if timerNode and timerNode:IsA("TextLabel") then timerNode else nil,
	}
end

local function _winnerPresentation(winnerTeam: string): (string, Color3)
	if winnerTeam == "A" then
		return "Team A", STYLE.winnerAColor
	elseif winnerTeam == "B" then
		return "Team B", STYLE.winnerBColor
	end

	return "Empate", STYLE.tieColor
end

function EndResultsView.new(gui: ScreenGui): any
	local refs = _resolveRefs(gui)
	if not refs then
		return nil
	end

	local self = setmetatable({}, EndResultsView)
	self._refs = refs
	self._countdownToken = 0
	self._onFinished = nil :: (() -> ())?

	refs.root.Enabled = false
	refs.root.ResetOnSpawn = false
	refs.container.BackgroundTransparency = STYLE.hiddenTransparency

	return self
end

function EndResultsView:show(data: ShowData, onFinished: (() -> ())?)
	self._countdownToken += 1
	local token = self._countdownToken
	self._onFinished = onFinished

	local winnerText, winnerColor = _winnerPresentation(data.winnerTeam)
	if self._refs.winnerLabel then
		self._refs.winnerLabel.Text = winnerText
		self._refs.winnerLabel.TextColor3 = winnerColor
	end

	if self._refs.modeLabel then
		self._refs.modeLabel.Text = data.modeLabelText or "Resultados finales"
	end

	if self._refs.scoreALabel then
		self._refs.scoreALabel.Text = tostring(math.max(0, data.scoreA))
	end

	if self._refs.scoreBLabel then
		self._refs.scoreBLabel.Text = tostring(math.max(0, data.scoreB))
	end

	self._refs.root.Enabled = true
	if self._refs.resultsScreen then
		self._refs.resultsScreen.Visible = true
	end
	self._refs.container.BackgroundTransparency = STYLE.hiddenTransparency
	TweenService:Create(self._refs.container, STYLE.showTween, {
		BackgroundTransparency = STYLE.visibleTransparency,
	}):Play()

	task.spawn(function()
		local duration = math.max(0, data.duration)
		local endAt = time() + duration
		while self._countdownToken == token do
			local left = math.ceil(math.max(0, endAt - time()))
			if self._refs.timerLabel then
				self._refs.timerLabel.Text = tostring(left)
			end

			if left <= 0 then
				if self._countdownToken == token and self._onFinished then
					self._onFinished()
				end
				return
			end

			task.wait(0.1)
		end
	end)
end

function EndResultsView:hide()
	self._countdownToken += 1
	if self._refs.timerLabel then
		self._refs.timerLabel.Text = "0"
	end

	local tween = TweenService:Create(self._refs.container, STYLE.hideTween, {
		BackgroundTransparency = STYLE.hiddenTransparency,
	})
	tween:Play()
	task.delay(STYLE.hideTween.Time, function()
		if self._refs.resultsScreen then
			self._refs.resultsScreen.Visible = false
		end
		self._refs.root.Enabled = false
	end)
end

function EndResultsView:Destroy()
	self._countdownToken += 1
	self._onFinished = nil
	self._refs.root.Enabled = false
end

return EndResultsView
