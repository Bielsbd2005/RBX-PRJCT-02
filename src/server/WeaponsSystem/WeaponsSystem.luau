
local function _isDescendantOfStarterGear(instance: Instance): boolean
	-- W10: nativo en lugar de loop manual sobre la ancestría.
	return instance:FindFirstAncestorOfClass("StarterGear") ~= nil
end
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Teams = game:GetService("Teams")
local IsServer = RunService:IsServer()

-- Dependencies
local WeaponData = script.Parent:WaitForChild("WeaponData")
local WeaponsSystemFolder = script.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local ActionRewards = require(Shared.constants.ActionRewards)
local WeaponTypes = WeaponsSystemFolder:WaitForChild("WeaponTypes")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local ShoulderCamera = require(Libraries:WaitForChild("ShoulderCamera"))
local WeaponsGui = require(Libraries:WaitForChild("WeaponsGui"))
local SpringService = require(Libraries:WaitForChild("SpringService"))
local ancestorHasTag = require(Libraries:WaitForChild("ancestorHasTag"))
ShoulderCamera.SpringService = SpringService

-- ─── Servicios inyectables ───────────────────────────────────
-- WeaponsSystem usa estos servicios para conceder Cash/XP/dailies en kills.
-- Dos rutas para resolverlos:
--
--   1. Inyección explícita (preferida): ServerBootstrap llama
--      `WeaponsSystem.injectServices({ DataService = ..., MatchService = ..., ... })`
--      antes de `WeaponsSystem.setup()`. Necesario para tests con mocks.
--
--   2. Autoload (fallback): si nadie inyecta, intentamos resolver los módulos
--      por nombre desde ServerScriptService.Server. Usamos WaitForChild con
--      timeout corto para tolerar carga concurrente (vs FindFirstChild antes).
--
-- Las variables son `local` para que las closures definidas más abajo capturen
-- el upvalue: re-asignar la variable se ve desde todas las funciones.
local MatchService = nil
local DataService = nil
local DailyTasksService = nil
local BattlePassService = nil
local RewardService = nil

local _AUTOLOAD_TIMEOUT = 5

local function _safeWaitForChild(parent: Instance, name: string): Instance?
	local ok, result = pcall(function()
		return parent:WaitForChild(name, _AUTOLOAD_TIMEOUT)
	end)
	if ok then
		return result
	end
	return nil
end

local function _safeRequire(module: Instance?, label: string): any
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn(("WeaponsSystem: Failed to load %s: %s"):format(label, tostring(result)))
		return nil
	end
	return result
end

local function _autoloadServices()
	local serverRoot = _safeWaitForChild(ServerScriptService, "Server")
	if not serverRoot then return end

	local featuresFolder = _safeWaitForChild(serverRoot, "features")
	local matchFeatures = featuresFolder and _safeWaitForChild(featuresFolder, "match")
	if matchFeatures then
		if not MatchService then
			MatchService = _safeRequire(matchFeatures:FindFirstChild("MatchService"), "MatchService")
		end
	end

	local coreFolder = _safeWaitForChild(serverRoot, "core")
	local dataFolder = coreFolder and _safeWaitForChild(coreFolder, "data")
	if dataFolder and not DataService then
		DataService = _safeRequire(dataFolder:FindFirstChild("DataService"), "DataService")
	end

	local dailyTasksFolder = featuresFolder and _safeWaitForChild(featuresFolder, "dailyTasks")
	if dailyTasksFolder and not DailyTasksService then
		DailyTasksService = _safeRequire(dailyTasksFolder:FindFirstChild("DailyTasksService"), "DailyTasksService")
	end

	local battlePassFolder = featuresFolder and _safeWaitForChild(featuresFolder, "battlepass")
	if battlePassFolder and not BattlePassService then
		BattlePassService = _safeRequire(battlePassFolder:FindFirstChild("BattlePassService"), "BattlePassService")
	end
end

if IsServer then
	_autoloadServices()
end

local Configuration = WeaponsSystemFolder:WaitForChild("Configuration")
local ConfigurationValues = {
	SprintEnabled = Configuration:WaitForChild("SprintEnabled"),
	SlowZoomWalkEnabled = Configuration:WaitForChild("SlowZoomWalkEnabled"),
}


local WEAPON_TAG = "WeaponsSystemWeapon"
local WEAPON_TYPES_LOOKUP = {}

local REMOTE_EVENT_NAMES = {
	"WeaponFired",
	"WeaponHit",
	"WeaponReloadRequest",
	"WeaponReloaded",
	"WeaponReloadCanceled",
	"WeaponActivated",
	"PlayerEliminated",
	"PlayerAssist",
	"SyncStreakState",
	"PlayExplosionVFX",
}

