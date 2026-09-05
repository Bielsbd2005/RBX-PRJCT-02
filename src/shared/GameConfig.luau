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
	-- Clave centinela para la opción "Random" en la votación (no es un mapa real).
	-- El cliente la envía como mapName al votar Random; el servidor la resuelve a
	-- un mapa concreto aleatorio entre las opciones al cerrar la votación.
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
	-- Segundos de inmunidad (ForceField) tras spawn — aplica a jugadores y bots.
	-- El shield NO se rompe al disparar; expira solo por tiempo.
	SpawnProtectionDuration = 2,
	MinPlayersToStart = 1,
	RealPlayerCapPerServer = 6,
	TeamSizeTarget = 4,
	TotalParticipantsTarget = 8,
	MaxRoundDuration = 480,
	-- Puntos para ganar. 1 punto = 1 muerte del equipo rival, y cuentan
	-- jugadores y bots por igual. Con equipos de 4 y el ritmo de diseno
	-- (10-15 kills por jugador y ronda) un equipo hace ~48 puntos en los
	-- 480s completos, asi que el 240 anterior era inalcanzable: TODAS las
	-- rondas acababan por reloj y el marcador no era un objetivo, solo un
	-- contador. A 75 solo llega el equipo que domina (~19 kills por jugador,
	-- 1,5x el ritmo normal), que es justo el caso que conviene cortar; la
	-- ronda pareja sigue yendo al reloj. Si se toca este numero hay que
	-- mover RESULTS_PRELOAD_SCORE_LEAD (cliente) en la misma proporcion.
	-- Recalibrar con el p95 real de puntos por ronda cuando haya telemetria.
	WinScoreLimit = 75,
	-- Ventana máxima entre el último daño y la muerte para acreditar el kill.
	-- Más allá de este tiempo, el kill se considera "muerte natural" / no atribuible.
	-- Consumida por MatchService (PvP) y AIService (bots) para mantener atribución uniforme.
	KillAttributionWindow = 2,
	-- Caps anti-farm POR PARTIDA, calibrados para morder en el MISMO punto
	-- (~33 kills con headshot: Cash 15/kill → 500; XP 40/kill → ~1.300). Son un
	-- backstop contra feeding/farmeo, no un límite de juego normal (una partida
	-- buena ronda las 10-15 kills). El XPCap anterior (800) saltaba a las 20
	-- kills — castigaba partidas reales buenas mientras el CashCap ni se
	-- inmutaba. Si se cambia uno hay que recalcular el otro con los rates de
	-- ActionRewards; tras el launch, recalibrar ambos con el p95 real de
	-- kills/partida del dashboard.
	--
	-- OJO: estos dos valores son el tope de una ronda COMPLETA
	-- (MaxRoundDuration). MatchService los DEVENGA con el reloj en vez de
	-- concederlos de golpe. Hace falta desde que WinScoreLimit baja a 75:
	-- las palizas ahora acaban antes de los 480s, y con un cap plano cada
	-- ronda corta habria regalado el cupo entero de una larga. Mas rondas
	-- por hora con el mismo cupo = mas techo de farmeo por hora, justo lo
	-- contrario de lo que este cap existe para frenar.
	MatchCashCap = 500,
	MatchXPCap = 1300,
	-- Fraccion del cap ya disponible en el segundo 0 de la ronda. Sin este
	-- colchon, el cupo devengado en los primeros segundos es menor que lo que
	-- paga una sola kill, y un buen arranque veria kills alternas sin premio:
	-- se lee como bug, no como anti-farm. 0.08 = ~3 kills de margen.
	--
	-- El valor esta acotado por ARRIBA por el farmeo, no por el confort: el
	-- colchon se reparte entero en CADA ronda, asi que cuanto mas corta sea la
	-- ronda mas veces por hora se cobra. Simulado sobre el caso peor (jugador
	-- solo contra bots, ronda cortada por puntos a los ~375s), 0.08 deja el
	-- techo en ~9.580 XP/h contra los ~9.493 XP/h del cap plano anterior, es
	-- decir plano; 0.15 ya lo subia a ~9.854. No subir de 0.08 sin rehacer esa
	-- cuenta. Holgura de sobra para el juego normal: el ritmo de diseno son
	-- ~44 XP/min y el devengo va a ~149 XP/min.
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
