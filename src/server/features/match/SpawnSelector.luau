--!strict

local SpawnSelector = {}

local DISTANCE_EPSILON = 0.001

local W_FOV_PENALTY = 50
local W_DEATH_PENALTY = 30
local DEATH_PENALTY_WINDOW = 8
local FOV_DOT_THRESHOLD = 0.7
local ALLY_PROXIMITY_RADIUS = 30
local ALLY_BONUS_PER_NEARBY = 10

-- Spawn-uniqueness guards. Burst spawns (round start: up to 8 bots + players in
-- the same frames) pick their points before any body has been teleported, so
-- physical occupancy alone can't prevent two entities choosing the same point —
-- the reuse window covers the gap between selection and the body landing.
local SPAWN_REUSE_WINDOW = 2
local OCCUPIED_RADIUS = 6

export type SpawnContext = {
	enemyPositions: { Vector3 },
	enemyLookVectors: { Vector3 },
	allyPositions: { Vector3 },
	recentDeaths: { [BasePart]: number },
	-- time() at which each spawn point was last handed out (players and bots
	-- share one map). Points used within SPAWN_REUSE_WINDOW are unavailable.
	recentSpawnUses: { [BasePart]: number },
	now: number,
}

local function _pickRandomSpawn(spawnPoints: { BasePart }): BasePart?
	if #spawnPoints == 0 then
		return nil
	end

	return spawnPoints[math.random(1, #spawnPoints)]
end

-- A point is unavailable if it was handed out within the reuse window or if
-- any live combatant (ally or enemy) is standing on it. The ally check matters:
-- the scoring below gives a BONUS for ally proximity, so without it a point
-- with a teammate standing on top would score best.
local function _isAvailable(spawnPoint: BasePart, context: SpawnContext): boolean
	local usedAt = context.recentSpawnUses[spawnPoint]
	if usedAt and (context.now - usedAt) < SPAWN_REUSE_WINDOW then
		return false
	end

	local spawnPos = spawnPoint.Position
	for _, enemyPos in context.enemyPositions do
		if (spawnPos - enemyPos).Magnitude < OCCUPIED_RADIUS then
			return false
		end
	end
	for _, allyPos in context.allyPositions do
		if (spawnPos - allyPos).Magnitude < OCCUPIED_RADIUS then
			return false
		end
	end

	return true
end

-- Returns the spawn points usable right now. Falls back to every point still
-- in the map when the filter empties the list (small maps / heavy churn):
-- degrading to "possibly shared point" beats failing the spawn.
local function _collectAvailable(spawnPoints: { BasePart }, context: SpawnContext): { BasePart }
	local available = {} :: { BasePart }
	for _, spawnPoint in spawnPoints do
		if spawnPoint.Parent ~= nil and _isAvailable(spawnPoint, context) then
			table.insert(available, spawnPoint)
		end
	end

	if #available == 0 then
		for _, spawnPoint in spawnPoints do
			if spawnPoint.Parent ~= nil then
				table.insert(available, spawnPoint)
			end
		end
	end

	return available
end

local function _isBetterScore(score: number, bestScore: number): boolean
	return score > (bestScore + DISTANCE_EPSILON)
end

local function _isTieScore(score: number, bestScore: number): boolean
	return math.abs(score - bestScore) <= DISTANCE_EPSILON
end

local function _scoreSpawnPoint(spawnPoint: BasePart, context: SpawnContext): number
	local spawnPos = spawnPoint.Position

	local minEnemyDistance = math.huge
	local fovPenalty = 0
	for index, enemyPos in context.enemyPositions do
		local toSpawn = spawnPos - enemyPos
		local distance = toSpawn.Magnitude
		if distance < minEnemyDistance then
			minEnemyDistance = distance
		end

		local lookVector = context.enemyLookVectors[index]
		if lookVector and distance > DISTANCE_EPSILON then
			local dot = lookVector:Dot(toSpawn / distance)
			if dot > FOV_DOT_THRESHOLD then
				fovPenalty += W_FOV_PENALTY
			end
		end
	end

	local allyBonus = 0
	for _, allyPos in context.allyPositions do
		if (spawnPos - allyPos).Magnitude < ALLY_PROXIMITY_RADIUS then
			allyBonus += ALLY_BONUS_PER_NEARBY
		end
	end

	local deathPenalty = 0
	local deathTime = context.recentDeaths[spawnPoint]
	if deathTime and (context.now - deathTime) < DEATH_PENALTY_WINDOW then
		deathPenalty = W_DEATH_PENALTY
	end

	if minEnemyDistance == math.huge then
		minEnemyDistance = 0
	end

	return minEnemyDistance + allyBonus - fovPenalty - deathPenalty
end

function SpawnSelector.select(spawnPoints: { BasePart }, context: SpawnContext, useIntelligentSpawning: boolean): BasePart?
	if #spawnPoints == 0 then
		return nil
	end

	-- The availability filter applies to BOTH paths: even random selection
	-- (maps without intelligent spawning, or no enemies alive yet) must not
	-- hand the same point to two entities in a burst.
	local available = _collectAvailable(spawnPoints, context)
	if #available == 0 then
		return _pickRandomSpawn(spawnPoints)
	end

	if not useIntelligentSpawning or #context.enemyPositions == 0 then
		return _pickRandomSpawn(available)
	end

	local bestScore = -math.huge
	local bestCandidates = {} :: { BasePart }

	for _, spawnPoint in available do
		local score = _scoreSpawnPoint(spawnPoint, context)
		if _isBetterScore(score, bestScore) then
			bestScore = score
			table.clear(bestCandidates)
			table.insert(bestCandidates, spawnPoint)
		elseif _isTieScore(score, bestScore) then
			table.insert(bestCandidates, spawnPoint)
		end
	end

	if #bestCandidates == 0 then
		return _pickRandomSpawn(available)
	end

	return bestCandidates[math.random(1, #bestCandidates)]
end

return table.freeze(SpawnSelector)