-- Damage contributors per humanoid for assist tracking.
-- W9: weak keys (__mode = "k") aseguran que si un Humanoid se queda sin refs
-- fuertes (mapa re-parented, mob destruido sin disparar Died, etc.) el GC
-- limpia la entry. Defense-in-depth — el flujo normal usa Died/AncestryChanged.
local damageContributors: { [Humanoid]: { [Player]: number } } = setmetatable({}, { __mode = "k" }) :: any
local assistDiedConnections: { [Humanoid]: RBXScriptConnection } = setmetatable({}, { __mode = "k" }) :: any
local assistAncestryConnections: { [Humanoid]: RBXScriptConnection } = setmetatable({}, { __mode = "k" }) :: any

local function _clearDamageContributors(target: Humanoid)
	damageContributors[target] = nil
	if assistDiedConnections[target] then
		assistDiedConnections[target]:Disconnect()
		assistDiedConnections[target] = nil
	end
	if assistAncestryConnections[target] then
		assistAncestryConnections[target]:Disconnect()
		assistAncestryConnections[target] = nil
	end
end

-- Forward declaration; body assigned after WeaponsSystem table exists
local flushAssists: (target: Humanoid, killerPlayer: Player?) -> ()

local REMOTE_FUNCTION_NAMES = {}

--Set up WeaponTypes lookup table
do
	local function onNewWeaponType(weaponTypeModule)
		if not weaponTypeModule:IsA("ModuleScript") then
			return
		end
		local weaponTypeName = weaponTypeModule.Name
		xpcall(function()
			coroutine.wrap(function()
				local weaponType = require(weaponTypeModule)
				assert(typeof(weaponType) == "table", string.format("WeaponType \"%s\" did not return a valid table", weaponTypeModule:GetFullName()))
				WEAPON_TYPES_LOOKUP[weaponTypeName] = weaponType
			end)()
		end, function(errMsg)
			warn(string.format("Error while loading %s: %s", weaponTypeModule:GetFullName(), errMsg))
			warn(debug.traceback())
		end)
	end
	for _, child in pairs(WeaponTypes:GetChildren()) do
		onNewWeaponType(child)
	end
	WeaponTypes.ChildAdded:Connect(onNewWeaponType)
end

local WeaponsSystem = {}
WeaponsSystem.didSetup = false
WeaponsSystem.knownWeapons = {}
WeaponsSystem.connections = {}
WeaponsSystem.networkFolder = nil
WeaponsSystem.remoteEvents = {}
WeaponsSystem.remoteFunctions = {}
WeaponsSystem.currentWeapon = nil
WeaponsSystem.aimRayCallback = nil
WeaponsSystem._hotbarFallbackInProgress = false
WeaponsSystem._hotbarFallbackTarget = nil

WeaponsSystem.CurrentWeaponChanged = Instance.new("BindableEvent")

