--!strict

local SpawnSelector = {}

local DISTANCE_EPSILON = 0.001

local W_FOV_PENALTY = 50
local W_DEATH_PENALTY = 30
local DEATH_PENALTY_WINDOW = 8
local FOV_DOT_THRESHOLD = 0.7
local ALLY_PROXIMITY_RADIUS = 30
local ALLY_BONUS_PER_NEARBY = 10

export type SpawnContext = {
	enemyPositions: { Vector3 },
	enemyLookVectors: { Vector3 },
	allyPositions: { Vector3 },
	recentDeaths: { [BasePart]: number },
	now: number,
}

local function _pickRandomSpawn(spawnPoints: { BasePart }): BasePart?
	if #spawnPoints == 0 then
		return nil
	end

	return spawnPoints[math.random(1, #spawnPoints)]
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

	if not useIntelligentSpawning or #context.enemyPositions == 0 then
		return _pickRandomSpawn(spawnPoints)
	end

	local bestScore = -math.huge
	local bestCandidates = {} :: { BasePart }

	for _, spawnPoint in spawnPoints do
		if spawnPoint.Parent == nil then
			continue
		end

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
		return _pickRandomSpawn(spawnPoints)
	end

	return bestCandidates[math.random(1, #bestCandidates)]
end

return table.freeze(SpawnSelector)
