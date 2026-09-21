--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ActionRewards = require(Shared:WaitForChild("constants"):WaitForChild("ActionRewards"))
local StoreProducts = require(Shared:WaitForChild("constants"):WaitForChild("StoreProducts"))

local TelemetryService = require(script.Parent.Parent.core.TelemetryService)

--[[
	Packs de Robux por moneda: lo que distingue un pack de Cash de uno de Gems vive aquí
	como datos y el camino de concesión (`grantPackPurchase`) es uno solo.
	Los packs sin ProductId configurado no entran en `ByProductId`, así que un
	receipt nunca puede resolverse a un pack a medio crear.
]]
type PackKind = {
	Catalog: StoreProducts.Catalog<any>,
	GetAmount: (any) -> number,
	-- Stats del profile: saldo y contador acumulado de la moneda.
	BalanceStat: string,
	TotalEarnedStat: string,
	-- Contador de lo COMPRADO, cuando la moneda lo separa: TotalCashEarned suma todo y
	-- este permite a la telemetría medir Coin por hora jugada sin las ventas.
	TotalPurchasedStat: string?,
	Currency: TelemetryService.Currency,
	TelemetryKind: TelemetryService.PurchaseKind,
}

local PACK_KINDS: { PackKind } = {
	{
		Catalog = StoreProducts.Cash,
		GetAmount = function(product: StoreProducts.StoreProductDefinition)
			return product.CashAmount
		end,
		BalanceStat = "Cash",
		TotalEarnedStat = "TotalCashEarned",
		TotalPurchasedStat = "TotalCashPurchased",
		Currency = "Cash",
		TelemetryKind = "CashPack",
	},
	{
		Catalog = StoreProducts.Gems,
		GetAmount = function(product: StoreProducts.GemProductDefinition)
			return product.GemAmount
		end,
		BalanceStat = "Gems",
		TotalEarnedStat = "TotalGemsEarned",
		Currency = "Gems",
		TelemetryKind = "GemPack",
	},
}

-- Primer pack (de cualquier moneda) que declara este developer product.
local function resolvePack(productId: number): (PackKind?, any)
	for _, kind in PACK_KINDS do
		local product = kind.Catalog.ByProductId[productId]
		if product then
			return kind, product
		end
	end
	return nil, nil
end

local ServerBootstrap = {}

local _started = false

