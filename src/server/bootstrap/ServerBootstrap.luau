--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local ServerBootstrap = {}

local _started = false

function ServerBootstrap.start(serverRoot: Script): ()
	if _started then
		return
	end

	_started = true
	StarterGui.ResetPlayerGuiOnSpawn = false

	local DataService = require(serverRoot.core.data.DataService)
	local ShopService = require(serverRoot.features.shop.ShopService)
	local StoreService = require(serverRoot.features.store.StoreService)
	local SettingsService = require(serverRoot.features.settings.SettingsService)
	local RewardsService = require(serverRoot.features.rewards.RewardsService)
	local CasesService = require(serverRoot.features.cases.CasesService)
	local MatchService = require(serverRoot.features.match.MatchService)
	local DailyTasksService = require(serverRoot.features.dailyTasks.DailyTasksService)
	local BattlePassService = require(serverRoot.features.battlepass.BattlePassService)
	local LockerService = require(serverRoot.features.locker.LockerService)
	local ClearDataCommandService = require(serverRoot.features.testing.ClearDataCommandService)

	DataService:Start()
	ShopService:Start(DataService)
	StoreService:Start(DataService)
	SettingsService:Start(DataService)
	RewardsService:Start(DataService)
	-- BattlePassService debe arrancar ANTES que CasesService porque CasesService
	-- registra MarketplaceService.ProcessReceipt y consultará BattlePassService
	-- en su dispatcher.
	BattlePassService:Start(DataService)
	CasesService:Start(DataService)
	DailyTasksService:Start(DataService)

	-- Inyectar servicios en WeaponsSystem ANTES de MatchService:Start, para
	-- que las primeras kills/assists ya tengan DataService disponible. Si
	-- inyectáramos después, kills procesadas en la window inicial perderían
	-- cash silenciosamente (autoload usa upvalues nil hasta el inject).
	-- WeaponsSystem.luau se clona a ReplicatedStorage por ServerWeaponsScript;
	-- requerirlo desde ahí garantiza la misma instancia que usa el resto del
	-- pipeline de armas. WaitForChild tolera el race con la clonación.
	local weaponsSystemFolder = ReplicatedStorage:WaitForChild("WeaponsSystem", 10)
	local weaponsSystemModule = weaponsSystemFolder and weaponsSystemFolder:WaitForChild("WeaponsSystem", 10)
	if weaponsSystemModule and weaponsSystemModule:IsA("ModuleScript") then
		local WeaponsSystem = require(weaponsSystemModule) :: any
		if type(WeaponsSystem.injectServices) == "function" then
			WeaponsSystem.injectServices({
				DataService = DataService,
				MatchService = MatchService,
				DailyTasksService = DailyTasksService,
				BattlePassService = BattlePassService,
			})
		else
			warn("[ServerBootstrap] WeaponsSystem.injectServices no disponible — usando autoload")
		end
	else
		warn("[ServerBootstrap] WeaponsSystem no encontrado tras 10s — kills no recompensarán cash")
	end

	MatchService:Start(DataService)
	LockerService:Start(DataService)
	ClearDataCommandService:Start(DataService)
end

return ServerBootstrap
