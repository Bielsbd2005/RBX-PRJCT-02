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
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local DailyTasksConfig = require(Shared.constants.DailyTasks)

local DAILY_TASK_COMPLETED_ICON = "rbxassetid://113694528712529"

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
local RESPAWN_REQUEST_TIMEOUT = 5
local RETURN_TO_MENU_TIMEOUT = 8

-- ── Helpers de resolución de GUI ──

local function _resolveEndResultsGui(playerGui: PlayerGui): ScreenGui?
	local node = playerGui:FindFirstChild("EndResultsGui")
	if node and node:IsA("ScreenGui") then
		return node
	end
	return nil
end

local function _resolveMapVote(menuGui: ScreenGui): (GuiObject?, GuiObject?)
	local mapVote = menuGui:FindFirstChild("MapVote")
	if not mapVote or not mapVote:IsA("GuiObject") then
		return nil, nil
	end
	local options = mapVote:FindFirstChild("Options")
	if not options or not options:IsA("GuiObject") then
		return mapVote, nil
	end
	return mapVote, options
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

	-- Bot
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("FakeUserId") == killerUserId then
			return child
		end
		if child:IsA("Folder") or child:IsA("Model") then
			local botsFolder = if child.Name == "Bots" then child else child:FindFirstChild("Bots")
			if botsFolder then
				for _, bot in botsFolder:GetChildren() do
					if bot:IsA("Model") and bot:GetAttribute("FakeUserId") == killerUserId then
						return bot
					end
				end
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
	local mapVoteNode, optionsNode = _resolveMapVote(menuGui)
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
	local matchMenu = MatchMenu.new(menuController, playerGui, menuGui, MatchState.shouldKeepMenuHidden)

	local playButton = matchMenu:getPlayButton()
	if not playButton then
		warn("[MatchFeature] No se encontro Menu.BottomContainer.Footer.Play")
		return janitor
	end

	local matchHudGui = playerGui:FindFirstChild("MatchHud")
	local hud = MatchHud.new(if matchHudGui and matchHudGui:IsA("ScreenGui") then matchHudGui else nil)
	hud:setScores(0, 0, GameConfig.MaxRoundDuration)

	-- ── Vistas ───────────────────────────────────────────────
	matchMenu:setPhaseLabel("DEPLOY")

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
		matchMenu:enforceHidden()
		iris:close(function()
			if MatchState.getPhase() == "Joining" then
				Network.Match.RequestJoinMatch.Send({})
				task.delay(JOIN_CONFIRM_TIMEOUT, function()
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
			matchMenu:setPhaseLabel("VOTING")
		else
			matchMenu:setPhaseLabel("DEPLOY")
		end
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
		killerKills: number,
		killerLevel: number,
		weaponName: string,
	})
		hud:incrementLocalDeaths()
		if not deathView then
			return
		end

		MatchState.setPhase("Dying")
		respawnRequestSent = false
		hud:setEnabled(false)

		killCam:start({
			killerUserId = data.killerUserId,
			killerName = data.killerName,
			weaponName = data.weaponName,
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
		matchMenu:forceShow()
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
			matchMenu:enforceHidden()
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
						matchMenu:setPhaseLabel("DEPLOY")
						matchMenu:forceShow()
					end)
				end)
			else
				MatchState.setPhase("Lobby")
				matchMenu:forceShow()
			end
		elseif wasJoining then
			matchMenu:forceShow()
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
		matchMenu:setPhaseLabel("VOTING")
		selectedMapName = ""
		menuController:setMapVoteVisible(true)
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
		matchMenu:setPhaseLabel("DEPLOY")
		selectedMapName = ""
		view:hide()
		menuController:setMapVoteVisible(false)
	end), true)

	-- ── DataController observer ──────────────────────────────
	local function findLevelUpUnlock(level: number): any
		for category, items in ItemsConfig do
			if type(items) == "table" then
				for itemKey, definition in items do
					if type(definition) == "table" and tonumber(definition.LevelRequired) == level then
						local name = if type(definition.Name) == "string" and definition.Name ~= ""
							then definition.Name
							else tostring(itemKey)
						local image = if type(definition.Image) == "string" then definition.Image else nil
						return {
							name = name,
							category = tostring(category),
							image = image,
						}
					end
				end
			end
		end
		return nil
	end

	local function _isKillChallengeSkin(skinKey: string): (boolean, any)
		local weaponSkins = ItemsConfig.WeaponSkins
		if type(weaponSkins) ~= "table" then
			return false, nil
		end
		local def = weaponSkins[skinKey]
		if type(def) ~= "table" then
			return false, nil
		end
		local challenge = def.KillChallenge
		if type(challenge) == "table" and tonumber(challenge.Kills) and challenge.Kills > 0 then
			return true, def
		end
		return false, nil
	end

	DataController:WhenReady():andThen(function()
		local lastSeenLevel: number? = nil
		local function updateCashAndLevel()
			local stats = Fusion.peek(DataController.Stats) :: any
			hud:updateCashLevel(stats)

			local currentLevel = if stats and type(stats.Level) == "number" then math.max(0, math.floor(stats.Level)) else 0
			if lastSeenLevel ~= nil and currentLevel > lastSeenLevel then
				local unlock = findLevelUpUnlock(currentLevel)
				hud:playLevelUpAnimation(currentLevel, unlock)
			end
			lastSeenLevel = currentLevel
		end
		local statsObserver = fusionScope:Observer(DataController.Stats)
		janitor:Add(statsObserver:onBind(updateCashAndLevel), true)
		updateCashAndLevel()

		-- BattlePass tier-up: detecta CurrentTier subiendo y dispara la animación.
		-- Convención: el jugador percibe "Lvl. N" como el último tier completado,
		-- así que mostramos `currentTier - 1` (CurrentTier internamente es "el tier
		-- hacia el que progreso"). Si ocurre cascading tier-up (subir 3 niveles
		-- en una sola kill), disparamos un único toast con el tier final, igual
		-- que hace el level up de character.
		local lastSeenBPTier: number? = nil
		local function checkBattlePassLevelUp()
			local bp = Fusion.peek(DataController.BattlePass) :: any
			if type(bp) ~= "table" then return end
			local currentTier = if type(bp.CurrentTier) == "number" then math.max(1, math.floor(bp.CurrentTier)) else 1
			if lastSeenBPTier ~= nil and currentTier > lastSeenBPTier then
				local displayLevel = math.max(0, currentTier - 1)
				hud:playBattlePassLevelUpAnimation(displayLevel)
			end
			lastSeenBPTier = currentTier
		end
		local bpObserver = fusionScope:Observer(DataController.BattlePass)
		janitor:Add(bpObserver:onBind(checkBattlePassLevelUp), true)
		checkBattlePassLevelUp()

		-- Snapshot inicial de wraps owned por arma para detectar desbloqueos.
		local previousByWeapon: { [string]: { [string]: { [string]: boolean } } } = {}
		local wrapsSeeded = false
		local function snapshotWrapsOwned(inventory: any): { [string]: { [string]: { [string]: boolean } } }
			local snapshot: { [string]: { [string]: { [string]: boolean } } } = {}
			local byWeapon = if type(inventory) == "table" then inventory.WeaponSkinsByWeapon else nil
			if type(byWeapon) ~= "table" then
				return snapshot
			end
			for category, weaponMap in byWeapon do
				if type(weaponMap) == "table" then
					local catSnap: { [string]: { [string]: boolean } } = {}
					for weaponKey, skinMap in weaponMap do
						if type(skinMap) == "table" then
							local skinSnap: { [string]: boolean } = {}
							for skinKey, owned in skinMap do
								if owned == true or (type(owned) == "number" and owned > 0) then
									skinSnap[skinKey] = true
								end
							end
							catSnap[weaponKey] = skinSnap
						end
					end
					snapshot[category] = catSnap
				end
			end
			return snapshot
		end

		local function updateWrapsAndDetectUnlocks()
			local inventory = Fusion.peek(DataController.Inventory) :: any
			local current = snapshotWrapsOwned(inventory)

			if wrapsSeeded then
				for category, weaponMap in current do
					local prevCat = previousByWeapon[category] or {}
					for weaponKey, skinMap in weaponMap do
						local prevSkins = prevCat[weaponKey] or {}
						for skinKey, _ in skinMap do
							if not prevSkins[skinKey] then
								local isChallenge, def = _isKillChallengeSkin(skinKey)
								if isChallenge then
									hud:playChallengeCompletedAnimation({
										name = if type(def.Name) == "string" and def.Name ~= "" then def.Name else skinKey,
										image = if type(def.Image) == "string" and def.Image ~= "" then def.Image else nil,
										previewWeaponCategory = category,
										previewWeaponKey = weaponKey,
										itemKey = skinKey,
										category = "WeaponSkins",
										textureID = if type(def.TextureID) == "string" then def.TextureID else nil,
										baseColor = if typeof(def.BaseColor) == "Color3" then def.BaseColor else nil,
										animated = def.Animated == true,
										studsPerTile = tonumber(def.StudsPerTile),
									})
								end
							end
						end
					end
				end
			end

			previousByWeapon = current
			wrapsSeeded = true
		end

		local inventoryObserver = fusionScope:Observer(DataController.Inventory)
		janitor:Add(inventoryObserver:onBind(updateWrapsAndDetectUnlocks), true)

		-- ── Daily tasks: detectar transición Claimed false→true ────
		-- Solo dispara la animación de "Completed" cuando el HUD de partida
		-- está activo (matchHudGui.Enabled). En menú no se muestra; el frame
		-- del lobby ya pinta el fill verde como feedback.
		local prevClaimed: { [string]: boolean } = {}
		local claimedSeeded = false
		local function onDailyTasksChanged()
			local state = Fusion.peek(DataController.DailyTasks) :: any
			local claimed = if state and type(state.Claimed) == "table" then state.Claimed else {}

			if claimedSeeded and matchHudGui and matchHudGui.Enabled then
				for _, def in DailyTasksConfig.Tasks do
					local now = (claimed :: any)[def.Id] == true
					local before = prevClaimed[def.Id] == true
					if now and not before then
						-- Description leerá "You earned Cash"; Reward.Value
						-- mostrará el monto otorgado por la tarea.
						hud:playChallengeCompletedAnimation({
							name = "Cash",
							image = DAILY_TASK_COMPLETED_ICON,
							cashAmount = def.Cash,
						})
					end
				end
			end

			local snapshot: { [string]: boolean } = {}
			for _, def in DailyTasksConfig.Tasks do
				snapshot[def.Id] = (claimed :: any)[def.Id] == true
			end
			prevClaimed = snapshot
			claimedSeeded = true
		end
		local dailyTasksObserver = fusionScope:Observer(DataController.DailyTasks)
		janitor:Add(dailyTasksObserver:onBind(onDailyTasksChanged), true)
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
		menuController:setMapVoteVisible(false)
		hud:setEnabled(false)
		if endResultsGui then
			endResultsGui.Enabled = false
		end
		iris:reset()
		Fusion.doCleanup(fusionScope)
	end, true)

	Network.Match.RequestVoteSync.Send({})

	return janitor
end

return MatchFeature