function ServerBootstrap.start(serverRoot: Script): ()
	if _started then
		return
	end

	_started = true
	StarterGui.ResetPlayerGuiOnSpawn = false

	local DataService = require(serverRoot.core.data.DataService)
	local RewardService = require(serverRoot.core.RewardService)
	local BattlePassConfig = require(Shared:WaitForChild("constants"):WaitForChild("BattlePassConfig"))
	local GamePassService = require(serverRoot.core.GamePassService)
	local ShopService = require(serverRoot.features.shop.ShopService)
	local SettingsService = require(serverRoot.features.settings.SettingsService)
	local RewardsService = require(serverRoot.features.rewards.RewardsService)
	local VIPItemsService = require(serverRoot.features.rewards.VIPItemsService)
	local MatchService = require(serverRoot.features.match.MatchService)
	local DailyTasksService = require(serverRoot.features.dailyTasks.DailyTasksService)
	local BattlePassService = require(serverRoot.features.battlepass.BattlePassService)
	local GiftingService = require(serverRoot.features.gifting.GiftingService)
	local LockerService = require(serverRoot.features.locker.LockerService)
	local ClearDataCommandService = require(serverRoot.features.testing.ClearDataCommandService)
	local TrainingDummyService = require(serverRoot.features.testing.TrainingDummyService)

	DataService:Start()

	-- Antes que las features: el prefetch de posesión de gamepasses es una llamada web y
	-- quien pregunta (bonus VIP, holster) no bloquea; cuanto antes se pueble el caché mejor.
	GamePassService.Start()

	--[[
		TelemetryService antes que RewardService: quien emite eventos necesita el servicio
		listo o los flujos de cash de la ventana inicial se pierden en silencio.

		El contador de bots se INYECTA en vez de requerir AI desde `core` (invertiría la
		dependencia core → features). Se resuelve lazy porque MatchService carga AIService en
		su Start, más tarde; `require` está memoizado, así que es la misma instancia.
	]]
	local _aiForTelemetry: any = nil
	local function _botCount(): number
		if not _aiForTelemetry then
			local aiModule = serverRoot:FindFirstChild("AI")
			if aiModule and aiModule:IsA("ModuleScript") then
				local ok, result = pcall(require, aiModule)
				if ok then
					_aiForTelemetry = result
				end
			end
		end

		local service = _aiForTelemetry
		if not service or type(service.GetBotRoster) ~= "function" then
			return 0
		end
		local ok, roster = pcall(function()
			return service:GetBotRoster()
		end)
		return if ok and type(roster) == "table" then #roster else 0
	end

	TelemetryService.Start(DataService, _botCount)

	-- RewardService antes que cualquier service que conceda XP o Cash (MatchService,
	-- RewardsService, DailyTasksService, WeaponsSystem inyectado).
	RewardService.Start(DataService)
	ShopService:Start(DataService)
	SettingsService:Start(DataService)
	RewardsService:Start(DataService)
	VIPItemsService:Start(DataService)
	BattlePassService:Start(DataService)
	GiftingService:Start(DataService)
	DailyTasksService:Start(DataService)

	--[[
		Concede un pack de Robux y devuelve la decisión del receipt, o nil si el ProductId no
		es de ningún pack (el dispatcher sigue probando handlers).
		Contrato de durabilidad: idempotencia por PurchaseId + ForceSave confirmado ANTES de
		conceder, porque Roblox da por consumido el receipt al devolver PurchaseGranted.
	]]
	local function grantPackPurchase(receiptInfo: any): Enum.ProductPurchaseDecision?
		local kind, product = resolvePack(receiptInfo.ProductId)
		if not kind or not product then
			return nil
		end

		local buyer = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not buyer then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- Ya procesado: no re-otorgar, pero forzar save por si un intento anterior concedió en
		-- memoria sin llegar a persistir.
		local purchaseId = tostring(receiptInfo.PurchaseId)
		if DataService:IsReceiptProcessed(buyer, purchaseId) then
			if DataService:ForceSave(buyer) then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local amount = kind.GetAmount(product)

		-- Atómico: grant de la moneda + mark receipt en el mismo BatchUpdate.
		local updates = {
			{ path = { "Stats", kind.BalanceStat }, delta = amount },
			{ path = { "Stats", kind.TotalEarnedStat }, delta = amount },
			{ path = { "Stats", "TotalRobuxSpent" }, delta = product.RobuxPrice },
			{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
		}
		if kind.TotalPurchasedStat then
			table.insert(updates, { path = { "Stats", kind.TotalPurchasedStat }, delta = amount })
		end
		local ok = DataService:BatchUpdate(buyer, updates)
		if not ok then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- Si el save falla, NotProcessedYet hace que Roblox reentregue el receipt (la
		-- idempotencia de arriba evita el doble-grant).
		if not DataService:ForceSave(buyer) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		TelemetryService.RecordFlow(buyer, "source", "RobuxPurchase", amount, product.ButtonName, kind.Currency)
		TelemetryService.RecordPurchase({
			userId = buyer.UserId,
			purchaseId = purchaseId,
			productId = receiptInfo.ProductId,
			sku = product.ButtonName,
			robuxPrice = product.RobuxPrice,
			-- El payload solo tiene columna de cash: un pack de Gems reporta 0 y
			-- se distingue por `kind`.
			cashGranted = if kind.Currency == "Cash" then amount else 0,
			kind = kind.TelemetryKind,
		})
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Dispatcher central de ProcessReceipt: BattlePass, luego regalos y por último packs.
	-- Vive aquí (cross-cutting) para no acoplarlo a una sola feature.
	MarketplaceService.ProcessReceipt = function(receiptInfo: any): Enum.ProductPurchaseDecision
		local bpDecision = BattlePassService:ProcessReceipt(receiptInfo)
		if bpDecision ~= nil then
			return bpDecision
		end

		-- Gifting intercepta receipts de store products cuando el comprador tiene
		-- una intención de regalo activa (GiftIntent): el cash va al receptor, no
		-- al comprador. nil ⇒ compra normal, sigue el handler de abajo.
		local giftDecision = GiftingService:ProcessReceipt(receiptInfo)
		if giftDecision ~= nil then
			return giftDecision
		end

		local packDecision = grantPackPurchase(receiptInfo)
		if packDecision ~= nil then
			return packDecision
		end

		warn("[ServerBootstrap] Unknown ProductId:", receiptInfo.ProductId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Inyectar servicios en WeaponsSystem ANTES de MatchService:Start: sin inject, el autoload
	-- usa upvalues nil y las kills de la ventana inicial perderían cash en silencio.
	-- ServerWeaponsScript clona WeaponsSystem.luau a ReplicatedStorage; requerirlo de ahí
	-- da la misma instancia que el pipeline de armas. WaitForChild tolera la carrera.
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
				RewardService = RewardService,
			})
		else
			warn("[ServerBootstrap] WeaponsSystem.injectServices no disponible — usando autoload")
		end

		-- Los concerns del kill flow PvP viven aquí y no en WeaponsSystem, que queda agnóstico
		-- al juego: el bootstrap es el único punto que sabe qué services existen.
		if type(WeaponsSystem) == "table" then
			-- killHook: síncrono, calcula el payload de PlayerEliminated (UI del killer en el mismo
			-- frame). NO concede cash/XP (eso lo hace MatchService vía RewardService); solo replica
			-- lo que se va a otorgar para que la UI no mienta.
			WeaponsSystem.killHook = function(_killer: Player, _victimHum: Humanoid, _weaponName: string, wasHeadshot: boolean)
				local xpGained = ActionRewards.GetXP("Kill")
				if wasHeadshot then
					xpGained += ActionRewards.GetXP("Headshot")
				end

				return {
					xpGained = xpGained,
				}
			end

			-- Killed: notificaciones async para services con side-effects; los nuevos se
			-- suscriben aquí sin tocar WeaponsSystem.luau.
			if WeaponsSystem.Killed and WeaponsSystem.Killed.Event then
				WeaponsSystem.Killed.Event:Connect(function(killer: Player, victimHum: Humanoid, _weaponName: string, wasHeadshot: boolean)
					-- Killed dispara con CUALQUIER humanoid que muera a tiros, también un cuerpo del
					-- lobby: aquí sólo cuentan las kills de partida. El pcall cubre un `killer` nil
					-- (kill de entorno).
					local okMatchKill, isMatchKill = pcall(function()
						return MatchService:IsMatchKill(killer, victimHum)
					end)
					if not okMatchKill or not isMatchKill then
						return
					end

					-- Las dailies no pasan por el cap de la ronda a propósito: su payout ya está acotado
					-- por diseño. OnKill lleva dentro la racha de bajas; el headshot es su propia tarea.
					if (DailyTasksService :: any).OnKill then
						pcall(function() (DailyTasksService :: any):OnKill(killer) end)
					end
					if wasHeadshot and (DailyTasksService :: any).OnHeadshot then
						pcall(function() (DailyTasksService :: any):OnHeadshot(killer) end)
					end
					-- El pase tiene su propio cupo por ronda, para que farmear kills no lo suba sin
					-- límite. La reserva va DENTRO del pcall: `killer` puede llegar nil (kill de
					-- entorno) y no debe tumbar el handler.
					if (BattlePassService :: any).OnKill then
						pcall(function()
							if MatchService:TryConsumeBattlePassXP(killer, BattlePassConfig.XPRates.PerKill) then
								(BattlePassService :: any):OnKill(killer)
							end
						end)
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
	TrainingDummyService:Start()

	-- Embudo de primera sesión (solo JoinCount == 1). Sin sessionId: corre una sola vez por
	-- jugador, así que no hay intentos que desambiguar.
	local ONBOARDING_STEP_NAMES: { [number]: string } = {
		[1] = "Joined",
		[2] = "FirstMatchStarted",
		[3] = "FirstKill",
		[4] = "FirstMatchCompleted",
		[5] = "ReturnedToLobby",
	}
	local function onboardingStep(player: Player, step: number)
		TelemetryService.RecordFunnelStep(player, "onboarding", step, ONBOARDING_STEP_NAMES[step])
	end

	local _onboardingPlayers: { [number]: true } = {}

	DataService.ProfileLoaded:Connect(function(player: Player)
		local profile = DataService:GetProfile(player)
		if not profile or not profile.Data then return end
		local joinCount = profile.Data.Metadata.JoinCount
		if joinCount == 1 then
			_onboardingPlayers[player.UserId] = true
			onboardingStep(player, 1)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		_onboardingPlayers[player.UserId] = nil
	end)

	MatchService.OnPlayerJoinedMatch = function(player: Player)
		if _onboardingPlayers[player.UserId] then
			onboardingStep(player, 2)
		end
	end

	MatchService.OnPlayerFirstKill = function(player: Player)
		if _onboardingPlayers[player.UserId] then
			onboardingStep(player, 3)
		end
	end

	MatchService.OnPlayerMatchCompleted = function(player: Player)
		if _onboardingPlayers[player.UserId] then
			onboardingStep(player, 4)
		end
	end

	MatchService.OnPlayerReturnedToLobby = function(player: Player)
		if _onboardingPlayers[player.UserId] then
			onboardingStep(player, 5)
			_onboardingPlayers[player.UserId] = nil
		end
	end
end

return ServerBootstrap
