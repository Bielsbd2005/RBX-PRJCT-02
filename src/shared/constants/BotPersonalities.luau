--!strict
--[[
	BotPersonalities.luau
	Define los "tiers" de personalidad de bots para sesgar apariencia +
	stats fingidas (level, historicalKills).

	Distribución pensada como pirámide de población:
	  - La mayoría de bots son Noob/Casual (visten Default, level bajo).
	  - Pocos son Veteran/Whale (rarities altas, level alto, sombrero seguro).
	Así los ítems Legendary mantienen valor visual: salen tan raras en bots
	como en la base real de jugadores.

	Shared (no server-only) para que el cliente pueda inspeccionar el tier
	en el futuro (UI de career card) si se necesita.
]]

export type LevelRange = { min: number, max: number }
export type KillsRange = { min: number, max: number }
export type RaritySet = { [string]: boolean }

export type Personality = {
	id: string,
	weight: number,
	levelRange: LevelRange,
	historicalKillsRange: KillsRange,
	allowedRarities: RaritySet,
	hatProbability: number,
}

-- Caps actuales (juego recién lanzado): level máx 50, kills históricas máx 124.
-- Cuando la población real crezca, sube los topes y re-distribuye.
local BotPersonalities: { [string]: Personality } = {
	Noob = {
		id = "Noob",
		weight = 50,
		levelRange = { min = 1, max = 5 },
		historicalKillsRange = { min = 0, max = 10 },
		allowedRarities = { Common = true },
		hatProbability = 0.1,
	},
	Casual = {
		id = "Casual",
		weight = 30,
		levelRange = { min = 5, max = 15 },
		historicalKillsRange = { min = 10, max = 35 },
		allowedRarities = { Common = true, Uncommon = true },
		hatProbability = 0.4,
	},
	Veteran = {
		id = "Veteran",
		weight = 15,
		levelRange = { min = 15, max = 30 },
		historicalKillsRange = { min = 35, max = 80 },
		allowedRarities = { Common = true, Uncommon = true, Rare = true, Epic = true },
		hatProbability = 0.75,
	},
	Whale = {
		id = "Whale",
		weight = 5,
		levelRange = { min = 30, max = 50 },
		historicalKillsRange = { min = 80, max = 124 },
		allowedRarities = { Common = true, Uncommon = true, Rare = true, Epic = true, Legendary = true },
		hatProbability = 1.0,
	},
}

return table.freeze(BotPersonalities)
