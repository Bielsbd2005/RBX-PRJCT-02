--!strict
--[[
	BattlePassService.luau  (Server)

	Mantiene el progreso de Battle Pass por jugador y otorga las recompensas
	de cada tier al ser claimadas. La definición de seasons, tiers y rewards
	vive en `shared/constants/BattlePassConfig.luau`.

	Server-authoritative end-to-end:
	  • Cliente nunca decide elegibilidad ni gana XP.
	  • Cada acción mutante valida y persiste con un único `BatchUpdate`
	    (idempotencia y atomicidad iguales a DailyTasksService).

	Responsabilidades:
	  • Reset por season: al cargar perfil o al detectar SeasonId mismatch en
	    una acción mutante.
	  • AddXP(player, amount): cascading tier-up con cap.
	  • Hook OnKill(player) llamado desde WeaponsSystem (inyectado).
	  • ClaimTier(player, tier): valida y otorga la recompensa única del tier.
	  • PromptPremium(player): compra del Premium con GEMS — chequeo de saldo +
	    cobro y grant en un único BatchUpdate atómico sobre Stats.Gems (mismo
	    patrón que ShopService). Sin receipt.
	  • ProcessReceipt(receiptInfo): developer products Robux. Skips de +1 y +5
	    niveles (el cliente lanza el prompt) y el Premium LEGACY, dormido con
	    PremiumProductId = 0. Idempotente vía DataService:IsReceiptProcessed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network   = require(Shared.networking.Network)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local Currency = require(Shared.constants.Currency)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule
local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)

local MAX_LEVELUP_ITERATIONS = 200 -- guard contra loops infinitos por XP descomunal

-- Rate-limit anti-spam para todos los handlers C→S. Aunque la lógica interna
-- es idempotente (claim del mismo tier dos veces no duplica recompensa), un
-- atacante puede spammear ClaimTier para forzar trabajo costoso (lookup de
-- season + GetProfile + BatchUpdate por cada request) o para pedir prompts
-- Robux en bucle. 0.3s por acción es generoso para UX y suficiente anti-spam.
local ACTION_COOLDOWN = 0.3
local _cooldowns: { [number]: { [string]: number } } = {}

local function _checkActionCooldown(player: Player, action: string): boolean
	local playerCooldowns = _cooldowns[player.UserId]
	if not playerCooldowns then
		playerCooldowns = {}
		_cooldowns[player.UserId] = playerCooldowns
	end

	local last = playerCooldowns[action] or 0
	if time() - last < ACTION_COOLDOWN then
		return false
	end

	playerCooldowns[action] = time()
	return true
end

local BattlePassService = {}

local _dataService: DataService = nil :: any
local _started = false

-- ────────────────────────────────────────────────────────────
-- HELPERS
-- ────────────────────────────────────────────────────────────

local function _respond(player: Player, success: boolean, message: string, tierLevel: number?): ()
	Network.BattlePass.Response.SendTo({
		success = success,
		message = message,
		tier = tierLevel or 0,
	}, player)
end

-- Resetea la sección BattlePass al estado inicial de la season indicada.
-- Una sola escritura: BatchUpdate sobre toda la sección (1 mensaje de red).
local function _resetForSeason(player: Player, seasonId: string): boolean
	if not _dataService then
		return false
	end
	return _dataService:BatchUpdate(player, {
		{ path = { "BattlePass", "SeasonId" },      value = seasonId },
		{ path = { "BattlePass", "CurrentTier" },   value = 1 },
		{ path = { "BattlePass", "XP" },            value = 0 },
		{ path = { "BattlePass", "TotalXPEarned" }, value = 0 },
		{ path = { "BattlePass", "PremiumOwned" },  value = false },
		{ path = { "BattlePass", "Claimed" },       value = {} },
		{ path = { "BattlePass", "GrantedSkips" },  value = {} },
	})
end

-- Deriva el tier que un jugador ha COMPLETADO según un total acumulado de XP
-- (sin descontar). Devuelve N tal que tiers 1..N-1 están completados (mismo
-- contrato que CurrentTier). Bounded por MaxTier+1 (sentinel "completado").
local function _deriveTierFromTotalXP(season: BattlePassConfig.Season, totalXP: number): number
	local maxTier = #season.Tiers
	local tier = 1
	local remaining = math.max(0, math.floor(totalXP))
	while tier <= maxTier do
		local def = season.Tiers[tier]
		if not def or remaining < def.XPRequired then
			break
		end
		remaining -= def.XPRequired
		tier += 1
	end
	return tier
end

-- Backfill one-shot para perfiles que existían antes de que TotalXPEarned
-- formase parte del schema. Reconcile rellena el campo con 0, pero un
-- jugador con CurrentTier > 1 ya tiene XP "histórica" no contabilizada;
-- sin esto, la validación cruzada en ClaimTier les bloquea claims legítimos.
-- Reconstruimos el total mínimo desde la suma de XPRequired de tiers
-- completados + XP residual del tier actual.
local function _backfillTotalXPIfNeeded(player: Player, state: any, season: BattlePassConfig.Season): ()
	if not _dataService then return end
	local totalXP = math.floor(state.TotalXPEarned or 0)
	if totalXP > 0 then return end

	local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
	local currentXP = math.max(0, math.floor(state.XP or 0))
	if currentTier <= 1 and currentXP == 0 then return end

	local minXP = 0
	local completedTiers = math.min(currentTier - 1, #season.Tiers)
	for i = 1, completedTiers do
		minXP += season.Tiers[i].XPRequired
	end
	minXP += currentXP

	if minXP <= 0 then return end

	_dataService:BatchUpdate(player, {
		{ path = { "BattlePass", "TotalXPEarned" }, value = minXP },
	})
end

-- Lazy: si la season activa cambió desde la última escritura del perfil,
-- resetea antes de cualquier mutación. Devuelve true si el perfil quedó listo.
local function _ensureSeason(player: Player): boolean
	if not _dataService then
		return false
	end
	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data then
		return false
	end

	local activeSeason = BattlePassConfig.GetActiveSeason()
	local stored = (profile.Data.BattlePass and profile.Data.BattlePass.SeasonId) or ""
	if stored ~= activeSeason.Id then
		_resetForSeason(player, activeSeason.Id)
	elseif profile.Data.BattlePass then
		_backfillTotalXPIfNeeded(player, profile.Data.BattlePass, activeSeason)
	end
	return true
end

-- Otorga un WeaponWrap a TODAS las armas del jugador (Main + Special) en una
-- única BatchUpdate atómica. Cobertura = unión de (catálogo ItemsConfig.<cat>)
-- ∪ (armas que el jugador posee, Inventory.<cat>): así nuevos catálogo-additions
-- se cubren automáticamente y armas legacy (e.g. "Default" en Special) que no
-- aparecen en el catálogo pero sí en el inventario tampoco se pierden el wrap.
-- Idempotente: claves repetidas se reescriben a `true` y el gate de Claimed
-- impide invocarlo dos veces para el mismo tier.
local function _grantGlobalWeaponWrap(player: Player, wrapId: string): boolean
	if not _dataService then return false end

	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data then return false end

	local updates: { any } = {
		{ path = { "InventoryMeta", "WeaponWraps", wrapId },
			value = { AcquiredAt = os.time(), Source = "BattlePass" } },
		{ path = { "NewItemFlags", "WeaponWraps", wrapId }, value = true },
	}

	local inventory = profile.Data.Inventory
	for _, category in { "Main", "Special" } do
		local seen: { [string]: boolean } = {}
		local catalog = ItemsConfig[category]
		if type(catalog) == "table" then
			for weaponId in catalog do
				seen[weaponId] = true
			end
		end
		local owned = if type(inventory) == "table" then inventory[category] else nil
		if type(owned) == "table" then
			for weaponId in owned do
				seen[weaponId] = true
			end
		end
		for weaponId in seen do
			table.insert(updates, {
				path = { "Inventory", "WeaponWrapsByWeapon", category, weaponId, wrapId },
				value = true,
			})
		end
	end

	return _dataService:BatchUpdate(player, updates)
end

-- Otorga un WeaponWrap a UN arma específica (per-weapon). Mismo set de paths
-- que el flujo de Shop para WeaponWraps comprados, así InventoryRepository y
-- el resto de consumidores leen el wrap exactamente igual que uno comprado.
local function _grantWeaponSpecificWrap(
	player: Player,
	wrapId: string,
	weaponCategory: string,
	weaponId: string
): boolean
	if not _dataService then return false end

	return _dataService:BatchUpdate(player, {
		{ path = { "InventoryMeta", "WeaponWraps", wrapId },
			value = { AcquiredAt = os.time(), Source = "BattlePass" } },
		{ path = { "NewItemFlags", "WeaponWraps", wrapId }, value = true },
		{ path = { "Inventory", "WeaponWrapsByWeapon", weaponCategory, weaponId, wrapId },
			value = true },
	})
end

-- Resuelve la op de BatchUpdate para una recompensa Cash.
-- Para Item devuelve nil (el grant se hace fuera vía DataService:GrantItem,
-- que es la API documentada para crear Inventory + InventoryMeta + NewItemFlags).
local function _rewardToOp(reward: BattlePassConfig.Reward): { path: { string }, delta: number }?
	if reward.Kind == "Cash" then
		return { path = { "Stats", "Cash" }, delta = math.max(0, math.floor(reward.Amount or 0)) }
	end
	if reward.Kind == "Gems" then
		return { path = { "Stats", "Gems" }, delta = math.max(0, math.floor(reward.Amount or 0)) }
	end
	return nil
end

-- Precio de tienda de un ítem del catálogo y la moneda en la que se paga.
-- 0 si no existe o no tiene precio (exclusivas del pase, Default…).
local function _shopPriceOf(category: string, itemId: string): (number, Currency.Currency)
	local catalog = ItemsConfig[category]
	local def = if type(catalog) == "table" then catalog[itemId] else nil
	if type(def) ~= "table" then
		return 0, Currency.CASH
	end
	local price = if type(def.Price) == "number" then math.max(0, math.floor(def.Price)) else 0
	return price, Currency.resolve(def.Currency)
end

--[[
	Atajo ya recorrido. Si el jugador YA tiene el ítem que regala el tier
	(lo compró en la tienda antes de llegar aquí), GrantItem es idempotente y
	el tier valía exactamente cero — sin aviso. Con 15 de los 22 ítems de
	tienda del pase llegando después de la hora a la que la tienda los vende
	(auditoría 2026-09-04), eso convertía el pase en un castigo por comprar
	pronto y en una razón para no comprar nunca lo que "ya viene".

	Se devuelve el precio de tienda en su moneda: quien compró acaba igual que
	quien esperó (el ítem y el Cash intacto). No es emisión nueva: es el Cash
	que el jugador ya pagó. Un wrap global devuelve el precio por cada arma
	que ya lo tenía, que es exactamente lo que la tienda cobra (vende wraps
	por arma). nil = no había nada que compensar.

	Hay que llamarlo ANTES del grant: el grant escribe Inventory a true y
	después ya no se distingue lo comprado de lo recién concedido.
]]
local function _refundForOwnedReward(
	data: any,
	reward: BattlePassConfig.Reward
): { amount: number, currency: Currency.Currency }?
	if reward.Kind ~= "Item" or not reward.Category or not reward.ItemId then
		return nil
	end
	local price, currency = _shopPriceOf(reward.Category, reward.ItemId)
	if price <= 0 then
		return nil
	end
	local inventory = if type(data) == "table" then data.Inventory else nil
	if type(inventory) ~= "table" then
		return nil
	end

	local owned = 0
	if reward.Category == "WeaponWraps" then
		local byWeapon = inventory.WeaponWrapsByWeapon
		if type(byWeapon) ~= "table" then
			return nil
		end
		if reward.Global == true then
			for _, weaponCategory in { "Main", "Special" } do
				local weapons = byWeapon[weaponCategory]
				if type(weapons) == "table" then
					for _, wraps in weapons do
						if type(wraps) == "table" and wraps[reward.ItemId] == true then
							owned += 1
						end
					end
				end
			end
		elseif reward.WeaponCategory and reward.WeaponId then
			local weapons = byWeapon[reward.WeaponCategory]
			local wraps = if type(weapons) == "table" then weapons[reward.WeaponId] else nil
			if type(wraps) == "table" and wraps[reward.ItemId] == true then
				owned = 1
			end
		end
	else
		local category = inventory[reward.Category]
		if type(category) == "table" and category[reward.ItemId] == true then
			owned = 1
		end
	end

	if owned == 0 then
		return nil
	end
	return { amount = price * owned, currency = currency }
end

-- ────────────────────────────────────────────────────────────
-- CORE: AddXP con cascading tier-up
-- ────────────────────────────────────────────────────────────

function BattlePassService:AddXP(player: Player, amount: number): ()
	if not _dataService then return end
	local delta = math.max(0, math.floor(amount or 0))
	if delta <= 0 then return end

	if not _ensureSeason(player) then return end

	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data or not profile.Data.BattlePass then return end

	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)

	local state = profile.Data.BattlePass
	local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
	local currentXP = math.max(0, math.floor(state.XP or 0))

	-- Ya completó la season: no escribir.
	if currentTier > maxTier then
		return
	end

	currentXP += delta

	local iterations = 0
	while currentTier <= maxTier and iterations < MAX_LEVELUP_ITERATIONS do
		local tierDef = BattlePassConfig.GetTier(season, currentTier)
		if not tierDef then break end
		local needed = tierDef.XPRequired
		if currentXP < needed then break end
		currentXP -= needed
		currentTier += 1
		iterations += 1
	end

	-- Sentinel "completado": congelar XP a 0.
	if currentTier > maxTier then
		currentXP = 0
	end

	_dataService:BatchUpdate(player, {
		{ path = { "BattlePass", "CurrentTier" },   value = currentTier },
		{ path = { "BattlePass", "XP" },            value = currentXP },
		{ path = { "BattlePass", "TotalXPEarned" }, delta = delta },
	})
end

-- Hook semántico: WeaponsSystem llama esto al registrar una kill del jugador.
function BattlePassService:OnKill(player: Player): ()
	self:AddXP(player, BattlePassConfig.XPRates.PerKill)
end

-- ────────────────────────────────────────────────────────────
-- CLAIM
-- ────────────────────────────────────────────────────────────

function BattlePassService:ClaimTier(player: Player, tierLevel: number): ()
	if not _dataService then return end
	if type(tierLevel) ~= "number" then
		_respond(player, false, "InvalidTier", 0)
		return
	end
	tierLevel = math.floor(tierLevel)

	if not _ensureSeason(player) then
		_respond(player, false, "ProfileUnavailable", tierLevel)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data or not profile.Data.BattlePass then
		_respond(player, false, "ProfileUnavailable", tierLevel)
		return
	end

	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)

	if tierLevel < 1 or tierLevel > maxTier then
		_respond(player, false, "InvalidTier", tierLevel)
		return
	end

	local state = profile.Data.BattlePass

	-- Defense-in-depth: derivar el tier "esperado" desde TotalXPEarned y usar
	-- el mínimo entre el almacenado y el derivado para la elegibilidad.
	local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
	local totalXPEarned = math.max(0, math.floor(state.TotalXPEarned or 0))
	local expectedTier = _deriveTierFromTotalXP(season, totalXPEarned)
	if currentTier > expectedTier then
		warn(("[BattlePassService] CurrentTier (%d) > expectedTier (%d) for user %d; clamping eligibility"):format(
			currentTier, expectedTier, player.UserId
		))
	end
	local effectiveTier = math.min(currentTier, expectedTier)

	-- Tier debe estar COMPLETADO: tier < effectiveTier.
	if tierLevel >= effectiveTier then
		_respond(player, false, "TierLocked", tierLevel)
		return
	end

	local tierDef = BattlePassConfig.GetTier(season, tierLevel)
	if not tierDef then
		_respond(player, false, "InvalidTier", tierLevel)
		return
	end

	-- Niveles PASS requieren PremiumOwned; los FREE los reclama cualquiera.
	if tierDef.Premium and state.PremiumOwned ~= true then
		_respond(player, false, "PremiumLocked", tierLevel)
		return
	end

	local claimMap = state.Claimed or {}
	local levelKey = tostring(tierLevel)
	if claimMap[levelKey] == true then
		_respond(player, false, "AlreadyClaimed", tierLevel)
		return
	end

	local reward = tierDef.Reward
	-- Antes del grant, mientras aún se distingue lo comprado de lo concedido.
	local refund = _refundForOwnedReward(profile.Data, reward)

	-- Para items: granteamos ANTES de marcar claimed (GrantItem idempotente).
	if reward.Kind == "Item" and reward.Category and reward.ItemId then
		local grantOk: boolean
		if reward.Category == "WeaponWraps" and reward.Global == true then
			grantOk = _grantGlobalWeaponWrap(player, reward.ItemId)
		elseif reward.Category == "WeaponWraps"
			and reward.WeaponCategory and reward.WeaponId
		then
			grantOk = _grantWeaponSpecificWrap(player, reward.ItemId, reward.WeaponCategory, reward.WeaponId)
		else
			grantOk = _dataService:GrantItem(player, reward.Category, reward.ItemId, "BattlePass")
		end
		if not grantOk then
			_respond(player, false, "SaveFailed", tierLevel)
			return
		end
	end

	-- Marcar claimed + grant Cash en un único BatchUpdate.
	local updates: { any } = {
		{ path = { "BattlePass", "Claimed", levelKey }, value = true },
	}
	local rewardOp = _rewardToOp(reward)
	if rewardOp then
		table.insert(updates, rewardOp)
		if reward.Kind == "Cash" then
			table.insert(updates, { path = { "Stats", "TotalCashEarned" }, delta = rewardOp.delta })
		elseif reward.Kind == "Gems" then
			table.insert(updates, { path = { "Stats", "TotalGemsEarned" }, delta = rewardOp.delta })
		end
	end
	-- Ítem que ya se tenía: el tier paga su precio de tienda (ver _refundForOwnedReward).
	if refund then
		local isGems = refund.currency == Currency.GEMS
		table.insert(updates, { path = Currency.balancePath(refund.currency), delta = refund.amount })
		table.insert(updates, {
			path = { "Stats", if isGems then "TotalGemsEarned" else "TotalCashEarned" },
			delta = refund.amount,
		})
	end

	local ok = _dataService:BatchUpdate(player, updates)
	if not ok then
		_respond(player, false, "SaveFailed", tierLevel)
		return
	end

	--[[
		Guardado durable antes de registrar: `BatchUpdate` sólo toca el perfil
		en memoria y el autosave puede tardar hasta 30 s. Un crash en esa
		ventana dejaba el evento emitido y la transacción inexistente (los Gems
		volvían al saldo del jugador y el sink seguía contado en el dashboard).
		Se registra igual si el Save falla —el jugador ya tiene el cambio en
		memoria— pero con aviso.
	]]
	if not _dataService:ForceSave(player) then
		warn(("[BattlePassService] claim del tier %d de %s registrado sin guardado confirmado"):format(
			tierLevel,
			player.Name
		))
	end

	-- "<SeasonId>::TierN": el ingest lo parte por season; sin el prefijo dos
	-- temporadas serían indistinguibles en economy_flow.
	local tierSku = season.Id .. "::Tier" .. tostring(tierLevel)
	if reward.Kind == "Cash" then
		local cashAmount = math.max(0, math.floor(reward.Amount or 0))
		if cashAmount > 0 then
			TelemetryService.RecordFlow(player, "source", "BattlePassClaim", cashAmount, tierSku, "Cash")
		end
	elseif reward.Kind == "Gems" then
		-- El grant ya lo hizo el BatchUpdate de arriba (atómico con el claim);
		-- aquí solo se registra. Por eso NO se llama a RewardService.AwardGems:
		-- duplicaría la concesión.
		local gemAmount = math.max(0, math.floor(reward.Amount or 0))
		if gemAmount > 0 then
			TelemetryService.RecordFlow(player, "source", "BattlePassClaim", gemAmount, tierSku, "Gems")
		end
	elseif reward.Kind == "Item" and reward.Category and reward.ItemId then
		TelemetryService.RecordItem(player, "BattlePassItem", reward.Category .. "::" .. reward.ItemId .. "::" .. tierSku)
		-- Etiqueta propia: en el dashboard sale como faucet aparte de
		-- BattlePassClaim, que es justo lo que hace falta para saber cuánto
		-- Cash devuelve el pase por ítems que ya se habían comprado.
		if refund then
			TelemetryService.RecordFlow(player, "source", "BattlePassRefund", refund.amount, tierSku, refund.currency)
		end
	end

	_respond(player, true, "OK", tierLevel)
