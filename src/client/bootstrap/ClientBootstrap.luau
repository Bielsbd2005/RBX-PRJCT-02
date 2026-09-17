--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local ClientBootStage = require(Shared:WaitForChild("constants"):WaitForChild("ClientBootStage"))

local ClientBootstrap = {}

local _started = false
local _janitor: any = nil
local CORE_GUI_DISABLE_RETRY_COUNT = 8
local CORE_GUI_DISABLE_RETRY_DELAY = 0.25

-- Handshake de join (informativo, no gatea el spawn): el cliente manda
-- ClientReady hasta ver el ACK del servidor (Player.JoinState == "Ready").
local CLIENT_READY_MAX_ATTEMPTS = 8
local CLIENT_READY_RETRY_SECONDS = 2
local NETWORK_WAIT_SECONDS = 5

-- TODA la resolución de la ruta va dentro del pcall: indexar fuera mataría el hilo
-- si la carpeta no ha replicado, y el require de Network puede fallar si el
-- StringValue del namespace de ByteNet aún no ha llegado. El bucle de envío reintenta.
local _network: any = nil
local function tryGetNetwork(): any
	if _network then
		return _network
	end
	local ok, result = pcall(function()
		local networking = Shared:WaitForChild("networking", NETWORK_WAIT_SECONDS)
		local module = networking and networking:WaitForChild("Network", NETWORK_WAIT_SECONDS)
		return require(module :: any)
	end)
	if ok then
		_network = result
	end
	return _network
end

local function sendClientReadyWithRetry(): ()
	local player = Players.LocalPlayer
	local function acked(): boolean
		return player:GetAttribute(ClientBootStage.JOIN_STATE_ATTRIBUTE) == ClientBootStage.JOIN_READY
	end
	for _ = 1, CLIENT_READY_MAX_ATTEMPTS do
		if acked() then
			return
		end
		local Network = tryGetNetwork()
		if Network then
			pcall(function()
				Network.Match.ClientReady.Send({})
			end)
		end
		task.wait(CLIENT_READY_RETRY_SECONDS)
	end
	if not acked() then
		warn("[ClientBootstrap] ClientReady sin ACK tras", CLIENT_READY_MAX_ATTEMPTS, "intentos")
	end
end

type DeferredFeatureEntry = {
	label: string,
	start: (any) -> any,
}

local function disableDefaultCoreGui(): ()
	task.spawn(function()
		for attempt = 1, CORE_GUI_DISABLE_RETRY_COUNT do
			local playerListOk = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			end)
			local healthOk = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
			end)

			if playerListOk and healthOk then
				return
			end

			if attempt < CORE_GUI_DISABLE_RETRY_COUNT then
				task.wait(CORE_GUI_DISABLE_RETRY_DELAY)
			end
		end
	end)
end

local function findLockerButton(menuGui: ScreenGui): GuiButton?
	local container = menuGui:FindFirstChild("Container")
	local btn = container and container:FindFirstChild("Locker")
	if btn and btn:IsA("GuiButton") then
		return btn
	end
	return nil
end

