--!strict

local PrestigeConfig = {}

PrestigeConfig.DEFAULT_BADGE_ASSET_ID = 125359854033234

export type PrestigeDefinition = {
	UnlockLevel: number,
	BadgeAssetId: number,
	Requirement1: {
		Title: string,
		StatKey: string,
		Required: number,
	},
	Requirement2: {
		Title: string,
		StatKey: string,
		Required: number,
	},
}

local DEFINITIONS: { [number]: PrestigeDefinition } = {
	[0] = {
		UnlockLevel = 0,
		BadgeAssetId = PrestigeConfig.DEFAULT_BADGE_ASSET_ID,
		Requirement1 = {
			Title = "Kills needed",
			StatKey = "Kills",
			Required = 0,
		},
		Requirement2 = {
			Title = "Wins needed",
			StatKey = "Wins",
			Required = 0,
		},
	},
	[1] = {
		UnlockLevel = 20,
		BadgeAssetId = 125359854033234,
		Requirement1 = {
			Title = "Kills needed",
			StatKey = "Kills",
			Required = 20,
		},
		Requirement2 = {
			Title = "Wins needed",
			StatKey = "Wins",
			Required = 5,
		},
	},
	[2] = {
		UnlockLevel = 35,
		BadgeAssetId = 73304953694237,
		Requirement1 = {
			Title = "Kills needed",
			StatKey = "Kills",
			Required = 60,
		},
		Requirement2 = {
			Title = "Wins needed",
			StatKey = "Wins",
			Required = 12,
		},
	},
	[3] = {
		UnlockLevel = 50,
		BadgeAssetId = 14500000003,
		Requirement1 = {
			Title = "Kills needed",
			StatKey = "Kills",
			Required = 120,
		},
		Requirement2 = {
			Title = "Wins needed",
			StatKey = "Wins",
			Required = 25,
		},
	},
	[4] = {
		UnlockLevel = 70,
		BadgeAssetId = 14500000004,
		Requirement1 = {
			Title = "Kills needed",
			StatKey = "Kills",
			Required = 220,
		},
		Requirement2 = {
			Title = "Wins needed",
			StatKey = "Wins",
			Required = 45,
		},
	},
	[5] = {
		UnlockLevel = 95,
		BadgeAssetId = 14500000005,
		Requirement1 = {
			Title = "Kills needed",
			StatKey = "Kills",
			Required = 360,
		},
		Requirement2 = {
			Title = "Wins needed",
			StatKey = "Wins",
			Required = 75,
		},
	},
	[6] = {
		UnlockLevel = 125,
		BadgeAssetId = 14500000006,
		Requirement1 = {
			Title = "Kills needed",
			StatKey = "Kills",
			Required = 540,
		},
		Requirement2 = {
			Title = "Wins needed",
			StatKey = "Wins",
			Required = 110,
		},
	},
	[7] = {
		UnlockLevel = 160,
		BadgeAssetId = 14500000007,
		Requirement1 = {
			Title = "Kills needed",
			StatKey = "Kills",
			Required = 760,
		},
		Requirement2 = {
			Title = "Wins needed",
			StatKey = "Wins",
			Required = 150,
		},
	},
}

PrestigeConfig.MAX_PRESTIGE = 7

function PrestigeConfig.GetMaxPrestige(): number
	return PrestigeConfig.MAX_PRESTIGE
end

function PrestigeConfig.GetDefinition(prestigeLevel: number): PrestigeDefinition?
	local clampedLevel = math.max(0, math.floor(prestigeLevel))
	return DEFINITIONS[clampedLevel]
end

function PrestigeConfig.GetNextDefinition(currentPrestige: number): PrestigeDefinition?
	local nextPrestige = math.max(0, math.floor(currentPrestige)) + 1
	if nextPrestige > PrestigeConfig.MAX_PRESTIGE then
		return nil
	end

	return DEFINITIONS[nextPrestige]
end

function PrestigeConfig.GetBadgeAssetId(prestigeLevel: number): number
	local definition = PrestigeConfig.GetDefinition(prestigeLevel)
	if not definition then
		return 0
	end

	return definition.BadgeAssetId
end

function PrestigeConfig.GetCurrentBadgeAssetId(currentPrestige: number): number
	return PrestigeConfig.GetBadgeAssetId(currentPrestige)
end

return table.freeze(PrestigeConfig)