end

-- ────────────────────────────────────────────────────────────
-- PREMIUM (compra con Gems)
-- ────────────────────────────────────────────────────────────

local _bpFunnelSessionByUserId: { [number]: string } = {}
local _bpFunnelCounter = 0

--[[
	Embudo de conversión a Premium. La taxonomía vive aquí, junto al código que
	la dispara, para que añadir un paso sea un cambio de un solo archivo.
	Con la compra en Gems no hay prompt externo que esperar: el embudo se reduce
	a click → cobro OK, y el drop entre 1 y 2 mide exactamente "quiso pero no
	tenía Gems" — la señal que dispara la compra de packs.
]]
local BP_PREMIUM_FUNNEL = "BattlePassPremium"
local BP_PREMIUM_STEP_NAMES: { [number]: string } = {
	[1] = "ClickedBuyPremium",
	[2] = "Purchased",
}

local function _bpPremiumStep(player: Player, step: number, sessionId: string?)
	TelemetryService.RecordFunnelStep(player, BP_PREMIUM_FUNNEL, step, BP_PREMIUM_STEP_NAMES[step], sessionId)
end

function BattlePassService:PromptPremium(player: Player): ()
	local season = BattlePassConfig.GetActiveSeason()
	local price = season.PremiumGemPrice
	if type(price) ~= "number" or price <= 0 then
		warn("[BattlePassService] PremiumGemPrice no configurado para season", season.Id)
		_respond(player, false, "PremiumUnavailable", 0)
		return
	end
	if not _ensureSeason(player) then
		_respond(player, false, "ProfileUnavailable", 0)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data then
		_respond(player, false, "ProfileUnavailable", 0)
		return
	end
	if profile.Data.BattlePass and profile.Data.BattlePass.PremiumOwned == true then
		_respond(player, false, "AlreadyOwned", 0)
		return
	end

	_bpFunnelCounter += 1
	local sessionId = tostring(player.UserId) .. "_" .. tostring(_bpFunnelCounter)
	_bpFunnelSessionByUserId[player.UserId] = sessionId
	_bpPremiumStep(player, 1, sessionId)

	-- Cobro en Gems: chequeo de saldo + delta negativo en el MISMO BatchUpdate
	-- que el grant (patrón de ShopService: el delta evita TOCTOU si otro flujo
	-- muta el saldo entre la lectura y el write).
	local stats = profile.Data.Stats
	local balance: number = if stats and type(stats.Gems) == "number" then stats.Gems else 0
	if balance < price then
		_respond(player, false, "GemsInsufficient", 0)
		return
	end

	local ok = _dataService:BatchUpdate(player, {
		{ path = Currency.balancePath(Currency.GEMS), delta = -price },
		{ path = { "BattlePass", "PremiumOwned" }, value = true },
	})
	if not ok then
		_respond(player, false, "InternalError", 0)
		return
	end

	--[[
		Guardado durable antes de registrar: `BatchUpdate` sólo toca el perfil
		en memoria y el autosave puede tardar hasta 30 s. Un crash en esa
		ventana dejaba el evento emitido y la transacción inexistente (los Gems
		volvían al saldo del jugador y el sink seguía contado en el dashboard).
		Se registra igual si el Save falla —el jugador ya tiene el cambio en
		memoria— pero con aviso.
	]]
	if not _dataService:ForceSave(player) then
		warn(("[BattlePassService] premium de %s registrado sin guardado confirmado"):format(player.Name))
	end

	_bpPremiumStep(player, 2, sessionId)
	_bpFunnelSessionByUserId[player.UserId] = nil
	TelemetryService.RecordFlow(player, "sink", "BattlePassPremium", price, season.Id, Currency.GEMS)
	_respond(player, true, "PremiumGranted", 0)
