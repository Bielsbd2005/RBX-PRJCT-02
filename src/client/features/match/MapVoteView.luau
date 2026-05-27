--!strict

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local MapVoteView = {}
MapVoteView.__index = MapVoteView

export type OptionModel = {
	mapName: string,
	mapImage: string,
	mapMode: string,
}

type OptionRefs = {
	container: GuiObject,
	button: GuiButton,
	indicator: GuiObject?,
	voteCountRoot: Instance?,
	playerTemplate: GuiObject?,
	mapNameLabel: TextLabel?,
	mapNameButtonLabel: TextLabel?,
	spawnedVotes: { GuiObject },
	mapName: string,
	originalSize: UDim2,
	originalPosition: UDim2,
}

local DEFAULT_MAP_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"
local SELECTED_ROTATION_DEG = 5
local ROTATION_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local LOSER_SLIDE_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local WINNER_POP_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local WINNER_SETTLE_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local WINNER_HOLD_SECONDS = 2.2

local LOCAL_USER_ID = Players.LocalPlayer and Players.LocalPlayer.UserId :: number

local function _getHeadshotUrl(userId: number): string
	return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(userId) .. "&w=48&h=48"
end

local function _parseVoterIds(raw: string): { number }
	if raw == "" then return {} end
	local ids = {}
	for idStr in string.gmatch(raw, "[^,]+") do
		local id = tonumber(idStr)
		if id then
			table.insert(ids, id)
		end
	end
	return ids
end

local function _ensureAvatarImage(icon: GuiObject): ImageLabel
	if icon:IsA("ImageLabel") then
		return icon :: ImageLabel
	end
	local existing = icon:FindFirstChildWhichIsA("ImageLabel")
	if existing then
		return existing :: ImageLabel
	end
	local img = Instance.new("ImageLabel")
	img.Name = "Avatar"
	img.Size = UDim2.fromScale(1, 1)
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Crop
	img.Parent = icon
	local corner = icon:FindFirstChildWhichIsA("UICorner")
	if corner then
		corner:Clone().Parent = img
	end
	return img
end

local function _findOptionContainers(optionsRoot: Instance): { GuiObject }
	local containers = {} :: { GuiObject }
	for _, child in optionsRoot:GetChildren() do
		if child:IsA("GuiObject") and child:FindFirstChild("Button") then
			table.insert(containers, child)
		end
	end
	table.sort(containers, function(a, b) return a.Name < b.Name end)
	return containers
end

local function _resolveOptionRefs(optionsRoot: Instance): { OptionRefs }
	local refs = {} :: { OptionRefs }
	for _, container in _findOptionContainers(optionsRoot) do
		local button = container:WaitForChild("Button") :: GuiButton
		local indicator = button:FindFirstChild("Indicator")
		local voteCountRoot = button:FindFirstChild("VoteCount")
		local playerTemplate = if voteCountRoot then voteCountRoot:FindFirstChild("Player") :: GuiObject? else nil
		if playerTemplate then
			playerTemplate.Visible = false
		end

		table.insert(refs, {
			container = container,
			button = button,
			indicator = if indicator and indicator:IsA("GuiObject") then indicator else nil,
			voteCountRoot = voteCountRoot,
			playerTemplate = playerTemplate,
			mapNameLabel = if voteCountRoot then voteCountRoot:FindFirstChild("name") :: TextLabel? else nil,
			mapNameButtonLabel = button:FindFirstChild("Name") :: TextLabel?,
			spawnedVotes = {},
			mapName = "",
			originalSize = container.Size,
			originalPosition = container.Position,
		})
	end
	return refs
end

local function _hideVoteIcons(optionRef: OptionRefs)
	for _, icon in optionRef.spawnedVotes do
		icon.Visible = false
	end
end

local function _resetOption(optionRef: OptionRefs)
	optionRef.mapName = ""
	optionRef.button.Rotation = 0
	optionRef.container.Visible = true
	optionRef.container.Size = optionRef.originalSize
	optionRef.container.Position = optionRef.originalPosition
	if optionRef.indicator then
		optionRef.indicator.Visible = false
	end
	_hideVoteIcons(optionRef)
end

-- ────────────────────────────────────────────────────────────

function MapVoteView.new(mapVoteFrame: GuiObject, optionsRoot: GuiObject): any
	local self = setmetatable({}, MapVoteView)
	self._frame = mapVoteFrame
	self._timerLabel = mapVoteFrame:FindFirstChild("Timer") :: TextLabel?
	local bar = mapVoteFrame:FindFirstChild("Bar")
	self._barFill = if bar then bar:FindFirstChild("Fill") :: Frame? else nil
	self._barContainer = bar
	self._options = _resolveOptionRefs(optionsRoot)
	self._selectedMapName = ""
	self._localVoterIcon = nil :: GuiObject?
	self._duration = 1
	self._onVote = nil :: ((string) -> ())?
	self._connections = {} :: { RBXScriptConnection }

	if self._barFill then
		self._barFill.AnchorPoint = Vector2.new(0.5, 0.5)
		self._barFill.Position = UDim2.fromScale(0.5, 0.5)
		self._barFill.Size = UDim2.new(0, 0, 1, 0)
	end

	self._frame.Visible = false
	return self
end

function MapVoteView:bindVoteHandler(onVote: (string) -> ())
	self._onVote = onVote
	for _, ref in self._options do
		local conn = ref.button.Activated:Connect(function()
			if ref.mapName ~= "" and self._onVote then
				self._onVote(ref.mapName)
			end
		end)
		table.insert(self._connections, conn)
	end
end

-- ────────────────────────────────────────────────────────────

