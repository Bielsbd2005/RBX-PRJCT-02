--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StoreProducts = require(Shared:WaitForChild("constants"):WaitForChild("StoreProducts"))

local STORE_PRODUCTS_BY_ID = StoreProducts.ProductsByProductId :: { [number]: { CashAmount: number } }

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
	local SettingsService = require(serverRoot.features.settings.SettingsService)
	local RewardsService = require(serverRoot.features.rewards.RewardsService)
	local MatchService = require(serverRoot.features.match.MatchService)
	local DailyTasksService = require(serverRoot.features.dailyTasks.DailyTasksService)
	local BattlePassService = require(serverRoot.features.battlepass.BattlePassService)
	local LockerService = require(serverRoot.features.locker.LockerService)
	local ClearDataCommandService = require(serverRoot.features.testing.ClearDataCommandService)

	DataService:Start()
	ShopService:Start(DataService)
	SettingsService:Start(DataService)
	RewardsService:Start(DataService)
	BattlePassService:Start(DataService)
	DailyTasksService:Start(DataService)

	-- ProcessReceipt dispatcher central: delega BattlePass primero, luego Cash
	-- store products. Vive aquí (cross-cutting) en lugar de en una feature para
	-- que la responsabilidad sea explícita y no quede acoplada a una sola.
	MarketplaceService.ProcessReceipt = function(receiptInfo: any): Enum.ProductPurchaseDecision
		local bpDecision = BattlePassService:ProcessReceipt(receiptInfo)
		if bpDecision ~= nil then
			return bpDecision
		end

		local storeProduct = STORE_PRODUCTS_BY_ID[receiptInfo.ProductId]
		if storeProduct then
			local buyer = Players:GetPlayerByUserId(receiptInfo.PlayerId)
			if not buyer then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end

			-- Idempotencia: si ya procesamos este PurchaseId, no re-otorgar Cash.
			local purchaseId = tostring(receiptInfo.PurchaseId)
			if DataService:IsReceiptProcessed(buyer, purchaseId) then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end

			-- Atómico: grant Cash + mark receipt en el mismo BatchUpdate.
			local ok = DataService:BatchUpdate(buyer, {
				{ path = { "Stats", "Cash" }, delta = storeProduct.CashAmount },
				{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
			})
			if ok then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		warn("[ServerBootstrap] Unknown ProductId:", receiptInfo.ProductId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

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

		-- Sprint 4 (P2 #21): cross-cutting concerns del PvP kill flow viven aquí
		-- en lugar de hardcoded en WeaponsSystem._defaultDamageCallback.
		-- WeaponsSystem queda agnóstico al juego; el bootstrap es el único punto
		-- que sabe qué services existen en este modo.
		if type(WeaponsSystem) == "table" then
			-- killHook: sincronía. Computa rewards data necesaria para el
			-- payload del PlayerEliminated remote (UI del killer la consume
			-- en el mismo frame: streak count, coinAmount).
			local CashBonusSystem: any = nil  -- placeholder hasta que se cree el módulo
			WeaponsSystem.killHook = function(killer: Player, _victimHum: Humanoid, _weaponName: string, wasHeadshot: boolean)
				local streakAfterKill = 1
				if MatchService and (MatchService :: any).GetPlayerKillStreak then
					local ok, currentStreak = pcall(function()
						return (MatchService :: any):GetPlayerKillStreak(killer)
					end)
					if ok and typeof(currentStreak) == "number" then
						streakAfterKill = math.max(1, currentStreak + 1)
					end
				end

				local coinAmount: number? = nil
				if CashBonusSystem and CashBonusSystem.CalculateKillReward then
					local reward = CashBonusSystem.CalculateKillReward(wasHeadshot, streakAfterKill)
					if reward then
						coinAmount = reward.coinAmount
						if reward.totalCash and reward.totalCash > 0 then
							local okIncrement = pcall(function()
								(DataService :: any):Increment(killer, { "Stats", "Cash" }, reward.totalCash)
							end)
							if not okIncrement then
								warn("[ServerBootstrap] Failed to grant kill cash to " .. killer.Name)
							end
						end
					end
				end

				return {
					streakAfterKill = streakAfterKill,
					coinAmount = coinAmount,
					xpGained = wasHeadshot and 150 or 100,
				}
			end

			-- Killed signal: notificaciones async para services side-effect.
			-- Cualquier service futuro (Achievements, Quests, etc.) puede
			-- subscribirse aquí sin tocar WeaponsSystem.luau.
			if WeaponsSystem.Killed and WeaponsSystem.Killed.Event then
				WeaponsSystem.Killed.Event:Connect(function(killer: Player, _victimHum: Humanoid, _weaponName: string, _wasHeadshot: boolean)
					if (DailyTasksService :: any).OnKill then
						pcall(function() (DailyTasksService :: any):OnKill(killer) end)
					end
					if (BattlePassService :: any).OnKill then
						pcall(function() (BattlePassService :: any):OnKill(killer) end)
					end
				end)
			end
		end
	else
		warn("[ServerBootstrap] WeaponsSystem no encontrado tras 10s — kills no recompensarán cash")
	end

	MatchService:Start(DataService)
	LockerService:Start(DataService)
	ClearDataCommandService:Start(DataService)
end

return ServerBootstrap
