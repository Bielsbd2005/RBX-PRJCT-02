--!strict
--[[
	KillAttributionService.luau
	Gestión de kill streaks: contador por usuario, timeout de decaimiento,
	dedupe del broadcast, y APIs de send para nuevos jugadores. Extraído de
	MatchService como parte del split estructural (audit AAA).

	Scope intencional: SOLO streaks/broadcasts. El death listener completo
	(con kill resolution + reward grants + persistence + score updates) se
	queda en MatchService porque tiene 10+ dependencias cross-cutting que
	requerirían un fat DI sin claro beneficio. La extracción completa de la
	lógica de kill attribution requeriría la redesign event-driven mencionada
	en el audit (#5 "Kill attribution vía SetAttribute → BindableEvent").

	API:
		KillAttributionService:Start({
			matchKillsByUserId, matchDeathsByUserId,
		})
		:RecordKill(attackerUserId) -> newStreak  -- ++streak, setupTimeout, broadcast
		:ResetStreak(userId) -> ()  -- streak=0, cancel timeout
		:GetStreak(userId) -> number
		:SendStreakBroadcast(userId)  -- to all
		:SendStreakSnapshotTo(player, userId)  -- targeted
		:SendAllStreaksTo(player)  -- onboarding (players + active bots)
		:Clear()  -- table.clear + cancel pending timeouts (called from match reset)
		:OnPlayerRemoving(userId) -> ()  -- per-player cleanup

	El timeout de decaimiento (7s) y el dedupe key (kills|streak|deaths) son
	internos. La sumarización ENTRA por `RecordKill`, sale por `Clear`/`ResetStreak`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)

type Deps = {
	-- Shared tables — leemos kills/deaths/asistencias para componer el packet de streak.
	matchKillsByUserId: { [number]: number },
	matchDeathsByUserId: { [number]: number },
	matchAssistsByUserId: { [number]: number },
}

local KillAttributionService = {}
KillAttributionService.__index = KillAttributionService

local STREAK_DECAY_SECONDS = 7

local _deps: Deps = nil :: any
local _started = false
local _killStreakByUserId: { [number]: number } = {}
local _killStreakTimeoutByUserId: { [number]: thread? } = {}
local _lastBroadcastStreakKeyByUserId: { [number]: string } = {}

-- ── Helpers privados ─────────────────────────────────────────

local function _cancelTimeout(userId: number)
	local pending = _killStreakTimeoutByUserId[userId]
	if pending then
		if type(task.cancel) == "function" then
			pcall(task.cancel, pending)
		end
		_killStreakTimeoutByUserId[userId] = nil
	end
end

-- ── API pública ──────────────────────────────────────────────

function KillAttributionService:Start(deps: Deps)
	if _started then
		return
	end
	_started = true
	_deps = deps
end

function KillAttributionService:GetStreak(userId: number): number
	return _killStreakByUserId[userId] or 0
end

function KillAttributionService:ResetStreak(userId: number)
	_killStreakByUserId[userId] = 0
	_cancelTimeout(userId)
end

-- Inicializa streak=0 sin cancelar timeout (uso al inicio de match).
function KillAttributionService:InitStreak(userId: number)
	_killStreakByUserId[userId] = 0
end

-- Setea streak=0 SOLO si la entry no existe (no sobreescribe streak en curso).
function KillAttributionService:EnsureStreakInitialized(userId: number)
	if _killStreakByUserId[userId] == nil then
		_killStreakByUserId[userId] = 0
	end
end

-- Setea streak directamente (uso interno desde MatchService al asignar
-- nil al salir un player). Equivalente a borrar la entrada.
function KillAttributionService:ClearStreakEntry(userId: number)
	_killStreakByUserId[userId] = nil
	_lastBroadcastStreakKeyByUserId[userId] = nil
end

-- Incrementa streak y programa timeout de decaimiento. Devuelve el nuevo valor.
function KillAttributionService:RecordKill(attackerUserId: number): number
	local newStreak = (_killStreakByUserId[attackerUserId] or 0) + 1
	_killStreakByUserId[attackerUserId] = newStreak

	-- Reset timeout previo y programar nuevo (decaimiento si no hay otra kill).
	_cancelTimeout(attackerUserId)
	_killStreakTimeoutByUserId[attackerUserId] = task.delay(STREAK_DECAY_SECONDS, function()
		_killStreakByUserId[attackerUserId] = 0
		_killStreakTimeoutByUserId[attackerUserId] = nil
		KillAttributionService:SendStreakBroadcast(attackerUserId)
	end)

	return newStreak
end

-- Broadcast con dedupe interno (no envía si el packet sería idéntico al último).
function KillAttributionService:SendStreakBroadcast(userId: number)
	local streak = _killStreakByUserId[userId] or 0
	local kills = _deps.matchKillsByUserId[userId] or 0
	local deaths = _deps.matchDeathsByUserId[userId] or 0
	local assists = _deps.matchAssistsByUserId[userId] or 0
	local key = string.format("%d|%d|%d|%d", kills, streak, deaths, assists)
	if _lastBroadcastStreakKeyByUserId[userId] == key then
		return
	end
	_lastBroadcastStreakKeyByUserId[userId] = key
	Network.Match.PlayerStreakState.SendToAll({
		userId = tostring(userId),
		kills = kills,
		streak = streak,
		deaths = deaths,
		assists = assists,
	})
end

function KillAttributionService:SendStreakSnapshotTo(player: Player, userId: number)
	pcall(function()
		Network.Match.PlayerStreakState.SendTo({
			userId = tostring(userId),
			kills = _deps.matchKillsByUserId[userId] or 0,
			streak = _killStreakByUserId[userId] or 0,
			deaths = _deps.matchDeathsByUserId[userId] or 0,
			assists = _deps.matchAssistsByUserId[userId] or 0,
		}, player)
	end)
end

-- Envía a `player` el estado de streak de todos los players + bots con actividad.
-- Usado en `RequestVoteSync` y onboarding.
function KillAttributionService:SendAllStreaksTo(player: Player)
	for _, otherPlayer in Players:GetPlayers() do
		self:SendStreakSnapshotTo(player, otherPlayer.UserId)
	end
	-- Bots: solo si tienen actividad (kills/deaths/streak > 0).
	for botUserId in _deps.matchKillsByUserId do
		if botUserId < 0 then
			local kills = _deps.matchKillsByUserId[botUserId] or 0
			local deaths = _deps.matchDeathsByUserId[botUserId] or 0
			local streak = _killStreakByUserId[botUserId] or 0
			if kills > 0 or deaths > 0 or streak > 0 then
				self:SendStreakSnapshotTo(player, botUserId)
			end
		end
	end
end

-- Limpia todo el state (used by _resetMatchScopedState de MatchService al
-- terminar/iniciar un round).
function KillAttributionService:Clear()
	table.clear(_killStreakByUserId)
	table.clear(_lastBroadcastStreakKeyByUserId)
	for _, timeout in _killStreakTimeoutByUserId do
		if timeout and type(task.cancel) == "function" then
			pcall(task.cancel, timeout)
		end
	end
	table.clear(_killStreakTimeoutByUserId)
end

function KillAttributionService:OnPlayerRemoving(userId: number)
	_killStreakByUserId[userId] = nil
	_lastBroadcastStreakKeyByUserId[userId] = nil
	_cancelTimeout(userId)
end

return KillAttributionService
