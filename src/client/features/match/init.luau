--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion)
local GameConfig = require(Shared.GameConfig)
local MatchSnapshot = require(Shared.MatchSnapshot)
local Network = require(Shared.networking.Network)

local IrisTransition = require(Client.core.ui.IrisTransition)
local ScreenFade = require(Client.core.ui.ScreenFade)

local MatchState = require(script.MatchState)
local MatchCamera = require(script.MatchCamera)
local MatchWeapons = require(script.MatchWeapons)
local MatchMenu = require(script.MatchMenu)
local MatchHud = require(script.MatchHud)
local MatchProgressionObserver = require(script.MatchProgressionObserver)

local DeathScreenView = require(script.DeathScreenView)
local ResultsView = require(script.ResultsView)
local ResultsScene = require(script.ResultsScene)
local KillCamFollowController = require(script.KillCamFollowController)
local CharacterHighlightController = require(script.CharacterHighlightController)
local HealthBillboardController = require(script.HealthBillboardController)
local MapVoteView = require(script.MapVoteView)
local PanelController = require(Client.core.ui.PanelController)
local BlurController = require(Client.core.ui.BlurController)
local TouchControlsController = require(Client.core.ui.TouchControlsController)
local ScenePresetController = require(Client.core.lighting.ScenePresetController)
local DepthOfFieldController = require(Client.core.lighting.DepthOfFieldController)


local MatchFeature = {}

-- "Reset Character": `false` lo apaga, `true` = por defecto (mata), BindableEvent =
-- Roblox mantiene la confirmación y dispara el evento en vez de matar.
-- SetCore falla hasta que CoreGui está listo, de ahí los reintentos.
local function setResetButtonCallback(callback: boolean | BindableEvent)
	task.spawn(function()
		local ok = false
		local attempts = 0
		repeat
			ok = pcall(function()
				StarterGui:SetCore("ResetButtonCallback", callback)
			end)
			attempts += 1
			if not ok then
				task.wait(0.2)
			end
		until ok or attempts >= 20
	end)
end

local LOCAL_VOTE_COOLDOWN = 0.3
local JOIN_CONFIRM_TIMEOUT = 8
local RESPAWN_REQUEST_TIMEOUT = 5
local RETURN_TO_MENU_TIMEOUT = 8
-- Negro entre el fundido de fin de ronda y Resultados: frames para que las réplicas
-- carguen idle, cara y hat antes de verse.
local RESULTS_BLACK_HOLD = 0.35
-- Si la votación no arranca en este tiempo tras Results, se vuelve al menú.
local VOTE_AUTO_TIMEOUT = 8

-- Lighting por atributo `LightingPreset`, sin nombres de preset en código:
-- lobby → Workspace.Cameras.lobby; partida → Workspace.ActiveMap o su modelo hijo.
local function resolveLobbyPresetNode(): Instance?
	local cameras = Workspace:FindFirstChild("Cameras")
	return if cameras then cameras:FindFirstChild("lobby") else nil
end

local function resolveMapPresetNode(): Instance?
	local activeMap = Workspace:FindFirstChild("ActiveMap")
	if not activeMap then
		return nil
	end
	if activeMap:GetAttribute("LightingPreset") ~= nil then
		return activeMap
	end
	for _, child in activeMap:GetChildren() do
		if child:GetAttribute("LightingPreset") ~= nil then
			return child
		end
	end
	return nil
end

-- false = nodo ausente o sin atributo: quien necesite garantizar el cambio de look
-- debe reaccionar en vez de quedarse con el preset anterior.
local function applyScenePreset(node: Instance?): boolean
	if node then
		return ScenePresetController.applyFrom(node)
	end
	return false
end

local function _resolveResultsFrame(playerGui: PlayerGui): GuiObject?
	local ui = playerGui:FindFirstChild("UserInterface")
	local node = if ui then ui:FindFirstChild("Results") else nil
	if node and node:IsA("GuiObject") then
		return node
	end
	warn("[MatchFeature] No se encontró PlayerGui.UserInterface.Results — la pantalla de Resultados (frames + rewards) no se mostrará.")
	return nil
end

