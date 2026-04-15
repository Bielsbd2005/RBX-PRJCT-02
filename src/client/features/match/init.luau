--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local GameConfig = require(Shared.GameConfig)
local Network = require(Shared.networking.Network)

local DeathScreenView = require(Client.features.match.DeathScreenView)
local EndResultsView = require(Client.features.match.EndResultsView)
local MapVoteView = require(Client.features.match.MapVoteView)

local MatchFeature = {}

local LOCAL_VOTE_COOLDOWN = 0.12
local FADE_IN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local JOIN_CONFIRM_TIMEOUT = 8

type FadeRefs = {
	screenGui: ScreenGui,
	frame: Frame,
}

type HudRefs = {
	scoreA: TextLabel?,
	scoreB: TextLabel?,
	timer: TextLabel?,
}

local function _findTextLabelByName(root: Instance, targetName: string): TextLabel?
	for _, node in root:GetDescendants() do
		if node:IsA("TextLabel") and string.lower(node.Name) == string.lower(targetName) then
			return node
		end
	end

	return nil
end

local function _resolveHudRefs(matchHudGui: ScreenGui?): HudRefs
	if not matchHudGui then
		return { scoreA = nil, scoreB = nil, timer = nil }
	end

	return {
		scoreA = _findTextLabelByName(matchHudGui, "ScoreA"),
		scoreB = _findTextLabelByName(matchHudGui, "ScoreB"),
		timer = _findTextLabelByName(matchHudGui, "Timer"),
	}
end

local function _setHudState(hudRefs: HudRefs, scoreA: number, scoreB: number, timeLeft: number)
	if hudRefs.scoreA then
		hudRefs.scoreA.Text = tostring(math.max(0, scoreA))
	end
	if hudRefs.scoreB then
		hudRefs.scoreB.Text = tostring(math.max(0, scoreB))
	end
	if hudRefs.timer then
		hudRefs.timer.Text = tostring(math.max(0, timeLeft))
	end
end

local function _log(message: string)
	print("[MatchFeature] " .. message)
end

local function _findScreenGuiAncestor(node: Instance): ScreenGui?
	local current: Instance? = node
	while current ~= nil do
		if current:IsA("ScreenGui") then
			return current
		end
		current = current.Parent
	end

	return nil
end

local function _resolveEndResultsGui(playerGui: PlayerGui): ScreenGui?
	local direct = playerGui:FindFirstChild("EndResultsGui") or playerGui:FindFirstChild("EndResults")
	if direct then
		if direct:IsA("ScreenGui") then
			return direct
		end
		local fromDirect = _findScreenGuiAncestor(direct)
		if fromDirect then
			return fromDirect
		end
	end

	local recursiveNamed = playerGui:FindFirstChild("EndResultsGui", true) or playerGui:FindFirstChild("EndResults", true)
	if recursiveNamed then
		if recursiveNamed:IsA("ScreenGui") then
			return recursiveNamed
		end
		local fromNamed = _findScreenGuiAncestor(recursiveNamed)
		if fromNamed then
			return fromNamed
		end
	end

	local resultsScreen = playerGui:FindFirstChild("ResultsScreen", true)
	if resultsScreen then
		local fromResults = _findScreenGuiAncestor(resultsScreen)
		if fromResults then
			return fromResults
		end
	end

	for _, node in playerGui:GetDescendants() do
		if node:IsA("TextLabel") and string.lower(node.Name) == "winner" then
			local maybeGui = _findScreenGuiAncestor(node)
			if maybeGui then
				return maybeGui
			end
		end
	end

	return nil
end

local function _resolveMapVote(playerGui: PlayerGui, menuGui: ScreenGui): (GuiObject?, GuiObject?)
	local mapVoteFromMenu = menuGui:FindFirstChild("MapVote", true)
	if mapVoteFromMenu and mapVoteFromMenu:IsA("GuiObject") then
		local options = mapVoteFromMenu:FindFirstChild("Options", true)
		if options and options:IsA("GuiObject") then
			return mapVoteFromMenu, options
		end
	end

	for _, candidate in playerGui:GetDescendants() do
		if candidate.Name ~= "MapVote" or not candidate:IsA("GuiObject") then
			continue
		end

		local options = candidate:FindFirstChild("Options", true)
		if options and options:IsA("GuiObject") then
			return candidate, options
		end
	end

	return nil, nil
end

