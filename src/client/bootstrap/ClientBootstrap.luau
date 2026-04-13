--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any

local ClientBootstrap = {}

local _started = false
local _janitor: any = nil

type DeferredFeatureEntry = {
	label: string,
	start: (any) -> any,
}

local function findLockerButton(menuGui: ScreenGui): GuiButton?
	local bottomContainer = menuGui:FindFirstChild("BottomContainer")
	if not bottomContainer then
		return nil
	end

	local footer = bottomContainer:FindFirstChild("Footer")
	if not footer then
		return nil
	end

	local lockerButton = footer:FindFirstChild("locker")
	if lockerButton and lockerButton:IsA("GuiButton") then
		return lockerButton
	end

	return nil
end

function ClientBootstrap.start(clientRoot: LocalScript): ()
	if _started then
		return
	end

	_started = true
	_janitor = Janitor.new()

	local DataController = require(clientRoot.core.data.DataController)
	local MenuController = require(clientRoot.core.ui.MenuController)
	local FusionFeature = require(clientRoot.features.fusion)
	local StoreFeature = require(clientRoot.features.store)
	local SettingsFeature = require(clientRoot.features.settings)
	local RewardsFeature = require(clientRoot.features.rewards)
	local CasesFeature = require(clientRoot.features.cases)
	local PlayTimeRewardsFeature = require(clientRoot.features.playtimerewards)

	DataController:Start()

	local camera = Workspace.CurrentCamera
	local camerasFolder = Workspace:WaitForChild("Cameras")
	local lobbyPart = camerasFolder:WaitForChild("lobby")
	if camera and lobbyPart:IsA("BasePart") then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = lobbyPart.CFrame
	end

	local menuController = MenuController.new()
	_janitor:Add(menuController, "Destroy")

	local deferredFeatures = {
		{ label = "fusion", start = FusionFeature.start },
		{ label = "store", start = StoreFeature.start },
		{ label = "settings", start = SettingsFeature.start },
		{ label = "rewards", start = RewardsFeature.start },
		{ label = "cases", start = CasesFeature.start },
		{ label = "playtimerewards", start = PlayTimeRewardsFeature.start },
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
		-- Fallback to previous eager behavior when the button cannot be resolved.
		bootLockerFeature(false)
	end
end

return ClientBootstrap
