--!strict

local SpawnSelector = {}

local DISTANCE_EPSILON = 0.001

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

local function _scoreSpawnPoint(spawnPoint: BasePart, enemyPositions: { Vector3 }): number
	local minDistance = math.huge
	for _, enemyPosition in enemyPositions do
		local distance = (spawnPoint.Position - enemyPosition).Magnitude
		if distance < minDistance then
			minDistance = distance
		end
	end

	return minDistance
end

function SpawnSelector.select(spawnPoints: { BasePart }, enemyPositions: { Vector3 }, useIntelligentSpawning: boolean): BasePart?
	if #spawnPoints == 0 then
		return nil
	end

	if not useIntelligentSpawning or #enemyPositions == 0 then
		return _pickRandomSpawn(spawnPoints)
	end

	local bestScore = -math.huge
	local bestCandidates = {} :: { BasePart }

	for _, spawnPoint in spawnPoints do
		if spawnPoint.Parent == nil then
			continue
		end

		local score = _scoreSpawnPoint(spawnPoint, enemyPositions)
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
