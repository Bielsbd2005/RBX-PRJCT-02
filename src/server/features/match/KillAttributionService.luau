--!strict
--[[
	Broadcast de kills/deaths/assists por jugador al marcador, con dedupe.
	Los nombres "Streak" (SendStreakBroadcast, packet PlayerStreakState) no
	implican rachas: transportan solo stats de combate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)

type Deps = {
	-- (kills, deaths, assists) de la ronda activa; 0s entre rondas o sin entrada.
	getCombatStats: (userId: number) -> (number, number, number),
	-- userIds (negativos) de bots con stats en la ronda activa.
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

function KillAttributionService:SendAllStreaksTo(player: Player)
	for _, otherPlayer in Players:GetPlayers() do
		self:SendStreakSnapshotTo(player, otherPlayer.UserId)
	end
	for _, botUserId in _deps.getActiveBotUserIds() do
		local kills, deaths = _deps.getCombatStats(botUserId)
		if kills > 0 or deaths > 0 then
			self:SendStreakSnapshotTo(player, botUserId)
		end
	end
end

-- Lo llama MatchService al desmontar la ronda.
function KillAttributionService:Clear()
	table.clear(_lastBroadcastKeyByUserId)
end

function KillAttributionService:OnPlayerRemoving(userId: number)
	_lastBroadcastKeyByUserId[userId] = nil
end

return KillAttributionService
