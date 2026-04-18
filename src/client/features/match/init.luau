--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion)
local GameConfig = require(Shared.GameConfig)
local Network = require(Shared.networking.Network)

local DataController = require(Client.core.data.DataController)
local DeathScreenView = require(Client.features.match.DeathScreenView)
local EndResultsView = require(Client.features.match.EndResultsView)
local KillCamController = require(Client.features.match.KillCamController)
local MapVoteView = require(Client.features.match.MapVoteView)

local MatchFeature = {}

local LOCAL_VOTE_COOLDOWN = 0.12
local FADE_IN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local JOIN_CONFIRM_TIMEOUT = 8
local STREAK_ANIMATION_FPS = 5
local STREAK_ANIMATION_FRAMES = {
	"rbxassetid://133335961818532",
	"rbxassetid://88381693098755",
	"rbxassetid://100516583629199",
}

type FadeRefs = {
	screenGui: ScreenGui,
	frame: Frame,
}

type HudRefs = {
	scoreA: TextLabel?,
	scoreB: TextLabel?,
	timer: TextLabel?,
	localKills: TextLabel?,
	cashValue: TextLabel?,
	levelValue: TextLabel?,
	levelBarFill: GuiObject?,
	playerRows: { HudPlayerRowRefs },
}

type HudPlayerRowRefs = {
	root: GuiObject,
	profile: ImageLabel?,
	streak: GuiObject?,
	streakValue: TextLabel?,
	totalKillsValue: TextLabel?,
	streakAnimatedImage: ImageLabel?,
}

local function _findChildGuiObject(parent: Instance?, childName: string): GuiObject?
	if not parent then
		return nil
	end

	local node = parent:FindFirstChild(childName)
	if node and node:IsA("GuiObject") then
		return node
	end

	return nil
end

local function _findChildTextLabel(parent: Instance?, childName: string): TextLabel?
	if not parent then
		return nil
	end

	local node = parent:FindFirstChild(childName)
	if node and node:IsA("TextLabel") then
		return node
	end

	return nil
end

local function _findFirstImageLabel(root: Instance?): ImageLabel?
	if not root then
		return nil
	end

	if root:IsA("ImageLabel") then
		return root
	end

	for _, node in root:GetDescendants() do
		if node:IsA("ImageLabel") then
			return node
		end
	end

	return nil
end

local function _collectHudPlayerRows(matchHudGui: ScreenGui): { HudPlayerRowRefs }
	local playersContainer = _findChildGuiObject(matchHudGui, "Players")
	if not playersContainer then
		return {}
	end

	local indexedRows = {} :: { { index: number, row: HudPlayerRowRefs } }
	for _, child in playersContainer:GetChildren() do
		if not child:IsA("GuiObject") then
			continue
		end

		local index = tonumber(child.Name)
		if not index then
			continue
		end

		local profileNode = child:FindFirstChild("Profile")
		local streakNode = child:FindFirstChild("Streak")
		local streakGui = if streakNode and streakNode:IsA("GuiObject") then streakNode else nil
		local streakValueNode = if streakGui then (streakGui:FindFirstChild("Kills") or streakGui:FindFirstChild("Value")) else nil
		local streakValue = if streakValueNode and streakValueNode:IsA("TextLabel") then streakValueNode else nil
		local totalKillsNode = child:FindFirstChild("Kills")
		local totalKillsValueNode = if totalKillsNode and totalKillsNode:IsA("TextLabel")
			then totalKillsNode
			elseif totalKillsNode and totalKillsNode:IsA("GuiObject")
				then (totalKillsNode:FindFirstChild("Value") or totalKillsNode:FindFirstChild("Kills"))
				else nil
		local totalKillsValue = if totalKillsValueNode and totalKillsValueNode:IsA("TextLabel") then totalKillsValueNode else nil
		local streakAnimatedImage = _findFirstImageLabel(streakGui)

		table.insert(indexedRows, {
			index = index,
			row = {
				root = child,
				profile = if profileNode and profileNode:IsA("ImageLabel") then profileNode else nil,
				streak = streakGui,
				streakValue = streakValue,
				totalKillsValue = totalKillsValue,
				streakAnimatedImage = streakAnimatedImage,
			},
		})
	end

	table.sort(indexedRows, function(a, b)
		return a.index < b.index
	end)

	local rows = {} :: { HudPlayerRowRefs }
	for _, entry in indexedRows do
		table.insert(rows, entry.row)
	end

	return rows
end

