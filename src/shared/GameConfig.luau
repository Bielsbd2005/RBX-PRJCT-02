--!strict

export type TeamDefinition = {
	Name: string,
	Color: Color3,
}

export type TeamsDefinition = {
	A: TeamDefinition,
	B: TeamDefinition,
}

export type MapDefinition = {
	Name: string,
	PlaceholderImage: string,
	UseIntelligentSpawning: boolean?,
}

export type GameConfigType = {
	VoteDuration: number,
	-- Centinela que el cliente envía como mapName al votar Random; el servidor lo
	-- resuelve a un mapa aleatorio de las opciones al cerrar la votación.
	RandomVoteKey: string,
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
	MatchCashCap: number,
	MatchXPCap: number,
	MatchCapGraceFraction: number,
	Teams: TeamsDefinition,
	Maps: { MapDefinition },
}

local GameConfig: GameConfigType = {
	VoteDuration = 3,
	RandomVoteKey = "__RANDOM__",
	EndResultsDuration = 10,
	RespawnCooldown = 1,
	-- Segundos de ForceField tras spawn (jugadores y bots); no se rompe al disparar.
	SpawnProtectionDuration = 2,
	MinPlayersToStart = 1,
	RealPlayerCapPerServer = 6,
	TeamSizeTarget = 4,
	TotalParticipantsTarget = 8,
	MaxRoundDuration = 480,
	-- 1 punto = 1 muerte rival (jugador o bot). Pensado para que solo el equipo que
	-- domina corte la ronda; la ronda pareja acaba por reloj.
	-- TODO: recalibrar con el p95 real de puntos por ronda de la telemetría.
	WinScoreLimit = 75,
	-- Segundos máximos entre el último daño y la muerte para acreditar el kill.
	-- La usan MatchService y AIService.
	KillAttributionWindow = 2,
	-- Caps anti-farm por partida, no un límite de juego normal. Ambos deben morder
	-- en el mismo número de kills: si se cambia uno, recalcular el otro con los
	-- rates de ActionRewards. Son el tope de una ronda COMPLETA (MaxRoundDuration):
	-- MatchService los devenga con el reloj para que las rondas cortas no den el cupo entero.
	MatchCashCap = 500,
	MatchXPCap = 1300,
	-- Fracción del cap disponible en el segundo 0: sin colchón, las primeras kills
	-- de un buen arranque no pagarían. Acotada por arriba por el farmeo (se cobra
	-- entera en cada ronda): no subirla sin simular el XP/h del caso peor (solo
	-- contra bots, rondas cortadas por puntos).
	MatchCapGraceFraction = 0.08,
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
		{ Name = "Sandtrap",   PlaceholderImage = "rbxassetid://130852161248051", UseIntelligentSpawning = true },
		{ Name = "Out of Stock",  PlaceholderImage = "rbxassetid://103886746608149", UseIntelligentSpawning = true },
		{ Name = "Under Construction", PlaceholderImage = "rbxassetid://74492386503921", UseIntelligentSpawning = true },
	},
}

return table.freeze(GameConfig)