end

-- ────────────────────────────────────────────────────────────
-- SKIP DE NIVELES (developer products Robux)
-- ────────────────────────────────────────────────────────────

-- Aplica un skip de `tierCount` niveles. Idempotente per-receipt vía
-- GrantedSkips[purchaseId]. Rellena el XP que falta del nivel actual y el
-- completo de los siguientes, y lo suma a TotalXPEarned para que
-- _deriveTierFromTotalXP devuelva el nuevo CurrentTier (sin ese ajuste,
-- ClaimTier capparía la elegibilidad). Nunca pasa de MaxTier+1 (completada):
-- si quedan menos niveles que los comprados, concede los que queden (el
-- cliente ya bloquea el prompt en ese caso; esto solo cubre la carrera).
local function _grantSkip(player: Player, purchaseId: string, tierCount: number, robuxPrice: number): boolean
	if not _dataService then return false end

	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data or not profile.Data.BattlePass then return false end

	local state = profile.Data.BattlePass
	local granted = state.GrantedSkips
	if type(granted) == "table" and granted[purchaseId] == true then
		return true -- ya aplicado, no-op
	end

	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)
	local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
	local tiersToGrant = math.clamp(tierCount, 0, math.max(0, maxTier - currentTier + 1))

	-- Contabilizar el gasto en el MISMO BatchUpdate atómico que GrantedSkips, no
	-- en un Increment separado posterior. Si el Increment fallaba tras persistir
	-- ProcessedReceipts, la reentrega devolvía PurchaseGranted sin reejecutarlo y
	-- el gasto se subcontaba para siempre. El path no-op (ya concedido arriba) no
	-- pasa por aquí, así que no hay doble conteo.
	local updates: { any } = {
		{ path = { "BattlePass", "GrantedSkips", purchaseId }, value = true },
	}
	if robuxPrice > 0 then
		table.insert(updates, { path = { "Stats", "TotalRobuxSpent" }, delta = robuxPrice })
	end

	if tiersToGrant > 0 then
		local currentXP = math.max(0, math.floor(state.XP or 0))
		local totalXP = math.max(0, math.floor(state.TotalXPEarned or 0))
		local xpToFill = 0
		for offset = 0, tiersToGrant - 1 do
			local tierDef = BattlePassConfig.GetTier(season, currentTier + offset)
			if not tierDef then return false end
			local alreadyEarned = if offset == 0 then currentXP else 0
			xpToFill += math.max(0, tierDef.XPRequired - alreadyEarned)
		end
		table.insert(updates, { path = { "BattlePass", "CurrentTier" }, value = currentTier + tiersToGrant })
		table.insert(updates, { path = { "BattlePass", "XP" }, value = 0 })
		table.insert(updates, { path = { "BattlePass", "TotalXPEarned" }, value = totalXP + xpToFill })
	end
	-- Season ya completada (tiersToGrant = 0): solo se marca el receipt para no
	-- quedar en bucle de reentregas.

	return _dataService:BatchUpdate(player, updates)
