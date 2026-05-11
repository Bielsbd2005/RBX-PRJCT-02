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
	  • ClaimTier(player, tier, track): valida y otorga la recompensa.
	  • PromptPremium(player) + ProcessReceipt(receiptInfo): compra del Premium
	    vía MarketplaceService developer product. Idempotente vía
	    DataService:IsReceiptProcessed.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network   = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local M = NetGuards.MAX

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

local function _respond(player: Player, success: boolean, message: string, tierLevel: number?, track: string?): ()
	Network.BattlePass.Response.SendTo({
		success = success,
		message = message,
		tier = tierLevel or 0,
		track = track or "",
	}, player)
end

-- Resetea la sección BattlePass al estado inicial de la season indicada.
-- Una sola escritura: BatchUpdate sobre toda la sección (1 mensaje de red).
local function _resetForSeason(player: Player, seasonId: string): boolean
	if not _dataService then
		return false
	end
	return _dataService:BatchUpdate(player, {
		{ path = { "BattlePass", "SeasonId" },       value = seasonId },
		{ path = { "BattlePass", "CurrentTier" },    value = 1 },
		{ path = { "BattlePass", "XP" },             value = 0 },
		{ path = { "BattlePass", "TotalXPEarned" },  value = 0 },
		{ path = { "BattlePass", "PremiumOwned" },   value = false },
		{ path = { "BattlePass", "ClaimedFree" },    value = {} },
		{ path = { "BattlePass", "ClaimedPremium" }, value = {} },
		{ path = { "BattlePass", "GrantedSkips" },   value = {} },
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

-- Resuelve la op de BatchUpdate para una recompensa Cash.
-- Para Item devuelve nil (el grant se hace fuera vía DataService:GrantItem,
-- que es la API documentada para crear Inventory + InventoryMeta + NewItemFlags).
local function _rewardToOp(reward: BattlePassConfig.Reward): { path: { string }, delta: number }?
	if reward.Kind == "Cash" then
		return { path = { "Stats", "Cash" }, delta = math.max(0, math.floor(reward.Amount or 0)) }
	end
	return nil
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

function BattlePassService:ClaimTier(player: Player, tierLevel: number, track: string): ()
	if not _dataService then return end
	if type(tierLevel) ~= "number" then
		_respond(player, false, "InvalidTier", 0, track)
		return
	end
	tierLevel = math.floor(tierLevel)

	if track ~= "Free" and track ~= "Premium" then
		_respond(player, false, "InvalidTrack", tierLevel, track)
		return
	end

	if not _ensureSeason(player) then
		_respond(player, false, "ProfileUnavailable", tierLevel, track)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data or not profile.Data.BattlePass then
		_respond(player, false, "ProfileUnavailable", tierLevel, track)
		return
	end

	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)

	if tierLevel < 1 or tierLevel > maxTier then
		_respond(player, false, "InvalidTier", tierLevel, track)
		return
	end

	local state = profile.Data.BattlePass

	-- Defense-in-depth: derivar el tier "esperado" desde TotalXPEarned y usar
	-- el mínimo entre el almacenado y el derivado para la elegibilidad. Si
	-- CurrentTier se corrompiera (migración rota, edición externa, race), el
	-- jugador no puede reclamar más allá de lo que su XP acumulada permite.
	local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
	local totalXPEarned = math.max(0, math.floor(state.TotalXPEarned or 0))
	local expectedTier = _deriveTierFromTotalXP(season, totalXPEarned)
	if currentTier > expectedTier then
		warn(("[BattlePassService] CurrentTier (%d) > expectedTier (%d) for user %d; clamping eligibility"):format(
			currentTier, expectedTier, player.UserId
		))
	end
	local effectiveTier = math.min(currentTier, expectedTier)

	-- Tier debe estar COMPLETADO: tier < effectiveTier (effectiveTier = N
	-- significa "tiers 1..N-1 ya son claimables").
	if tierLevel >= effectiveTier then
		_respond(player, false, "TierLocked", tierLevel, track)
		return
	end

	if track == "Premium" and state.PremiumOwned ~= true then
		_respond(player, false, "PremiumLocked", tierLevel, track)
		return
	end

	local claimMapKey = if track == "Premium" then "ClaimedPremium" else "ClaimedFree"
	local claimMap = state[claimMapKey] or {}
	local levelKey = tostring(tierLevel)
	if claimMap[levelKey] == true then
		_respond(player, false, "AlreadyClaimed", tierLevel, track)
		return
	end

	local tierDef = BattlePassConfig.GetTier(season, tierLevel)
	if not tierDef then
		_respond(player, false, "InvalidTier", tierLevel, track)
		return
	end
	local reward = if track == "Premium" then tierDef.Premium else tierDef.Free

	-- Para items: granteamos ANTES de marcar claimed. GrantItem es idempotente
	-- (escribe valores fijos en Inventory/Meta/NewItemFlags), así que si el
	-- server crashea entre el grant y el flag, en el próximo claim el grant
	-- vuelve a correr sin duplicar inventario y el flag se setea recién al
	-- final. Si el grant fallara, el flag queda sin setear y el jugador puede
	-- reintentar — el item no se pierde en silencio.
	if reward.Kind == "Item" and reward.Category and reward.ItemId then
		local grantOk = _dataService:GrantItem(player, reward.Category, reward.ItemId, "BattlePass")
		if not grantOk then
			_respond(player, false, "SaveFailed", tierLevel, track)
			return
		end
	end

	-- Marcar claimed + grant Cash en un único BatchUpdate. Para Cash, flag y
	-- delta van juntos para que un crash entre ambos no dupliques el pago.
	-- Para Item, este BatchUpdate sólo escribe el flag (el grant ya ocurrió).
	local updates: { any } = {
		{ path = { "BattlePass", claimMapKey, levelKey }, value = true },
	}
	local rewardOp = _rewardToOp(reward)
	if rewardOp then
		table.insert(updates, rewardOp)
	end

	local ok = _dataService:BatchUpdate(player, updates)
	if not ok then
		_respond(player, false, "SaveFailed", tierLevel, track)
		return
	end

	_respond(player, true, "OK", tierLevel, track)
end

-- ────────────────────────────────────────────────────────────
-- PREMIUM (Robux developer product)
-- ────────────────────────────────────────────────────────────

function BattlePassService:PromptPremium(player: Player): ()
	local season = BattlePassConfig.GetActiveSeason()
	if season.PremiumProductId == 0 then
		warn("[BattlePassService] PremiumProductId no configurado para season", season.Id)
		_respond(player, false, "PremiumUnavailable", 0, "Premium")
		return
	end
	if not _ensureSeason(player) then
		_respond(player, false, "ProfileUnavailable", 0, "Premium")
		return
	end

	local profile = _dataService:GetProfile(player)
	if profile and profile.Data and profile.Data.BattlePass and profile.Data.BattlePass.PremiumOwned == true then
		_respond(player, false, "AlreadyOwned", 0, "Premium")
		return
	end

	-- PromptProductPurchase abre el modal de Roblox; el grant ocurre en
	-- ProcessReceipt cuando Roblox confirma la compra.
	pcall(function()
		MarketplaceService:PromptProductPurchase(player, season.PremiumProductId)
	end)
end

-- ────────────────────────────────────────────────────────────
-- SKIP TIER (Robux developer product)
-- ────────────────────────────────────────────────────────────

function BattlePassService:PromptSkip(player: Player): ()
	local season = BattlePassConfig.GetActiveSeason()
	if season.SkipProductId == 0 then
		warn("[BattlePassService] SkipProductId no configurado para season", season.Id)
		_respond(player, false, "SkipUnavailable", 0, "Skip")
		return
	end
	if not _ensureSeason(player) then
		_respond(player, false, "ProfileUnavailable", 0, "Skip")
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data or not profile.Data.BattlePass then
		_respond(player, false, "ProfileUnavailable", 0, "Skip")
		return
	end

	-- Si ya completó la season, no tiene sentido cobrar por un skip.
	local maxTier = BattlePassConfig.GetMaxTier(season)
	local currentTier = math.max(1, math.floor(profile.Data.BattlePass.CurrentTier or 1))
	if currentTier > maxTier then
		_respond(player, false, "SeasonCompleted", currentTier, "Skip")
		return
	end

	pcall(function()
		MarketplaceService:PromptProductPurchase(player, season.SkipProductId)
	end)
end

-- Aplica un skip de 1 tier al jugador. Idempotente per-receipt: si
-- GrantedSkips[purchaseId] ya está marcado, devuelve true sin tocar nada.
-- Mantiene la invariante de defense-in-depth: TotalXPEarned se incrementa
-- exactamente lo necesario para que _deriveTierFromTotalXP devuelva el
-- nuevo CurrentTier (sin ese ajuste, ClaimTier capparía la elegibilidad).
local function _grantSkip(player: Player, purchaseId: string): boolean
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

	if currentTier > maxTier then
		-- Season ya completada. El paid-grant no aplica; pero marcamos el
		-- receipt como granted para que ProcessReceipt no quede en loop si
		-- llegase a invocarse (no debería: PromptSkip lo bloquea antes).
		return _dataService:BatchUpdate(player, {
			{ path = { "BattlePass", "GrantedSkips", purchaseId }, value = true },
		})
	end

	local currentXP = math.max(0, math.floor(state.XP or 0))
	local totalXP = math.max(0, math.floor(state.TotalXPEarned or 0))
	local tierDef = BattlePassConfig.GetTier(season, currentTier)
	if not tierDef then return false end

	-- XP que faltaba para completar el tier actual; se suma a TotalXPEarned
	-- para que derive(TotalXPEarned) == nuevo CurrentTier exactamente.
	local xpToFill = math.max(0, tierDef.XPRequired - currentXP)

	-- Todo en sección BattlePass → un único SetValue, fully atomic.
	return _dataService:BatchUpdate(player, {
		{ path = { "BattlePass", "CurrentTier" },              value = currentTier + 1 },
		{ path = { "BattlePass", "XP" },                       value = 0 },
		{ path = { "BattlePass", "TotalXPEarned" },            value = totalXP + xpToFill },
		{ path = { "BattlePass", "GrantedSkips", purchaseId }, value = true },
	})
end

--[[
	ProcessReceipt: invocado desde el dispatcher central en CasesService.
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
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Por si la season cambió entre prompt y receipt: garantiza que la
	-- compra aplique sobre la season actual del jugador.
	if not _ensureSeason(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if kind == "Premium" then
		-- Si la season del producto NO es la activa, granteamos igualmente sobre
		-- la activa: el jugador pagó y debe recibir Premium, no perder Robux por
		-- un cambio de config en mid-prompt. Marcamos el receipt para no doble-grant.
		local ok = _dataService:BatchUpdate(player, {
			{ path = { "BattlePass", "PremiumOwned" },    value = true },
			{ path = { "ProcessedReceipts", purchaseId }, value = os.time() },
		})
		if not ok then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		_respond(player, true, "PremiumGranted", 0, "Premium")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Skip: el grant es idempotente vía GrantedSkips[purchaseId]. Si grant
	-- tuvo éxito y MarkReceiptProcessed falla, el retry de Roblox volverá a
	-- llamar _grantSkip, que verá GrantedSkips[purchaseId]=true y no aplicará
	-- el skip dos veces.
	local granted = _grantSkip(player, purchaseId)
	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not _dataService:MarkReceiptProcessed(player, purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- tier en la respuesta = nuevo CurrentTier (post-skip), para que el cliente
	-- pueda mostrar feedback sin volver a leer el profile.
	local profile = _dataService:GetProfile(player)
	local newTier = if profile and profile.Data and profile.Data.BattlePass
		then math.floor(profile.Data.BattlePass.CurrentTier or 0)
		else 0
	_respond(player, true, "SkipGranted", newTier, "Skip")
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

	-- Reset al cargar nuevos perfiles. PlayerAdded se dispara antes de que
	-- el profile esté listo; reintentamos hasta que GetProfile devuelva no-nil
	-- (mismo patrón que DailyTasksService).
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			for _ = 1, 30 do
				if not player.Parent then return end
				if _dataService:GetProfile(player) then
					_ensureSeason(player)
					return
				end
				task.wait(1)
			end
		end)
	end)

	-- Cleanup de cooldowns.
	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
	end)

	-- Listeners de red. Cada handler aplica:
	--   1) NetGuards: cap longitud de strings (ByteNet no impone maxLength).
	--   2) ACTION_COOLDOWN: rate-limit por player+acción (anti-spam).
	Network.BattlePass.ClaimTier.Listen(function(data: any, player: Player)
		if not NetGuards.validate(data, { track = M.Track }) then return end
		if not _checkActionCooldown(player, "claim") then return end
		BattlePassService:ClaimTier(player, data.tier, data.track)
	end)

	Network.BattlePass.BuyPremium.Listen(function(_data: any, player: Player)
		if not _checkActionCooldown(player, "premium") then return end
		BattlePassService:PromptPremium(player)
	end)

	Network.BattlePass.BuySkip.Listen(function(_data: any, player: Player)
		if not _checkActionCooldown(player, "skip") then return end
		BattlePassService:PromptSkip(player)
	end)
end

return BattlePassService
