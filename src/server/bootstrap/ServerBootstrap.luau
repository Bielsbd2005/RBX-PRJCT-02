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
	Packs de Robux que concede este dispatcher, uno por moneda. TODO lo que
	distingue un pack de Cash de uno de Gems vive aquí como datos; el camino de
	concesión (`grantPackPurchase`) es uno solo. Mientras fueron dos bloques
	gemelos, cada arreglo de idempotencia o de durabilidad había que acordarse
	de replicarlo en el otro.

	Los packs sin ProductId configurado no entran en `ByProductId`, así que un
	receipt nunca puede resolverse a un pack a medio crear.
]]
type PackKind = {
	Catalog: StoreProducts.Catalog<any>,
	GetAmount: (any) -> number,
	-- Stats del profile: saldo y contador acumulado de la moneda.
	BalanceStat: string,
	TotalEarnedStat: string,
	-- Contador de lo COMPRADO, cuando la moneda lo separa. TotalCashEarned
	-- suma todo (grind + packs + regalos); este es el que permite a la
	-- telemetría restar y medir "Coin por hora jugada" sin las ventas dentro.
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
	local GamePassService = require(serverRoot.core.GamePassService)
	local ShopService = require(serverRoot.features.shop.ShopService)
	local SettingsService = require(serverRoot.features.settings.SettingsService)
	local RewardsService = require(serverRoot.features.rewards.RewardsService)
	local MatchService = require(serverRoot.features.match.MatchService)
	local DailyTasksService = require(serverRoot.features.dailyTasks.DailyTasksService)
	local BattlePassService = require(serverRoot.features.battlepass.BattlePassService)
	local GiftingService = require(serverRoot.features.gifting.GiftingService)
	local LockerService = require(serverRoot.features.locker.LockerService)
	local ClearDataCommandService = require(serverRoot.features.testing.ClearDataCommandService)
	local TrainingDummyService = require(serverRoot.features.testing.TrainingDummyService)

	DataService:Start()

	-- Antes que las features: el prefetch de posesión de gamepasses tarda una
	-- llamada web, y quien pregunta (bonus VIP de resultados, holster del arma)
	-- lo hace sin bloquear. Cuanto antes se pueble el caché, menos beneficios se
	-- quedan apagados en los primeros segundos de sesión.
	GamePassService.Start()

	--[[
		TelemetryService antes que RewardService por el mismo motivo que
		RewardService va antes que el resto: quien emite eventos necesita el
		servicio listo. Si arrancara después, los flujos de cash de la ventana
		inicial se perderían en silencio.

		El contador de bots se INYECTA en vez de requerir AI desde `core`
		(invertiría la dependencia core → features). Se resuelve de forma lazy
		dentro del closure porque MatchService carga AIService en su propio
		Start, que corre más tarde que este bloque. `require` está memoizado en
		Roblox, así que devuelve la misma instancia que usa MatchService.
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

	-- RewardService arranca justo después de DataService: cualquier service
	-- que conceda XP o Cash (MatchService, RewardsService, DailyTasksService,
	-- WeaponsSystem injected) lo necesita listo antes de su propio Start.
	RewardService.Start(DataService)
	ShopService:Start(DataService)
	SettingsService:Start(DataService)
	RewardsService:Start(DataService)
	BattlePassService:Start(DataService)
	GiftingService:Start(DataService)
	DailyTasksService:Start(DataService)

	--[[
		Concede un pack de Robux (Cash o Gems) y devuelve la decisión del receipt,
		o nil si el ProductId no es de ningún pack (para que el dispatcher siga
		probando handlers).

		Ambas monedas comparten el camino entero; lo único que cambia son los
		datos de PACK_KINDS. Contrato de durabilidad: idempotencia por PurchaseId
		+ ForceSave confirmado ANTES de conceder, porque Roblox da por consumido
		el receipt en cuanto devolvemos PurchaseGranted.
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

		-- Idempotencia: si ya procesamos este PurchaseId, no re-otorgar la moneda.
		-- Aun así forzamos un save: si un intento anterior concedió en memoria
		-- pero no llegó a persistir, esto lo confirma antes de devolver
		-- PurchaseGranted (Roblox consume el receipt al concederlo).
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

		-- Roblox no espera a nuestro write: save confirmado ANTES de conceder.
		-- Si falla, NotProcessedYet hace que reentregue el receipt (la
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

	-- ProcessReceipt dispatcher central: prueba BattlePass, luego regalos y por
	-- último los packs de moneda (Cash y Gems). Vive aquí (cross-cutting) en
	-- lugar de en una feature para que la responsabilidad sea explícita y no
	-- quede acoplada a una sola.
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
				RewardService = RewardService,
			})
		else
			warn("[ServerBootstrap] WeaponsSystem.injectServices no disponible — usando autoload")
		end

		-- Sprint 4 (P2 #21): cross-cutting concerns del PvP kill flow viven aquí
		-- en lugar de hardcoded en WeaponsSystem._defaultDamageCallback.
		-- WeaponsSystem queda agnóstico al juego; el bootstrap es el único punto
		-- que sabe qué services existen en este modo.
		if type(WeaponsSystem) == "table" then
			-- killHook: sincronía. Calcula el payload del remote PlayerEliminated
			-- (UI del killer en el mismo frame). NO concede cash/XP — eso lo hace
			-- MatchService vía RewardService en _registerKillEvent. Aquí solo
			-- replicamos lo que va a otorgar para que la UI no mienta.
			WeaponsSystem.killHook = function(_killer: Player, _victimHum: Humanoid, _weaponName: string, wasHeadshot: boolean)
				-- Valores reales de ActionRewards (no hardcoded). El cash/XP lo otorga
				-- MatchService vía RewardService; aquí solo se replica el XP a mostrar.
				local xpGained = ActionRewards.GetXP("Kill")
				if wasHeadshot then
					xpGained += ActionRewards.GetXP("Headshot")
				end

				return {
					xpGained = xpGained,
				}
			end

			-- Killed signal: notificaciones async para services side-effect.
			-- Cualquier service futuro (Achievements, Quests, etc.) puede
			-- subscribirse aquí sin tocar WeaponsSystem.luau.
			if WeaponsSystem.Killed and WeaponsSystem.Killed.Event then
				WeaponsSystem.Killed.Event:Connect(function(killer: Player, _victimHum: Humanoid, _weaponName: string, wasHeadshot: boolean)
					-- Dailies: siguen la señal cruda a propósito — su payout está
					-- acotado por diseño (3 tareas al día), no necesitan cap. OnKill
					-- lleva dentro la racha de bajas; el headshot es su propia tarea.
					if (DailyTasksService :: any).OnKill then
						pcall(function() (DailyTasksService :: any):OnKill(killer) end)
					end
					if wasHeadshot and (DailyTasksService :: any).OnHeadshot then
						pcall(function() (DailyTasksService :: any):OnHeadshot(killer) end)
					end
					-- Battle Pass: respeta el MatchXPCap igual que el XP de cuenta.
					-- Sin este guard, farmear kills capaba el XP de nivel pero seguía
					-- subiendo el pase sin límite: una season (~660 kills) se cerraba
					-- en ~2h de feeding, con sus Gems y exclusivas incluidas.
					-- El check va DENTRO del pcall: si `killer` llegara nil (kill de
					-- entorno) no debe tumbar el handler de la señal.
					if (BattlePassService :: any).OnKill then
						pcall(function()
							if not MatchService:IsXPCapReached(killer) then
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

	-- ── Onboarding Funnel ──────────────────────────────────────
	-- Track first-session players through: Joined → FirstMatch → FirstKill →
	-- MatchCompleted → ReturnedToLobby. Only fires for JoinCount == 1.
	--
	-- Sin sessionId: el embudo corre UNA sola vez por jugador (el gate de
	-- JoinCount == 1 lo garantiza), así que no hay intentos que desambiguar.
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