-- Sprint 4 (P2 #21): hook + signal para desacoplar la lógica de rewards del
-- WeaponsSystem. Antes _defaultDamageCallback hardcodeaba calls a 5 services
-- (DataService, MatchService, DailyTasksService, BattlePassService,
-- CashBonusSystem) — el módulo era inreusable en otro modo.
--
-- killHook (sincronía):
--   Bootstrap registra una función que recibe (killer, victimHumanoid,
--   weaponName, wasHeadshot) y devuelve { coinAmount, streakAfterKill,
--   xpGained } para el payload del PlayerEliminated remote (UI del killer
--   los necesita en el mismo frame). Si nadie registra el hook, valores
--   default resueltos vía ActionRewards (Kill + Headshot si aplica).
--
-- Killed.Event (asíncrono):
--   Se Fire después de aplicar damage + flush assists. Bootstrap conecta
--   listeners para DailyTasks/BattlePass/etc. WeaponsSystem solo notifica.
WeaponsSystem.Killed = Instance.new("BindableEvent")
WeaponsSystem.killHook = (nil :: any) :: ((killer: Player, victimHum: Humanoid, weaponName: string, wasHeadshot: boolean) -> { coinAmount: number?, streakAfterKill: number?, xpGained: number? })?

-- Inyección explícita de servicios. Llama a esto desde ServerBootstrap antes
-- de WeaponsSystem.setup() para evitar el autoload por nombre y para tests.
-- Las claves son opcionales: solo se sobrescriben las pasadas.
function WeaponsSystem.injectServices(services: {
	DataService: any?,
	MatchService: any?,
	DailyTasksService: any?,
	BattlePassService: any?,
	RewardService: any?,
})
	if services.DataService ~= nil then DataService = services.DataService end
	if services.MatchService ~= nil then MatchService = services.MatchService end
	if services.DailyTasksService ~= nil then DailyTasksService = services.DailyTasksService end
	if services.BattlePassService ~= nil then BattlePassService = services.BattlePassService end
	if services.RewardService ~= nil then RewardService = services.RewardService end
end

-- Assign flushAssists body now that WeaponsSystem exists
flushAssists = function(target: Humanoid, killerPlayer: Player?)
	local assistEvent = WeaponsSystem.remoteEvents["PlayerAssist"]
	if damageContributors[target] then
		for contributor, _ in damageContributors[target] do
			-- Guard estricto: contributor sigue en el server Y no es el killer.
			-- Re-evaluamos contributor.Parent justo antes del write (puede haber
			-- cambiado entre iteraciones si dispatchamos algo que yieldea, aunque
			-- aquí no es el caso — defensa proactiva).
			if contributor ~= killerPlayer and contributor.Parent then
				if assistEvent then
					assistEvent:FireClient(contributor)
				end
				if RewardService then
					-- Stats.Assists+1 va atómico con el Cash dentro del mismo
					-- BatchUpdate. XP se aplica internamente vía AddXP (cascada
					-- de level-up).
					(RewardService :: any).Award(contributor, "Assist", {
						{ path = { "Stats", "Assists" }, delta = 1 },
					})
				end
			end
		end
	end
	_clearDamageContributors(target)
end

local function _getToolCategory(tool: Tool?): string?
	if not tool then
		return nil
	end

	if ItemsConfig.Main[tool.Name] then
		return "Main"
	end
	if ItemsConfig.Special[tool.Name] then
		return "Special"
	end

	return nil
end

local function _findLocalHotbarTools(): (Tool?, Tool?, boolean)
	if IsServer then
		return nil, nil, false
	end

	local player = Players.LocalPlayer
	if not player then
		return nil, nil, false
	end

	local mainTool = nil
	local specialTool = nil
	local hasMatchTool = false

	local character = player.Character
	local backpack = player:FindFirstChildOfClass("Backpack")
	local containers = { character, backpack }

	for _, container in ipairs(containers) do
		if not container then
			continue
		end

		for _, child in ipairs(container:GetChildren()) do
			if not child:IsA("Tool") then
				continue
			end

			if child:GetAttribute("MatchLoadoutTool") == true then
				hasMatchTool = true
			end

			local category = _getToolCategory(child)
			if category == "Main" then
				if not mainTool or (character and child:IsDescendantOf(character)) then
					mainTool = child
				end
			elseif category == "Special" then
				if not specialTool or (character and child:IsDescendantOf(character)) then
					specialTool = child
				end
			end
		end
	end

	return mainTool, specialTool, hasMatchTool
end

local function _tryReequipHotbarFallback(previousWeapon): (boolean, any)
	if IsServer then
		return false, nil
	end

	if WeaponsSystem._hotbarFallbackInProgress then
		return true, previousWeapon
	end

	local player = Players.LocalPlayer
	local character = player and player.Character
	if not character then
		return false, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, nil
	end

	local mainTool, specialTool, hasMatchTool = _findLocalHotbarTools()
	if not hasMatchTool then
		return false, nil
	end

	local prevTool = previousWeapon and previousWeapon.instance
	local fallbackTool = nil

	if prevTool == mainTool then
		fallbackTool = specialTool or mainTool
	else
		fallbackTool = mainTool or specialTool
	end

	if not fallbackTool then
		return false, nil
	end

	if prevTool and fallbackTool == prevTool then
		return true, previousWeapon
	end

	local fallbackWeapon = WeaponsSystem.getWeaponForInstance(fallbackTool)
	WeaponsSystem._hotbarFallbackInProgress = true
	WeaponsSystem._hotbarFallbackTarget = fallbackTool

	-- Watchdog: si EquipTool bloquea o el cleanup nunca corre, libera el flag
	-- a los 2s. Sin esto, el flag pegado bloquea futuras llamadas de fallback.
	task.delay(2, function()
		if WeaponsSystem._hotbarFallbackTarget == fallbackTool then
			WeaponsSystem._hotbarFallbackTarget = nil
			WeaponsSystem._hotbarFallbackInProgress = false
		end
	end)

	task.defer(function()
		if character.Parent and fallbackTool.Parent then
			local currentlyEquipped = character:FindFirstChildOfClass("Tool")
			if currentlyEquipped ~= fallbackTool then
				-- pcall por si EquipTool falla (tool destruido a mitad).
				pcall(function()
					humanoid:EquipTool(fallbackTool)
				end)
			end
		end

		-- Liberar siempre, no solo cuando target sigue siendo el nuestro.
		-- El watchdog ya cubre el caso degenerado, pero clear inmediato es lo
		-- que queremos en el path normal.
		if WeaponsSystem._hotbarFallbackTarget == fallbackTool then
			WeaponsSystem._hotbarFallbackTarget = nil
			WeaponsSystem._hotbarFallbackInProgress = false
		end
	end)

	return true, fallbackWeapon or previousWeapon
end

local NetworkingCallbacks = require(WeaponsSystemFolder:WaitForChild("NetworkingCallbacks"))
NetworkingCallbacks.WeaponsSystem = WeaponsSystem

local _damageCallback = nil
local _getTeamCallback = nil

function WeaponsSystem.setDamageCallback(cb)
	_damageCallback = cb
end

function WeaponsSystem.setGetTeamCallback(cb)
	_getTeamCallback = cb
end

function WeaponsSystem.setup()
	if WeaponsSystem.didSetup then
		warn("Warning: trying to run WeaponsSystem setup twice on the same module.")
		return
	end
	--print(script.Parent:GetFullName(), "is now active.")

	WeaponsSystem.doingSetup = true

	-- Bind WeaponsNetwork singleton — antes de cualquier require de armas que lo use.
	local WeaponsNetwork = require(script.Parent:WaitForChild("Libraries"):WaitForChild("WeaponsNetwork"))
	WeaponsNetwork.bind(WeaponsSystem)

	--Setup network routing
	if IsServer then
		local networkFolder = Instance.new("Folder")
		networkFolder.Name = "Network"

		for _, remoteEventName in pairs(REMOTE_EVENT_NAMES) do
			local remoteEvent = Instance.new("RemoteEvent")
			remoteEvent.Name = remoteEventName
			remoteEvent.Parent = networkFolder

			local callback = NetworkingCallbacks[remoteEventName]
			if not callback then
				--Connect a no-op function to ensure the queue doesn't pile up.
				warn("There is no server callback implemented for the WeaponsSystem RemoteEvent \"%s\"!")
				warn("A default no-op function will be implemented so that the queue cannot be abused.")
				callback = function() end
			end
			WeaponsSystem.connections[remoteEventName .. "Remote"] = remoteEvent.OnServerEvent:Connect(function(...)
				callback(...)
			end)
			WeaponsSystem.remoteEvents[remoteEventName] = remoteEvent
		end
		for _, remoteFuncName in pairs(REMOTE_FUNCTION_NAMES) do
			local remoteFunc = Instance.new("RemoteEvent")
			remoteFunc.Name = remoteFuncName
			remoteFunc.Parent = networkFolder

			local callback = NetworkingCallbacks[remoteFuncName]
			if not callback then
				--Connect a no-op function to ensure the queue doesn't pile up.
				warn("There is no server callback implemented for the WeaponsSystem RemoteFunction \"%s\"!")
				warn("A default no-op function will be implemented so that the queue cannot be abused.")
				callback = function() end
			end
			remoteFunc.OnServerInvoke = function(...)
				return callback(...)
			end
			WeaponsSystem.remoteFunctions[remoteFuncName] = remoteFunc
		end

		networkFolder.Parent = WeaponsSystemFolder
		WeaponsSystem.networkFolder = networkFolder
	else
		WeaponsSystem.StarterGui = game:GetService("StarterGui")

		WeaponsSystem.camera = ShoulderCamera.new(WeaponsSystem)
		WeaponsSystem.gui = WeaponsGui.new(WeaponsSystem)

		-- Sprint disabled
		-- if ConfigurationValues.SprintEnabled.Value then
		-- 	WeaponsSystem.camera:setSprintEnabled(ConfigurationValues.SprintEnabled.Value)
		-- end

		if ConfigurationValues.SlowZoomWalkEnabled.Value then
			WeaponsSystem.camera:setSlowZoomWalkEnabled(ConfigurationValues.SlowZoomWalkEnabled.Value)
		end

		local networkFolder = WeaponsSystemFolder:WaitForChild("Network", math.huge)

		for _, remoteEventName in pairs(REMOTE_EVENT_NAMES) do
			coroutine.wrap(function()
				local remoteEvent = networkFolder:WaitForChild(remoteEventName, math.huge)
				local callback = NetworkingCallbacks[remoteEventName]
				if callback then
					WeaponsSystem.connections[remoteEventName .. "Remote"] = remoteEvent.OnClientEvent:Connect(function(...)
						callback(...)
					end)
				end
				WeaponsSystem.remoteEvents[remoteEventName] = remoteEvent
			end)()
		end
		for _, remoteFuncName in pairs(REMOTE_FUNCTION_NAMES) do
			coroutine.wrap(function()
				local remoteFunc = networkFolder:WaitForChild(remoteFuncName, math.huge)
				local callback = NetworkingCallbacks[remoteFuncName]
				if callback then
					remoteFunc.OnClientInvoke = function(...)
						return callback(...)
					end
				end
				WeaponsSystem.remoteFunctions[remoteFuncName] = remoteFunc
			end)()
		end

		Players.LocalPlayer.CharacterAdded:Connect(WeaponsSystem.onCharacterAdded)
		if Players.LocalPlayer.Character then
			WeaponsSystem.onCharacterAdded(Players.LocalPlayer.Character)
		end

		WeaponsSystem.networkFolder = networkFolder
		WeaponsSystem.camera:setEnabled(false)
	end

	--Setup weapon tools and listening
	WeaponsSystem.connections.weaponAdded = CollectionService:GetInstanceAddedSignal(WEAPON_TAG):Connect(WeaponsSystem.onWeaponAdded)
	WeaponsSystem.connections.weaponRemoved = CollectionService:GetInstanceRemovedSignal(WEAPON_TAG):Connect(WeaponsSystem.onWeaponRemoved)

	for _, instance in pairs(CollectionService:GetTagged(WEAPON_TAG)) do
		WeaponsSystem.onWeaponAdded(instance)
	end

	WeaponsSystem.doingSetup = false
	WeaponsSystem.didSetup = true
end

function WeaponsSystem.resetClientRuntimeState()
	if IsServer then
		return
	end

	WeaponsSystem.currentWeapon = nil
	WeaponsSystem._hotbarFallbackInProgress = false
	WeaponsSystem._hotbarFallbackTarget = nil
	WeaponsSystem.aimRayCallback = nil

	if WeaponsSystem.gui then
		if WeaponsSystem.gui.setEnabled then
			WeaponsSystem.gui:setEnabled(false)
		end
		if WeaponsSystem.gui.setZoomed then
			WeaponsSystem.gui:setZoomed(false)
		end
		if WeaponsSystem.gui.setScopeEnabled then
			WeaponsSystem.gui:setScopeEnabled(false)
		end
	end

	if WeaponsSystem.camera then
		if WeaponsSystem.camera.setEnabled then
			WeaponsSystem.camera:setEnabled(false)
		end
		WeaponsSystem.camera.rotateCharacterWithCamera = false
		if WeaponsSystem.camera.setForceZoomed then
			WeaponsSystem.camera:setForceZoomed(false)
		end
		if WeaponsSystem.camera.setZoomedFromInput then
			WeaponsSystem.camera:setZoomedFromInput(false)
		end
		if WeaponsSystem.camera.resetZoomFactor then
			WeaponsSystem.camera:resetZoomFactor()
		end
		if WeaponsSystem.camera.setHasScope then
			WeaponsSystem.camera:setHasScope(false)
		end
	end
end

function WeaponsSystem.onCharacterAdded(character)
	-- Reset client state on new character so camera/gui do not keep stale values.
	WeaponsSystem.resetClientRuntimeState()

	-- Make it so players unequip weapons while seated, then reequip weapons when they become unseated
	local humanoid = character:WaitForChild("Humanoid")
	if WeaponsSystem.connections.seated then
		WeaponsSystem.connections.seated:Disconnect()
	end
	WeaponsSystem.connections.seated = humanoid.Seated:Connect(function(isSeated)
		if isSeated then
			WeaponsSystem.seatedWeapon = character:FindFirstChildOfClass("Tool")
			humanoid:UnequipTools()
			WeaponsSystem.StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		else
			WeaponsSystem.StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			if WeaponsSystem.seatedWeapon then
				humanoid:EquipTool(WeaponsSystem.seatedWeapon)
			end
		end
	end)
	WeaponsSystem.StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)

	if WeaponsSystem.connections.died then
		WeaponsSystem.connections.died:Disconnect()
	end
	WeaponsSystem.connections.died = humanoid.Died:Once(function()
		WeaponsSystem.resetClientRuntimeState()
	end)
