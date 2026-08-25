--!strict
--[[
	MatchResultsService.luau  (Server)

	Dueño de TODO lo relativo a las recompensas de fin de partida (pantalla de
	Resultados). Mantiene MatchService delgado: este service computa, concede y
	empaqueta; MatchService solo le da el contexto del jugador al terminar la ronda.

	Responsabilidades:
	  • VIP: caché por jugador del gamepass `StoreProducts.GamePasses.VIP` (prefetch
	    en PlayerAdded + update en GamePassPurchaseFinished). Lectura síncrona
	    (IsVIPCached) para no bloquear el envío de RoundEnded.
	  • Snapshot de inicio de partida (nivel + tier de BP) por jugador, para luego
	    computar qué items se DESBLOQUEARON durante la partida (display-only — el
	    granting de esos items ya lo hace la progresión: level-up / BP).
	  • BuildResults(player, ctx): arma el paquete { outcome, cash, items } que el
	    cliente renderiza. El cash se resuelve desde `ResultsRewards` (configurable).
	  • GrantCash(player, cash): concede el cash NO bloqueado vía RewardService.

	Importante: el cash se concede server-side a todos los elegibles, vean o no la
	pantalla de Resultados (MatchService llama GrantCash en su loop de fin de ronda).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ResultsRewards = require(Shared.constants.ResultsRewards)
local StoreProducts = require(Shared.constants.StoreProducts)
local RewardService = require(script.Parent.Parent.Parent.core.RewardService)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

-- Tope de items mostrados en Resultados (un gran salto de niveles no debe
-- inundar la pantalla). Es solo display; lo concedido por progresión no se ve afectado.
local MAX_ITEMS = 6

export type MatchContext = ResultsRewards.MatchContext

export type ResultItem = {
	source: string, -- "Locker" | "Pass"
	title: string, -- "UNLOCKED" | "PASS"
	category: string,
	itemId: string,
	image: string,
	name: string,
}

-- Entrada de recompensa YA aplanada para el cliente (mismo template para cash e
-- items). `amount > 0` → es cash (se muestra Amount); `amount == 0` → es item.
export type DisplayReward = {
	title: string, -- texto de Title.Value ("VICTORY" | "UNLOCKED" | "PASS" | ...)
	image: string, -- ImageLabel.Image (icono de cash o imagen del item)
	amount: number, -- monto de cash (0 = item: se oculta Amount)
	locked: boolean, -- bonus VIP no poseído → gris + Locked (no se concede)
}

export type MatchResults = {
	outcome: string, -- "Victory" | "Defeat"
	-- Lista resuelta de cash CON id (solo server, para GrantCash + analytics).
	cash: { ResultsRewards.ResolvedCashReward },
	-- Lista aplanada (cash + items) que se serializa y renderiza en el cliente.
	rewards: { DisplayReward },
}

local MatchResultsService = {}

local _started = false
local _dataService: DataService = nil :: any

-- VIP cache por userId (nil = sin resolver todavía).
local _vipByUserId: { [number]: boolean } = {}
-- Snapshot de inicio de partida por userId (set-if-absent; se limpia por ronda).
local _startSnapshotByUserId: { [number]: { level: number, bpTier: number } } = {}

-- ── VIP ──────────────────────────────────────────────────────

local function _fetchVIP(userId: number): boolean
	local gamePassId = StoreProducts.GamePasses.VIP.PassId
	if gamePassId <= 0 then
		return false
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(userId, gamePassId)
	end)
	if not ok then
		warn("[MatchResultsService] UserOwnsGamePassAsync falló para", userId, ":", owns)
		return false
	end
	return owns == true
end

-- Prefetch asíncrono (no bloquea). Idempotente: solo resuelve si aún es nil.
local function _prefetchVIP(userId: number)
	if _vipByUserId[userId] ~= nil then
		return
	end
	task.spawn(function()
		if _vipByUserId[userId] == nil then
			_vipByUserId[userId] = _fetchVIP(userId)
		end
	end)
end

-- Lectura síncrona (default false si aún no resolvió). El prefetch en join/added
-- mantiene el caché caliente para cuando termina la ronda.
function MatchResultsService:IsVIPCached(player: Player): boolean
	return _vipByUserId[player.UserId] == true
end

-- ── Snapshot de inicio de partida ────────────────────────────

-- Captura nivel + tier de BP del jugador al ENTRAR a la partida (set-if-absent,
-- para que un re-join en la misma ronda no pise el snapshot original).
function MatchResultsService:CaptureMatchStart(player: Player)
	if _startSnapshotByUserId[player.UserId] then
		return
	end
	local profile = if _dataService then _dataService:GetProfile(player) else nil
	if not profile or not profile.Data then
		return
	end
	local level = if profile.Data.Stats and type(profile.Data.Stats.Level) == "number"
		then math.floor(profile.Data.Stats.Level)
		else 0
	local bp = profile.Data.BattlePass
	local bpTier = if bp and type(bp.CurrentTier) == "number" then math.floor(bp.CurrentTier) else 1
	_startSnapshotByUserId[player.UserId] = { level = level, bpTier = bpTier }
	_prefetchVIP(player.UserId)
end

-- Limpia los snapshots de inicio (llamado por MatchService al resetear la ronda).
function MatchResultsService:ClearSnapshots()
	table.clear(_startSnapshotByUserId)
end

-- ── Items desbloqueados durante la partida (display-only) ─────

-- Items del locker cuyo LevelRequired == `level` (se desbloquean al alcanzarlo).
-- Se ignoran defaults (LevelRequired <= 1).
local function _lockerItemsForLevel(level: number, out: { ResultItem })
	if level <= 1 then
		return
	end
	for category, items in ItemsConfig do
		if type(items) ~= "table" then
			continue
		end
		for itemId, definition in items do
			if type(definition) == "table" and tonumber(definition.LevelRequired) == level then
				local name = if type(definition.Name) == "string" and definition.Name ~= ""
					then definition.Name
					else tostring(itemId)
				table.insert(out, {
					source = "Locker",
					title = "UNLOCKED",
					category = tostring(category),
					itemId = tostring(itemId),
					image = if type(definition.Image) == "string" then definition.Image else "",
					name = name,
				})
				if #out >= MAX_ITEMS then
					return
				end
			end
		end
	end
end

-- Items del pase de batalla de los tiers COMPLETADOS durante la partida.
local function _battlePassItemsBetweenTiers(startCompleted: number, endCompleted: number, out: { ResultItem })
	if endCompleted <= startCompleted then
		return
	end
	local season = BattlePassConfig.GetActiveSeason()
	for level = startCompleted + 1, endCompleted do
		local tier = BattlePassConfig.GetTier(season, level)
		if tier and tier.Reward and tier.Reward.Kind == "Item" then
			local reward = tier.Reward
			local category = tostring(reward.Category)
			local itemId = tostring(reward.ItemId)
			local categoryConfig = ItemsConfig[category]
			local def = if type(categoryConfig) == "table" then categoryConfig[itemId] else nil
			local name = if def and type(def.Name) == "string" and def.Name ~= "" then def.Name else itemId
			local image = reward.Icon
				or (if def and type(def.Image) == "string" then def.Image else "")
			table.insert(out, {
				source = "Pass",
				title = "PASS",
				category = category,
				itemId = itemId,
				image = image,
				name = name,
			})
			if #out >= MAX_ITEMS then
				return
			end
		end
	end
end

function MatchResultsService:_computeItemUnlocks(player: Player): { ResultItem }
	local out: { ResultItem } = {}
	local snapshot = _startSnapshotByUserId[player.UserId]
	if not snapshot then
		return out
	end
	local profile = if _dataService then _dataService:GetProfile(player) else nil
	if not profile or not profile.Data then
		return out
	end

	-- Locker (por crossing de niveles de character).
	local endLevel = if profile.Data.Stats and type(profile.Data.Stats.Level) == "number"
		then math.floor(profile.Data.Stats.Level)
		else snapshot.level
	for level = snapshot.level + 1, endLevel do
		_lockerItemsForLevel(level, out)
		if #out >= MAX_ITEMS then
			return out
		end
	end

	-- BattlePass (por tiers completados). CurrentTier = "progresando hacia N" →
	-- completados = CurrentTier - 1.
	local bp = profile.Data.BattlePass
	local endTier = if bp and type(bp.CurrentTier) == "number" then math.floor(bp.CurrentTier) else snapshot.bpTier
	_battlePassItemsBetweenTiers(math.max(0, snapshot.bpTier - 1), math.max(0, endTier - 1), out)

	return out
end

-- ── Build + grant ────────────────────────────────────────────

-- Arma el paquete de Resultados del jugador. Síncrono (no yield) para poder
-- enviarlo en el mismo frame que RoundEnded. Aplana cash + items en una sola
-- lista `rewards` (mismo template en el cliente); `cash` se conserva con id
-- para el granting/analytics.
function MatchResultsService:BuildResults(player: Player, ctx: MatchContext): MatchResults
	local cash = ResultsRewards.resolveCash(ctx)
	local items = self:_computeItemUnlocks(player)

	local rewards: { DisplayReward } = {}
	for _, entry in cash do
		table.insert(rewards, {
			title = entry.title,
			image = ResultsRewards.CashIcon,
			amount = entry.cash,
			locked = entry.locked,
		})
	end
	for _, item in items do
		table.insert(rewards, {
			title = item.title,
			image = item.image,
			amount = 0,
			locked = false,
		})
	end

	return {
		outcome = if ctx.won then "Victory" else "Defeat",
		cash = cash,
		rewards = rewards,
	}
end

-- Concede el cash NO bloqueado del paquete. Los bonus VIP que el jugador no
-- posee llegan con locked=true → no se conceden (solo se muestran como upsell).
function MatchResultsService:GrantCash(player: Player, cash: { ResultsRewards.ResolvedCashReward })
	for _, entry in cash do
		if not entry.locked and entry.cash > 0 then
			RewardService.AwardCash(player, entry.cash, "MatchEnd::" .. entry.id)
		end
	end
end

-- ── Lifecycle ────────────────────────────────────────────────

function MatchResultsService:Start(deps: { dataService: DataService })
	if _started then
		return
	end
	_started = true
	_dataService = deps.dataService

	for _, player in Players:GetPlayers() do
		_prefetchVIP(player.UserId)
	end
	Players.PlayerAdded:Connect(function(player)
		_prefetchVIP(player.UserId)
	end)
	Players.PlayerRemoving:Connect(function(player)
		_vipByUserId[player.UserId] = nil
		_startSnapshotByUserId[player.UserId] = nil
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		-- Si la compra se confirma DESPUÉS de que PlayerRemoving limpió la entrada,
		-- repoblarla la dejaría huérfana para siempre (fuga por userId). Solo
		-- escribir si el jugador sigue conectado; un re-join repuebla vía prefetch.
		if wasPurchased and gamePassId == StoreProducts.GamePasses.VIP.PassId and player:IsDescendantOf(Players) then
			_vipByUserId[player.UserId] = true
		end
	end)
end

return MatchResultsService
