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

local IrisTransition = require(Client.core.ui.IrisTransition)

local MatchState = require(script.MatchState)
local MatchCamera = require(script.MatchCamera)
local MatchWeapons = require(script.MatchWeapons)
local MatchMenu = require(script.MatchMenu)
local MatchHud = require(script.MatchHud)
local MatchProgressionObserver = require(script.MatchProgressionObserver)

local DeathScreenView = require(script.DeathScreenView)
local ResultsView = require(script.ResultsView)
local KillCamController = require(script.KillCamController)
local CharacterHighlightController = require(script.CharacterHighlightController)
local HealthBillboardController = require(script.HealthBillboardController)
local MapVoteView = require(script.MapVoteView)
local PanelController = require(Client.core.ui.PanelController)
local BlurController = require(Client.core.ui.BlurController)
local LightingPresetController = require(Client.core.lighting.LightingPresetController)


local MatchFeature = {}

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

-- Mapeo mapName (GameConfig.Maps) → preset de LightingPresets. Mapas sin
-- entrada caen al preset genérico "Match".
local MAP_TO_LIGHTING_PRESET: { [string]: string } = {
	Canyon = "Match_Canyon",
	Factory = "Match_Factory",
	Rooftops = "Match_Rooftops",
}

-- ── Helpers de resolución de GUI ──

