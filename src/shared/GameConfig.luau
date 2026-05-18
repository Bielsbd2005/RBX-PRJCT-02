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
	SpawnProtectionDuration: number,
	MinPlayersToStart: number,
	RealPlayerCapPerServer: number,
	TeamSizeTarget: number,
	TotalParticipantsTarget: number,
	MaxRoundDuration: number,
	WinScoreLimit: number,
	KillAttributionWindow: number,
	Teams: TeamsDefinition,
	Maps: { MapDefinition },
}

local GameConfig: GameConfigType = {
	VoteDuration = 4,
	MapLoadTimeout = 12,
	PregameCountdown = 5,
	EndResultsDuration = 10,
	RespawnCooldown = 1,
	-- Segundos de inmunidad (ForceField) tras spawn — aplica a jugadores y bots.
	-- El shield NO se rompe al disparar; expira solo por tiempo.
	SpawnProtectionDuration = 3,
	MinPlayersToStart = 1,
	RealPlayerCapPerServer = 6,
	TeamSizeTarget = 4,
	TotalParticipantsTarget = 8,
	MaxRoundDuration = 480,
	WinScoreLimit = 240,
	-- Ventana máxima entre el último daño y la muerte para acreditar el kill.
	-- Más allá de este tiempo, el kill se considera "muerte natural" / no atribuible.
	-- Consumida por MatchService (PvP) y AIService (bots) para mantener atribución uniforme.
	KillAttributionWindow = 2,

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
		{ Name = "Factory",  Modes = { "TeamDeathmatch" }, PlaceholderImage = "rbxassetid://138703710359327", UseIntelligentSpawning = true },
		{ Name = "Rooftops", Modes = { "TeamDeathmatch" }, PlaceholderImage = "rbxassetid://138703710359327", UseIntelligentSpawning = true },
	},
}

return table.freeze(GameConfig)
