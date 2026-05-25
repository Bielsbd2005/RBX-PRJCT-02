--!strict

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
	voteTemplate: GuiObject?,
	mapNameLabel: TextLabel?,
	mapNameButtonLabel: TextLabel?,
	mapModeLabel: TextLabel?,
	spawnedVotes: { GuiObject },
	mapName: string,
}

local DEFAULT_MAP_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"
local VOTE_INDICATOR_IMAGE = "rbxassetid://127687698791848"
local VOTE_INDICATOR_SIZE = UDim2.new(-0.254, 100, 1, 0)
local SELECTED_ROTATION_DEG = 5
local ROTATION_TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local function _toArray(optionsByKey: { [string]: OptionModel }): { OptionModel }
	return {
		optionsByKey.optionA,
		optionsByKey.optionB,
		optionsByKey.optionC,
	}
end

local function _findOptionContainers(optionsRoot: Instance): { GuiObject }
	local containers = {} :: { GuiObject }
	for _, child in optionsRoot:GetChildren() do
		if child:IsA("GuiObject") and child:FindFirstChild("Button") then
			table.insert(containers, child)
		end
	end

	table.sort(containers, function(a, b)
		return a.Name < b.Name
	end)

	return containers
end

local function _resolveOptionRefs(optionsRoot: Instance): { OptionRefs }
	local refs = {} :: { OptionRefs }
	for _, container in _findOptionContainers(optionsRoot) do
		local buttonRoot = container:WaitForChild("Button") :: GuiButton
		local indicator = buttonRoot:FindFirstChild("Indicator")
		local voteCountRoot = container:FindFirstChild("VoteCount")
		local mapNameLabel = if voteCountRoot then voteCountRoot:FindFirstChild("name") :: TextLabel? else nil
		local mapNameButtonLabel = buttonRoot:FindFirstChild("Name") :: TextLabel?
		local mapModeLabel = buttonRoot:FindFirstChild("Mode") :: TextLabel?

		local voteTemplateAnchor = if voteCountRoot then voteCountRoot:FindFirstChild("Vote") :: GuiObject? else nil
		if voteTemplateAnchor then
			voteTemplateAnchor.Visible = false
		end

		table.insert(refs, {
			container = container,
			button = buttonRoot,
			indicator = if indicator and indicator:IsA("GuiObject") then indicator else nil,
			voteCountRoot = voteCountRoot,
			voteTemplate = voteTemplateAnchor,
			mapNameLabel = mapNameLabel,
			mapNameButtonLabel = mapNameButtonLabel,
			mapModeLabel = mapModeLabel,
			spawnedVotes = {},
			mapName = "",
		})
	end

	return refs
end

local function _hideVoteIcons(optionRef: OptionRefs)
	for _, voteIcon in optionRef.spawnedVotes do
		voteIcon.Visible = false
	end
end

function MapVoteView.new(mapVoteFrame: GuiObject, optionsRoot: GuiObject): any
	local self = setmetatable({}, MapVoteView)

	self._frame = mapVoteFrame
	self._timerLabel = mapVoteFrame:FindFirstChild("Timer") :: TextLabel?
	local bar = mapVoteFrame:FindFirstChild("Bar")
	self._barFill = if bar then bar:FindFirstChild("Fill") :: Frame? else nil
	self._options = _resolveOptionRefs(optionsRoot)
	self._selectedMapName = ""
	self._duration = 1
	self._onVote = nil :: ((string) -> ())?
	self._connections = {} :: { RBXScriptConnection }

	if self._barFill then
		self._barFill.AnchorPoint = Vector2.new(0.5, 0.5)
		self._barFill.Position = UDim2.fromScale(0.5, 0.5)
		self._barFill.Size = UDim2.new(0, 0, 1, 0)
	end

	self._frame.Visible = false

	if #self._options == 0 then
		warn("[MapVoteView] No se encontraron option containers en MapVote.Options")
	end

	return self
end

function MapVoteView:bindVoteHandler(onVote: (string) -> ())
	self._onVote = onVote

	for _, optionRef in self._options do
		local connection = optionRef.button.Activated:Connect(function()
			if optionRef.mapName == "" then
				return
			end
			if self._onVote then
				self._onVote(optionRef.mapName)
			end
		end)
		table.insert(self._connections, connection)
	end