-- Pantalla de Resultados: frame bajo PlayerGui.UserInterface.Results.
local function _resolveResultsFrame(playerGui: PlayerGui): GuiObject?
	local ui = playerGui:FindFirstChild("UserInterface")
	local node = if ui then ui:FindFirstChild("Results") else nil
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

	-- Bot: reusamos el cache de KillCamController (mapRoot.Bots) en lugar de
	-- escanear workspace:GetChildren() en cada muerte.
	local botsFolder = KillCamController.getBotsFolder()
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
	local deathScreenGui = playerGui:FindFirstChild("DeathScreen")
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

	-- Lighting: aplicar preset Lobby al arrancar (sin tween) y alternar
	-- entre Match/Lobby según la fase. El Locker se controla en su feature.
	-- `activeMapName` lo actualiza el listener de MapLoadState más abajo;
	-- al entrar a una fase de match se mapea a un preset específico del mapa
	-- (MAP_TO_LIGHTING_PRESET) o se cae al genérico "Match".
	local activeMapName = ""
	LightingPresetController.applyImmediate("Lobby")
	MatchState.setOnPhaseChanged(function(_prev, nextPhase)
		if nextPhase == "Lobby" or nextPhase == "ReturningToMenu" then
			LightingPresetController.apply("Lobby")
		else
			-- Joining/InMatch/Dying/ShowingResults usan el look del mapa actual.
			local presetName = MAP_TO_LIGHTING_PRESET[activeMapName] or "Match"
			LightingPresetController.apply(presetName)
		end
	end)
	janitor:Add(function()
		MatchState.setOnPhaseChanged(nil)
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

	local deathView = if deathScreenGui and deathScreenGui:IsA("ScreenGui")
		then DeathScreenView.new(deathScreenGui)
		else nil

	local killCam = KillCamController.new(playerGui)
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
		if isVoting then
			if votingPanel then
				-- Refresca opciones/votos por si se perdió algún StartVote/VoteState.
				Network.Match.RequestVoteSync.Send({})
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

	-- ── Network: MapLoadState ────────────────────────────────
	janitor:Add(Network.Match.MapLoadState.Listen(function(data: {
		isLoading: boolean,
		playEnabled: boolean,
		mapName: string,
		isVoting: boolean,
	})
		-- Capturado para que el handler de fase pueda elegir el preset de
		-- iluminación específico del mapa (ver MAP_TO_LIGHTING_PRESET arriba).
		activeMapName = data.mapName

		-- MapLoadState es la fuente de verdad del estado de votación: si perdimos el
		-- StartVote (carrera al unirse / arrancar el servidor), aquí lo recuperamos.
		if data.isVoting and not isVoting then
			isVoting = true
			-- No tenemos las opciones (perdimos StartVote): pídelas para poblar la vista.
			Network.Match.RequestVoteSync.Send({})
		elseif not data.isVoting and isVoting then
			-- La votación acabó sin que recibiéramos EndVote: limpieza de seguridad.
			isVoting = false
			selectedVoteKey = ""
			view:hide()
			if votingPanel then
				votingPanel:close()
			end
		end

		matchMenu:setPhaseLabel(if isVoting then "VOTING" else "DEPLOY")
		setPlayEnabled(data.playEnabled and not data.isLoading)
		matchMenu:enforceHidden()
	end), true)

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
		if deathScreenGui and deathScreenGui:IsA("ScreenGui") then
			deathScreenGui.Enabled = false
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

	-- ── Network: RoundState ──────────────────────────────────
	janitor:Add(Network.Match.RoundState.Listen(function(data: {
		scoreA: number,
		scoreB: number,
		timeLeft: number,
	})
		hud:setScores(data.scoreA, data.scoreB, data.timeLeft)

		-- Precargar las réplicas de Resultados un poco antes del fin de ronda (por
		-- tiempo o por puntuación cercana al límite) para que no se vea el "pop".
		if not resultsPreloaded and MatchState.isActive() then
			local nearTime = data.timeLeft <= RESULTS_PRELOAD_LEAD_SECONDS
			local nearScore = math.max(data.scoreA, data.scoreB)
				>= GameConfig.WinScoreLimit - RESULTS_PRELOAD_SCORE_LEAD
			if nearTime or nearScore then
				resultsPreloaded = true
				local lt, entries = hud:captureEndResultsData()
				resultsView:preload(lt, entries)
			end
		end
	end), true)

	-- ── Network: PlayerStreakState ────────────────────────────
	janitor:Add(Network.Match.PlayerStreakState.Listen(function(data: {
		userId: string,
		kills: number,
		deaths: number,
		streak: number,
		assists: number,
	})
		local userId = tonumber(data.userId)
		if not userId then
			return
		end
		hud:applyPlayerState(userId, data.kills, data.deaths, data.streak, data.assists)

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

		local killerCharacter = _resolveKillerCharacter(data.killerUserId)
		deathView:show(data.respawnCooldown, {
			name = data.killerName,
			kills = data.killerKills,
			level = data.killerLevel,
			character = killerCharacter,
		})
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
		if deathScreenGui and deathScreenGui:IsA("ScreenGui") then
			deathScreenGui.Enabled = false
		end
		hud:setEnabled(false)
		MatchWeapons.cleanAllWithRetries(playerGui, notInActiveMatch)
		MatchCamera.forceLobbyWithRetries(notInActiveMatch)
		matchMenu:forceShow()
		iris:open()
		Network.Match.RequestVoteSync.Send({})
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
		if deathScreenGui and deathScreenGui:IsA("ScreenGui") then
			deathScreenGui.Enabled = false
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
				-- abrir directo; si no (suele llegar StartVote casi a la vez), esperar
				-- a StartVote vía pendingAutoVote, con fallback al menú por timeout.
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

	-- ── Network: StartVote ───────────────────────────────────
	-- No abre la pantalla por sí sola salvo para quien acaba de ver Results
	-- (pendingAutoVote). El resto entra con Play (label "VOTING").
	janitor:Add(Network.Match.StartVote.Listen(function(data: {
		option1Name: string,
		option1Image: string,
		option1Mode: string,
		option2Name: string,
		option2Image: string,
		option2Mode: string,
		option3Name: string,
		option3Image: string,
		option3Mode: string,
		duration: number,
	})
		isVoting = true
		matchMenu:setPhaseLabel("VOTING")
		selectedVoteKey = ""
		setPlayEnabled(playEnabled) -- recalcula Active (clickeable durante votación)
		view:show({
			option1 = { mapName = data.option1Name, mapImage = data.option1Image, mapMode = data.option1Mode },
			option2 = { mapName = data.option2Name, mapImage = data.option2Image, mapMode = data.option2Mode },
			option3 = { mapName = data.option3Name, mapImage = data.option3Image, mapMode = data.option3Mode },
		}, data.duration)
		view:setSelectedMap("")

		-- Quien venía de ver Results entra a la votación automáticamente.
		if pendingAutoVote then
			pendingAutoVote = false
			if votingPanel then
				votingPanel:open()
			end
		end
	end), true)

	-- ── Network: VoteState ───────────────────────────────────
	janitor:Add(Network.Match.VoteState.Listen(function(data: {
		option1Name: string,
		option1VoterIds: string,
		option2Name: string,
		option2VoterIds: string,
		option3Name: string,
		option3VoterIds: string,
		randomVoterIds: string,
		timeLeft: number,
	})
		if not isVoting then
			return
		end
		view:updateTimer(data.timeLeft)
		view:updateVotes({
			random = data.randomVoterIds,
			option1 = data.option1VoterIds,
			option2 = data.option2VoterIds,
			option3 = data.option3VoterIds,
		})
		if selectedVoteKey ~= "" then
			view:setSelectedMap(selectedVoteKey)
		end
	end), true)

	-- ── Network: EndVote ─────────────────────────────────────
	janitor:Add(Network.Match.EndVote.Listen(function(data: { winnerMapName: string })
		isVoting = false
		selectedVoteKey = ""
		pendingAutoVote = false
		setPlayEnabled(playEnabled) -- ya no es clickeable por votación

		local function finishVote()
			matchMenu:setPhaseLabel("DEPLOY")
			view:hide()
			if votingPanel then
				votingPanel:close()
			end
		end

		-- Solo animamos el ganador si el jugador está viendo la pantalla; si no,
		-- reseteamos en silencio (sigue en el menú).
		if votingPanelOpen then
			view:showWinner(data.winnerMapName, finishVote)
		else
			finishVote()
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

	Network.Match.RequestVoteSync.Send({})

	return janitor
end

return MatchFeature