end

function WeaponsSystem.shutdown()
	if not WeaponsSystem.didSetup then
		return
	end

	for _, weapon in pairs(WeaponsSystem.knownWeapons) do
		weapon:onDestroyed()
	end
	WeaponsSystem.knownWeapons = {}

	if IsServer and WeaponsSystem.networkFolder then
		WeaponsSystem.networkFolder:Destroy()
	end
	WeaponsSystem.networkFolder = nil
	WeaponsSystem.remoteEvents = {}
	WeaponsSystem.remoteFunctions = {}

	for _, connection in pairs(WeaponsSystem.connections) do
		if typeof(connection) == "RBXScriptConnection" then
			connection:Disconnect()
		end
	end
	WeaponsSystem.connections = {}
end

function WeaponsSystem.createWeaponForInstance(weaponInstance)
	coroutine.wrap(function()
		local weaponTypeAttribute = weaponInstance:GetAttribute("WeaponType")
		if type(weaponTypeAttribute) ~= "string" or weaponTypeAttribute == "" then
			warn(string.format("Missing Tool attribute WeaponType on %s.", weaponInstance:GetFullName()))
			return
		end

		local weaponType = WEAPON_TYPES_LOOKUP[weaponTypeAttribute]
		if not weaponType then
			warn(string.format("Cannot find the weapon type \"%s\" for the instance %s!", weaponTypeAttribute, weaponInstance:GetFullName()))
			return
		end

		-- Since we might have yielded while trying to get the WeaponType, we need to make sure not to continue
		-- making a new weapon if something else beat this iteration.
		if WeaponsSystem.getWeaponForInstance(weaponInstance) then
			warn("Already got ", weaponInstance:GetFullName())
			warn(debug.traceback())
			return
		end

		-- We should be pretty sure we got a valid weaponType by now
		assert(weaponType, "Got invalid weaponType")

		local weapon = weaponType.new(WeaponsSystem, weaponInstance)
		WeaponsSystem.knownWeapons[weaponInstance] = weapon
	end)()
