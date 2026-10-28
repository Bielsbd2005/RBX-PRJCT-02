--!strict
--[[
	Lee la tabla de sesiones de MatchService y es el único que escribe `session.team`.
]]

local Players = game:GetService("Players")

type TeamSide = "A" | "B"

-- Vista estructural de la PlayerSession de MatchService (solo lo que se usa).
type SessionView = {
	team: TeamSide?,
	inMenu: boolean,
	pendingSpawn: boolean,
}

type Deps = {
	-- Tabla de sesiones compartida con MatchService, keyed por userId.
	sessions: { [number]: SessionView },
	-- Para el tie-break por marcador.
	getRoundScoreA: () -> number,
	getRoundScoreB: () -> number,
	-- Cap por equipo (de GameConfig.TeamSizeTarget).
	teamSizeTarget: number,
	-- Stats de por vida del perfil (DataTemplate.Stats); nil si aún no cargó.
	getStats: (player: Player) -> { Kills: number, Deaths: number }?,
}

-- K/D virtual que se suma a todo jugador: sin él, un perfil nuevo con 1 kill y
-- 0 muertes contaría como el mejor del servidor.
local RATING_PRIOR = 10
-- Fuerza de un bot de relleno en la escala de K/D. Los K/D reales van inflados
-- porque incluyen kills a bots, así que un bot vale menos que un jugador medio.
local BOT_RATING = 0.5

local TeamAssignmentService = {}
TeamAssignmentService.__index = TeamAssignmentService

local _deps: Deps = nil :: any
local _tieBreakToA = false
local _started = false

function TeamAssignmentService:Start(deps: Deps)
	if _started then
		return
	end
	_started = true
	_deps = deps
	_tieBreakToA = false
end

local function _skillRating(player: Player): number
	local stats = _deps.getStats(player)
	local kills = if stats then stats.Kills else 0
	local deaths = if stats then stats.Deaths else 0
	return (kills + RATING_PRIOR) / (deaths + RATING_PRIOR)
end

local function _forEachActiveReal(callback: (player: Player, side: TeamSide) -> ())
	for _, player in Players:GetPlayers() do
		local session = _deps.sessions[player.UserId]
		local side = if session then session.team else nil
		if session and side and (session.inMenu == false or session.pendingSpawn) then
			callback(player, side)
		end
	end
end

function TeamAssignmentService:CountActiveRealAssignments(): (number, number)
	local a = 0
	local b = 0
	_forEachActiveReal(function(_, side)
		if side == "A" then
			a += 1
		else
			b += 1
		end
	end)

	return a, b
end

-- Fuerza estimada de cada equipo con los bots que rellenarán sus huecos.
local function _teamStrengths(): (number, number)
	local countA, countB = TeamAssignmentService:CountActiveRealAssignments()
	local cap = _deps.teamSizeTarget
	local strengthA = math.max(0, cap - countA) * BOT_RATING
	local strengthB = math.max(0, cap - countB) * BOT_RATING
	_forEachActiveReal(function(player, side)
		if side == "A" then
			strengthA += _skillRating(player)
		else
			strengthB += _skillRating(player)
		end
	end)

	return strengthA, strengthB
end

local function _pickTeamByScoreTieBreak(): TeamSide
	local scoreA = _deps.getRoundScoreA()
	local scoreB = _deps.getRoundScoreB()
	if scoreA < scoreB then
		return "A"
	end
	if scoreB < scoreA then
		return "B"
	end

	_tieBreakToA = not _tieBreakToA
	return if _tieBreakToA then "A" else "B"
end

-- INVARIANTE: yield-free. Es la sección crítica del debounce de MatchService._onRequestJoinMatch;
-- un yield permitiría doble-spawn.
function TeamAssignmentService:PickBalancedTeam(userId: number): TeamSide?
	local session = _deps.sessions[userId]
	if not session then
		return nil
	end

	local assigned = session.team
	local countA, countB = self:CountActiveRealAssignments()
	local cap = _deps.teamSizeTarget

	if assigned then
		if assigned == "A" and countA < cap then
			return "A"
		elseif assigned == "B" and countB < cap then
			return "B"
		elseif assigned == "A" and countB < cap then
			session.team = "B"
			return "B"
		elseif assigned == "B" and countA < cap then
			session.team = "A"
			return "A"
		end

		return nil
	end

	local selected: TeamSide
	local canJoinA = countA < cap
	local canJoinB = countB < cap

	if canJoinA and canJoinB then
		-- El que entra sustituye a un bot en cualquiera de los dos equipos, así
		-- que equilibra más yendo al más débil.
		local strengthA, strengthB = _teamStrengths()
		if strengthA < strengthB then
			selected = "A"
		elseif strengthB < strengthA then
			selected = "B"
		else
			selected = _pickTeamByScoreTieBreak()
		end
	elseif canJoinA then
		selected = "A"
	elseif canJoinB then
		selected = "B"
	else
		return nil
	end

	session.team = selected
	return selected
end

return TeamAssignmentService