end

--[[
	ProcessReceipt: invocado desde el dispatcher central en ServerBootstrap.
	Devuelve:
	  • Enum.ProductPurchaseDecision si este servicio reconoce el producto
	    (PurchaseGranted en éxito o idempotencia, NotProcessedYet en error).
	  • nil si el producto no corresponde a un Battle Pass — el dispatcher
	    debe seguir buscando handlers.
]]
function BattlePassService:ProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision?
	if not _dataService then
		return nil
	end
	if type(receiptInfo) ~= "table" or type(receiptInfo.ProductId) ~= "number" then
		return nil
	end

	local season, kind = BattlePassConfig.ResolveReceipt(receiptInfo.ProductId)
	if not season or not kind then
		return nil -- no es nuestro
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = tostring(receiptInfo.PurchaseId)
	if _dataService:IsReceiptProcessed(player, purchaseId) then
		-- Ya concedido en memoria; confirmar que está persistido antes de
		-- conceder (Roblox consume el receipt al devolver PurchaseGranted).
		if _dataService:ForceSave(player) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Por si la season cambió entre prompt y receipt: garantiza que la
	-- compra aplique sobre la season actual del jugador.
	if not _ensureSeason(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if kind == "Premium" then
		-- Si la season del producto NO es la activa, granteamos igualmente sobre
		-- la activa (el jugador pagó). Marcamos el receipt para no doble-grant.
		local premiumRobux = (season.PremiumRobuxPrice and season.PremiumRobuxPrice > 0) and season.PremiumRobuxPrice or 0
		local bpUpdates: { any } = {
			{ path = { "BattlePass", "PremiumOwned" },    value = true },
			{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
		}
		if premiumRobux > 0 then
			table.insert(bpUpdates, { path = { "Stats", "TotalRobuxSpent" }, delta = premiumRobux })
		end
		local ok = _dataService:BatchUpdate(player, bpUpdates)
		if not ok then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		-- Durabilidad del receipt: persistir confirmado antes de conceder
		-- (Roblox no espera a nuestro write tras PurchaseGranted).
		if not _dataService:ForceSave(player) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		-- Paso 2 = "Purchased" (el embudo es de 2 pasos desde la compra en Gems;
		-- este path legacy reporta el mismo paso final para no romper la serie).
		local sessionId = _bpFunnelSessionByUserId[player.UserId]
		_bpPremiumStep(player, 2, sessionId)
		_bpFunnelSessionByUserId[player.UserId] = nil

		TelemetryService.RecordPurchase({
			userId = player.UserId,
			purchaseId = purchaseId,
			productId = receiptInfo.ProductId,
			sku = "BattlePassPremium::" .. season.Id,
			robuxPrice = premiumRobux,
			cashGranted = 0,
			kind = "BattlePassPremium",
		})

		_respond(player, true, "PremiumGranted", 0)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Skip (+1 o +5): grant idempotente vía GrantedSkips[purchaseId].
	local skipKind = kind :: BattlePassConfig.SkipKind
	local _, skipRobux, tierCount = BattlePassConfig.GetSkipOffer(season, skipKind)
	skipRobux = math.max(0, skipRobux)
	local granted = _grantSkip(player, purchaseId, tierCount, skipRobux)
	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not _dataService:MarkReceiptProcessed(player, purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- TotalRobuxSpent se contabiliza dentro del BatchUpdate atómico de _grantSkip
	-- (antes era un Increment suelto aquí que podía perderse y subcontar el gasto).

	-- Durabilidad del receipt: persistir el skip (GrantedSkips + ProcessedReceipts
	-- + tier) confirmado antes de conceder. Si falla, NotProcessedYet → Roblox
	-- reentrega y la idempotencia de GrantedSkips evita un segundo tier-up.
	if not _dataService:ForceSave(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = _dataService:GetProfile(player)
	local newTier = if profile and profile.Data and profile.Data.BattlePass
		then math.floor(profile.Data.BattlePass.CurrentTier or 0)
		else 0

	TelemetryService.RecordPurchase({
		userId = player.UserId,
		purchaseId = purchaseId,
		productId = receiptInfo.ProductId,
		-- Mismo kind para los dos skips; el sku los separa ("SkipTier" / "SkipTier5").
		-- Los skips son globales: el sku lleva el Id de la season ACTIVA, que es
		-- sobre la que se concedió.
		sku = (if skipKind == "Skip5" then "SkipTier5::" else "SkipTier::") .. BattlePassConfig.GetActiveSeason().Id,
		robuxPrice = skipRobux,
		cashGranted = 0,
		kind = "SkipTier",
	})

	_respond(player, true, if skipKind == "Skip5" then "Skip5Granted" else "SkipGranted", newTier)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ────────────────────────────────────────────────────────────
-- LIFECYCLE
-- ────────────────────────────────────────────────────────────

function BattlePassService:Start(dataService: DataService): ()
	if _started then return end
	_started = true
	_dataService = dataService

	-- Reset al cargar perfiles ya presentes (hot reload).
	for _, player in Players:GetPlayers() do
		task.spawn(_ensureSeason, player)
	end

	-- Audit mobile: signal-driven en lugar de polling cada 1s × 30 iteraciones.
	-- DataService.ProfileLoaded dispara una vez por player cuando su Replica
	-- está lista. Si el profile ya está cargado al subscribir, fast-path.
	Players.PlayerAdded:Connect(function(player)
		if _dataService:GetProfile(player) then
			_ensureSeason(player)
		end
	end)
	if _dataService.ProfileLoaded then
		_dataService.ProfileLoaded:Connect(function(player)
			if player and player.Parent then
				_ensureSeason(player)
			end
		end)
	end

	-- Cleanup de cooldowns.
	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
		_bpFunnelSessionByUserId[player.UserId] = nil
	end)

	-- Listeners de red. ACTION_COOLDOWN: rate-limit por player+acción (anti-spam).
	Network.BattlePass.ClaimTier.Listen(function(data: any, player: Player)
		if not _checkActionCooldown(player, "claim") then return end
		BattlePassService:ClaimTier(player, data.tier)
	end)

	Network.BattlePass.BuyPremium.Listen(function(_data: any, player: Player)
		if not _checkActionCooldown(player, "premium") then return end
		BattlePassService:PromptPremium(player)
	end)
end

return BattlePassService
