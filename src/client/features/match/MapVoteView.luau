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
		local buttonRoot = container:FindFirstChild("Button")
		if not buttonRoot then
			continue
		end

		local buttonNode: GuiButton? = nil
		if buttonRoot:IsA("GuiButton") then
			buttonNode = buttonRoot
		else
			local nestedButton = buttonRoot:FindFirstChildWhichIsA("GuiButton", true)
			if nestedButton then
				buttonNode = nestedButton
			end
		end

		if not buttonNode then
			continue
		end

		local indicator = buttonRoot:FindFirstChild("Indicator", true)
		local indicatorObject = if indicator and indicator:IsA("GuiObject") then indicator else nil

		-- Buscar VoteCount recursivamente en el container completo para cubrir
		-- tanto Button-como-Frame como Button-como-GuiButton.
		local voteCountRoot = container:FindFirstChild("VoteCount", true)
		local mapNameNode = if voteCountRoot then voteCountRoot:FindFirstChild("name") else nil
		local mapNameLabel = if mapNameNode and mapNameNode:IsA("TextLabel") then mapNameNode else nil

		-- Etiquetas de nombre y modo ubicadas como hijos directos del Button.
		local mapNameBtnNode = buttonRoot:FindFirstChild("Name")
		local mapNameButtonLabel = if mapNameBtnNode and mapNameBtnNode:IsA("TextLabel") then mapNameBtnNode else nil
		local mapModeNode = buttonRoot:FindFirstChild("Mode")
		local mapModeLabel = if mapModeNode and mapModeNode:IsA("TextLabel") then mapModeNode else nil

		-- Ocultar el template Vote si existe (se usara solo como ancora de parent).
		local voteTemplateAnchor = if voteCountRoot then voteCountRoot:FindFirstChild("Vote") else nil
		if voteTemplateAnchor and voteTemplateAnchor:IsA("GuiObject") then
			voteTemplateAnchor.Visible = false
		end

		if not voteCountRoot then
			warn("[MapVoteView] VoteCount no encontrado en container: " .. container:GetFullName())
		end

		table.insert(refs, {
			container = container,
			button = buttonNode,
			indicator = indicatorObject,
			voteCountRoot = voteCountRoot,
			voteTemplate = voteTemplateAnchor :: GuiObject?,
			mapNameLabel = mapNameLabel,
			mapNameButtonLabel = mapNameButtonLabel,
			mapModeLabel = mapModeLabel,
			spawnedVotes = {},
			mapName = "",
		})
	end

	return refs
end

local function _clearVoteIcons(optionRef: OptionRefs)
	for _, voteIcon in optionRef.spawnedVotes do
		voteIcon:Destroy()
	end
	table.clear(optionRef.spawnedVotes)
end

function MapVoteView.new(mapVoteFrame: GuiObject, optionsRoot: GuiObject): any
	local self = setmetatable({}, MapVoteView)

	self._frame = mapVoteFrame
	self._timerLabel = mapVoteFrame:FindFirstChild("Timer", true) :: TextLabel?
	self._barFill = (function(): Frame?
		local bar = mapVoteFrame:FindFirstChild("Bar", true)
		if not bar then
			return nil
		end

		local fill = bar:FindFirstChild("Fill", true)
		if fill and fill:IsA("Frame") then
			return fill
		end

		return nil
	end)()
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
	self._frame.Visible = true

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

		_clearVoteIcons(optionRef)
	end

	self:updateTimer(duration)
	self:updateVotes({})
end

function MapVoteView:hide()
	self._frame.Visible = false
	self._selectedMapName = ""
	for _, optionRef in self._options do
		optionRef.mapName = ""
		optionRef.button.Rotation = 0
		if optionRef.indicator then
			optionRef.indicator.Visible = false
		end
		_clearVoteIcons(optionRef)
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
		_clearVoteIcons(optionRef)

		if not optionRef.voteCountRoot then
			continue
		end

		local voteCount = math.max(0, votesByMapName[optionRef.mapName] or 0)
		for _ = 1, voteCount do
			local icon = Instance.new("ImageLabel")
			icon.Name = "VoteIndicator"
			icon.Image = VOTE_INDICATOR_IMAGE
			icon.Size = VOTE_INDICATOR_SIZE
			icon.BackgroundTransparency = 1
			icon.Visible = true
			icon.Parent = optionRef.voteCountRoot
			table.insert(optionRef.spawnedVotes, icon)
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