end

function WeaponsSystem.getWeaponForInstance(weaponInstance)
	if not typeof(weaponInstance) == "Instance" then
		warn("WeaponsSystem.getWeaponForInstance(weaponInstance): 'weaponInstance' was not an instance.")
		return nil
	end

	return WeaponsSystem.knownWeapons[weaponInstance]
end

-- and (IsServer or weaponInstance:IsDescendantOf(Players.LocalPlayer))

function WeaponsSystem.onWeaponAdded(weaponInstance)
	if not weaponInstance:IsA("Tool") then
		return
	end

	-- StarterGear tools are templates for respawn and should not be initialized as active weapons.
	if _isDescendantOfStarterGear(weaponInstance) then
		return
	end

	local weapon = WeaponsSystem.getWeaponForInstance(weaponInstance)
	if not weapon then
		WeaponsSystem.createWeaponForInstance(weaponInstance)
	end
end

function WeaponsSystem.onWeaponRemoved(weaponInstance)
	local weapon = WeaponsSystem.getWeaponForInstance(weaponInstance)
	if weapon then
		weapon:onDestroyed()
	end
	WeaponsSystem.knownWeapons[weaponInstance] = nil

end

function WeaponsSystem.getRemoteEvent(name)
	if not WeaponsSystem.networkFolder then
		return
	end

	local remoteEvent = WeaponsSystem.remoteEvents[name]
	if IsServer then
		if not remoteEvent then
			warn("No RemoteEvent named ", name)
			return nil
		end

		return remoteEvent
	else
		if not remoteEvent then
			remoteEvent = WeaponsSystem.networkFolder:WaitForChild(name, math.huge)
		end

		return remoteEvent
	end
