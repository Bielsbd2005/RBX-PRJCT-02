--!strict
--[[
	Recompensas de fin de partida (pantalla de Resultados): computa, concede y
	empaqueta; MatchService solo aporta el contexto. Los ítems "desbloqueados" son
	solo display (los concede la progresión). El cash se concede a todos los
	elegibles, vean o no la pantalla.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local ResultsRewards = require(Shared.constants.ResultsRewards)
local StoreProducts = require(Shared.constants.StoreProducts)
local RewardService = require(script.Parent.Parent.Parent.core.RewardService)
local GamePassService = require(script.Parent.Parent.Parent.core.GamePassService)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

-- Solo display: lo concedido por progresión no se ve afectado.
local MAX_ITEMS = 6
-- Los bonus escalados se redondean a este múltiplo: en pantalla no debe salir un 29.
local BONUS_STEP = 5

export type MatchContext = ResultsRewards.MatchContext

export type ResultItem = {
	source: string, -- "Locker"
	title: string, -- "UNLOCKED"
	category: string,
	itemId: string,
	image: string,
	name: string,
}

-- `amount == 0` indica ítem (el cliente oculta Amount).
export type DisplayReward = {
	title: string,
	image: string,
	amount: number,
	locked: boolean, -- bonus VIP no poseído: se muestra como upsell, no se concede
}

export type MatchResults = {
	outcome: string, -- "Victory" | "Defeat"
	-- Con id, solo server (GrantCash + analytics).
	cash: { ResultsRewards.ResolvedCashReward },
	rewards: { DisplayReward },
}

local MatchResultsService = {}

local _started = false
local _dataService: DataService = nil :: any

-- Set-if-absent: un re-join en la misma ronda no pisa el snapshot.
local _startSnapshotByUserId: { [number]: { level: number } } = {}

-- false si el prefetch de GamePassService aún no resolvió (síncrono para no
-- bloquear RoundEnded).
function MatchResultsService:IsVIPCached(player: Player): boolean
	return GamePassService.Owns(player, StoreProducts.GamePasses.ByName.VIP.PassId)
end

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
	_startSnapshotByUserId[player.UserId] = { level = level }

	-- Resultado descartado a propósito: si el prefetch de PlayerAdded falló, relanza la consulta.
	MatchResultsService:IsVIPCached(player)
end

function MatchResultsService:ClearSnapshots()
	table.clear(_startSnapshotByUserId)
end

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
					image = if type(definition.Image) == "string" and definition.Image ~= ""
						then definition.Image
						elseif type(definition.CatalogEmoteId) == "number"
						then "rbxthumb://type=Asset&id=" .. tostring(definition.CatalogEmoteId) .. "&w=150&h=150"
						else "",
					name = name,
				})
				if #out >= MAX_ITEMS then
					return
				end
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

	local endLevel = if profile.Data.Stats and type(profile.Data.Stats.Level) == "number"
		then math.floor(profile.Data.Stats.Level)
		else snapshot.level
	for level = snapshot.level + 1, endLevel do
		_lockerItemsForLevel(level, out)
		if #out >= MAX_ITEMS then
			return out
		end
	end

	return out
end

-- Síncrono (sin yields): se envía en el mismo frame que RoundEnded.
-- `bonusScale` (0..1) lo calcula MatchService: 0 = sin participación mínima (no hay
-- bonus, ni el upsell VIP); si no, tiempo en partida sobre ronda completa × techo diario. El
-- importe escalado es el que se pinta Y el que se concede; lo que redondea a 0 se cae.
function MatchResultsService:BuildResults(player: Player, ctx: MatchContext, bonusScale: number): MatchResults
	local cash: { ResultsRewards.ResolvedCashReward } = {}
	for _, entry in ResultsRewards.resolveCash(ctx) do
		-- Hacia abajo: redondeando al más cercano, la ronda corta cobraría de más por hora.
		local scaled = math.floor(entry.cash * math.clamp(bonusScale, 0, 1) / BONUS_STEP) * BONUS_STEP
		if scaled > 0 then
			table.insert(cash, { id = entry.id, title = entry.title, cash = scaled, locked = entry.locked })
		end
	end
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

-- `matchId` viaja como sku a telemetría para cruzar los faucets MatchEnd::* con
-- el evento de fin de partida.
function MatchResultsService:GrantCash(
	player: Player,
	cash: { ResultsRewards.ResolvedCashReward },
	matchId: string?
)
	for _, entry in cash do
		if not entry.locked and entry.cash > 0 then
			RewardService.AwardCash(player, entry.cash, "MatchEnd::" .. entry.id, matchId, true)
		end
	end
end

function MatchResultsService:Start(deps: { dataService: DataService })
	if _started then
		return
	end
	_started = true
	_dataService = deps.dataService

	Players.PlayerRemoving:Connect(function(player)
		_startSnapshotByUserId[player.UserId] = nil
	end)
end

return MatchResultsService