function ClientBootstrap.start(clientRoot: LocalScript): ()
	if _started then
		return
	end

	_started = true
	_janitor = Janitor.new()

	disableDefaultCoreGui()

	local DataController = require(clientRoot.core.data.DataController)
	local ScenePresetController = require(clientRoot.core.lighting.ScenePresetController)
	local MenuController = require(clientRoot.core.ui.MenuController)
	local UISoundsController = require(clientRoot.core.ui.UISoundsController)
	local ShadeController = require(clientRoot.core.ui.ShadeController)
	local WeaponWrapAnimator = require(clientRoot.core.visuals.WeaponWrapAnimator)
	local BalloonPopVisuals = require(clientRoot.core.visuals.BalloonPopVisuals)
	local BurningVisuals = require(clientRoot.core.visuals.BurningVisuals)
	local AbductionVisuals = require(clientRoot.core.visuals.AbductionVisuals)
	local XpOrbsVisuals = require(clientRoot.core.visuals.XpOrbsVisuals)
	local StoreFeature = require(clientRoot.features.store)
	local SettingsFeature = require(clientRoot.features.settings)
	local RewardsFeature = require(clientRoot.features.rewards)
	local DailyTasksFeature = require(clientRoot.features.dailyTasks)
	local BattlePassFeature = require(clientRoot.features.battlepass)
	local LobbyFeature = require(clientRoot.features.lobby)
	local LobbyMusicFeature = require(clientRoot.features.music)
	local MatchFeature = require(clientRoot.features.match)
	local MatchState = require(clientRoot.features.match.MatchState)
	local MatchCamera = require(clientRoot.features.match.MatchCamera)
	local GiftingFeature = require(clientRoot.features.gifting)

	-- El motor re-engancha la cámara al Humanoid en cada spawn y el personaje puede
	-- llegar antes o después del bootstrap: se re-afirma ahora y en cada CharacterAdded.
	local function applyLobbyCameraIfInMenu(): ()
		if MatchState.getPhase() ~= "Lobby" then
			return
		end
		MatchCamera.forceLobbyWithRetries(function()
			return MatchState.getPhase() == "Lobby"
		end)
	end

	DataController:Start()
	WeaponWrapAnimator.start()
	-- Antes que el lobby: el preview del kill effect en el Locker también lo usa.
	BalloonPopVisuals.start()
	BurningVisuals.start()
	AbductionVisuals.start()
	XpOrbsVisuals.start()
	-- No bloqueante: evita el streaming de skyboxes en el primer cambio de escena.
	ScenePresetController.preload()
	_janitor:Add(function()
		WeaponWrapAnimator.stop()
		BalloonPopVisuals.stop()
		BurningVisuals.stop()
		AbductionVisuals.stop()
		XpOrbsVisuals.stop()
	end, true)

	-- Timeout para que una replicación lenta (móvil) no cuelgue el bootstrap.
	local camera = Workspace.CurrentCamera
	local camerasFolder = Workspace:WaitForChild("Cameras", 10)
	local lobbyPart = camerasFolder and camerasFolder:WaitForChild("lobby", 10)
	if camera and lobbyPart and lobbyPart:IsA("BasePart") then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = lobbyPart.CFrame
		camera.FieldOfView = 40
	end
	applyLobbyCameraIfInMenu()

	_janitor:Add(Players.LocalPlayer.CharacterAdded:Connect(function()
		disableDefaultCoreGui()
		applyLobbyCameraIfInMenu()
	end), "Disconnect")

	local menuController = MenuController.new()
	_janitor:Add(menuController, "Destroy")

	-- Cámara fijada y menú construido: la pantalla de carga (ReplicatedFirst)
	-- lee este atributo local para abrirse, y el servidor recibe ClientReady.
	Players.LocalPlayer:SetAttribute(ClientBootStage.BOOT_STAGE_ATTRIBUTE, ClientBootStage.MENU_READY)
	task.spawn(sendClientReadyWithRetry)

	_janitor:Add(UISoundsController.start(), "Destroy")


	local deferredFeatures = {
		{ label = "shade", start = ShadeController.start },
		{ label = "store", start = StoreFeature.start },
		{ label = "settings", start = SettingsFeature.start },
		{ label = "rewards", start = RewardsFeature.start },
		{ label = "dailyTasks", start = DailyTasksFeature.start },
		{ label = "battlepass", start = BattlePassFeature.start },
		{ label = "lobby", start = LobbyFeature.start },
		{ label = "music", start = LobbyMusicFeature.start },
		{ label = "match", start = MatchFeature.start },
		{ label = "gifting", start = GiftingFeature.start },
	} :: { DeferredFeatureEntry }

	for _, feature in deferredFeatures do
		task.defer(function()
			local success, featureHandle = pcall(feature.start, menuController)
			if not success then
				warn("[ClientBootstrap] Failed to start feature:", feature.label, featureHandle)
				return
			end

			_janitor:Add(featureHandle, "Destroy")
		end)
	end

	local lockerFeatureHandle: any = nil
	local lockerFeatureModule: any = nil
	local lockerFeatureBooting = false
	local lockerLazyConnection: RBXScriptConnection? = nil
	-- Tabla compartida a propósito: LockerFeature.start lee `autoOpen` al final de
	-- su arranque, así que un clic llegado mientras bootea todavía abre el locker.
	local lockerFeatureOptions = { autoOpen = false }

	local function bootLockerFeature(openImmediately: boolean): ()
		if openImmediately then
			lockerFeatureOptions.autoOpen = true
		end

		if lockerFeatureHandle or lockerFeatureBooting then
			return
		end

		lockerFeatureBooting = true

		local success, result = pcall(function()
			lockerFeatureModule = lockerFeatureModule or require(clientRoot.features.locker)
			return lockerFeatureModule.start(menuController, lockerFeatureOptions)
		end)

		lockerFeatureBooting = false

		if not success then
			warn("[ClientBootstrap] Failed to start locker feature:", result)
			return
		end

		lockerFeatureHandle = result
		_janitor:Add(lockerFeatureHandle, "Destroy")

		if lockerLazyConnection then
			lockerLazyConnection:Disconnect()
			lockerLazyConnection = nil
		end
	end

	-- Arranca con el juego (cerrado), no al primer clic: su start() coloca las armas
	-- en Workspace.Locker y apaga el BillboardGui de stats del place.
	task.defer(function()
		bootLockerFeature(false)
	end)

	-- Red de seguridad: clic durante el boot, o reintento si el arranque falló.
	local lockerButton = findLockerButton(menuController:getGui())
	if lockerButton then
		lockerLazyConnection = lockerButton.MouseButton1Click:Connect(function()
			bootLockerFeature(true)
		end)

		_janitor:Add(function()
			if lockerLazyConnection then
				lockerLazyConnection:Disconnect()
				lockerLazyConnection = nil
			end
		end, true)
	end
end

return ClientBootstrap