local function _hasOpenLobbyPanel(playerGui: PlayerGui): boolean
	local panelNames = {
		"LockerGui",
		"SettingsGui",
		"Store",
		"Cases",
		"Rewards",
	}

	for _, panelName in panelNames do
		local panel = playerGui:FindFirstChild(panelName)
		if panel and panel:IsA("ScreenGui") and panel.Enabled then
			return true
		end
	end

	return false
end

local function _findPlayButton(menuGui: ScreenGui): GuiButton?
	local bottom = menuGui:FindFirstChild("BottomContainer")
	if not bottom then
		return nil
	end

	local footer = bottom:FindFirstChild("Footer")
	if not footer then
		return nil
	end

	local playNode = footer:FindFirstChild("Play") or footer:FindFirstChild("play")
	if playNode and playNode:IsA("GuiButton") then
		return playNode
	end

	return nil
end

local function _ensureFadeGui(playerGui: PlayerGui): FadeRefs
	local existing = playerGui:FindFirstChild("MatchTransitionFade")
	if existing and existing:IsA("ScreenGui") then
		local existingFrame = existing:FindFirstChild("Fade")
		if existingFrame and existingFrame:IsA("Frame") then
			return {
				screenGui = existing,
				frame = existingFrame,
			}
		end
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MatchTransitionFade"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 9999
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		screenGui.ScreenInsets = Enum.ScreenInsets.None
	end)
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Fade"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.ZIndex = 9999
	frame.Parent = screenGui

	return {
		screenGui = screenGui,
		frame = frame,
	}
end

local function _tweenFade(frame: Frame, targetTransparency: number, tweenInfo: TweenInfo): Tween
	frame.Visible = true
	local tween = TweenService:Create(frame, tweenInfo, {
		BackgroundTransparency = targetTransparency,
	})
	tween:Play()
	if targetTransparency >= 1 then
		task.delay(tweenInfo.Time, function()
			frame.Visible = false
		end)
	end
	return tween
end

local function _setLobbyCamera()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local camerasFolder = workspace:FindFirstChild("Cameras")
	local lobbyPart = if camerasFolder then camerasFolder:FindFirstChild("lobby") else nil
	if lobbyPart and lobbyPart:IsA("BasePart") then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = lobbyPart.CFrame
	end
end