function MapVoteView:show(optionsByKey: { [string]: OptionModel }, duration: number)
	self._duration = math.max(1, duration)
	self._selectedMapName = ""

	local options = { optionsByKey.optionA, optionsByKey.optionB, optionsByKey.optionC }
	for i, ref in self._options do
		local model = options[i]
		if not model then
			ref.container.Visible = false
			continue
		end

		ref.container.Visible = true
		ref.mapName = model.mapName
		if ref.mapNameLabel then ref.mapNameLabel.Text = model.mapName end
		if ref.mapNameButtonLabel then ref.mapNameButtonLabel.Text = model.mapName end
		if ref.indicator then ref.indicator.Visible = false end
		if ref.button:IsA("ImageButton") then
			ref.button.Image = if model.mapImage ~= "" then model.mapImage else DEFAULT_MAP_IMAGE
		end
		_hideVoteIcons(ref)
	end

	self:updateTimer(duration)
	self:updateVotes({})
end

function MapVoteView:hide()
	self._selectedMapName = ""
	if self._localVoterIcon then
		self._localVoterIcon.Visible = false
	end
	if self._timerLabel then self._timerLabel.Visible = true end
	if self._barContainer then (self._barContainer :: GuiObject).Visible = true end
	for _, ref in self._options do
		_resetOption(ref)
	end
end

-- ────────────────────────────────────────────────────────────

function MapVoteView:setSelectedMap(mapName: string)
	self._selectedMapName = mapName

	for _, ref in self._options do
		local selected = ref.mapName ~= "" and ref.mapName == mapName
		if ref.indicator then ref.indicator.Visible = selected end
		TweenService:Create(ref.button, ROTATION_INFO, {
			Rotation = if selected then SELECTED_ROTATION_DEG else 0,
		}):Play()
	end

	if not LOCAL_USER_ID or mapName == "" then return end

	if self._localVoterIcon then
		self._localVoterIcon.Visible = false
	end

	for _, ref in self._options do
		if ref.mapName ~= mapName or not ref.voteCountRoot or not ref.playerTemplate then
			continue
		end

		local icon = self._localVoterIcon
		if not icon then
			icon = ref.playerTemplate:Clone()
			icon.Name = "LocalVoter"
			self._localVoterIcon = icon
			_ensureAvatarImage(icon).Image = _getHeadshotUrl(LOCAL_USER_ID)
		end
		icon.Parent = ref.voteCountRoot
		icon.Visible = true
		break
	end
end

function MapVoteView:updateVotes(voterIdStrByMapName: { [string]: string })
	for _, ref in self._options do
		_hideVoteIcons(ref)
		if not ref.voteCountRoot or not ref.playerTemplate then continue end

		local voterIds = _parseVoterIds(voterIdStrByMapName[ref.mapName] or "")
		local pool = ref.spawnedVotes
		local idx = 0

		for _, userId in voterIds do
			if userId == LOCAL_USER_ID then continue end
			idx += 1

			local icon = pool[idx]
			if not icon then
				icon = ref.playerTemplate:Clone()
				icon.Name = "Voter_" .. tostring(idx)
				icon.Parent = ref.voteCountRoot
				pool[idx] = icon
			end
			icon.Visible = true
			_ensureAvatarImage(icon).Image = _getHeadshotUrl(userId)
		end
	end
end

-- ────────────────────────────────────────────────────────────

function MapVoteView:showWinner(winnerMapName: string, onDone: (() -> ())?)
	if self._localVoterIcon then self._localVoterIcon.Visible = false end
	if self._timerLabel then self._timerLabel.Visible = false end
	if self._barContainer then (self._barContainer :: GuiObject).Visible = false end

	local winnerRef: OptionRefs? = nil

	for _, ref in self._options do
		if ref.indicator then ref.indicator.Visible = false end
		TweenService:Create(ref.button, ROTATION_INFO, { Rotation = 0 }):Play()

		if ref.mapName == winnerMapName then
			winnerRef = ref
		else
			_hideVoteIcons(ref)
			TweenService:Create(ref.container, LOSER_SLIDE_INFO, {
				Position = UDim2.new(
					ref.originalPosition.X.Scale, ref.originalPosition.X.Offset,
					ref.originalPosition.Y.Scale + 1.5, ref.originalPosition.Y.Offset
				),
			}):Play()
		end
	end

	task.delay(LOSER_SLIDE_INFO.Time + 0.1, function()
		for _, ref in self._options do
			if ref.mapName ~= winnerMapName then
				ref.container.Visible = false
			end
		end

		if winnerRef then
			local w = winnerRef :: OptionRefs
			local pop = 1.2
			TweenService:Create(w.container, WINNER_POP_INFO, {
				Size = UDim2.new(
					w.originalSize.X.Scale * pop, w.originalSize.X.Offset,
					w.originalSize.Y.Scale * pop, w.originalSize.Y.Offset
				),
				Position = UDim2.fromScale(0.5, w.originalPosition.Y.Scale),
			}):Play()

			task.delay(WINNER_POP_INFO.Time, function()
				TweenService:Create(w.container, WINNER_SETTLE_INFO, {
					Size = w.originalSize,
				}):Play()
			end)
		end

		task.delay(WINNER_POP_INFO.Time + WINNER_SETTLE_INFO.Time + WINNER_HOLD_SECONDS, function()
			if onDone then onDone() end
		end)
	end)
end

-- ────────────────────────────────────────────────────────────

function MapVoteView:updateTimer(timeLeft: number)
	local clamped = math.max(0, timeLeft)
	if self._timerLabel then
		self._timerLabel.Text = tostring(clamped)
	end
	if self._barFill then
		local elapsed = math.clamp(self._duration - clamped, 0, self._duration)
		self._barFill.Size = UDim2.new(if self._duration > 0 then elapsed / self._duration else 0, 0, 1, 0)
	end
end

function MapVoteView:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	self:hide()
end

return MapVoteView
