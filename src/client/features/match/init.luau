--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion)
local GameConfig = require(Shared.GameConfig)
local Network = require(Shared.networking.Network)

local DataController = require(Client.core.data.DataController)
local IrisTransition = require(Client.core.ui.IrisTransition)

local MatchState = require(script.MatchState)
local MatchCamera = require(script.MatchCamera)
local MatchWeapons = require(script.MatchWeapons)
local MatchMenu = require(script.MatchMenu)
local MatchHud = require(script.MatchHud)

local DeathScreenView = require(script.DeathScreenView)
local EndResultsView = require(script.EndResultsView)
local KillCamController = require(script.KillCamController)
local NPCHighlightController = require(script.NPCHighlightController)
local HealthBillboardController = require(script.HealthBillboardController)
local MapVoteView = require(script.MapVoteView)


local MatchFeature = {}

local LOCAL_VOTE_COOLDOWN = 0.12
local JOIN_CONFIRM_TIMEOUT = 8

-- ── Helpers de resolución de GUI (uso puntual, no extraídos) ──

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

	for _, guiNode in playerGui:GetDescendants() do
		if guiNode:IsA("TextLabel") and string.lower(guiNode.Name) == "winner" then
			local maybeGui = _findScreenGuiAncestor(guiNode)
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

-- ── Feature principal ────────────────────────────────────────

function MatchFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local menuGui = menuController:getGui()
	local mapVoteNode, optionsNode = _resolveMapVote(playerGui, menuGui)
	local deathScreenGui = playerGui:FindFirstChild("DeathScreen")
	local endResultsGui = _resolveEndResultsGui(playerGui)
	local iris = IrisTransition.new(playerGui)

	if not mapVoteNode then
		warn("[MatchFeature] No se encontro Menu.MapVote")
		return janitor
	end
	if not optionsNode then
		warn("[MatchFeature] No se encontro Menu.MapVote.Options")
		return janitor
	end

	-- ── Inicializar sub-módulos ──────────────────────────────
	MatchState.reset()
	MatchMenu.init(menuController, playerGui, menuGui, MatchState.shouldKeepMenuHidden)

	local playButton = MatchMenu.getPlayButton()
	if not playButton then
		warn("[MatchFeature] No se encontro Menu.BottomContainer.Footer.Play")
		return janitor
	end

	local matchHudGui = playerGui:FindFirstChild("MatchHud")
	local hud = MatchHud.new(if matchHudGui and matchHudGui:IsA("ScreenGui") then matchHudGui else nil)
	hud:setScores(0, 0, GameConfig.MaxRoundDuration)

	-- ── Vistas ───────────────────────────────────────────────
	local voteScreenGui = _findScreenGuiAncestor(mapVoteNode)
	local voteScreenWasEnabled = if voteScreenGui then voteScreenGui.Enabled else nil
	local shouldToggleVoteScreenGui = voteScreenGui ~= nil and voteScreenGui ~= menuGui
	local voteScreenTemporarilyEnabled = false

	MatchMenu.setPhaseLabel("DEPLOY")

	local view = MapVoteView.new(mapVoteNode, optionsNode)
	janitor:Add(view, "Destroy")

	local deathView = if deathScreenGui and deathScreenGui:IsA("ScreenGui")
		then DeathScreenView.new(deathScreenGui)
		else nil
	local killCam = KillCamController.new(playerGui)
	janitor:Add(killCam, "Destroy")

	NPCHighlightController:Start()
	HealthBillboardController:Start()
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

	if endResultsGui then
		endResultsGui.Enabled = false
	end

	-- ── Estado local (ortogonal a MatchState) ────────────────
	local isVoting = false
	local selectedMapName = ""
	local lastLocalVoteAt = 0
	local playEnabled = false
	local respawnRequestSent = false

	playButton.Active = false
	playButton.AutoButtonColor = false

	local function setPlayEnabled(enabled: boolean)
		playEnabled = enabled
		playButton.Active = enabled
		playButton.AutoButtonColor = enabled
	end

	local function tryJoinMatchFromLobby()
		if not playEnabled or MatchState.getPhase() ~= "Lobby" then
			return
		end

		MatchState.setPhase("Joining")
		MatchMenu.enforceHidden()
		iris:close(function()
			if MatchState.getPhase() == "Joining" then
				Network.Match.RequestJoinMatch.Send({})
				task.delay(JOIN_CONFIRM_TIMEOUT, function()
					if MatchState.getPhase() ~= "Joining" then
						return
					end
					MatchState.setPhase("Lobby")
					MatchMenu.forceShow()
					iris:open()
					warn("[MatchFeature] Join timeout waiting for spawn confirmation.")
				end)
			end
		end)
	end

	local function notInActiveMatch(): boolean
		return not MatchState.isActive()
	end

	-- ── Bind de DeathView ────────────────────────────────────
	if deathView then
		deathView:bind(function()
			local phase = MatchState.getPhase()
			if phase == "ReturningToMenu" or respawnRequestSent then
				return
			end
			respawnRequestSent = true
			Network.Match.RequestRespawn.Send({})
		end, function()
			if MatchState.getPhase() == "ReturningToMenu" then
				return
			end
			MatchState.setPhase("ReturningToMenu")
			iris:close(function()
				if MatchState.getPhase() == "ReturningToMenu" then
					Network.Match.RequestReturnToMenu.Send({})
				end
			end)
		end)
	end

	-- ── Bind de MapVote ──────────────────────────────────────
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

	-- ── Conexiones de Players ────────────────────────────────
	janitor:Add(Players.PlayerAdded:Connect(function()
		hud:queuePlayerRowsUpdate()
	end), "Disconnect")

	janitor:Add(Players.PlayerRemoving:Connect(function(player)
		hud:onPlayerRemoved(player.UserId)
	end), "Disconnect")

	-- ── Play button ──────────────────────────────────────────
	janitor:Add(playButton.MouseButton1Click:Connect(function()
		tryJoinMatchFromLobby()
	end), "Disconnect")

	janitor:Add(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if input.KeyCode ~= Enum.KeyCode.Space then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		tryJoinMatchFromLobby()
	end), "Disconnect")

	-- ── Network: MapLoadState ────────────────────────────────
	janitor:Add(Network.Match.MapLoadState.Listen(function(data: {
		isLoading: boolean,
		playEnabled: boolean,
		mapName: string,
	})
		if isVoting then
			MatchMenu.setPhaseLabel("VOTING")
		else
			MatchMenu.setPhaseLabel("DEPLOY")
		end
		setPlayEnabled(data.playEnabled and not data.isLoading)
		MatchMenu.enforceHidden()
	end), true)

	-- ── Menu GUI tracking ────────────────────────────────────
	janitor:Add(menuGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		MatchMenu.enforceHidden()
	end), "Disconnect")

	janitor:Add(playerGui.ChildAdded:Connect(function(child)
		if child.Name == "Menu" and child:IsA("ScreenGui") then
			child.ResetOnSpawn = false
			MatchMenu.applyPhaseLabelToNewGui(child)
			if MatchMenu.shouldKeepHidden() then
				child.Enabled = false
			end
		end
	end), "Disconnect")

	-- ── CharacterAdded ───────────────────────────────────────
	janitor:Add(Players.LocalPlayer.CharacterAdded:Connect(function(character)
		local phase = MatchState.getPhase()

		-- Durante resultados, el jugador fue teleportado al lobby:
		-- limpiar armas y forzar cámara lobby con reintentos.
		if phase == "ShowingResults" then
			local guard = function()
				return MatchState.getPhase() == "ShowingResults"
			end
			MatchWeapons.cleanAllWithRetries(playerGui, guard)
			MatchCamera.forceLobbyWithRetries(guard)
			for _, delaySec in { 0, 0.1, 0.2, 0.5 } do
				task.delay(delaySec, function()
					if guard() then
						MatchWeapons.clearGui(playerGui)
					end
				end)
			end
			MatchMenu.enforceHidden()
			return
		end

		if not MatchState.isActive() then
			return
		end

		-- En kill cam: mantener cámara Scriptable, no restaurar a gameplay.
		if phase == "Dying" then
			task.defer(function()
				if MatchState.getPhase() == "Dying" then
					MatchCamera.forceScriptable()
				end
			end)
			MatchMenu.enforceHidden()
			return
		end

		-- InMatch: restaurar HUD y cámara de gameplay.
		hud:setEnabled(true)
		if deathScreenGui and deathScreenGui:IsA("ScreenGui") then
			deathScreenGui.Enabled = false
		end
		task.defer(function()
			MatchCamera.setGameplay(character)
		end)
		MatchMenu.enforceHidden()
	end), "Disconnect")

	-- ── Network: JoinMatchSpawned ────────────────────────────
	janitor:Add(Network.Match.JoinMatchSpawned.Listen(function(_: {})
		MatchState.setPhase("InMatch")
		killCam:stop()
		hud:resetMatchState()
		menuController:hide()
		MatchMenu.enforceHidden()
		if deathView then
			deathView:hide()
		end
		local activeEndResultsView = ensureEndResultsView()
		if activeEndResultsView then
			activeEndResultsView:hide()
		end
		hud:setScores(0, 0, GameConfig.MaxRoundDuration)
		hud:setEnabled(true)
		hud:queuePlayerRowsUpdate()
		task.defer(function()
			local character = Players.LocalPlayer.Character
			if not character then
				character = Players.LocalPlayer.CharacterAdded:Wait()
			end
			MatchCamera.setGameplay(character)
		end)
		iris:open()
	end), true)

	-- ── Network: RoundState ──────────────────────────────────
	janitor:Add(Network.Match.RoundState.Listen(function(data: {
		scoreA: number,
		scoreB: number,
		timeLeft: number,
	})
		hud:setScores(data.scoreA, data.scoreB, data.timeLeft)
	end), true)

	-- ── Network: PlayerStreakState ────────────────────────────
	janitor:Add(Network.Match.PlayerStreakState.Listen(function(data: {
		userId: string,
		kills: number,
		deaths: number,
		streak: number,
	})
		local userId = tonumber(data.userId)
		if not userId then
			return
		end
		hud:applyPlayerState(userId, data.kills, data.deaths, data.streak)

		-- Si es el jugador local, sincroniza el StreakController con el streak del servidor
	end), true)

	-- ── Network: BotRoster ───────────────────────────────────
	janitor:Add(Network.Match.BotRoster.Listen(function(data: { json: string })
		local ok, roster = pcall(HttpService.JSONDecode, HttpService, data.json)
		if not ok or type(roster) ~= "table" then
			return
		end
		local parsed = {} :: { [number]: any }
		for _, entry in roster do
			if type(entry) == "table" and type(entry.fakeUserId) == "number" then
				parsed[entry.fakeUserId] = {
					displayName = entry.displayName or "",
					team = entry.team or "",
					image = entry.image or "",
				}
			end
		end
		hud:setBotRoster(parsed)
	end), true)

	-- ── Network: DeathScreenShow ─────────────────────────────
	janitor:Add(Network.Match.DeathScreenShow.Listen(function(data: {
		respawnCooldown: number,
		killerUserId: string,
		killerName: string,
		weaponName: string,
		killerPositionX: number,
		killerPositionY: number,
		killerPositionZ: number,
	})
		hud:incrementLocalDeaths()
		if not deathView then
			return
		end

		MatchState.setPhase("Dying")
		respawnRequestSent = false
		MatchCamera.forceScriptable()
		hud:setEnabled(false)

		local killerPos = Vector3.new(data.killerPositionX, data.killerPositionY, data.killerPositionZ)
		killCam:start({
			killerUserId = data.killerUserId,
			killerName = data.killerName,
			weaponName = data.weaponName,
			killerPosition = if killerPos.Magnitude > 0 then killerPos else nil,
		})
		deathView:show(GameConfig.KillCamDuration)
	end), true)

	-- ── Network: DeathScreenHide ─────────────────────────────
	janitor:Add(Network.Match.DeathScreenHide.Listen(function(_: {})
		respawnRequestSent = false
		killCam:stop()
		if deathView then
			deathView:hide()
		end
		if MatchState.getPhase() == "Dying" then
			MatchState.setPhase("InMatch")
		end
		if MatchState.isActive() then
			task.defer(function()
				MatchCamera.setGameplay(Players.LocalPlayer.Character)
			end)
			hud:setEnabled(true)
		end
	end), true)

	-- ── Network: ReturnToMenuDone ────────────────────────────
	janitor:Add(Network.Match.ReturnToMenuDone.Listen(function(_: {})
		MatchState.setPhase("Lobby")
		killCam:stop()
		hud:resetMatchState()
		if deathView then
			deathView:hide()
		end
		local activeEndResultsView = ensureEndResultsView()
		if activeEndResultsView then
			activeEndResultsView:hide()
		end
		if endResultsGui then
			endResultsGui.Enabled = false
		end
		if deathScreenGui and deathScreenGui:IsA("ScreenGui") then
			deathScreenGui.Enabled = false
		end
		hud:setEnabled(false)
		MatchWeapons.cleanAllWithRetries(playerGui, notInActiveMatch)
		MatchCamera.forceLobbyWithRetries(notInActiveMatch)
		MatchMenu.forceShow()
		iris:open()
		Network.Match.RequestVoteSync.Send({})
	end), true)

	-- ── Network: RoundEnded ──────────────────────────────────
	janitor:Add(Network.Match.RoundEnded.Listen(function(data: {
		winnerTeam: string,
		scoreA: number,
		scoreB: number,
	})
		local prevPhase = MatchState.getPhase()
		local wasActive = prevPhase == "InMatch" or prevPhase == "Dying" or prevPhase == "ReturningToMenu"
		local wasJoining = prevPhase == "Joining"

		-- Limpiar estado inmediatamente.
		MatchState.setPhase("Lobby")
		MatchMenu.setPhaseLabel("ENDING")
		killCam:stop()
		setPlayEnabled(false)
		hud:setEnabled(false)
		if deathView then
			deathView:hide()
		end
		if deathScreenGui and deathScreenGui:IsA("ScreenGui") then
			deathScreenGui.Enabled = false
		end

		MatchWeapons.cleanAllWithRetries(playerGui, notInActiveMatch)

		-- Capturar datos de jugadores ANTES de resetear roster.
		local localTeam, playerEntries = hud:captureEndResultsData()
		hud:resetMatchState()

		if wasActive or wasJoining then
			MatchCamera.forceLobbyWithRetries(notInActiveMatch)
			iris:open()
		end

		-- Si estaba en partida: mostrar ResultsScreen; al pulsar CloseBtn → menú.
		if wasActive then
			MatchState.setPhase("ShowingResults")
			MatchMenu.enforceHidden()
			local activeEndResultsView = ensureEndResultsView()
			if activeEndResultsView then
				activeEndResultsView:show({
					winnerTeam = data.winnerTeam,
					localTeam = localTeam,
					scoreA = data.scoreA,
					scoreB = data.scoreB,
					duration = GameConfig.EndResultsDuration,
					players = playerEntries,
				}, function()
					activeEndResultsView:hide(function()
						MatchState.setPhase("Lobby")
						MatchMenu.setPhaseLabel("DEPLOY")
						MatchMenu.forceShow()
					end)
				end)
			else
				MatchState.setPhase("Lobby")
				MatchMenu.forceShow()
			end
		elseif wasJoining then
			MatchMenu.forceShow()
		end
	end), true)

	-- ── Network: StartVote ───────────────────────────────────
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
		isVoting = true
		MatchMenu.setPhaseLabel("VOTING")
		selectedMapName = ""
		if mapVoteNode:IsA("GuiObject") then
			mapVoteNode.Visible = true
		end
		local hasOpenPanel = MatchMenu.hasOpenLobbyPanel()
		voteScreenTemporarilyEnabled = false
		if shouldToggleVoteScreenGui and voteScreenGui and voteScreenGui.Enabled == false and not hasOpenPanel then
			voteScreenGui.Enabled = true
			voteScreenTemporarilyEnabled = true
		end
		view:show({
			optionA = { mapName = data.optionAName, mapImage = data.optionAImage, mapMode = data.optionAMode },
			optionB = { mapName = data.optionBName, mapImage = data.optionBImage, mapMode = data.optionBMode },
			optionC = { mapName = data.optionCName, mapImage = data.optionCImage, mapMode = data.optionCMode },
		}, data.duration)
		view:setSelectedMap("")
	end), true)

	-- ── Network: VoteState ───────────────────────────────────
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

	-- ── Network: EndVote ─────────────────────────────────────
	janitor:Add(Network.Match.EndVote.Listen(function(_: { winnerMapName: string })
		isVoting = false
		MatchMenu.setPhaseLabel("DEPLOY")
		selectedMapName = ""
		view:hide()
		if mapVoteNode:IsA("GuiObject") then
			mapVoteNode.Visible = false
		end
		if shouldToggleVoteScreenGui and voteScreenTemporarilyEnabled and voteScreenGui then
			voteScreenGui.Enabled = false
		end
		voteScreenTemporarilyEnabled = false
	end), true)

	-- ── DataController observer ──────────────────────────────
	DataController:WhenReady():andThen(function()
		local function updateCashAndLevel()
			local stats = Fusion.peek(DataController.Stats) :: any
			hud:updateCashLevel(stats)
		end
		local statsObserver = fusionScope:Observer(DataController.Stats)
		janitor:Add(statsObserver:onBind(updateCashAndLevel), true)
		updateCashAndLevel()
	end)

	-- ── Cleanup ──────────────────────────────────────────────
	janitor:Add(function()
		MatchState.reset()
		isVoting = false
		selectedMapName = ""
		setPlayEnabled(false)
		hud:setScores(0, 0, GameConfig.MaxRoundDuration)
		view:hide()
		if deathView then
			deathView:hide()
		end
		killCam:stop()
		if mapVoteNode:IsA("GuiObject") then
			mapVoteNode.Visible = false
		end
		hud:setEnabled(false)
		if endResultsGui then
			endResultsGui.Enabled = false
		end
		local irisCircle = iris._circle
		irisCircle.Size = UDim2.new(0, 0, 0, 0)
		irisCircle.Visible = false
		if voteScreenGui and voteScreenWasEnabled ~= nil then
			voteScreenGui.Enabled = voteScreenWasEnabled
		end
		voteScreenTemporarilyEnabled = false
		Fusion.doCleanup(fusionScope)
	end, true)

	Network.Match.RequestVoteSync.Send({})

	return janitor
end

return MatchFeature
