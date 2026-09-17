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
}

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

function TeamAssignmentService:CountActiveRealAssignments(): (number, number)
	local a = 0
	local b = 0
	for _, player in Players:GetPlayers() do
		local session = _deps.sessions[player.UserId]
		local side = if session then session.team else nil
		if session and side and (session.inMenu == false or session.pendingSpawn) then
			if side == "A" then
				a += 1
			else
				b += 1
			end
		end
	end

	return a, b
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
		if countA < countB then
			selected = "A"
		elseif countB < countA then
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
