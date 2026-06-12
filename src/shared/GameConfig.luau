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
	-- Gamepass de Roblox que otorga VIP (bonus de cash de fin de partida). 0 =
	-- sin configurar → nadie es VIP (el bonus se muestra siempre "Locked").
	-- Pegar acá el id real del gamepass.
	VIPGamePassId: number,
	Teams: TeamsDefinition,
	Maps: { MapDefinition },
}

local GameConfig: GameConfigType = {
	VoteDuration = 4,
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
	WinScoreLimit = 240,
	-- Ventana máxima entre el último daño y la muerte para acreditar el kill.
	-- Más allá de este tiempo, el kill se considera "muerte natural" / no atribuible.
	-- Consumida por MatchService (PvP) y AIService (bots) para mantener atribución uniforme.
	KillAttributionWindow = 2,
	MatchCashCap = 500,
	MatchXPCap = 800,
	-- TODO: pegar el id real del gamepass VIP de Roblox. 0 = sin configurar.
	VIPGamePassId = 0,

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
		{ Name = "Canyon",   PlaceholderImage = "rbxassetid://138703710359327", UseIntelligentSpawning = true },
		{ Name = "Factory",  PlaceholderImage = "rbxassetid://138703710359327", UseIntelligentSpawning = true },
		{ Name = "Rooftops", PlaceholderImage = "rbxassetid://138703710359327", UseIntelligentSpawning = true },
	},
}

return table.freeze(GameConfig)
