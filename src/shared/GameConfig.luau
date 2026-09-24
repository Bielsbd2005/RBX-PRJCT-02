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
	AssistMinDamage: number,
	AssistWindow: number,
	ShotBroadcastRange: number,
	ShotBroadcastLodDistance: number,
	ShotBroadcastLodDivisor: number,
	MatchEndMinSeconds: number,
	MatchEndMinContribution: number,
	DailyPlayedCashTiers: { { UpTo: number, Factor: number } },
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
	-- en el mismo número de kills CON la mezcla real de headshots y asistencias (no con
	-- kills puras): si se cambia uno, recalcular el otro con ActionRewards. Son el tope de una ronda COMPLETA (MaxRoundDuration):
	-- KillRewardsService los devenga con el reloj de CADA JUGADOR (desde su primera entrada a la
	-- ronda), para que ni la ronda corta ni entrar tarde den el cupo entero.
	-- MatchXPCap mide también el cupo del XP de pase, que lleva contador aparte
	-- (KillRewardsService, _tryConsumeBattlePassXP).
	MatchCashCap = 500,
	MatchXPCap = 1000,
	-- Fracción del cap disponible en el segundo 0: sin colchón, las primeras kills
	-- de un buen arranque no pagarían. Acotada por arriba por el farmeo (se cobra
	-- entera en cada ronda): no subirla sin simular el XP/h del caso peor (solo
	-- contra bots, rondas cortadas por puntos).
	MatchCapGraceFraction = 0.05,
	-- Asistencia: daño mínimo a la víctima, con el último impacto dentro de la ventana
	-- (segundos) previa a su muerte. El suelo evita cobrar por una bala suelta a un bot
	-- que luego remata otro.
	AssistMinDamage = 25,
	AssistWindow = 6,
	-- Cada WeaponFired que recibe un cliente simula la bala completa. Por distancia
	-- observador↔tirador (jugador o bot): > Range no se envía; <= LodDistance, todo. Entre
	-- medias, si se sabe si el disparo acierta (bots), 1 de cada LodDivisor aciertos y
	-- ningún fallo; si no se sabe (jugadores), todo.
	ShotBroadcastRange = 300,
	ShotBroadcastLodDistance = 60,
	ShotBroadcastLodDivisor = 2,
	-- Bonus de fin de partida (ResultsRewards): segundos EN PARTIDA (el lobby no cuenta) y
	-- kills + asistencias mínimos para cobrarlos. Se pagan escalados por esos segundos
	-- sobre MaxRoundDuration: la ronda corta no rinde más por hora.
	MatchEndMinSeconds = 120,
	MatchEndMinContribution = 3,
	-- Techo diario del Cash JUGADO (combate + bonus de fin de partida; diarias, pase,
	-- códigos y packs no cuentan). Tramos sobre lo ya cobrado hoy (día UTC), en orden:
	-- el primero cubre una sesión larga de tryhard; el resto frena macros y maratones.
	DailyPlayedCashTiers = {
		{ UpTo = 16000, Factor = 1 },
		{ UpTo = 20000, Factor = 0.5 },
		{ UpTo = math.huge, Factor = 0.1 },
	},
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