end

function WeaponsSystem.getRemoteFunction(name)
	if not WeaponsSystem.networkFolder then
		return
	end

	local remoteFunc = WeaponsSystem.remoteFunctions[name]
	if IsServer then
		if not remoteFunc then
			warn("No RemoteFunction named ", name)
			return nil
		end

		return remoteFunc
	else
		if not remoteFunc then
			remoteFunc = WeaponsSystem.networkFolder:WaitForChild(name, math.huge)
		end

		return remoteFunc
	end
end

function WeaponsSystem.setWeaponEquipped(weapon, equipped)
	assert(not IsServer, "WeaponsSystem.setWeaponEquipped should only be called on the client.")
	if not weapon then
		return
	end

	local lastWeapon = WeaponsSystem.currentWeapon
	local weaponChanged = false

	if equipped and weapon.instance == WeaponsSystem._hotbarFallbackTarget then
		WeaponsSystem._hotbarFallbackTarget = nil
		WeaponsSystem._hotbarFallbackInProgress = false
	end

	if lastWeapon == weapon then
		if not equipped then
			local blockedUnequip, fallbackWeapon = _tryReequipHotbarFallback(lastWeapon)
			if blockedUnequip then
				WeaponsSystem.currentWeapon = fallbackWeapon or lastWeapon
				weaponChanged = WeaponsSystem.currentWeapon ~= lastWeapon
			else
				WeaponsSystem.currentWeapon = nil
				weaponChanged = true
			end
		else
			weaponChanged = false
		end
	else
		if equipped then
			WeaponsSystem.currentWeapon = weapon
			weaponChanged = true
		end
	end

	if WeaponsSystem.camera then
		local weaponIsActive = WeaponsSystem.currentWeapon ~= nil
		WeaponsSystem.camera:setEnabled(weaponIsActive)
		WeaponsSystem.camera.rotateCharacterWithCamera = weaponIsActive

		WeaponsSystem.camera:resetZoomFactor()
		WeaponsSystem.camera:setHasScope(false)

		if WeaponsSystem.currentWeapon then
			WeaponsSystem.camera:setZoomFactor(WeaponsSystem.currentWeapon:getConfigValue("ZoomFactor", 1.1))
			WeaponsSystem.camera:setHasScope(WeaponsSystem.currentWeapon:getConfigValue("HasScope", false))
		end
	end

	if WeaponsSystem.gui then
		local weaponIsActive = WeaponsSystem.currentWeapon ~= nil
		WeaponsSystem.gui:setEnabled(weaponIsActive)

		if WeaponsSystem.currentWeapon then
			WeaponsSystem.gui:setCrosshairWeaponScale(WeaponsSystem.currentWeapon:getConfigValue("CrosshairScale", 1))
		else
			WeaponsSystem.gui:setCrosshairWeaponScale(1)
		end
	end

	if weaponChanged then
		WeaponsSystem.CurrentWeaponChanged:Fire(weapon.instance, lastWeapon and lastWeapon.instance)
	end