function MatchFeature.start(menuController: any): any
	local janitor = Janitor.new()

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local menuGui = menuController:getGui()
	menuGui.ResetOnSpawn = false
	local mapVoteNode, optionsNode = _resolveMapVote(playerGui, menuGui)
	local playButton = _findPlayButton(menuGui)
	local matchHudGui = playerGui:FindFirstChild("MatchHud")
	local deathScreenGui = playerGui:FindFirstChild("DeathScreen")
	local endResultsGui = _resolveEndResultsGui(playerGui)
	local fadeRefs = _ensureFadeGui(playerGui)
	local hudRefs = _resolveHudRefs(if matchHudGui and matchHudGui:IsA("ScreenGui") then matchHudGui else nil)

	if not mapVoteNode then
		warn("[MatchFeature] No se encontro Menu.MapVote")
		return janitor
	end

	if not optionsNode then
		warn("[MatchFeature] No se encontro Menu.MapVote.Options")
		return janitor
	end

	if not playButton then
		warn("[MatchFeature] No se encontro Menu.BottomContainer.Footer.Play")
		return janitor
	end

	local voteScreenGui = _findScreenGuiAncestor(mapVoteNode)
	local voteScreenWasEnabled = if voteScreenGui then voteScreenGui.Enabled else nil
	local shouldToggleVoteScreenGui = voteScreenGui ~= nil and voteScreenGui ~= menuGui
	local voteScreenTemporarilyEnabled = false

	_log("MapVote resolved at: " .. mapVoteNode:GetFullName())
	_log("Options resolved at: " .. optionsNode:GetFullName())
	if voteScreenGui then
		_log("MapVote ScreenGui: " .. voteScreenGui:GetFullName() .. " | enabled=" .. tostring(voteScreenGui.Enabled))
	end

	local view = MapVoteView.new(mapVoteNode, optionsNode)
	janitor:Add(view, "Destroy")

	local deathView = if deathScreenGui and deathScreenGui:IsA("ScreenGui") then DeathScreenView.new(deathScreenGui) else nil
	if deathView then
		janitor:Add(deathView, "Destroy")
	end

	local endResultsView = nil :: any
	local function ensureEndResultsView(): any
		if endResultsView then
			return endResultsView
		end

		local resolvedGui = _resolveEndResultsGui(playerGui)
		if not resolvedGui then
			return nil
		end

		endResultsGui = resolvedGui
		endResultsView = EndResultsView.new(resolvedGui)
		if endResultsView then
			janitor:Add(endResultsView, "Destroy")
		end

		return endResultsView
	end

	local isVoting = false
	local isInMatch = false
	local pendingRoundEndReturn = false
	local selectedMapName = ""
	local lastLocalVoteAt = 0
	local playEnabled = false
	local joinRequestInFlight = false
	local returnMenuInFlight = false
	local camera = workspace.CurrentCamera

	local function getCurrentMenuGui(): ScreenGui?
		local current = playerGui:FindFirstChild("Menu")
		if current and current:IsA("ScreenGui") then
			return current
		end

		if menuGui and menuGui.Parent then
			return menuGui
		end

		return nil
	end

	local function shouldKeepMenuHidden(): boolean
		return joinRequestInFlight or isInMatch
	end

	local function enforceMenuHiddenIfNeeded()
		local currentMenuGui = getCurrentMenuGui()
		if not currentMenuGui then
			return
		end

		currentMenuGui.ResetOnSpawn = false
		if shouldKeepMenuHidden() and currentMenuGui.Enabled then
			currentMenuGui.Enabled = false
		end
	end

	local function forceShowMenu()
		-- Hard reset de estado para evitar bloqueo permanente del menu.
		joinRequestInFlight = false
		isInMatch = false
		returnMenuInFlight = false

		local currentMenuGui = getCurrentMenuGui() or menuGui
		currentMenuGui.ResetOnSpawn = false
		currentMenuGui.Enabled = true
		menuController:show()

		-- Reaplicar una vez por seguridad ante scripts que oculten el menu justo despues.
		task.delay(0.2, function()
			if shouldKeepMenuHidden() then
				return
			end
			local lateMenu = getCurrentMenuGui()
			if lateMenu then
				lateMenu.Enabled = true
			end
		end)
	end

	if matchHudGui and matchHudGui:IsA("ScreenGui") then
		matchHudGui.Enabled = false
	end
	if endResultsGui then
		endResultsGui.Enabled = false
	end
	_setHudState(hudRefs, 0, 0, GameConfig.MaxRoundDuration)

	playButton.Active = false
	playButton.AutoButtonColor = false

	local function setPlayEnabled(enabled: boolean)
		playEnabled = enabled
		playButton.Active = enabled
		playButton.AutoButtonColor = enabled
	end

	if deathView then
		deathView:bind(function()
			if returnMenuInFlight then
				return
			end
			Network.Match.RequestRespawn.Send({})
		end, function()
			if returnMenuInFlight then
				return
			end
			returnMenuInFlight = true
			_tweenFade(fadeRefs.frame, 0, FADE_IN_TWEEN)
			task.delay(FADE_IN_TWEEN.Time, function()
				if returnMenuInFlight then
					Network.Match.RequestReturnToMenu.Send({})
				end
			end)
		end)
	end

	view:bindVoteHandler(function(mapName: string)
		if not isVoting then
			return
		end

		local now = time()
		if now - lastLocalVoteAt < LOCAL_VOTE_COOLDOWN then
			return
		end
		lastLocalVoteAt = now

		selectedMapName = mapName
		view:setSelectedMap(mapName)
		Network.Match.CastVote.Send({ mapName = mapName })
	end)

	janitor:Add(playButton.MouseButton1Click:Connect(function()
		if not playEnabled or joinRequestInFlight then
			return
		end

		joinRequestInFlight = true
		enforceMenuHiddenIfNeeded()
		_tweenFade(fadeRefs.frame, 0, FADE_IN_TWEEN)
		task.delay(FADE_IN_TWEEN.Time, function()
			if joinRequestInFlight then
				Network.Match.RequestJoinMatch.Send({})
				task.delay(JOIN_CONFIRM_TIMEOUT, function()
					if not joinRequestInFlight then
						return
					end
					joinRequestInFlight = false
					if not isInMatch then
						local currentMenuGui = getCurrentMenuGui()
						if currentMenuGui then
							currentMenuGui.Enabled = true
						end
					end
					_tweenFade(fadeRefs.frame, 1, FADE_OUT_TWEEN)
					warn("[MatchFeature] Join timeout waiting for spawn confirmation.")
				end)
			end
		end)
	end), "Disconnect")

	janitor:Add(Network.Match.MapLoadState.Listen(function(data: {
		isLoading: boolean,
		playEnabled: boolean,
		mapName: string,
	})
		if not data.playEnabled and not data.isLoading then
			isInMatch = false
		end
		setPlayEnabled(data.playEnabled and not data.isLoading)
		enforceMenuHiddenIfNeeded()
	end), true)

	janitor:Add(menuGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		enforceMenuHiddenIfNeeded()
	end), "Disconnect")

	janitor:Add(playerGui.ChildAdded:Connect(function(child)
		if child.Name == "Menu" and child:IsA("ScreenGui") then
			child.ResetOnSpawn = false
			if shouldKeepMenuHidden() then
				child.Enabled = false
			end
		end
	end), "Disconnect")

	janitor:Add(Players.LocalPlayer.CharacterAdded:Connect(function()
		if not isInMatch then
			return
		end
		enforceMenuHiddenIfNeeded()
	end), "Disconnect")

	janitor:Add(Network.Match.JoinMatchSpawned.Listen(function(_: {})
		joinRequestInFlight = false
		isInMatch = true
		pendingRoundEndReturn = false
		menuController:hide()
		enforceMenuHiddenIfNeeded()
		if deathView then
			deathView:hide()
		end
		local activeEndResultsView = ensureEndResultsView()
		if activeEndResultsView then
			activeEndResultsView:hide()
		end
		_setHudState(hudRefs, 0, 0, GameConfig.MaxRoundDuration)
		if matchHudGui and matchHudGui:IsA("ScreenGui") then
			matchHudGui.Enabled = true
		end
		task.defer(function()
			local currentCamera = camera or workspace.CurrentCamera
			if not currentCamera then
				return
			end
			local character = Players.LocalPlayer.Character
			if not character then
				character = Players.LocalPlayer.CharacterAdded:Wait()
			end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			currentCamera.CameraType = Enum.CameraType.Custom
			if humanoid then
				currentCamera.CameraSubject = humanoid
			end
		end)
		_tweenFade(fadeRefs.frame, 1, FADE_OUT_TWEEN)
	end), true)

	janitor:Add(Network.Match.RoundState.Listen(function(data: {
		scoreA: number,
		scoreB: number,
		timeLeft: number,
	})
		_setHudState(hudRefs, data.scoreA, data.scoreB, data.timeLeft)
	end), true)

	janitor:Add(Network.Match.DeathScreenShow.Listen(function(data: { respawnCooldown: number })
		if not deathView then
			return
		end
		deathView:show(data.respawnCooldown)
	end), true)

	janitor:Add(Network.Match.DeathScreenHide.Listen(function(_: {})
		if deathView then
			deathView:hide()
		end
	end), true)

	janitor:Add(Network.Match.ReturnToMenuDone.Listen(function(_: {})
		local hadReturnMenuInFlight = returnMenuInFlight
		local shouldShowMenu = hadReturnMenuInFlight or pendingRoundEndReturn

		returnMenuInFlight = false
		joinRequestInFlight = false
		isInMatch = false
		pendingRoundEndReturn = false

		if deathView then
			deathView:hide()
		end
		local activeEndResultsView = ensureEndResultsView()
		if activeEndResultsView then
			activeEndResultsView:hide()
		end
		if deathScreenGui and deathScreenGui:IsA("ScreenGui") then
			deathScreenGui.Enabled = false
		end
		if matchHudGui and matchHudGui:IsA("ScreenGui") then
			matchHudGui.Enabled = false
		end

		if shouldShowMenu then
			forceShowMenu()
		end
		_setLobbyCamera()
		_tweenFade(fadeRefs.frame, 1, FADE_OUT_TWEEN)
		Network.Match.RequestVoteSync.Send({})
	end), true)

	janitor:Add(Network.Match.RoundEnded.Listen(function(data: {
		winnerTeam: string,
		scoreA: number,
		scoreB: number,
	})
		isInMatch = false
		joinRequestInFlight = false
		pendingRoundEndReturn = true
		setPlayEnabled(false)
		if matchHudGui and matchHudGui:IsA("ScreenGui") then
			matchHudGui.Enabled = false
		end
		if deathView then
			deathView:hide()
		end

		local activeEndResultsView = ensureEndResultsView()
		if activeEndResultsView then
			activeEndResultsView:show({
				winnerTeam = data.winnerTeam,
				scoreA = data.scoreA,
				scoreB = data.scoreB,
				duration = GameConfig.EndResultsDuration,
				modeLabelText = "Resultados finales",
			}, function()
				_tweenFade(fadeRefs.frame, 0, FADE_IN_TWEEN)
			end)
		elseif endResultsGui then
			endResultsGui.Enabled = false
			warn("[MatchFeature] RoundEnded recibido pero no se resolvio EndResults GUI.")
		end
	end), true)

	janitor:Add(Network.Match.StartVote.Listen(function(data: {
		optionAName: string,
		optionAImage: string,
		optionAMode: string,
		optionBName: string,
		optionBImage: string,
		optionBMode: string,
		optionCName: string,
		optionCImage: string,
		optionCMode: string,
		duration: number,
	})
		_log(string.format("StartVote received. options=[%s, %s, %s], duration=%d", data.optionAName, data.optionBName, data.optionCName, data.duration))
		isVoting = true
		selectedMapName = ""
		if mapVoteNode:IsA("GuiObject") then
			mapVoteNode.Visible = true
		end
		local hasOpenPanel = _hasOpenLobbyPanel(playerGui)
		voteScreenTemporarilyEnabled = false
		if shouldToggleVoteScreenGui and voteScreenGui and voteScreenGui.Enabled == false and not hasOpenPanel then
			voteScreenGui.Enabled = true
			voteScreenTemporarilyEnabled = true
			_log("Enabled vote ScreenGui to display MapVote.")
		elseif hasOpenPanel then
			_log("StartVote received while a lobby panel is open; keeping current panel visible.")
		end
		view:show({
			optionA = { mapName = data.optionAName, mapImage = data.optionAImage, mapMode = data.optionAMode },
			optionB = { mapName = data.optionBName, mapImage = data.optionBImage, mapMode = data.optionBMode },
			optionC = { mapName = data.optionCName, mapImage = data.optionCImage, mapMode = data.optionCMode },
		}, data.duration)
		view:setSelectedMap("")
		_log("MapVote UI shown.")
	end), true)

	janitor:Add(Network.Match.VoteState.Listen(function(data: {
		optionAName: string,
		optionAVotes: number,
		optionBName: string,
		optionBVotes: number,
		optionCName: string,
		optionCVotes: number,
		timeLeft: number,
	})
		if not isVoting then
			return
		end

		view:updateTimer(data.timeLeft)
		view:updateVotes({
			[data.optionAName] = data.optionAVotes,
			[data.optionBName] = data.optionBVotes,
			[data.optionCName] = data.optionCVotes,
		})

		if selectedMapName ~= "" then
			view:setSelectedMap(selectedMapName)
		end
	end), true)

	janitor:Add(Network.Match.EndVote.Listen(function(_: { winnerMapName: string })
		isVoting = false
		selectedMapName = ""
		view:hide()
		if mapVoteNode:IsA("GuiObject") then
			mapVoteNode.Visible = false
		end
		if shouldToggleVoteScreenGui and voteScreenTemporarilyEnabled and voteScreenGui then
			voteScreenGui.Enabled = false
		end
		voteScreenTemporarilyEnabled = false
		_log("MapVote UI hidden (vote ended).")
	end), true)

	janitor:Add(function()
		isVoting = false
		isInMatch = false
		selectedMapName = ""
		joinRequestInFlight = false
		returnMenuInFlight = false
		setPlayEnabled(false)
		_setHudState(hudRefs, 0, 0, GameConfig.MaxRoundDuration)
		view:hide()
		if deathView then
			deathView:hide()
		end
		if mapVoteNode:IsA("GuiObject") then
			mapVoteNode.Visible = false
		end
		if matchHudGui and matchHudGui:IsA("ScreenGui") then
			matchHudGui.Enabled = false
		end
		if endResultsGui then
			endResultsGui.Enabled = false
		end
		fadeRefs.frame.BackgroundTransparency = 1
		fadeRefs.frame.Visible = false
		if voteScreenGui and voteScreenWasEnabled ~= nil then
			voteScreenGui.Enabled = voteScreenWasEnabled
		end
		voteScreenTemporarilyEnabled = false
	end, true)

	Network.Match.RequestVoteSync.Send({})
	_log("Requested vote sync from server.")

	_log("MatchFeature started and listeners bound.")

	return janitor
end

return MatchFeature
