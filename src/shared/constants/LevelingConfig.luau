--!strict

local LevelingConfig = {}

LevelingConfig.BASE_XP_TO_NEXT_LEVEL = 100
LevelingConfig.XP_GROWTH_PER_LEVEL = 25

function LevelingConfig.GetXPToNextLevel(level: number): number
	local clampedLevel = math.max(0, math.floor(level))
	return LevelingConfig.BASE_XP_TO_NEXT_LEVEL + (clampedLevel * LevelingConfig.XP_GROWTH_PER_LEVEL)
end

return table.freeze(LevelingConfig)
