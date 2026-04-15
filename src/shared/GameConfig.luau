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
}

export type GameConfigType = {
	VoteDuration: number,
	MapLoadTimeout: number,
	PregameCountdown: number,
	EndResultsDuration: number,
	RespawnCooldown: number,
	MinPlayersToStart: number,
	MaxRoundDuration: number,
	WinScoreLimit: number,
	Teams: TeamsDefinition,
	Maps: { MapDefinition },
}

local GameConfig: GameConfigType = {
	VoteDuration = 4,
	MapLoadTimeout = 12,
	PregameCountdown = 5,
	EndResultsDuration = 10,
	RespawnCooldown = 3,
	MinPlayersToStart = 1,
	MaxRoundDuration = 60,
	WinScoreLimit = 30,

	Teams = {
		A = {
			Name = "Alpha",
			Color = Color3.fromRGB(219, 68, 55),
		},
		B = {
			Name = "Bravo",
			Color = Color3.fromRGB(66, 133, 244),
		},
	},

	Maps = {
		{ Name = "Canyon",   Modes = { "TeamDeathmatch" }, PlaceholderImage = "rbxassetid://138703710359327" },
		{ Name = "Factory",  Modes = { "TeamDeathmatch" }, PlaceholderImage = "rbxassetid://138703710359327" },
		{ Name = "Rooftops", Modes = { "TeamDeathmatch" }, PlaceholderImage = "rbxassetid://138703710359327" },
	},
}

return table.freeze(GameConfig)
