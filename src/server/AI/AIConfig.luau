--!strict

export type AIConfigType = {
	BotNamePrefix: string,
	SpawnHeightOffset: number,
	DefaultTeamSizeTarget: number,
}

local AIConfig: AIConfigType = {
	BotNamePrefix = "Bot",
	SpawnHeightOffset = 3,
	DefaultTeamSizeTarget = 6,
}

return table.freeze(AIConfig)