end


function WeaponsSystem.getPlayerFromHumanoid(humanoid)
	-- W5: nativo O(1) via tabla interna del servicio. Antes loop sobre
	-- Players:GetPlayers() + IsDescendantOf por hit (caro en explosiones,
	-- que llaman este por cada parte en el radio).
	local parent = humanoid and humanoid.Parent
	if not parent then
		return nil
	end
	return Players:GetPlayerFromCharacter(parent)
end


--[[
	Resuelve el humanoid del modelo padre del part hiteado, devolviendo además
	si el hit fue un headshot.

	Antes usábamos un BoolValue global (`dmiHandler`) que getHumanoid mutaba y
	_defaultDamageCallback leía. Eso permitía races: dos hits concurrentes
	(p. ej. múltiples parts en el radio de una explosión) podían interleavear
	la mutación del flag y el siguiente hit leía el valor del anterior.

	Ahora devolvemos `(humanoid, wasHeadshot)` como tuple. Los callers que
	necesitan el flag (BulletWeapon.onHit) lo guardan en hitInfo y lo pasan
	a doDamage; los que no, ignoran el segundo retorno.
]]
function WeaponsSystem.getHumanoid(part)
	local wasHeadshot = false
	while part and part ~= workspace do
		if part:IsA("Model") and part.PrimaryPart and part.PrimaryPart.Name == "HumanoidRootPart" then
			return part:FindFirstChildOfClass("Humanoid"), wasHeadshot
		end

		if part.Name == "Head" then
			wasHeadshot = true
		end
		part = part.Parent
	end
	return nil, false
end


-- Función optimizada para servidor
local TeamUtils = require(Shared.utils.TeamUtils)