local function _resolveDeathScreen(playerGui: PlayerGui): GuiObject?
	local ui = playerGui:FindFirstChild("UserInterface")
	local node = if ui then ui:FindFirstChild("DeathScreen") else nil
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

-- CloseBtn opcional, en la raíz o en Header.
local function _resolveVotingFrame(playerGui: PlayerGui): (GuiObject?, GuiButton?)
	local ui = playerGui:FindFirstChild("UserInterface")
	if not ui then
		return nil, nil
	end
	local voting = ui:FindFirstChild("Voting")
	if not voting or not voting:IsA("GuiObject") then
		return nil, nil
	end
	local closeNode = voting:FindFirstChild("CloseBtn")
	if not closeNode then
		local header = voting:FindFirstChild("Header")
		closeNode = if header then header:FindFirstChild("CloseBtn") else nil
	end
	local closeBtn = if closeNode and closeNode:IsA("GuiButton") then closeNode else nil
	return voting, closeBtn
end

-- Bots: userId negativo = atributo FakeUserId del modelo en mapRoot.Bots.
local function _resolveKillerCharacter(killerUserIdStr: string): Model?
	if killerUserIdStr == "" then
		return nil
	end
	local killerUserId = tonumber(killerUserIdStr)
	if not killerUserId then
		return nil
	end

	if killerUserId > 0 then
		local player = Players:GetPlayerByUserId(killerUserId)
		return if player then player.Character else nil
	end

	local botsFolder = KillCamFollowController.getBotsFolder()
	if botsFolder then
		for _, bot in botsFolder:GetChildren() do
			if bot:IsA("Model") and bot:GetAttribute("FakeUserId") == killerUserId then
				return bot
			end
		end
	end
	return nil
end

function MatchFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local menuGui = menuController:getGui()
	local votingFrame, votingCloseBtn = _resolveVotingFrame(playerGui)
	local deathScreenGui = _resolveDeathScreen(playerGui)
	local resultsFrame = _resolveResultsFrame(playerGui)
	local iris = IrisTransition.new(playerGui)
	-- Tapa el montaje de la pantalla de Resultados.
	local fade = ScreenFade.new(playerGui)

	if not votingFrame then
		warn("[MatchFeature] UserInterface.Voting no encontrado — votación de mapa deshabilitada.")
	end

	-- Todo task.delay de handlers debe comprobar featureAlive: tras destroy() tocaría
	-- objetos ya destruidos por el janitor.
	local featureAlive = true
	janitor:Add(function()
		featureAlive = false
	end, true)

	MatchState.reset()

	-- Al entrar a partida el mapa puede no haber replicado cuando llega la fase: se
	-- hace poll acotado, y lightingGeneration cancela esperas obsoletas.
	local lightingGeneration = 0
	local function applyLobbyLighting()
		lightingGeneration += 1
		if applyScenePreset(resolveLobbyPresetNode()) then
			return
		end
		-- Si no, el lobby heredaría el lighting y el DoF del mapa o del locker.
		warn("[MatchFeature] No se pudo aplicar el preset del lobby (falta Workspace.Cameras.lobby o su atributo LightingPreset); se restaura el lighting base.")
		ScenePresetController.restore()
	end
	local function applyMapLighting()
		lightingGeneration += 1
		local myGen = lightingGeneration
		local node = resolveMapPresetNode()
		if node then
			applyScenePreset(node)
			return
		end
		task.spawn(function()
			local deadline = os.clock() + 10
			while os.clock() < deadline do
				task.wait(0.1)
				if lightingGeneration ~= myGen then
					return
				end
				local ready = resolveMapPresetNode()
				if ready then
					applyScenePreset(ready)
					return
				end
			end
		end)
	end
	janitor:Add(function()
		lightingGeneration += 1
	end, true)

	applyLobbyLighting()
	-- El DoF concreto lo aporta el preset activo; aquí solo se enciende/apaga.
	DepthOfFieldController.setEnabled(true)
	TouchControlsController.setEnabled(false)
	-- En partida el reset NO mata: vuelve al menú como el botón Menu de la pantalla de
	-- muerte (conectado más abajo). Matar contaría como muerte y pasaría por el cooldown.
	local resetCharacterEvent = Instance.new("BindableEvent")
	janitor:Add(resetCharacterEvent, "Destroy")
	setResetButtonCallback(false)

	MatchState.setOnPhaseChanged(function(_prev, nextPhase)
		local inMenu = nextPhase == "Lobby" or nextPhase == "ReturningToMenu"
		DepthOfFieldController.setEnabled(inMenu)
		if inMenu then
			applyLobbyLighting()
		else
			applyMapLighting()
		end

		-- El podio de Resultados vive en el mapa y el servidor lo desmonta con su propio
		-- reloj: hay que copiarlo mientras se juega.
		if nextPhase == "InMatch" then
			ResultsScene.captureWithRetries()
		end

		local inGameplay = nextPhase == "InMatch" or nextPhase == "Dying"
		TouchControlsController.setEnabled(inGameplay)
		setResetButtonCallback(if inGameplay then resetCharacterEvent else false)
	end)
	janitor:Add(function()
		ResultsScene.clear()
		MatchState.setOnPhaseChanged(nil)
		DepthOfFieldController.setEnabled(false)
		TouchControlsController.setEnabled(true)
		setResetButtonCallback(true)
	end, true)

	local matchMenu = MatchMenu.new(menuController, playerGui, menuGui, MatchState.shouldKeepMenuHidden)

	local playButton = matchMenu:getPlayButton()
	if not playButton then
		warn("[MatchFeature] No se encontro Menu.PlayBtn")
		return janitor
	end

	local matchHudGui = playerGui:FindFirstChild("MatchHud")
	local matchStatsGui = playerGui:FindFirstChild("MatchStats")
	if matchStatsGui and matchStatsGui:IsA("ScreenGui") then
		-- Reclonar en cada respawn dejaría refs cacheadas a frames destruidos.
		matchStatsGui.ResetOnSpawn = false
	end
	local hud = MatchHud.new(
		if matchHudGui and matchHudGui:IsA("ScreenGui") then matchHudGui else nil,
		if matchStatsGui and matchStatsGui:IsA("ScreenGui") then matchStatsGui else nil
	)
	janitor:Add(hud, "destroy")
	hud:setScores(0, 0, GameConfig.MaxRoundDuration)

	matchMenu:setPhaseLabel("DEPLOY")

	local view = MapVoteView.new(votingFrame)
	janitor:Add(view, "Destroy")

	-- Sin botón de apertura: se abre desde Play mientras hay votación activa. Cerrarla
	-- no afecta a la votación.
	local votingPanelOpen = false
	local votingPanel: any = nil
	if votingFrame then
		votingFrame.Visible = false
		votingPanel = PanelController.new(menuController, votingFrame, nil, votingCloseBtn, {
			animationMode = "none",
			onOpen = function()
				votingPanelOpen = true
				BlurController.acquire("Voting")
			end,
			onClose = function()
				votingPanelOpen = false
				BlurController.release("Voting")
			end,
		})
		janitor:Add(votingPanel, "Destroy")
	end

	local deathView = if deathScreenGui
		then DeathScreenView.new(deathScreenGui)
		else nil

	local killCam = KillCamFollowController.new(playerGui)
	janitor:Add(killCam, "Destroy")

	-- Un solo GetDescendants compartido por ambos controllers.
	local prescannedModels: { Model } = {}
	for _, desc in workspace:GetDescendants() do
		if desc:IsA("Model") then
			table.insert(prescannedModels, desc)
		end
	end
	CharacterHighlightController:Start(prescannedModels)
	HealthBillboardController:Start(prescannedModels)
	-- Sin Stop() en teardown los listeners se duplicarían en el siguiente Start().
	janitor:Add(function()
		CharacterHighlightController:Stop()
		HealthBillboardController:Stop()
	end, true)
	if deathView then
		janitor:Add(deathView, "Destroy")
	end

	-- Tolerante a frame nulo.
	local resultsView = ResultsView.new(resultsFrame)
	janitor:Add(resultsView, "Destroy")

	-- Estado local, ortogonal a MatchState.
	local isVoting = false
	local selectedVoteKey = ""
	local lastLocalVoteAt = 0
	local playEnabled = false
	local respawnRequestSent = false
	-- Match.MatchResults llega justo antes de RoundEnded. nil = sin recompensas.
	local latestMatchResults: any = nil
	-- Solo quien viene de ver Results entra solo a la votación; a los del lobby no se les fuerza.
	local pendingAutoVote = false

	local function setPlayEnabled(enabled: boolean)
		playEnabled = enabled

		local currentPlayButton = (matchMenu:getPlayButton() or playButton) :: GuiButton

		-- Durante la votación Play abre la pantalla de votación.
		currentPlayButton.Active = enabled or isVoting

		local indicator = currentPlayButton:FindFirstChild("Indicator")
		if not indicator then
			return
		end

		local enabledGradient = indicator:FindFirstChild("Enabled")
		local disabledGradient = indicator:FindFirstChild("Disabled")
		local statusLabel = indicator:FindFirstChild("Status")

		if enabledGradient and enabledGradient:IsA("UIGradient") then
			enabledGradient.Enabled = enabled
		end
		if disabledGradient and disabledGradient:IsA("UIGradient") then
			disabledGradient.Enabled = not enabled
		end
		if statusLabel and statusLabel:IsA("TextLabel") then
			statusLabel.TextColor3 = if enabled
				then Color3.fromRGB(160, 128, 6)
				else Color3.fromRGB(255, 255, 255)
		end
	end

	setPlayEnabled(false)

	local function tryJoinMatchFromLobby()
		if not playEnabled or MatchState.getPhase() ~= "Lobby" then
			return
		end

		-- Incluye la animación del ganador: si no, espacio al acabar la votación entra
		-- en partida con la GUI de votación encima.
		if votingPanelOpen then
			return
		end

		MatchState.setPhase("Joining")
		matchMenu:enforceHidden()
		iris:close(function()
			if MatchState.getPhase() == "Joining" then
				Network.Match.RequestJoinMatch.Send({})
				task.delay(JOIN_CONFIRM_TIMEOUT, function()
					if not featureAlive then return end
					if MatchState.getPhase() ~= "Joining" then
						return
					end
					MatchState.setPhase("Lobby")
					matchMenu:forceShow()
					iris:open()
					warn("[MatchFeature] Join timeout waiting for spawn confirmation.")
				end)
			end
		end)
	end

	local function notInActiveMatch(): boolean
		return not MatchState.isActive()
	end

	-- Botón Menu de la pantalla de muerte y Reset Character: vivo o muerto el camino
	-- es el mismo. Espera ReturnToMenuDone con timeout de recuperación.
	local function returnToMenu()
		if MatchState.getPhase() == "ReturningToMenu" then
			return
		end
		MatchState.setPhase("ReturningToMenu")
		iris:close(function()
			if MatchState.getPhase() == "ReturningToMenu" then
				Network.Match.RequestReturnToMenu.Send({})
				task.delay(RETURN_TO_MENU_TIMEOUT, function()
					if not featureAlive then return end
					if MatchState.getPhase() == "ReturningToMenu" then
						MatchState.setPhase("Lobby")
						matchMenu:forceShow()
						iris:open()
						warn("[MatchFeature] ReturnToMenu timeout — recuperando estado.")
					end
				end)
			end
		end)
	end

	-- Se re-comprueba la fase por si el evento llega con ella ya cambiada.
	janitor:Add(resetCharacterEvent.Event:Connect(function()
		if MatchState.isActive() then
			returnToMenu()
		end
	end), "Disconnect")

	if deathView then
		deathView:bind(function()
			local phase = MatchState.getPhase()
			if phase == "ReturningToMenu" or respawnRequestSent then
				return
			end
			respawnRequestSent = true
			Network.Match.RequestRespawn.Send({})
			task.delay(RESPAWN_REQUEST_TIMEOUT, function()
				if not featureAlive then return end
				if respawnRequestSent and MatchState.getPhase() ~= "ReturningToMenu" then
					respawnRequestSent = false
				end
			end)
		end, returnToMenu)
	end

	-- voteKey = nombre del mapa o GameConfig.RandomVoteKey.
	view:bindVoteHandler(function(voteKey: string)
		if not isVoting then
			return
		end
		local now = time()
		if now - lastLocalVoteAt < LOCAL_VOTE_COOLDOWN then
			return
		end
		lastLocalVoteAt = now
		selectedVoteKey = voteKey
		view:setSelectedMap(voteKey)
		Network.Match.CastVote.Send({ mapName = voteKey })
	end)

	janitor:Add(Players.PlayerAdded:Connect(function()
		hud:queuePlayerRowsUpdate()
	end), "Disconnect")

	janitor:Add(Players.PlayerRemoving:Connect(function(player)
		hud:onPlayerRemoved(player.UserId)
	end), "Disconnect")

	local function onPlayPressed()
		-- Solo con el menú limpio, sin ningún panel abierto.
		if menuController:hasOpenPanel() then
			return
		end
		if isVoting then
			if votingPanel then
				votingPanel:open()
			end
			return
		end
		tryJoinMatchFromLobby()
	end

	janitor:Add(playButton.MouseButton1Click:Connect(function()
		onPlayPressed()
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
		onPlayPressed()
	end), "Disconnect")

	-- Fase/mapa/voto/score llegan como attributes de MatchSnapshot. Los countdowns se
	-- derivan localmente de PhaseEndsAt (reloj de servidor), sin ticks de red.
	local snapshotPhase: string = MatchSnapshot.getPhase()

	local function getPhaseTimeLeft(): number
		local endsAt = MatchSnapshot.getNumber("PhaseEndsAt")
		if endsAt <= 0 then
			return 0
		end
		return math.ceil(math.max(0, endsAt - MatchSnapshot.now()))
	end

	local function readVoteOptions()
		return {
			option1 = { mapName = MatchSnapshot.getString("Option1Name"), mapImage = MatchSnapshot.getString("Option1Image") },
			option2 = { mapName = MatchSnapshot.getString("Option2Name"), mapImage = MatchSnapshot.getString("Option2Image") },
			option3 = { mapName = MatchSnapshot.getString("Option3Name"), mapImage = MatchSnapshot.getString("Option3Image") },
		}
	end

	local function applyVoterIds()
		if not isVoting then
			return
		end
		view:updateVotes({
			random = MatchSnapshot.getString("VotesRandom"),
			option1 = MatchSnapshot.getString("Votes1"),
			option2 = MatchSnapshot.getString("Votes2"),
			option3 = MatchSnapshot.getString("Votes3"),
		})
		if selectedVoteKey ~= "" then
			view:setSelectedMap(selectedVoteKey)
		end
	end

	local function updateRoundHud()
		if snapshotPhase ~= "InRound" then
			return
		end
		local scoreA = MatchSnapshot.getNumber("ScoreA")
		local scoreB = MatchSnapshot.getNumber("ScoreB")
		local timeLeft = getPhaseTimeLeft()
		hud:setScores(scoreA, scoreB, timeLeft)
	end

	local function applySnapshotPhase(phase: string)
		snapshotPhase = phase

		-- Congelar la cámara aquí y no en RoundEnded: Phase=Results replica antes que el
		-- respawn en el lobby, pero RoundEnded (ByteNet, fin de frame) llega DESPUÉS y
		-- dejaría ver un frame del lobby.
		if phase == "Results" and MatchState.isActive() then
			MatchCamera.holdCurrent(function()
				if not featureAlive then
					return false
				end
				return MatchState.getPhase() == "ShowingResults"
					or (MatchState.isActive() and snapshotPhase == "Results")
			end)
		end
		local wasVoting = isVoting
		isVoting = phase == "Voting"
		setPlayEnabled(phase == "InRound")

		if isVoting and not wasVoting then
			matchMenu:setPhaseLabel("VOTING")
			selectedVoteKey = ""
			view:show(readVoteOptions(), GameConfig.VoteDuration)
			view:setSelectedMap("")
			view:updateTimer(getPhaseTimeLeft())
			applyVoterIds()
			if pendingAutoVote then
				pendingAutoVote = false
				if votingPanel then
					-- true = sin sonido (no la abre el usuario).
					votingPanel:open(true)
				end
			end
		elseif wasVoting and not isVoting then
			selectedVoteKey = ""
			pendingAutoVote = false
			local function finishVote()
				matchMenu:setPhaseLabel("DEPLOY")
				view:hide()
				if votingPanel then
					votingPanel:close(true)
				end
			end
			local winnerMapName = MatchSnapshot.getString("WinnerMapName")
			if votingPanelOpen and winnerMapName ~= "" then
				view:showWinner(winnerMapName, finishVote)
			else
				finishVote()
			end
		else
			matchMenu:setPhaseLabel(if isVoting then "VOTING" else "DEPLOY")
		end

		updateRoundHud()
		matchMenu:enforceHidden()
	end

	janitor:Add(MatchSnapshot.observe("Phase", function(value)
		applySnapshotPhase(if type(value) == "string" then value else "Idle")
	end), "Disconnect")
	for _, votesKey in { "Votes1", "Votes2", "Votes3", "VotesRandom" } do
		janitor:Add(MatchSnapshot.observe(votesKey, applyVoterIds), "Disconnect")
	end
	for _, scoreKey in { "ScoreA", "ScoreB" } do
		janitor:Add(MatchSnapshot.observe(scoreKey, updateRoundHud), "Disconnect")
	end

	task.spawn(function()
		while featureAlive do
			if isVoting then
				view:updateTimer(getPhaseTimeLeft())
			else
				updateRoundHud()
			end
			task.wait(1)
		end
	end)

	janitor:Add(menuGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		matchMenu:enforceHidden()
	end), "Disconnect")

	janitor:Add(playerGui.ChildAdded:Connect(function(child)
		if child.Name == "Menu" and child:IsA("ScreenGui") then
			child.ResetOnSpawn = false
			matchMenu:applyPhaseLabelToNewGui(child)
			if matchMenu:shouldKeepHidden() then
				child.Enabled = false
			end
		end
	end), "Disconnect")

	janitor:Add(Players.LocalPlayer.CharacterAdded:Connect(function(character)
		-- Espacio aún pulsado (usado para entrar o respawnear): bloquear el salto hasta soltarlo.
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			task.spawn(function()
				local humanoid = character:WaitForChild("Humanoid", 2)
				if not humanoid or not humanoid:IsA("Humanoid") then
					return
				end
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
				local releaseConn: RBXScriptConnection
				releaseConn = UserInputService.InputEnded:Connect(function(input)
					if input.KeyCode ~= Enum.KeyCode.Space then
						return
					end
					releaseConn:Disconnect()
					if humanoid.Parent then
						humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
					end
				end)
			end)
		end

		local phase = MatchState.getPhase()

		-- El jugador reaparece en el lobby: limpiar armas. La cámara de Resultados ya
		-- re-afirma Scriptable cada frame.
		if phase == "ShowingResults" then
			local guard = function()
				return MatchState.getPhase() == "ShowingResults"
			end
			MatchWeapons.cleanAllWithRetries(playerGui, guard)
			for _, delaySec in { 0, 0.1, 0.2, 0.5 } do
				task.delay(delaySec, function()
					if not featureAlive then return end
					if guard() then
						MatchWeapons.clearGui(playerGui)
					end
				end)
			end
			hud:resetMatchState()
			matchMenu:enforceHidden()
			return
		end

		-- La cámara de lobby la re-afirma ClientBootstrap en su CharacterAdded; no duplicar aquí.
		if not MatchState.isActive() then
			return
		end

		-- La cámara no se toca hasta que DeathScreenHide reactive la de gameplay.
		if phase == "Dying" then
			matchMenu:enforceHidden()
			return
		end

		hud:setEnabled(true)
		if deathScreenGui then
			deathScreenGui.Visible = false
		end
		task.defer(function()
			MatchCamera.setGameplay(character)
		end)
		matchMenu:enforceHidden()
	end), "Disconnect")

	janitor:Add(Network.Match.JoinMatchSpawned.Listen(function(_: {})
		MatchState.setPhase("InMatch")
		killCam:stop()
		hud:resetMatchState()
		menuController:hide()
		matchMenu:enforceHidden()
		if deathView then
			deathView:hide()
		end
		resultsView:hide()
		pendingAutoVote = false
		latestMatchResults = nil
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

	janitor:Add(Network.Match.PlayerStreakState.Listen(function(data: {
		userId: string,
		kills: number,
		deaths: number,
		assists: number,
	})
		local userId = tonumber(data.userId)
		if not userId then
			return
		end
		hud:applyPlayerState(userId, data.kills, data.deaths, data.assists)
	end), true)

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
					level = if type(entry.level) == "number" then entry.level else 1,
					outfitId = if type(entry.outfitId) == "string" then entry.outfitId else "",
					faceId = if type(entry.faceId) == "string" then entry.faceId else "",
					hatId = if type(entry.hatId) == "string" then entry.hatId else "",
				}
			end
		end
		hud:setBotRoster(parsed)
	end), true)

	janitor:Add(Network.Match.TeamCosmetics.Listen(function(data: { json: string })
		local ok, list = pcall(HttpService.JSONDecode, HttpService, data.json)
		if not ok or type(list) ~= "table" then
			return
		end
		local byUserId = {} :: { [number]: any }
		for _, entry in list do
			if type(entry) == "table" and type(entry.userId) == "number" then
				byUserId[entry.userId] = {
					outfitId = if type(entry.outfitId) == "string" then entry.outfitId else "",
					faceId = if type(entry.faceId) == "string" then entry.faceId else "",
					hatId = if type(entry.hatId) == "string" then entry.hatId else "",
				}
			end
		end
		hud:setPlayerCosmetics(byUserId)
	end), true)

	-- OJO: el servidor lo manda ANTES que RoundEnded pero llega DESPUÉS (ByteNet vacía
	-- la cola de broadcast antes que la por-jugador). Por eso además de guardarlas se
	-- pintan sobre la pantalla ya abierta.
	janitor:Add(Network.Match.MatchResults.Listen(function(data: { json: string })
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, data.json)
		if ok and type(decoded) == "table" then
			-- Un array vacío puede no sobrevivir al JSON.
			if type(decoded.rewards) ~= "table" then
				decoded.rewards = {}
			end
			latestMatchResults = decoded
			resultsView:applyRewards(decoded)
		end
	end), true)

	janitor:Add(Network.Match.DeathScreenShow.Listen(function(data: {
		respawnCooldown: number,
		killerUserId: string,
		killerName: string,
		killerLevel: number,
		killerBanner: string,
		weaponId: string,
	})
		hud:incrementLocalDeaths()
		if not deathView then
			return
		end

		MatchState.setPhase("Dying")
		respawnRequestSent = false
		hud:setEnabled(false)

		local guard = function()
			return MatchState.getPhase() == "Dying"
		end
		MatchWeapons.cleanAllWithRetries(playerGui, guard)

		killCam:start({
			killerUserId = data.killerUserId,
		})

		-- Sin asesino (vacío, entorno) va nil y no una tabla con nombre vacío:
		-- _populateCard rotularía un "Eliminated by " colgando.
		local killer = if data.killerName ~= ""
			then {
				name = data.killerName,
				level = data.killerLevel,
				bannerId = data.killerBanner,
				character = _resolveKillerCharacter(data.killerUserId),
			}
			else nil
		deathView:show(data.respawnCooldown, killer)
	end), true)

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

	janitor:Add(Network.Match.ReturnToMenuDone.Listen(function(_: {})
		MatchState.setPhase("Lobby")
		killCam:stop()
		hud:resetMatchState()
		if deathView then
			deathView:hide()
		end
		resultsView:hide()
		if deathScreenGui then
			deathScreenGui.Visible = false
		end
		hud:setEnabled(false)
		MatchWeapons.cleanAllWithRetries(playerGui, notInActiveMatch)
		MatchCamera.forceLobbyWithRetries(notInActiveMatch)
		matchMenu:forceShow()
		iris:open()
	end), true)

	janitor:Add(Network.Match.RoundEnded.Listen(function(_data: {
		winnerTeam: string,
		scoreA: number,
		scoreB: number,
	})
		local prevPhase = MatchState.getPhase()
		local wasActive = prevPhase == "InMatch" or prevPhase == "Dying" or prevPhase == "ReturningToMenu"
		local wasJoining = prevPhase == "Joining"

		MatchState.setPhase("Lobby")
		matchMenu:setPhaseLabel("ENDING")
		killCam:stop()
		setPlayEnabled(false)
		hud:setEnabled(false)
		if deathView then
			deathView:hide()
		end
		if deathScreenGui then
			deathScreenGui.Visible = false
		end

		MatchWeapons.cleanAllWithRetries(playerGui, notInActiveMatch)

		-- ANTES de resetear: el servidor despawnea bots y manda a los jugadores al lobby
		-- nada más acabar la ronda (el mapa sí se queda hasta el final de Resultados).
		local localTeam, playerEntries = hud:captureEndResultsData()
		hud:resetMatchState()

		-- Fundido a negro → con la pantalla tapada se montan réplicas y cámara → reveal.
		if wasActive then
			MatchState.setPhase("ShowingResults")
			matchMenu:enforceHidden()
			local roundEndedAt = os.clock()
			local function isShowingResults(): boolean
				return featureAlive and MatchState.getPhase() == "ShowingResults"
			end

			-- Normalmente ya congelada desde applySnapshotPhase; esto cambia el guard a esta fase.
			MatchCamera.holdCurrent(isShowingResults)

			local function onResultsFinished()
				if not isShowingResults() then
					return
				end
				resultsView:hide()
				MatchState.setPhase("Lobby")
				MatchCamera.stopResultsCinematic()
				MatchCamera.forceLobbyWithRetries(notInActiveMatch)
				latestMatchResults = nil

				-- La fase Voting suele llegar casi a la vez: si aún no, la abre applySnapshotPhase
				-- vía pendingAutoVote.
				matchMenu:setPhaseLabel("VOTING")
				if isVoting and votingPanel then
					votingPanel:open(true)
				else
					pendingAutoVote = true
					task.delay(VOTE_AUTO_TIMEOUT, function()
						if not featureAlive then return end
						if pendingAutoVote then
							pendingAutoVote = false
							matchMenu:setPhaseLabel("DEPLOY")
							matchMenu:forceShow()
						end
					end)
				end
			end

			-- Si algo saca al jugador de Resultados a mitad del fundido, descubrir la pantalla.
			fade:cover(function()
				if not isShowingResults() then
					fade:reveal()
					return
				end
				-- Si venía de ReturningToMenu el iris puede estar cerrado.
				iris:reset()
				resultsView:preload(localTeam, playerEntries)

				task.delay(RESULTS_BLACK_HOLD, function()
					if not isShowingResults() then
						fade:reveal()
						return
					end
					MatchCamera.startResultsCinematic(isShowingResults)
					-- La ventana del servidor empezó en RoundEnded: se descuenta el fundido para cerrar
					-- a la vez que desmonta el mapa.
					local remaining = GameConfig.EndResultsDuration - (os.clock() - roundEndedAt)
					resultsView:show(localTeam, playerEntries, remaining, onResultsFinished, latestMatchResults)
					fade:reveal()
				end)
			end)
		elseif wasJoining then
			MatchCamera.forceLobbyWithRetries(notInActiveMatch)
			iris:open()
			matchMenu:forceShow()
		end
	end), true)

	MatchProgressionObserver.attach({
		hud = hud,
		matchHudGui = if matchHudGui and matchHudGui:IsA("ScreenGui") then matchHudGui else nil,
		fusionScope = fusionScope,
		janitor = janitor,
	})

	janitor:Add(function()
		MatchState.reset()
		isVoting = false
		setPlayEnabled(false)
		hud:setScores(0, 0, GameConfig.MaxRoundDuration)
		view:hide()
		if deathView then
			deathView:hide()
		end
		killCam:stop()
		hud:setEnabled(false)
		resultsView:hide()
		MatchCamera.stopResultsCinematic()
		iris:reset()
		fade:reset()
		Fusion.doCleanup(fusionScope)
	end, true)

	Network.Match.RequestMatchSync.Send({})

	return janitor
end

return MatchFeature
