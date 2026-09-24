--!strict
--[[
	Todo lo que paga una kill y quién se la lleva: atribución, cash/XP de cuenta con los
	caps de la ronda, Stats lifetime, kills por arma y wraps de maestría, multikills,
	dailies, XP del pase y créditos de health pickup. También las asistencias
	(GrantCombatReward) y la muerte del jugador (RegisterPlayerDeath).

	MatchService es dueño de la ronda y de las sesiones: este servicio las lee por los
	accesores de Start y no guarda estado propio entre rondas.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Network = require(Shared.networking.Network)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local WeaponCategory = require(Shared.constants.WeaponCategory)
local InventoryRepository = require(Shared.data.InventoryRepository)
local WrapMastery = require(Shared.data.WrapMastery)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local KillAttributionService = require(script.Parent:WaitForChild("KillAttributionService"))
local DailyTasksService = require(script.Parent.Parent.dailyTasks.DailyTasksService)
local BattlePassService = require(script.Parent.Parent.battlepass.BattlePassService)
local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
local RewardService = require(script.Parent.Parent.Parent.core.RewardService)
local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)
local LastAttackerStore = require(ReplicatedStorage:WaitForChild("WeaponsSystem"):WaitForChild("Libraries"):WaitForChild("LastAttackerStore"))
type DataService = DataServiceMod.DataServiceModule

local MULTIKILL_WINDOW = 4
local PICKUP_ELIGIBILITY_WINDOW = 15
local PICKUP_ELIGIBILITY_MAX_QUEUED = 8

export type CombatStats = {
	kills: number,
	deaths: number,
	assists: number,
}

-- La parte de la ronda de MatchService que lee y escribe este servicio.
export type RoundLedger = {
	cashEarnedByUserId: { [number]: number },
	xpEarnedByUserId: { [number]: number },
	bpXpEarnedByUserId: { [number]: number },
	firstJoinAtByUserId: { [number]: number },
	recentKillTimestampsByUserId: { [number]: { number } },
	pickupCreditsByUserId: { [number]: { number } },
}

export type Deps = {
	dataService: DataService,
	-- nil sin ronda activa.
	getRound: () -> RoundLedger?,
	-- Stats de combate de la ronda activa (incluye bots), creadas lazy.
	roundStats: (userId: number) -> CombatStats?,
	isPlayerInMenu: (userId: number) -> boolean,
	-- Aplaza `fn` hasta que cargue el profile del jugador.
	deferUntilProfile: (player: Player, fn: () -> ()) -> (),
	resolveKillerName: (userId: number?) -> string,
	onFirstKill: (player: Player) -> (),
}

local KillRewardsService = {}

local _deps: Deps = nil :: any
local _dataService: DataService = nil :: any

function KillRewardsService:Start(deps: Deps)
	_deps = deps
	_dataService = deps.dataService
end

-- Acumula lo de esta ronda para los caps por moneda. El Cash es el BASE de ActionRewards,
-- no el cobrado: si el techo diario lo recorta, más kills no deben compensarlo.
local function _trackRoundEarnings(userId: number, cashBase: number, xpGranted: number)
	local round = _deps.getRound()
	if not round then
		return
	end
	round.cashEarnedByUserId[userId] = (round.cashEarnedByUserId[userId] or 0) + cashBase
	round.xpEarnedByUserId[userId] = (round.xpEarnedByUserId[userId] or 0) + xpGranted
end

-- Empuja una kill como crédito de pickup consumible. Llamado en ambos paths de
-- kill (PvP y vs bot) sólo para jugadores humanos in-match.
local function _recordPickupEligibility(userId: number)
	local round = _deps.getRound()
	if not round or userId <= 0 then
		return
	end
	local queue = round.pickupCreditsByUserId[userId]
	if not queue then
		queue = {}
		round.pickupCreditsByUserId[userId] = queue
	end
	table.insert(queue, time())
	-- Cap defensivo: nunca acumular más de N créditos pendientes (evita que un
	-- jugador que nunca se cura "ahorre" curaciones para más tarde).
	while #queue > PICKUP_ELIGIBILITY_MAX_QUEUED do
		table.remove(queue, 1)
	end
end

-- Consume (de existir) un crédito de pickup reciente. Devuelve true si había uno
-- dentro de la ventana. Poda timestamps caducados antes de decidir.
function KillRewardsService:ConsumePickupCredit(userId: number): boolean
	local round = _deps.getRound()
	local queue = if round then round.pickupCreditsByUserId[userId] else nil
	if not queue then
		return false
	end
	local now = time()
	while #queue > 0 and (now - queue[1]) > PICKUP_ELIGIBILITY_WINDOW do
		table.remove(queue, 1)
	end
	if #queue == 0 then
		return false
	end
	table.remove(queue, 1)
	return true
end

-- categoryHint manda si existe: sin él, un id presente en varias categorías ("Default")
-- se resolvería siempre a la primera de WeaponCategory.ALL.
local function _resolveWeaponItem(weaponId: string?, categoryHint: string?): (string?, string?)
	if type(weaponId) ~= "string" or weaponId == "" then
		return nil, nil
	end

	if categoryHint then
		local hinted = ItemsConfig[categoryHint]
		if type(hinted) == "table" and type(hinted[weaponId]) == "table" then
			return categoryHint, weaponId
		end
	end

	for _, category in WeaponCategory.ALL do
		local categoryConfig = ItemsConfig[category]
		if type(categoryConfig) == "table" then
			if type(categoryConfig[weaponId]) == "table" then
				return category, weaponId
			end
			for itemId, definition in categoryConfig do
				if type(definition) == "table" and definition.Name == weaponId then
					return category, itemId
				end
			end
		end
	end

	return nil, nil
end

local function _hasProfile(player: Player): boolean
	return _dataService ~= nil and _dataService:GetProfile(player) ~= nil
end

-- Cupo de recompensa disponible AHORA para `userId`. El cap de GameConfig es el de una
-- ronda COMPLETA y se devenga linealmente desde un colchón (MatchCapGraceFraction): con
-- un cap plano, las rondas cortadas por WinScoreLimit subirían el techo por hora. El
-- reloj es el del JUGADOR (su primera entrada), no el de la ronda, o entrar tarde daría
-- casi todo el cupo de golpe. Sin entrada registrada no hay cupo.
local function _capAllowance(fullCap: number, userId: number): number
	local round = _deps.getRound()
	if not round then
		return fullCap
	end
	local joinedAt = round.firstJoinAtByUserId[userId]
	if not joinedAt then
		return 0
	end
	local grace = GameConfig.MatchCapGraceFraction
	local full = math.max(1, GameConfig.MaxRoundDuration)
	local elapsed = math.clamp(os.time() - joinedAt, 0, full)
	return fullCap * (grace + (1 - grace) * (elapsed / full))
end

-- Caps de cash y XP INDEPENDIENTES: cada moneda se frena cuando ESA llega a su cap
-- (opts.skipCash/skipXP en RewardService.Award).
local function _isCashCapReached(userId: number): boolean
	local round = _deps.getRound()
	local earned = if round then round.cashEarnedByUserId[userId] or 0 else 0
	return earned >= _capAllowance(GameConfig.MatchCashCap, userId)
end

local function _isXPCapReached(userId: number): boolean
	local round = _deps.getRound()
	local earned = if round then round.xpEarnedByUserId[userId] or 0 else 0
	return earned >= _capAllowance(GameConfig.MatchXPCap, userId)
end

--[[
	Reserva `amount` de XP de pase en el cupo de la ronda (el mismo devengo que MatchXPCap,
	con contador propio) y devuelve si cabía. Reservar y comprobar van juntos para que quien
	concede el XP no pueda olvidar apuntarlo. Sin ronda activa no hay cupo.
]]
local function _tryConsumeBattlePassXP(player: Player, amount: number): boolean
	local round = _deps.getRound()
	if not round or amount <= 0 then
		return false
	end
	local userId = player.UserId
	local earned = round.bpXpEarnedByUserId[userId] or 0
	if earned >= _capAllowance(GameConfig.MatchXPCap, userId) then
		return false
	end
	round.bpXpEarnedByUserId[userId] = earned + amount
	return true
end

local function _grantActionRewardsToAttacker(attacker: Player?, action: string, weaponId: string?)
	if not _dataService or not attacker then
		return
	end

	local skipCash = _isCashCapReached(attacker.UserId)
	local skipXP = _isXPCapReached(attacker.UserId)
	if skipCash and skipXP then
		return
	end

	if not _hasProfile(attacker) then
		_deps.deferUntilProfile(attacker, function()
			_grantActionRewardsToAttacker(attacker, action, weaponId)
		end)
		return
	end

	local ok, xpGranted, _cashGranted, cashBase =
		RewardService.Award(attacker, action, nil, weaponId, { skipCash = skipCash, skipXP = skipXP, played = true })
	if ok then
		_trackRoundEarnings(attacker.UserId, cashBase, xpGranted)
	end
end

local function _grantMasteryWrapsIfEligible(player: Player, weaponCategory: string, weaponId: string, newKillCount: number)
	if not _dataService or newKillCount <= 0 then
		return
	end

	local weaponWrapsConfig = ItemsConfig.WeaponWraps
	if type(weaponWrapsConfig) ~= "table" then
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile or not profile.Data then
		return
	end

	local profileData = profile.Data
	local function owns(category: string, id: string, wrapKey: string): boolean
		return InventoryRepository.ownsWeaponWrap(profileData, category :: any, id, wrapKey)
	end

	local grants: { WrapMastery.Grant } = {}
	local killGranted: { [string]: boolean } = {}
	for wrapKey, definition in weaponWrapsConfig do
		if type(definition) == "table" then
			local challenge = definition.KillChallenge
			local kills: number? = nil
			if challenge then
				kills = tonumber(challenge.Kills)
			end
			if kills and kills > 0 and newKillCount >= kills and not owns(weaponCategory, weaponId, wrapKey) then
				killGranted[wrapKey] = true
				table.insert(grants, { category = weaponCategory, weaponId = weaponId, wrapId = wrapKey })
			end
		end
	end

	-- Se evalúa en cada kill, no solo al ganar uno nuevo: así también lo reciben
	-- quienes ya tenían los prerequisitos o cuando el catálogo cambia.
	local function ownsWithKillGrants(category: string, id: string, wrapKey: string): boolean
		return (category == weaponCategory and id == weaponId and killGranted[wrapKey] == true)
			or owns(category, id, wrapKey)
	end
	for _, grant in WrapMastery.pendingGrants(ownsWithKillGrants, weaponCategory, weaponId) do
		table.insert(grants, grant)
	end

	if #grants == 0 then
		return
	end

	-- Todos los wraps elegibles en un solo BatchUpdate.
	local targetsByWrap: { [string]: { DataServiceMod.WrapTarget } } = {}
	for _, grant in grants do
		local targets = targetsByWrap[grant.wrapId]
		if not targets then
			targets = {}
			targetsByWrap[grant.wrapId] = targets
		end
		table.insert(targets, { category = grant.category, weaponId = grant.weaponId })
	end
	local updates = {}
	for wrapId, targets in targetsByWrap do
		local wrapUpdates = _dataService:GrantWeaponWrapUpdates(wrapId, targets, "Mastery")
		table.move(wrapUpdates, 1, #wrapUpdates, #updates + 1, updates)
	end

	local ok, err = pcall(function()
		_dataService:BatchUpdate(player, updates)
	end)
	if not ok then
		warn("[KillRewardsService] Mastery wraps BatchUpdate error: " .. tostring(err))
		return
	end

	for _, grant in grants do
		TelemetryService.RecordItem(player, "MasteryWrap", grant.category .. "::" .. grant.weaponId .. "::" .. grant.wrapId)
	end
end

local function _registerWeaponKillForAttacker(attackerUserId: number?, weaponId: string?, weaponCategory: string?)
	if not _dataService or not attackerUserId or attackerUserId <= 0 then
		return
	end

	local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
	if not attackerPlayer then
		return
	end

	if not _hasProfile(attackerPlayer) then
		_deps.deferUntilProfile(attackerPlayer, function()
			_registerWeaponKillForAttacker(attackerUserId, weaponId, weaponCategory)
		end)
		return
	end

	local resolvedCategory, resolvedWeaponId = _resolveWeaponItem(weaponId, weaponCategory)
	if not resolvedCategory or not resolvedWeaponId then
		return
	end

	local ok, success, newCount = pcall(_dataService.IncrementWeaponKills, _dataService, attackerPlayer, resolvedCategory, resolvedWeaponId, 1)
	if not ok then
		warn("[KillRewardsService] IncrementWeaponKills error: " .. tostring(success))
		return
	end

	if success and type(newCount) == "number" then
		_grantMasteryWrapsIfEligible(attackerPlayer, resolvedCategory, resolvedWeaponId, newCount)
	end
end

--[[
	Persiste Stats lifetime del atacante en UN BatchUpdate atómico (Kills y
	Headshots). Stats.KillStreakBest no lo escribe nadie. Lo usan los paths PvP y PvE.
]]
local function _persistAttackerKillStats(attacker: Player, wasHeadshot: boolean)
	if not _dataService then
		return
	end

	if not _hasProfile(attacker) then
		_deps.deferUntilProfile(attacker, function()
			_persistAttackerKillStats(attacker, wasHeadshot)
		end)
		return
	end

	local updates = {
		{ path = { "Stats", "Kills" }, delta = 1 },
	}
	if wasHeadshot then
		table.insert(updates, { path = { "Stats", "Headshots" }, delta = 1 })
	end

	pcall(function()
		_dataService:BatchUpdate(attacker, updates)
	end)
end

-- Quién se lleva una muerte: el último que dañó a la víctima, si fue dentro de
-- KillAttributionWindow y, si es humano, sigue en partida (la misma condición que
-- IsMatchKill pone a las asistencias). Única regla para víctimas jugador y bot.
function KillRewardsService:ResolveKillAttacker(victim: Humanoid): (number?, string, boolean, string?)
	local lastAttacker = LastAttackerStore.get(victim)
	if not lastAttacker then
		return nil, "", false, nil
	end
	local attackerUserId: number? = lastAttacker.UserId
	if lastAttacker.At > 0 and time() - lastAttacker.At > GameConfig.KillAttributionWindow then
		attackerUserId = nil
	end
	if attackerUserId and attackerUserId > 0 and _deps.isPlayerInMenu(attackerUserId) then
		attackerUserId = nil
	end
	return attackerUserId, lastAttacker.WeaponId or "", lastAttacker.Headshot == true, lastAttacker.WeaponCategory
end

--[[
	Camino ÚNICO de acreditación de una kill al atacante — lo comparten el
	path PvP (víctima jugador) y PvE (víctima bot):
	  • bots atacantes: SOLO contador de HUD (sin rewards/persistencia)
	  • humanos: todo lo que paga una kill (stats de ronda, maestría, health
	    pickup, cash/XP, Stats lifetime, multikills, dailies y XP del pase), para
	    que una muerte cuente para todo o para nada.
	No toca a la víctima; la atribución sale de ResolveKillAttacker.

	`victimIsBot` sólo se usa para telemetría: un K/D o win rate por arma que mezcle
	bots con humanos no sirve para balancear.
]]
function KillRewardsService:CreditKill(
	attackerUserId: number,
	weaponId: string?,
	wasHeadshot: boolean,
	victimIsBot: boolean,
	weaponCategory: string?
)
	if attackerUserId < 0 then
		local botStats = _deps.roundStats(attackerUserId)
		if botStats then
			botStats.kills += 1
		end
		KillAttributionService:SendStreakBroadcast(attackerUserId)
		return
	end

	local attacker = Players:GetPlayerByUserId(attackerUserId)
	if not attacker then
		return
	end

	local attackerStats = _deps.roundStats(attackerUserId)
	if not attackerStats then
		return
	end
	attackerStats.kills += 1

	if attackerStats.kills == 1 then
		pcall(_deps.onFirstKill, attacker)
	end

	KillAttributionService:SendStreakBroadcast(attackerUserId)
	_registerWeaponKillForAttacker(attackerUserId, weaponId, weaponCategory)

	-- Telemetría de combate aquí y no en RewardService: las recompensas se cortan en
	-- MatchCashCap/MatchXPCap y truncarían las kills de quien más mata.
	local telemetryCategory, telemetryWeapon = _resolveWeaponItem(weaponId, weaponCategory)
	if telemetryCategory and telemetryWeapon then
		TelemetryService.RecordCombat(attacker, telemetryCategory, telemetryWeapon, victimIsBot, wasHeadshot)
	end
	-- Una kill humana dropea un health pickup en cliente; este crédito valida el
	-- RequestPickup correspondiente.
	_recordPickupEligibility(attackerUserId)
	_grantActionRewardsToAttacker(attacker, "Kill", weaponId)
	if wasHeadshot then
		_grantActionRewardsToAttacker(attacker, "Headshot", weaponId)
	end

	_persistAttackerKillStats(attacker, wasHeadshot)

	-- Las dailies no pasan por el cap de la ronda a propósito: su payout ya está acotado
	-- por diseño. OnKill lleva dentro la racha de bajas; el headshot es su propia tarea.
	pcall(function()
		DailyTasksService:OnKill(attacker)
		if wasHeadshot then
			DailyTasksService:OnHeadshot(attacker)
		end
	end)
	-- El pase tiene su propio cupo por ronda, para que farmear kills no lo suba sin límite.
	pcall(function()
		if _tryConsumeBattlePassXP(attacker, BattlePassConfig.XPRates.PerKill) then
			BattlePassService:OnKill(attacker)
		end
	end)

	-- Multikills: ventana corta de kills consecutivas → Stats lifetime.
	local round = _deps.getRound()
	if not round then
		return
	end
	local now = time()
	local timestamps = round.recentKillTimestampsByUserId[attackerUserId]
	if not timestamps then
		timestamps = {}
		round.recentKillTimestampsByUserId[attackerUserId] = timestamps
	end
	table.insert(timestamps, now)
	while #timestamps > 0 and (now - timestamps[1]) > MULTIKILL_WINDOW do
		table.remove(timestamps, 1)
	end
	if _dataService and _hasProfile(attacker) then
		local killsInWindow = #timestamps
		if killsInWindow == 2 then
			pcall(_dataService.Increment, _dataService, attacker, { "Stats", "DoubleKills" }, 1)
		elseif killsInWindow == 3 then
			pcall(_dataService.Increment, _dataService, attacker, { "Stats", "TripleKills" }, 1)
		end
	end
end

-- Muerte de un jugador en partida: kill feed, sus stats de muerte y, si lo mató un humano
-- en partida, la kill del atacante.
function KillRewardsService:RegisterPlayerDeath(deadPlayer: Player, attackerUserId: number?, attackerWeaponId: string?, attackerWasHeadshot: boolean?, attackerWeaponCategory: string?)
	local killerName = _deps.resolveKillerName(attackerUserId)
	pcall(function()
		Network.Combat.KillFeed.SendToAll({
			killerName = killerName,
			victimName = deadPlayer.Name,
			weaponId = attackerWeaponId or "",
		})
	end)

	local deadStats = _deps.roundStats(deadPlayer.UserId)
	if deadStats then
		deadStats.deaths += 1
	end
	KillAttributionService:SendStreakBroadcast(deadPlayer.UserId)
	-- Morir corta la racha de bajas que cuenta la tarea diaria de racha.
	pcall(function()
		DailyTasksService:OnDeath(deadPlayer)
	end)

	if _dataService then
		if _hasProfile(deadPlayer) then
			pcall(_dataService.Increment, _dataService, deadPlayer, { "Stats", "Deaths" }, 1)
		else
			_deps.deferUntilProfile(deadPlayer, function()
				pcall(_dataService.Increment, _dataService, deadPlayer, { "Stats", "Deaths" }, 1)
			end)
		end
	end

	if not attackerUserId or attackerUserId == deadPlayer.UserId then
		return
	end

	-- Kills sobre jugadores solo se acreditan a HUMANOS in-match (los bots solo suman
	-- contador al matar bots); la muerte cuenta igual.
	if attackerUserId < 0 or _deps.isPlayerInMenu(attackerUserId) then
		return
	end

	-- Víctima jugador: PvP.
	self:CreditKill(attackerUserId, attackerWeaponId, attackerWasHeadshot == true, false, attackerWeaponCategory)
end

-- Recompensa de las asistencias (WeaponsSystem vía MatchService:GrantCombatReward), con
-- los caps de la ronda.
function KillRewardsService:GrantCombatReward(player: Player, actionKey: string, extraUpdates: any?, itemSku: string?)
	-- Caps por moneda independientes. Con ambas capadas solo se corta si no hay
	-- extraUpdates (p. ej. Stats.Assists), que deben persistirse igualmente.
	local skipCash = _isCashCapReached(player.UserId)
	local skipXP = _isXPCapReached(player.UserId)
	if skipCash and skipXP and extraUpdates == nil then
		return false, 0, 0
	end

	local ok, xpGranted, cashGranted, cashBase = RewardService.Award(
		player,
		actionKey,
		extraUpdates,
		itemSku,
		{ skipCash = skipCash, skipXP = skipXP, played = true }
	)
	if ok then
		_trackRoundEarnings(player.UserId, cashBase, xpGranted)

		-- Asistencias de la partida: las difundimos vía streak para Resultados.
		if actionKey == "Assist" then
			local stats = _deps.roundStats(player.UserId)
			if stats then
				stats.assists += 1
				KillAttributionService:SendStreakBroadcast(player.UserId)
			end
			pcall(function()
				DailyTasksService:OnAssist(player)
			end)
		end
	end
	return ok, xpGranted, cashGranted
end

return KillRewardsService
