--!strict
--[[
	KillAttributionService.luau
	Broadcast de stats de combate por jugador (kills/deaths/assists) al marcador,
	con dedupe interno y APIs de send para nuevos jugadores.

	NOTA: la lógica de kill streaks vivía aquí y se eliminó. Los nombres "Streak"
	(SendStreakBroadcast, etc.) y el packet PlayerStreakState se conservan por
	compatibilidad de llamadas; transportan solo stats de combate hasta que se
	implemente el sistema de rachas nuevo.

	API:
		KillAttributionService:Start({ getCombatStats, getActiveBotUserIds })
		:SendStreakBroadcast(userId)          -- a todos (con dedupe)
		:SendStreakSnapshotTo(player, userId)  -- dirigido
		:SendAllStreaksTo(player)             -- onboarding (players + bots activos)
		:Clear()                              -- reset de dedupe (al desmontar ronda)
		:OnPlayerRemoving(userId)             -- cleanup por jugador
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)

type Deps = {
	-- Stats de combate de la ronda activa para componer el packet:
	-- (kills, deaths, assists). Devuelve 0s entre rondas o sin entrada.
	getCombatStats: (userId: number) -> (number, number, number),
	-- userIds (negativos) de bots con stats en la ronda activa — para el sync
	-- de onboarding (SendAllStreaksTo).
	getActiveBotUserIds: () -> { number },
}

local KillAttributionService = {}
KillAttributionService.__index = KillAttributionService

local _deps: Deps = nil :: any
local _started = false
local _lastBroadcastKeyByUserId: { [number]: string } = {}

function KillAttributionService:Start(deps: Deps)
	if _started then
		return
	end
	_started = true
	_deps = deps
end

-- Broadcast con dedupe interno (no envía si el packet sería idéntico al último).
function KillAttributionService:SendStreakBroadcast(userId: number)
	local kills, deaths, assists = _deps.getCombatStats(userId)
	local key = string.format("%d|%d|%d", kills, deaths, assists)
	if _lastBroadcastKeyByUserId[userId] == key then
		return
	end
	_lastBroadcastKeyByUserId[userId] = key
	Network.Match.PlayerStreakState.SendToAll({
		userId = tostring(userId),
		kills = kills,
		deaths = deaths,
		assists = assists,
	})
end

function KillAttributionService:SendStreakSnapshotTo(player: Player, userId: number)
	local kills, deaths, assists = _deps.getCombatStats(userId)
	pcall(function()
		Network.Match.PlayerStreakState.SendTo({
			userId = tostring(userId),
			kills = kills,
			deaths = deaths,
			assists = assists,
		}, player)
	end)
end

-- Envía a `player` los stats de todos los players + bots con actividad.
-- Usado en `RequestMatchSync` y onboarding.
function KillAttributionService:SendAllStreaksTo(player: Player)
	for _, otherPlayer in Players:GetPlayers() do
		self:SendStreakSnapshotTo(player, otherPlayer.UserId)
	end
	-- Bots: solo si tienen actividad (kills/deaths > 0).
	for _, botUserId in _deps.getActiveBotUserIds() do
		local kills, deaths = _deps.getCombatStats(botUserId)
		if kills > 0 or deaths > 0 then
			self:SendStreakSnapshotTo(player, botUserId)
		end
	end
end

-- Limpia el state de dedupe (lo llama MatchService al desmontar la ronda).
function KillAttributionService:Clear()
	table.clear(_lastBroadcastKeyByUserId)
end

function KillAttributionService:OnPlayerRemoving(userId: number)
	_lastBroadcastKeyByUserId[userId] = nil
end

return KillAttributionService
