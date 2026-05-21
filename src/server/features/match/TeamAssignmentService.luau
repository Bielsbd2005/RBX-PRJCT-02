--!strict
--[[
	TeamAssignmentService.luau
	Lógica de asignación de equipos balanceados. Extraído de MatchService como
	parte del split estructural (audit AAA). Sigue el patrón de
	HealthPickupService: estado propio (`_tieBreakToA`) + predicates inyectados
	en `Start({...})` para leer estado externo sin acoplarse a MatchService.

	API:
		TeamAssignmentService:Start({
			teamByUserId, isInMenuByUserId, pendingSpawnByUserId,
			getRoundScoreA, getRoundScoreB, teamSizeTarget,
		})
		TeamAssignmentService:CountActiveRealAssignments() -> (number, number)
		TeamAssignmentService:PickBalancedTeam(userId) -> ("A" | "B")?

	`_pickBalancedTeam` debe permanecer **yield-free** — es la sección crítica
	del debounce de `_onRequestJoinMatch`; un yield permitiría doble-spawn.
]]

local Players = game:GetService("Players")

type TeamSide = "A" | "B"

type Deps = {
	-- Tabla compartida con MatchService — escribimos a ella cuando asignamos.
	teamByUserId: { [number]: TeamSide },
	-- Predicates de estado externo (no copiamos, leemos vía función).
	isInMenuByUserId: { [number]: boolean? },
	pendingSpawnByUserId: { [number]: boolean? },
	-- Score actual del round para tie-break determinístico.
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
	local connectedByUserId = {} :: { [number]: true }
	for _, player in Players:GetPlayers() do
		connectedByUserId[player.UserId] = true
	end

	local a = 0
	local b = 0
	for userId, side in _deps.teamByUserId do
		local isConnected = connectedByUserId[userId] == true
		local isActiveOrPending = (_deps.isInMenuByUserId[userId] == false)
			or (_deps.pendingSpawnByUserId[userId] == true)
		if isConnected and isActiveOrPending then
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

-- INVARIANT: yield-free.
function TeamAssignmentService:PickBalancedTeam(userId: number): TeamSide?
	local assigned = _deps.teamByUserId[userId]
	local countA, countB = self:CountActiveRealAssignments()
	local cap = _deps.teamSizeTarget

	if assigned then
		if assigned == "A" and countA < cap then
			return "A"
		elseif assigned == "B" and countB < cap then
			return "B"
		elseif assigned == "A" and countB < cap then
			_deps.teamByUserId[userId] = "B"
			return "B"
		elseif assigned == "B" and countA < cap then
			_deps.teamByUserId[userId] = "A"
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

	_deps.teamByUserId[userId] = selected
	return selected
end

return TeamAssignmentService