local function _resolveHudRefs(matchHudGui: ScreenGui?): HudRefs
	if not matchHudGui then
		return {
			scoreA = nil,
			scoreB = nil,
			timer = nil,
			localKills = nil,
			playerRows = {},
		}
	end

	local statusNode = _findChildGuiObject(matchHudGui, "Status")
	local scoreANode = _findChildGuiObject(statusNode, "ScoreA")
	local scoreBNode = _findChildGuiObject(statusNode, "ScoreB")
	local timerNode = _findChildGuiObject(statusNode, "Timer")
	local cashNode = _findChildGuiObject(statusNode, "Cash")
	local levelNode = _findChildGuiObject(statusNode, "Level")
	local streakNode = _findChildGuiObject(matchHudGui, "Streak")

	return {
		scoreA = _findChildTextLabel(scoreANode, "Value"),
		scoreB = _findChildTextLabel(scoreBNode, "Value"),
		timer = _findChildTextLabel(timerNode, "Value"),
		localKills = _findChildTextLabel(streakNode, "Kills"),
		cashValue = _findChildTextLabel(cashNode, "Value"),
		levelValue = _findChildTextLabel(levelNode, "Value"),
		levelBarFill = if levelNode then _findChildGuiObject(levelNode, "Fill") else nil,
		playerRows = _collectHudPlayerRows(matchHudGui),
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

local function _updatePlayerCashLevel(hudRefs: HudRefs, stats: any)
	if hudRefs.cashValue then
		local cash = if stats and type(stats.Cash) == "number" then stats.Cash else 0
		hudRefs.cashValue.Text = tostring(math.max(0, cash))
	end

	if hudRefs.levelValue then
		local level = if stats and type(stats.Level) == "number" then stats.Level else 0
		hudRefs.levelValue.Text = string.format("LVL %d", level)
	end

	if hudRefs.levelBarFill then
		local currentXP = if stats and type(stats.XP) == "number" then stats.XP else 0
		local xpToNext = if stats and type(stats.XPToNextLevel) == "number" then stats.XPToNextLevel else 1
		local fillRatio = math.min(1, math.max(0, currentXP / xpToNext))
		hudRefs.levelBarFill.Size = UDim2.new(fillRatio, 0, 1, 0)
	end
end

local function _setHudLocalKills(hudRefs: HudRefs, kills: number)
	if hudRefs.localKills then
		hudRefs.localKills.Text = tostring(math.max(0, kills))
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
		camera.CameraSubject = nil
		camera.CFrame = lobbyPart.CFrame
	end
end

local function _setGameplayCamera(character: Model?)
	local currentCamera = workspace.CurrentCamera
	if not currentCamera then
		return
	end

	local targetCharacter = character
	if not targetCharacter then
		targetCharacter = Players.LocalPlayer.Character
	end
	if not targetCharacter then
		return
	end

	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	currentCamera.CameraType = Enum.CameraType.Custom
	currentCamera.CameraSubject = humanoid
end

function MatchFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)

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
	local killCam = KillCamController.new(playerGui)
	janitor:Add(killCam, "Destroy")
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
	local localUserId = Players.LocalPlayer.UserId
	local localMatchKills = 0
	local playerKillsByUserId  = {} :: { [number]: number }
	local playerStreakByUserId = {} :: { [number]: number }
	local playerDeathsByUserId = {} :: { [number]: number }
	local rowUserIdByIndex = {} :: { [number]: number? }
	local streakAnimationRunning = true

	local function preloadStreakImages()
		for _, id in STREAK_ANIMATION_FRAMES do
			local tempImage = Instance.new("ImageLabel")
			tempImage.Image = id
			ContentProvider:PreloadAsync({ tempImage })
			tempImage:Destroy()
		end
	end

	local function setRowStats(rowRef: HudPlayerRowRefs, streakValue: number, totalKills: number)
		if not rowRef.streak then
			if rowRef.totalKillsValue then
				rowRef.totalKillsValue.Text = tostring(math.max(0, totalKills))
			end
			return
		end

		local isVisible = streakValue > 0
		rowRef.streak.Visible = isVisible
		if rowRef.streakValue then
			rowRef.streakValue.Text = tostring(math.max(0, streakValue))
		end
		if rowRef.totalKillsValue then
			rowRef.totalKillsValue.Text = tostring(math.max(0, totalKills))
		end
	end

	local function updatePlayerRows()
		if #hudRefs.playerRows == 0 then
			return
		end

		local players = Players:GetPlayers()
		table.sort(players, function(a, b)
			local killsA = playerKillsByUserId[a.UserId] or 0
			local killsB = playerKillsByUserId[b.UserId] or 0
			if killsA ~= killsB then
				return killsA > killsB
			end

			local streakA = playerStreakByUserId[a.UserId] or 0
			local streakB = playerStreakByUserId[b.UserId] or 0
			if streakA ~= streakB then
				return streakA > streakB
			end

			if a.Name ~= b.Name then
				return a.Name < b.Name
			end

			return a.UserId < b.UserId
		end)

		for index, rowRef in ipairs(hudRefs.playerRows) do
			local player = players[index]
			rowRef.root.Visible = player ~= nil
			if not player then
				rowUserIdByIndex[index] = nil
				if rowRef.profile then
					rowRef.profile.Image = ""
				end
				setRowStats(rowRef, 0, 0)
				continue
			end

			rowUserIdByIndex[index] = player.UserId
			if rowRef.profile then
				local expectedUserId = player.UserId
				local rowIndex = index
				local profileRef = rowRef.profile
				task.spawn(function()
					local ok, content = pcall(function()
						return Players:GetUserThumbnailAsync(expectedUserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
					end)
					if not ok or not streakAnimationRunning then
						return
					end
					if rowUserIdByIndex[rowIndex] ~= expectedUserId then
						return
					end
					profileRef.Image = content
				end)
			end

			setRowStats(
				rowRef,
				playerStreakByUserId[player.UserId] or 0,
				playerKillsByUserId[player.UserId] or 0
			)
		end
	end

	local function setLocalMatchKills(value: number)
		localMatchKills = math.max(0, value)
		_setHudLocalKills(hudRefs, localMatchKills)
	end

	local function resetAllStreakState()
		setLocalMatchKills(0)
		table.clear(playerKillsByUserId)
		table.clear(playerStreakByUserId)
		table.clear(playerDeathsByUserId)
		playerStreakByUserId[localUserId] = 0
		playerKillsByUserId[localUserId]  = 0
		playerDeathsByUserId[localUserId] = 0
		updatePlayerRows()
	end

	local function applyPlayerStreakState(userId: number, kills: number, streak: number)
		playerKillsByUserId[userId] = math.max(0, kills)
		playerStreakByUserId[userId] = math.max(0, streak)
		if userId == localUserId then
			setLocalMatchKills(playerKillsByUserId[userId])
		end
		updatePlayerRows()
	end

	task.spawn(preloadStreakImages)
	for _, rowRef in hudRefs.playerRows do
		setRowStats(rowRef, 0, 0)
		if rowRef.streakAnimatedImage then
			local animatedImage = rowRef.streakAnimatedImage
			local streakRef = rowRef.streak
			task.spawn(function()
				local frameIndex = 1
				while streakAnimationRunning do
					if streakRef and streakRef.Visible then
						animatedImage.Image = STREAK_ANIMATION_FRAMES[frameIndex]
						frameIndex += 1
						if frameIndex > #STREAK_ANIMATION_FRAMES then
							frameIndex = 1
						end
					end
					task.wait(1 / STREAK_ANIMATION_FPS)
				end
			end)
		end
	end
	updatePlayerRows()
	resetAllStreakState()

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

	local function clearWeaponsSystemGui()
		for _, node in playerGui:GetChildren() do
			if not node:IsA("ScreenGui") then
				continue
			end

			local isWeaponsGui = node.Name == "WeaponsSystemGui"
				or node.Name == "WeaponGUI"
				or node.Name == "WeaponGui"

			if not isWeaponsGui then
				local scalingElements = node:FindFirstChild("ScalingElements")
				local hasCrosshair = node:FindFirstChild("Crosshair", true) ~= nil
				isWeaponsGui = scalingElements ~= nil and hasCrosshair
			end

			if isWeaponsGui then
				node.Enabled = false
			end
		end
	end

	local cachedWeaponsSystemModule = nil :: any
	local attemptedWeaponsSystemResolve = false

	local function getWeaponsSystemModule(): any
		if attemptedWeaponsSystemResolve then
			return cachedWeaponsSystemModule
		end
		attemptedWeaponsSystemResolve = true

		local weaponsSystemFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
		if not weaponsSystemFolder then
			return nil
		end

		local weaponsSystemModule = weaponsSystemFolder:FindFirstChild("WeaponsSystem")
		if not weaponsSystemModule or not weaponsSystemModule:IsA("ModuleScript") then
			return nil
		end

		local ok, moduleOrError = pcall(function()
			return require(weaponsSystemModule)
		end)
		if ok then
			cachedWeaponsSystemModule = moduleOrError
			return cachedWeaponsSystemModule
		end

		warn("[MatchFeature] No se pudo cargar WeaponsSystem module: " .. tostring(moduleOrError))
		return nil
	end

	local function deactivateWeaponsRuntimeState()
		local weaponsSystem = getWeaponsSystemModule()
		if not weaponsSystem then
			return
		end

		if weaponsSystem.resetClientRuntimeState then
			weaponsSystem.resetClientRuntimeState()
			return
		end

		weaponsSystem.currentWeapon = nil

		if weaponsSystem.gui and weaponsSystem.gui.setEnabled then
			weaponsSystem.gui:setEnabled(false)
		end

		if weaponsSystem.camera then
			if weaponsSystem.camera.setEnabled then
				weaponsSystem.camera:setEnabled(false)
			end
			weaponsSystem.camera.rotateCharacterWithCamera = false
			if weaponsSystem.camera.resetZoomFactor then
				weaponsSystem.camera:resetZoomFactor()
			end
			if weaponsSystem.camera.setHasScope then
				weaponsSystem.camera:setHasScope(false)
			end
		end
	end

	local function clearLocalWeaponsAndUi()
		local localPlayer = Players.LocalPlayer
		local character = localPlayer.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid:UnequipTools()
				-- Evita que quede pegada la pose de arma (hold/reload/aim) al cerrar ronda.
				for _, track in humanoid:GetPlayingAnimationTracks() do
					local priority = track.Priority
					if priority == Enum.AnimationPriority.Action
						or priority == Enum.AnimationPriority.Action2
						or priority == Enum.AnimationPriority.Action3
						or priority == Enum.AnimationPriority.Action4
					then
						track:Stop(0)
					end
				end
			end
		end

		deactivateWeaponsRuntimeState()

		local backpack = localPlayer:FindFirstChildOfClass("Backpack")
		if backpack then
			for _, tool in backpack:GetChildren() do
				if tool:IsA("Tool") then
					tool:Destroy()
				end
			end
		end

		if character then
			for _, tool in character:GetChildren() do
				if tool:IsA("Tool") then
					tool:Destroy()
				end
			end
		end

		clearWeaponsSystemGui()
	end

	local function clearLocalWeaponsAndUiWithRetries()
		clearLocalWeaponsAndUi()
		for _, delaySec in { 0.05, 0.2, 0.5 } do
			task.delay(delaySec, function()
				if pendingRoundEndReturn or not isInMatch then
					clearLocalWeaponsAndUi()
				end
			end)
		end
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

	janitor:Add(function()
		streakAnimationRunning = false
	end, true)

	janitor:Add(Players.PlayerAdded:Connect(function()
		updatePlayerRows()
	end), "Disconnect")

	janitor:Add(Players.PlayerRemoving:Connect(function(player)
		playerKillsByUserId[player.UserId] = nil
		playerStreakByUserId[player.UserId] = nil
		updatePlayerRows()
	end), "Disconnect")

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

	janitor:Add(Players.LocalPlayer.CharacterAdded:Connect(function(character)
		if pendingRoundEndReturn then
			clearLocalWeaponsAndUiWithRetries()
		end
		if not isInMatch then
			return
		end
		task.defer(function()
			_setGameplayCamera(character)
		end)
		enforceMenuHiddenIfNeeded()
	end), "Disconnect")

	janitor:Add(Network.Match.JoinMatchSpawned.Listen(function(_: {})
		joinRequestInFlight = false
		isInMatch = true
		pendingRoundEndReturn = false
		killCam:stop()
		resetAllStreakState()
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
			local character = Players.LocalPlayer.Character
			if not character then
				character = Players.LocalPlayer.CharacterAdded:Wait()
			end
			_setGameplayCamera(character)
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

	janitor:Add(Network.Match.PlayerStreakState.Listen(function(data: {
		userId: string,
		kills: number,
		streak: number,
	})
		local userId = tonumber(data.userId)
		if not userId then
			return
		end
		applyPlayerStreakState(userId, data.kills, data.streak)
	end), true)

	janitor:Add(Network.Match.DeathScreenShow.Listen(function(data: {
		respawnCooldown: number,
		killerUserId: string,
		killerName: string,
		weaponName: string,
	})
		playerDeathsByUserId[localUserId] = (playerDeathsByUserId[localUserId] or 0) + 1
		if not deathView then
			return
		end
		killCam:start({
			killerUserId = data.killerUserId,
			killerName = data.killerName,
			weaponName = data.weaponName,
		})
		deathView:show(data.respawnCooldown)
	end), true)

	janitor:Add(Network.Match.DeathScreenHide.Listen(function(_: {})
		killCam:stop()
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
		killCam:stop()
		resetAllStreakState()

		if deathView then
			deathView:hide()
		end
		local activeEndResultsView = ensureEndResultsView()
		if activeEndResultsView then
			activeEndResultsView:hide()
		end
		if endResultsGui then
			-- Evita solape visual: ocultar ResultsScreen antes de volver a mostrar Menu.
			endResultsGui.Enabled = false
		end
		if deathScreenGui and deathScreenGui:IsA("ScreenGui") then
			deathScreenGui.Enabled = false
		end
		if matchHudGui and matchHudGui:IsA("ScreenGui") then
			matchHudGui.Enabled = false
		end
		clearLocalWeaponsAndUiWithRetries()

		if shouldShowMenu then
			forceShowMenu()
		end
		_setLobbyCamera()
		-- Reaplicar en diferido por si algún sistema pisa la cámara al volver al menú.
		task.delay(0.2, function()
			if not isInMatch and not joinRequestInFlight then
				_setLobbyCamera()
			end
		end)
		task.delay(0.6, function()
			if not isInMatch and not joinRequestInFlight then
				_setLobbyCamera()
			end
		end)
		Network.Match.RequestVoteSync.Send({})
		_tweenFade(fadeRefs.frame, 1, FADE_OUT_TWEEN)
	end), true)

	janitor:Add(Network.Match.RoundEnded.Listen(function(data: {
		winnerTeam: string,
		scoreA: number,
		scoreB: number,
	})
		isInMatch = false
		joinRequestInFlight = false
		pendingRoundEndReturn = true
		killCam:stop()
		resetAllStreakState()
		setPlayEnabled(false)
		if matchHudGui and matchHudGui:IsA("ScreenGui") then
			matchHudGui.Enabled = false
		end
		if deathView then
			deathView:hide()
		end

		clearLocalWeaponsAndUiWithRetries()

		-- Determinar equipo del jugador local
		local localPlayerTeam = Players.LocalPlayer.Team
		local localTeam = ""
		if localPlayerTeam then
			if localPlayerTeam.Name == GameConfig.Teams.A.Name then
				localTeam = "A"
			elseif localPlayerTeam.Name == GameConfig.Teams.B.Name then
				localTeam = "B"
			end
		end

		-- Construir lista de jugadores con stats de la partida
		local playerEntries = {}
		for _, player in Players:GetPlayers() do
			local playerSide = ""
			if player.Team then
				if player.Team.Name == GameConfig.Teams.A.Name then
					playerSide = "A"
				elseif player.Team.Name == GameConfig.Teams.B.Name then
					playerSide = "B"
				end
			end
			if playerSide == "" then continue end

			local level = 0
			local leaderstats = player:FindFirstChild("leaderstats")
			if leaderstats then
				local levelNode = leaderstats:FindFirstChild("Level")
				if levelNode and (levelNode:IsA("IntValue") or levelNode:IsA("NumberValue")) then
					level = (levelNode :: IntValue).Value
				end
			end

			table.insert(playerEntries, {
				userId  = player.UserId,
				name    = player.Name,
				team    = playerSide :: "A" | "B",
				kills   = playerKillsByUserId[player.UserId] or 0,
				deaths  = playerDeathsByUserId[player.UserId] or 0,
				level   = level,
			})
		end

		local activeEndResultsView = ensureEndResultsView()
		if activeEndResultsView then
			activeEndResultsView:show({
				winnerTeam  = data.winnerTeam,
				localTeam   = localTeam,
				scoreA      = data.scoreA,
				scoreB      = data.scoreB,
				duration    = GameConfig.EndResultsDuration,
				players     = playerEntries,
			})
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

	DataController:WhenReady():andThen(function()
		local function updateCashAndLevel()
			local stats = Fusion.peek(DataController.Stats) :: any
			_updatePlayerCashLevel(hudRefs, stats)
		end

		local statsObserver = fusionScope:Observer(DataController.Stats)
		janitor:Add(statsObserver:onBind(updateCashAndLevel), true)

		updateCashAndLevel()
	end)

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
		killCam:stop()
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
		Fusion.doCleanup(fusionScope)
	end, true)

	Network.Match.RequestVoteSync.Send({})
	_log("Requested vote sync from server.")

	_log("MatchFeature started and listeners bound.")

	return janitor
end

return MatchFeature
