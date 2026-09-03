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

local MatchState = require(script.MatchState)
local MatchCamera = require(script.MatchCamera)
local MatchWeapons = require(script.MatchWeapons)
local MatchMenu = require(script.MatchMenu)
local MatchHud = require(script.MatchHud)
local MatchProgressionObserver = require(script.MatchProgressionObserver)

local DeathScreenView = require(script.DeathScreenView)
local ResultsView = require(script.ResultsView)
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

local function setResetButtonEnabled(enabled: boolean)
	task.spawn(function()
		local ok = false
		local attempts = 0
		repeat
			ok = pcall(function()
				StarterGui:SetCore("ResetButtonCallback", enabled)
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
-- Precarga de las réplicas de Resultados un poco antes de que acabe la ronda
-- (por tiempo o por puntuación cercana al límite) para evitar el "pop" al cortar
-- a la cámara de Resultados.
local RESULTS_PRELOAD_LEAD_SECONDS = 5
local RESULTS_PRELOAD_SCORE_LEAD = 20
-- Tras Results se espera a que arranque la votación para abrirla automáticamente;
-- si no llega en este tiempo (no se pudo iniciar), se vuelve al menú.
local VOTE_AUTO_TIMEOUT = 8

-- Lighting 100% dirigido por atributo `LightingPreset` (ScenePresetController):
-- ningún nombre de preset vive en código. Cada contexto lee el atributo del nodo
-- de escena correspondiente:
--   * Lobby/menú → Workspace.Cameras.lobby      (atributo LightingPreset="Lobby")
--   * Partida    → el mapa cargado en Workspace.ActiveMap (o su modelo hijo), que
--                  el diseñador autora con su propio LightingPreset por mapa.
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
	-- El atributo lo suele llevar el modelo del mapa (hijo del contenedor ActiveMap).
	for _, child in activeMap:GetChildren() do
		if child:GetAttribute("LightingPreset") ~= nil then
			return child
		end
	end
	return nil
end

-- Aplica el preset leyendo el atributo del nodo. Devuelve true solo si el nodo
-- existía y llevaba atributo: quien necesite garantizar el cambio de look (el
-- lobby) debe reaccionar al false en vez de quedarse con el preset anterior.
local function applyScenePreset(node: Instance?): boolean
	if node then
		return ScenePresetController.applyFrom(node)
	end
	return false
end

-- ── Helpers de resolución de GUI ──

-- Pantalla de Resultados: frame bajo PlayerGui.UserInterface.Results.
local function _resolveResultsFrame(playerGui: PlayerGui): GuiObject?
	local ui = playerGui:FindFirstChild("UserInterface")
	local node = if ui then ui:FindFirstChild("Results") else nil
	if node and node:IsA("GuiObject") then
		return node
	end
	-- Sin este frame, ResultsView queda no-op: ni frames de jugador ni rewards.
	warn("[MatchFeature] No se encontró PlayerGui.UserInterface.Results — la pantalla de Resultados (frames + rewards) no se mostrará.")
	return nil
end

-- Pantalla de muerte: frame bajo PlayerGui.UserInterface.DeathScreen.
local function _resolveDeathScreen(playerGui: PlayerGui): GuiObject?
	local ui = playerGui:FindFirstChild("UserInterface")
	local node = if ui then ui:FindFirstChild("DeathScreen") else nil
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

-- Pantalla de votación independiente: PlayerGui.UserInterface.Voting (ya no vive
-- dentro del Menu). El CloseBtn es opcional (raíz o Header).
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

-- Resolver el Model del jugador/bot que mató al local. Para humanos vamos por
-- userId; para bots negativos buscamos el FakeUserId attribute en mapRoot/Bots.
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

	-- Bot: reusamos el cache de KillCamFollowController (mapRoot.Bots) en lugar de
	-- escanear workspace:GetChildren() en cada muerte.
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

-- ── Feature principal ────────────────────────────────────────

function MatchFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local menuGui = menuController:getGui()
	local votingFrame, votingCloseBtn = _resolveVotingFrame(playerGui)
	local deathScreenGui = _resolveDeathScreen(playerGui)
	local resultsFrame = _resolveResultsFrame(playerGui)
	local iris = IrisTransition.new(playerGui)

	-- Voting opcional: si la GUI aún no tiene UserInterface.Voting (migración), se
	-- deshabilita la votación pero el resto del feature (Play, HUD, fases) sigue.
	if not votingFrame then
		warn("[MatchFeature] UserInterface.Voting no encontrado — votación de mapa deshabilitada.")
	end

	-- D4: flag de vida del feature. Cualquier task.delay scheduled en
	-- handlers de red o callbacks chequea `featureAlive` antes de mutar
	-- estado — sin esto, una task disparada tras destroy() tocaría objetos
	-- (matchMenu, hud, iris) ya destruidos por el janitor.
	local featureAlive = true
	janitor:Add(function()
		featureAlive = false
	end, true)

	-- ── Inicializar sub-módulos ──────────────────────────────
	MatchState.reset()

	-- Lighting: preset del Lobby al arrancar y alternar entre el look del mapa y el
	-- del Lobby según la fase. Todo por atributo (ver resolvers arriba); el Locker
	-- se controla en su feature.
	--
	-- Robustez ante el race de replicación: al entrar a partida el modelo del mapa
	-- (Workspace.ActiveMap) puede no haber replicado aún cuando llega el snapshot de
	-- fase. Si el nodo no está, esperamos (poll acotado) y aplicamos en cuanto
	-- aparezca. Un contador de generación cancela esperas obsoletas al cambiar de
	-- fase o destruir el feature.
	local lightingGeneration = 0
	local function applyLobbyLighting()
		lightingGeneration += 1
		if applyScenePreset(resolveLobbyPresetNode()) then
			return
		end
		-- Sin preset de lobby aplicable, volver al menú dejaría activo el preset del
		-- mapa (o el del locker): el lobby heredaría su lighting y su DoF. Restaurar
		-- el look base del place es el fallback correcto.
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
					return -- otra transición (o el teardown) tomó el control
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
		-- Invalida cualquier espera de mapa pendiente al destruir el feature.
		lightingGeneration += 1
	end, true)

	applyLobbyLighting()
	-- DOF de fondo del menú: encendido al arrancar (estamos en Lobby) y alternado
	-- por fase abajo. El DoF concreto lo aporta el preset activo (el locker trae el
	-- suyo); este controller solo decide si está encendido.
	DepthOfFieldController.setEnabled(true)
	-- Controles táctiles por defecto (joystick): ocultos al arrancar (Lobby) y solo
	-- visibles en partida activa. Se alternan junto al resto del estado de fase.
	TouchControlsController.setEnabled(false)
	-- Reset de personaje: deshabilitado en lobby/menú, habilitado en partida.
	setResetButtonEnabled(false)

	MatchState.setOnPhaseChanged(function(_prev, nextPhase)
		local inMenu = nextPhase == "Lobby" or nextPhase == "ReturningToMenu"
		DepthOfFieldController.setEnabled(inMenu)
		if inMenu then
			applyLobbyLighting()
		else
			-- Joining/InMatch/Dying/ShowingResults: el look lo autora el propio mapa
			-- (atributo LightingPreset en Workspace.ActiveMap o su modelo).
			applyMapLighting()
		end

		-- El joystick y el reset de personaje solo en gameplay activo (InMatch/Dying).
		local inGameplay = nextPhase == "InMatch" or nextPhase == "Dying"
		TouchControlsController.setEnabled(inGameplay)
		setResetButtonEnabled(inGameplay)
	end)
	janitor:Add(function()
		MatchState.setOnPhaseChanged(nil)
		DepthOfFieldController.setEnabled(false)
		-- Restaurar el comportamiento por defecto de Roblox al desmontar el feature.
		TouchControlsController.setEnabled(true)
		setResetButtonEnabled(true)
	end, true)

	local matchMenu = MatchMenu.new(menuController, playerGui, menuGui, MatchState.shouldKeepMenuHidden)

	local playButton = matchMenu:getPlayButton()
	if not playButton then
		warn("[MatchFeature] No se encontro Menu.PlayBtn")
		return janitor
	end

	local matchHudGui = playerGui:FindFirstChild("MatchHud")
	local hud = MatchHud.new(if matchHudGui and matchHudGui:IsA("ScreenGui") then matchHudGui else nil)
	janitor:Add(hud, "destroy")
	hud:setScores(0, 0, GameConfig.MaxRoundDuration)

	-- ── Vistas ───────────────────────────────────────────────
	matchMenu:setPhaseLabel("DEPLOY")

	local view = MapVoteView.new(votingFrame)
	janitor:Add(view, "Destroy")

	-- Panel de la pantalla de votación (independiente del Menu). Sin botón de
	-- apertura: se abre programáticamente desde Play mientras hay votación activa.
	-- El CloseBtn (si existe) la cierra y devuelve al menú sin afectar la votación.
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

	-- Killcam que sigue al asesino desde delante (con karma cam si el asesino muere).
	local killCam = KillCamFollowController.new(playerGui)
	janitor:Add(killCam, "Destroy")

	-- Scan compartido de workspace para evitar que cada controller haga su
	-- propio `workspace:GetDescendants()` (eran dos escaneos secuenciales sobre
	-- la misma jerarquía gigante).
	local prescannedModels: { Model } = {}
	for _, desc in workspace:GetDescendants() do
		if desc:IsA("Model") then
			table.insert(prescannedModels, desc)
		end
	end
	CharacterHighlightController:Start(prescannedModels)
	HealthBillboardController:Start(prescannedModels)
	-- D1+D2: registrar Stop() en el janitor para que un teardown del feature
	-- (e.g. hot reload) desconecte los PlayerAdded/DescendantAdded/Team
	-- listeners que de otra forma se duplicarían en el siguiente Start().
	janitor:Add(function()
		CharacterHighlightController:Stop()
		HealthBillboardController:Stop()
	end, true)
	if deathView then
		janitor:Add(deathView, "Destroy")
	end

	-- Pantalla de Resultados (cámara + réplicas 3D + UI). Tolerante a frame nulo.
	local resultsView = ResultsView.new(resultsFrame)
	janitor:Add(resultsView, "Destroy")

	-- ── Estado local (ortogonal a MatchState) ────────────────
	local isVoting = false
	local selectedVoteKey = ""
	local lastLocalVoteAt = 0
	local playEnabled = false
	local respawnRequestSent = false
	local resultsPreloaded = false
	-- Último paquete de recompensas de fin de partida (Match.MatchResults). Llega
	-- justo antes de RoundEnded; se pasa a resultsView:show. nil = sin recompensas.
	local latestMatchResults: any = nil
	-- true cuando el jugador acaba de ver Results y debe entrar a la votación en
	-- cuanto esta arranque (los del locker/lobby no la activan → no se les fuerza).
	local pendingAutoVote = false

	-- Estructura nueva: PlayBtn.Indicator { Enabled, Disabled (UIGradient), Status }.
	-- Se muestra/oculta el gradiente según el estado.
	local function setPlayEnabled(enabled: boolean)
		playEnabled = enabled

		local currentPlayButton = matchMenu:getPlayButton() or playButton
		if not currentPlayButton then
			return
		end

		-- Clickeable también durante la votación: ahí Play abre la pantalla de
		-- votación en vez de unirse a la partida.
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

		-- No unirse mientras la pantalla de votación sigue abierta (incluida la
		-- animación del ganador tras acabar la votación): el jugador debe estar 100%
		-- de vuelta en el menú. Sin esto, pulsar espacio justo al terminar la
		-- votación lo metía en partida con la GUI de votación sobrepuesta.
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

	-- ── Bind de DeathView ────────────────────────────────────
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
		end, function()
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
		end)
	end

	-- ── Bind de votación ─────────────────────────────────────
	-- voteKey = nombre del mapa (Option1/2/3) o GameConfig.RandomVoteKey (Random).
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

	-- ── Conexiones de Players ────────────────────────────────
	janitor:Add(Players.PlayerAdded:Connect(function()
		hud:queuePlayerRowsUpdate()
	end), "Disconnect")

	janitor:Add(Players.PlayerRemoving:Connect(function(player)
		hud:onPlayerRemoved(player.UserId)
	end), "Disconnect")

	-- Play tiene doble función: durante la votación abre la pantalla de votación;
	-- en lobby normal intenta unirse a la partida.
	local function onPlayPressed()
		-- El espacio (y Play) solo funciona en el menú limpio: si hay cualquier
		-- pestaña abierta (Settings, Locker, BattlePass, Store, Rewards, Voting…),
		-- no hace nada — ni se une a partida ni abre la votación.
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

	-- ── Play button ──────────────────────────────────────────
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

	-- ── MatchSnapshot: estado ambiental replicado ────────────
	-- Fase/mapa/voto/score viajan como attributes (ReplicatedStorage.
	-- MatchSnapshot): el valor vigente está siempre disponible —late joiners
	-- incluidos— y los cambios llegan por AttributeChanged, sin resyncs ni
	-- timeouts de recuperación. Los countdowns se derivan localmente de
	-- PhaseEndsAt (reloj de servidor sincronizado), sin ticks de red.
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

	-- HUD de ronda: score por AttributeChanged + countdown del ticker (abajo).
	local function updateRoundHud()
		if snapshotPhase ~= "InRound" then
			return
		end
		local scoreA = MatchSnapshot.getNumber("ScoreA")
		local scoreB = MatchSnapshot.getNumber("ScoreB")
		local timeLeft = getPhaseTimeLeft()
		hud:setScores(scoreA, scoreB, timeLeft)

		-- Precargar las réplicas de Resultados un poco antes del fin de ronda (por
		-- tiempo o por puntuación cercana al límite) para evitar el "pop".
		if not resultsPreloaded and MatchState.isActive() then
			local nearTime = timeLeft <= RESULTS_PRELOAD_LEAD_SECONDS
			local nearScore = math.max(scoreA, scoreB)
				>= GameConfig.WinScoreLimit - RESULTS_PRELOAD_SCORE_LEAD
			if nearTime or nearScore then
				resultsPreloaded = true
				local lt, entries = hud:captureEndResultsData()
				resultsView:preload(lt, entries)
			end
		end
	end

	local function applySnapshotPhase(phase: string)
		snapshotPhase = phase
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
			-- Quien venía de ver Results entra a la votación automáticamente.
			if pendingAutoVote then
				pendingAutoVote = false
				if votingPanel then
					votingPanel:open()
				end
			end
		elseif wasVoting and not isVoting then
			selectedVoteKey = ""
			pendingAutoVote = false
			local function finishVote()
				matchMenu:setPhaseLabel("DEPLOY")
				view:hide()
				if votingPanel then
					votingPanel:close()
				end
			end
			-- Solo animamos el ganador si el jugador está viendo la pantalla; si
			-- no, reseteamos en silencio (sigue en el menú).
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

	-- Ticker local 1 Hz para los countdowns (voto y ronda) derivados de
	-- PhaseEndsAt — el servidor ya no emite ticks periódicos.
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

	-- ── Menu GUI tracking ────────────────────────────────────
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

	-- ── CharacterAdded ───────────────────────────────────────
	janitor:Add(Players.LocalPlayer.CharacterAdded:Connect(function(character)
		-- Si Espacio sigue pulsado al respawnear (p. ej. el jugador lo usó
		-- para confirmar respawn o entrar a la partida), bloquea el primer
		-- salto hasta que suelte la tecla.
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

		-- Durante resultados, el jugador fue teleportado al lobby: limpiar armas. La
		-- cámara cinemática de Resultados ya conduce la vista cada frame (re-afirma
		-- Scriptable), así que un respawn aquí no necesita re-forzarla.
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
			-- Reset HUD al respawnear durante resultados — evita mostrar kills/deaths
			-- de la partida anterior si el jugador rejoin antes de volver al lobby.
			hud:resetMatchState()
			matchMenu:enforceHidden()
			return
		end

		if not MatchState.isActive() then
			return
		end

		-- "Dying": la death screen cubre la pantalla; no tocamos la cámara
		-- hasta que DeathScreenHide reactive la de gameplay.
		if phase == "Dying" then
			matchMenu:enforceHidden()
			return
		end

		-- InMatch: restaurar HUD y cámara de gameplay.
		hud:setEnabled(true)
		if deathScreenGui then
			deathScreenGui.Visible = false
		end
		task.defer(function()
			MatchCamera.setGameplay(character)
		end)
		matchMenu:enforceHidden()
	end), "Disconnect")

	-- ── Network: JoinMatchSpawned ────────────────────────────
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
		resultsPreloaded = false
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

	-- ── Network: PlayerStreakState (stats de combate para el marcador) ──
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
					level = if type(entry.level) == "number" then entry.level else 1,
					historicalKills = if type(entry.historicalKills) == "number" then entry.historicalKills else 0,
					outfitId = if type(entry.outfitId) == "string" then entry.outfitId else "",
					faceId = if type(entry.faceId) == "string" then entry.faceId else "",
					hatId = if type(entry.hatId) == "string" then entry.hatId else "",
				}
			end
		end
		hud:setBotRoster(parsed)
	end), true)

	-- ── Network: TeamCosmetics ───────────────────────────────
	-- Cosméticos (outfit/face/hat) de mis compañeros reales, para sus réplicas en
	-- Resultados. Solo llega mi propio equipo.
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

	-- ── Network: MatchResults ────────────────────────────────
	-- Recompensas de fin de partida del jugador (outcome + cash + items). Llega
	-- justo antes de RoundEnded; se guarda para pasárselo a resultsView:show.
	janitor:Add(Network.Match.MatchResults.Listen(function(data: { json: string })
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, data.json)
		if ok and type(decoded) == "table" then
			-- JSON puede omitir un array vacío: normalizar `rewards` a tabla.
			if type(decoded.rewards) ~= "table" then
				decoded.rewards = {}
			end
			latestMatchResults = decoded
		end
	end), true)

	-- ── Network: DeathScreenShow ─────────────────────────────
	janitor:Add(Network.Match.DeathScreenShow.Listen(function(data: {
		respawnCooldown: number,
		killerUserId: string,
		killerName: string,
		killerKills: number,
		killerLevel: number,
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
			killerName = data.killerName,
			weaponId = data.weaponId,
		})

		-- Sin asesino (caída al vacío, reset de personaje, daño de entorno) la tarjeta
		-- va a nil, no con el nombre vacío: `_populateCard` ya distingue los dos casos
		-- y con la tabla puesta rotulaba un "Eliminated by " colgando.
		local killer = if data.killerName ~= ""
			then {
				name = data.killerName,
				kills = data.killerKills,
				level = data.killerLevel,
				character = _resolveKillerCharacter(data.killerUserId),
			}
			else nil
		deathView:show(data.respawnCooldown, killer)
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

	-- ── Network: RoundEnded ──────────────────────────────────
	janitor:Add(Network.Match.RoundEnded.Listen(function(_data: {
		winnerTeam: string,
		scoreA: number,
		scoreB: number,
	})
		local prevPhase = MatchState.getPhase()
		local wasActive = prevPhase == "InMatch" or prevPhase == "Dying" or prevPhase == "ReturningToMenu"
		local wasJoining = prevPhase == "Joining"

		-- Limpiar estado inmediatamente.
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

		-- Capturar datos de jugadores ANTES de resetear roster. Las réplicas se
		-- clonan en resultsView:show desde los Characters vivos, así que hay que
		-- mostrarla pronto (antes de que el servidor desmonte el mapa/bots).
		local localTeam, playerEntries = hud:captureEndResultsData()
		hud:resetMatchState()

		-- Si estaba en partida: pantalla de Resultados (cámara results + réplicas).
		-- Auto-cierre tras EndResultsDuration → vuelta al lobby/menú.
		if wasActive then
			MatchState.setPhase("ShowingResults")
			matchMenu:enforceHidden()
			-- Cámara cinemática (tilt + zoom + dolly dramático hacia el encuadre).
			-- Autoritaria mientras estemos en ShowingResults (se re-impone cada frame
			-- y se auto-detiene al salir de la fase).
			MatchCamera.startResultsCinematic(function()
				return MatchState.getPhase() == "ShowingResults"
			end)
			-- Sin flash negro al entrar a Results: reset deja el iris abierto al
			-- instante (open() siempre cubre de negro y luego revela).
			iris:reset()
			resultsView:show(localTeam, playerEntries, GameConfig.EndResultsDuration, function()
				-- onFinished (cierre de la pantalla de Resultados)
				if not featureAlive or MatchState.getPhase() ~= "ShowingResults" then
					return
				end
				resultsView:hide()
				MatchState.setPhase("Lobby")
				MatchCamera.stopResultsCinematic()
				MatchCamera.forceLobbyWithRetries(notInActiveMatch)
				latestMatchResults = nil

				-- Tras Results, enviar a la votación automáticamente. Si ya empezó,
				-- abrir directo; si no (la fase Voting suele llegar casi a la vez),
				-- esperar al observer de fase vía pendingAutoVote, con fallback al
				-- menú por timeout.
				matchMenu:setPhaseLabel("VOTING")
				if isVoting and votingPanel then
					votingPanel:open()
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
			end, latestMatchResults)
		elseif wasJoining then
			MatchCamera.forceLobbyWithRetries(notInActiveMatch)
			iris:open()
			matchMenu:forceShow()
		end
	end), true)

	-- ── DataController observers ─────────────────────────────
	-- Level up / BP tier-up / wrap challenge unlock / daily task claim viven
	-- en MatchProgressionObserver (extraído de aquí). Wirea sus observers al
	-- janitor del feature, así un teardown limpia todo.
	MatchProgressionObserver.attach({
		hud = hud,
		matchHudGui = if matchHudGui and matchHudGui:IsA("ScreenGui") then matchHudGui else nil,
		fusionScope = fusionScope,
		janitor = janitor,
	})

	-- ── Cleanup ──────────────────────────────────────────────
	janitor:Add(function()
		MatchState.reset()
		isVoting = false
		selectedVoteKey = ""
		pendingAutoVote = false
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
		Fusion.doCleanup(fusionScope)
	end, true)

	-- Sync inicial del estado event-driven (streaks + roster de bots); el
	-- estado ambiental ya se reconcilió arriba al observar el snapshot.
	Network.Match.RequestMatchSync.Send({})

	return janitor
end

return MatchFeature