local function _defaultDamageCallback(system, target, amount, damageType, dealer, hitInfo, damageData)
	if not target or not target:IsA("Humanoid") or target.Health <= 0 then return end
	local targetCharacter = target.Parent
	if not targetCharacter then return end

	-- Bloquear friendly fire: mismos equipos no se hacen daño
	if dealer and dealer.Character then
		if TeamUtils.isSameTeam(dealer.Character, targetCharacter :: Model) then
			return
		end
	end

	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	local dealerPlayer = dealer and Players:GetPlayerFromCharacter(dealer.Character)
	local weaponName = "Unknown Weapon"
	if dealer and dealer.Character then
		local equippedTool = dealer.Character:FindFirstChildOfClass("Tool")
		if equippedTool then weaponName = equippedTool.Name end
	end
	if weaponName == "Unknown Weapon" and damageData then
		if typeof(damageData) == "Instance" then
			weaponName = damageData.Name
		elseif typeof(damageData) == "table" and damageData.Name then
			weaponName = damageData.Name
		end
	end
	-- wasHeadshot llega via hitInfo (poblado por BulletWeapon.onHit usando el
	-- segundo retorno de getHumanoid). Defensivo: si el caller no lo pasó
	-- (e.g. damage de una explosión), tratamos como bodyshot.
	local wasHeadshot = type(hitInfo) == "table" and hitInfo.wasHeadshot == true
	local finalDamage = wasHeadshot and (amount * 2) or amount
	local isLethal = target.Health <= finalDamage

	if dealer and dealer.Character then
		if dealerPlayer then
			target:SetAttribute("LastAttackerUserId", dealerPlayer.UserId)
			target:SetAttribute("LastAttackerAt", time())
			target:SetAttribute("LastAttackerWeaponId", weaponName)
			target:SetAttribute("LastAttackerHeadshot", wasHeadshot == true)

			-- Track damage contributor for assists
			if not damageContributors[target] then
				damageContributors[target] = {}
				-- Listen for death caused by anything (including NPCs bypassing doDamage)
				if not assistDiedConnections[target] then
					assistDiedConnections[target] = target.Died:Once(function()
						-- Delay one frame so the in-callback flush (if any) runs first
						task.defer(function()
							if damageContributors[target] then
								flushAssists(target, nil)
							end
						end)
					end)
				end
				-- Listen for the humanoid leaving the data model (respawn, despawn, etc.)
				-- Without this, contributor entries leak when bots are removed or characters
				-- are destroyed without firing Died.
				if not assistAncestryConnections[target] then
					assistAncestryConnections[target] = target.AncestryChanged:Connect(function()
						if not target:IsDescendantOf(game) then
							_clearDamageContributors(target)
						end
					end)
				end
			end
			damageContributors[target][dealerPlayer] = (damageContributors[target][dealerPlayer] or 0) + finalDamage
		end

		target:TakeDamage(finalDamage)

		if target.Health <= 0 then
			local victimName = if targetPlayer then targetPlayer.Name
				else (targetCharacter:GetAttribute("DisplayName") or targetCharacter.Name)

			if dealerPlayer then
				local eliminatedEvent = WeaponsSystem.remoteEvents["PlayerEliminated"]
				if eliminatedEvent then
					local targetHrp = targetCharacter:FindFirstChild("HumanoidRootPart")
					local victimPos = targetHrp and targetHrp.Position or targetCharacter:GetPivot().Position

					-- Hook sincrono — el bootstrap puede registrarlo para
					-- computar streak/cash/xp. Si nadie registra, defaults.
					local rewards: { coinAmount: number?, streakAfterKill: number?, xpGained: number? }? = nil
					local hook = WeaponsSystem.killHook
					if hook then
						local ok, result = pcall(hook, dealerPlayer, target, weaponName, wasHeadshot)
						if ok and type(result) == "table" then
							rewards = result
						else
							warn("WeaponsSystem: killHook error: " .. tostring(result))
						end
					end

					-- Fallback solo cuando nadie registró killHook (uso standalone
					-- del módulo). En el flujo normal el bootstrap registra el hook
					-- y devuelve los valores reales de ActionRewards.
					local fallbackXp = ActionRewards.GetXP("Kill") + (wasHeadshot and ActionRewards.GetXP("Headshot") or 0)
					local xpGained = (rewards and rewards.xpGained) or fallbackXp
					local streakAfterKill = (rewards and rewards.streakAfterKill) or 1
					local coinAmount = rewards and rewards.coinAmount

					eliminatedEvent:FireClient(dealerPlayer, victimName, xpGained, wasHeadshot, victimPos, coinAmount, streakAfterKill)
				end
			end

			-- Flush assists immediately (cancels the deferred Died listener)
			flushAssists(target, dealerPlayer)

			-- Sprint 4: notificar listeners async (DailyTasks, BattlePass, etc.).
			-- Antes hardcoded inline arriba; ahora bootstrap conecta los services.
			if dealerPlayer then
				WeaponsSystem.Killed:Fire(dealerPlayer, target, weaponName, wasHeadshot)
			end
		end
	end
end

function WeaponsSystem.doDamage(target, amount, damageType, dealer, hitInfo, damageData)
	if not target or ancestorHasTag(target, "WeaponsSystemIgnore") then
		return
	end
	if IsServer then
		if target:IsA("Humanoid") and dealer:IsA("Player") and dealer.Character then
			local dealerHumanoid = dealer.Character:FindFirstChildOfClass("Humanoid")
			local targetPlayer = Players:GetPlayerFromCharacter(target.Parent)
			local dealerHRP = dealer.Character:FindFirstChild("HumanoidRootPart")
			if dealerHumanoid and target ~= dealerHumanoid and targetPlayer and dealerHRP then
				-- Trigger the damage indicator
				WeaponData:FireClient(targetPlayer, "HitByOtherPlayer", dealerHRP.Position)
			end
		end


		-- NOTE:  damageData is a more or less free-form parameter that can be used for passing information from the code that is dealing damage about the cause.
		-- .The most obvious usage is extracting icons from the various weapon types (in which case a weapon instance would likely be passed in)
		-- ..The default weapons pass in that data
		local handler = _damageCallback or _defaultDamageCallback
		handler(WeaponsSystem, target, amount, damageType, dealer, hitInfo, damageData)
	end
end

-- antes devolvía siempre 0
local function _defaultGetTeamCallback(player)
	if not player or not player.Team then
		return 0
	end
end

function WeaponsSystem.getTeam(player)
	local handler = _getTeamCallback or _defaultGetTeamCallback
	return handler(player)
end

function WeaponsSystem.playersOnDifferentTeams(player1, player2)
	if not player1 or not player2 then
		return true
	end
	local char1 = player1.Character
	local char2 = player2.Character
	return TeamUtils.areEnemies(char1, char2)
end

return WeaponsSystem