end

function MapVoteView:show(optionsByKey: { [string]: OptionModel }, duration: number)
	self._duration = math.max(1, duration)
	self._selectedMapName = ""
	-- La visibilidad del frame la controla MenuController:setMapVoteVisible —
	-- si la votación arranca con un panel abierto (locker, settings...), el
	-- MenuController mantiene el frame oculto hasta que se cierre el panel.
	-- Aquí solo poblamos contenido.

	local options = _toArray(optionsByKey)
	for index, optionRef in self._options do
		local model = options[index]
		if not model then
			optionRef.container.Visible = false
			continue
		end

		optionRef.container.Visible = true
		optionRef.mapName = model.mapName
		if optionRef.mapNameLabel then
			optionRef.mapNameLabel.Text = model.mapName
		end
		if optionRef.mapNameButtonLabel then
			optionRef.mapNameButtonLabel.Text = model.mapName
		end
		if optionRef.mapModeLabel then
			optionRef.mapModeLabel.Text = model.mapMode
		end
		if optionRef.indicator then
			optionRef.indicator.Visible = false
		end

		if optionRef.button:IsA("ImageButton") then
			local image = if model.mapImage ~= "" then model.mapImage else DEFAULT_MAP_IMAGE
			optionRef.button.Image = image
		end

		_hideVoteIcons(optionRef)
	end

	self:updateTimer(duration)
	self:updateVotes({})
end

function MapVoteView:hide()
	-- Visibilidad la controla MenuController:setMapVoteVisible(false) (que
	-- siempre se llama justo después de view:hide en init.luau:603-604).
	self._selectedMapName = ""
	for _, optionRef in self._options do
		optionRef.mapName = ""
		optionRef.button.Rotation = 0
		if optionRef.indicator then
			optionRef.indicator.Visible = false
		end
		_hideVoteIcons(optionRef)
	end
end

function MapVoteView:setSelectedMap(mapName: string)
	self._selectedMapName = mapName

	for _, optionRef in self._options do
		local isSelected = optionRef.mapName ~= "" and optionRef.mapName == mapName
		-- Indicator es local: visible solo para quien voto ese mapa.
		if optionRef.indicator then
			optionRef.indicator.Visible = isSelected
		end
		-- Rotacion local: el boton votado se inclina 5 grados, el resto vuelve a 0.
		TweenService:Create(optionRef.button, ROTATION_TWEEN_INFO, {
			Rotation = if isSelected then SELECTED_ROTATION_DEG else 0,
		}):Play()
	end
end

function MapVoteView:updateVotes(votesByMapName: { [string]: number })
	for _, optionRef in self._options do
		_hideVoteIcons(optionRef)

		if not optionRef.voteCountRoot then
			continue
		end

		local voteCount = math.max(0, votesByMapName[optionRef.mapName] or 0)
		local pool = optionRef.spawnedVotes

		for i = 1, voteCount do
			local icon = pool[i]
			if icon then
				icon.Visible = true
			else
				icon = Instance.new("ImageLabel")
				icon.Name = "VoteIndicator"
				icon.Image = VOTE_INDICATOR_IMAGE
				icon.Size = VOTE_INDICATOR_SIZE
				icon.BackgroundTransparency = 1
				icon.Visible = true
				icon.Parent = optionRef.voteCountRoot
				pool[i] = icon
			end
		end
	end
end

function MapVoteView:updateTimer(timeLeft: number)
	local clampedTimeLeft = math.max(0, timeLeft)
	if self._timerLabel then
		self._timerLabel.Text = tostring(clampedTimeLeft)
	end

	if not self._barFill then
		return
	end

	local elapsed = math.clamp(self._duration - clampedTimeLeft, 0, self._duration)
	local progress = if self._duration > 0 then (elapsed / self._duration) else 0
	self._barFill.Size = UDim2.new(progress, 0, 1, 0)
end

function MapVoteView:Destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	self:hide()
end

return MapVoteView
