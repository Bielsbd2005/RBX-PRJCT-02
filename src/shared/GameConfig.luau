--!strict

export type TeamDefinition = {
	Name: string,
	Color: Color3,
}

export type TeamsDefinition = {
	A: TeamDefinition,
	B: TeamDefinition,
}

export type GameMode = "TeamDeathmatch"

export type MapDefinition = {
	Name: string,
	Modes: { GameMode },
	PlaceholderImage: string,
	UseIntelligentSpawning: boolean?,
}

export type GameConfigType = {
	VoteDuration: number,
	MapLoadTimeout: number,
	PregameCountdown: number,
	EndResultsDuration: number,
	RespawnCooldown: number,
	MinPlayersToStart: number,
	RealPlayerCapPerServer: number,
	TeamSizeTarget: number,
	TotalParticipantsTarget: number,
	MaxRoundDuration: number,
	WinScoreLimit: number,
	KillCamDuration: number,
	Teams: TeamsDefinition,
	Maps: { MapDefinition },
}

local GameConfig: GameConfigType = {
	VoteDuration = 4,
	MapLoadTimeout = 12,
	PregameCountdown = 5,
	EndResultsDuration = 10,
	RespawnCooldown = 5,
	KillCamDuration = 5,
	MinPlayersToStart = 1,
	RealPlayerCapPerServer = 6,
	TeamSizeTarget = 4,
	TotalParticipantsTarget = 8,
	MaxRoundDuration = 3,
	WinScoreLimit = 30,

	Teams = {
		A = {
			Name = "TeamA",
			Color = Color3.fromRGB(219, 68, 55),
		},
		B = {
			Name = "TeamB",
			Color = Color3.fromRGB(66, 133, 244),
		},
	},

	Maps = {
		{ Name = "Canyon",   Modes = { "TeamDeathmatch" }, PlaceholderImage = "rbxassetid://138703710359327", UseIntelligentSpawning = true },
		{ Name = "Factory",  Modes = { "TeamDeathmatch" }, PlaceholderImage = "rbxassetid://138703710359327", UseIntelligentSpawning = false },
		{ Name = "Rooftops", Modes = { "TeamDeathmatch" }, PlaceholderImage = "rbxassetid://138703710359327", UseIntelligentSpawning = false },
	},
}

return table.freeze(GameConfig)
