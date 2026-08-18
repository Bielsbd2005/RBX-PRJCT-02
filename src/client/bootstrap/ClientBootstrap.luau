--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any

local ClientBootstrap = {}

local _started = false
local _janitor: any = nil
local CORE_GUI_DISABLE_RETRY_COUNT = 8
local CORE_GUI_DISABLE_RETRY_DELAY = 0.25

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

	-- Evita recreacion de ScreenGuis en respawn (rompe bindings de botones si cambia la instancia).
	StarterGui.ResetPlayerGuiOnSpawn = false
	disableDefaultCoreGui()

	-- Forzar orientación horizontal en móvil. LandscapeSensor bloquea el juego a
	-- horizontal pero permite girar el teléfono a izquierda o derecha. En PC/consola
	-- la propiedad se ignora. Se aplica sobre el PlayerGui vivo (StarterGui solo
	-- siembra el valor al unirse, así que esto es lo que manda en runtime).
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor

	local DataController = require(clientRoot.core.data.DataController)
	local ScenePresetController = require(clientRoot.core.lighting.ScenePresetController)
	local MenuController = require(clientRoot.core.ui.MenuController)
	local UISoundsController = require(clientRoot.core.ui.UISoundsController)
	local ShadeController = require(clientRoot.core.ui.ShadeController)
	local WeaponWrapAnimator = require(clientRoot.core.visuals.WeaponWrapAnimator)
	local StoreFeature = require(clientRoot.features.store)
	local SettingsFeature = require(clientRoot.features.settings)
	local RewardsFeature = require(clientRoot.features.rewards)
	local DailyTasksFeature = require(clientRoot.features.dailyTasks)
	local BattlePassFeature = require(clientRoot.features.battlepass)
	local LobbyFeature = require(clientRoot.features.lobby)
	local LobbyMusicFeature = require(clientRoot.features.music)
	local MatchFeature = require(clientRoot.features.match)
	local GiftingFeature = require(clientRoot.features.gifting)

	DataController:Start()
	WeaponWrapAnimator.start()
	-- Precarga (no bloqueante) los assets de los presets de lighting para que el
	-- primer cambio de escena no sufra el streaming de skyboxes/texturas.
	ScenePresetController.preload()
	_janitor:Add(function()
		WeaponWrapAnimator.stop()
	end, true)

	-- Audit mobile: timeout en WaitForChild para que la replicación lenta
	-- del workspace (común en móvil flaky) no bloquee el bootstrap entero.
	-- Si Cameras/lobby no llegan en 10s, dejamos la cámara con su CFrame
	-- por defecto (default camera type) — UX degradada pero no hang.
	local camera = Workspace.CurrentCamera
	local camerasFolder = Workspace:WaitForChild("Cameras", 10)
	local lobbyPart = camerasFolder and camerasFolder:WaitForChild("lobby", 10)
	if camera and lobbyPart and lobbyPart:IsA("BasePart") then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = lobbyPart.CFrame
	end

	_janitor:Add(game:GetService("Players").LocalPlayer.CharacterAdded:Connect(function()
		disableDefaultCoreGui()
	end), "Disconnect")

	local menuController = MenuController.new()
	_janitor:Add(menuController, "Destroy")

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
			if not _started or not _janitor then
				return
			end

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

	local function bootLockerFeature(openImmediately: boolean): ()
		if lockerFeatureHandle or lockerFeatureBooting then
			return
		end

		lockerFeatureBooting = true

		local success, result = pcall(function()
			lockerFeatureModule = lockerFeatureModule or require(clientRoot.features.locker)
			return lockerFeatureModule.start(menuController, {
				autoOpen = openImmediately,
			})
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
	else
		-- Sin botón Locker en el menú (se quitó la barra inferior): el locker
		-- queda dormido en vez de bootear sin forma de abrirlo. Si más adelante
		-- se agrega un GuiButton llamado "Locker" en cualquier parte del menú,
		-- findLockerButton lo tomará y se booteará on-click, sin tocar código.
	end
end

return ClientBootstrap
