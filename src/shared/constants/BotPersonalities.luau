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

-- D1: per-tier combat skill. Every field is optional — missing fields fall
-- back to the global BotConfig.Combat profile, so a personality only declares
-- what makes it different. JumpChanceMult is a multiplier (not an absolute)
-- because the base JumpChance is intentionally asymmetric per target type
-- (VsPlayer 0.03 vs VsBot 0.4) and the personality should scale both.
export type CombatOverrides = {
	Precision: number?,
	ReactionDelayMin: number?,
	ReactionDelayMax: number?,
	CombatPauseChance: number?,
	CombatPauseMin: number?,
	CombatPauseMax: number?,
	CombatStepMin: number?,
	CombatStepMax: number?,
	JumpChanceMult: number?,
}

export type Personality = {
	id: string,
	weight: number,
	levelRange: LevelRange,
	historicalKillsRange: KillsRange,
	allowedRarities: RaritySet,
	hatProbability: number,
	combat: CombatOverrides?,
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
		-- Aims poorly, reacts slowly, stands still more, barely jumps.
		combat = {
			Precision = 25,
			ReactionDelayMin = 0.3,
			ReactionDelayMax = 0.55,
			CombatPauseChance = 0.6,
			JumpChanceMult = 0.5,
		},
	},
	Casual = {
		id = "Casual",
		weight = 30,
		levelRange = { min = 5, max = 15 },
		historicalKillsRange = { min = 10, max = 35 },
		allowedRarities = { Common = true, Uncommon = true },
		hatProbability = 0.4,
		-- Slightly below the global baseline (Precision 40, 0.15–0.35s).
		combat = {
			Precision = 35,
			ReactionDelayMin = 0.2,
			ReactionDelayMax = 0.4,
			CombatPauseChance = 0.45,
		},
	},
	Veteran = {
		id = "Veteran",
		weight = 15,
		levelRange = { min = 15, max = 30 },
		historicalKillsRange = { min = 35, max = 80 },
		allowedRarities = { Common = true, Uncommon = true, Rare = true, Epic = true },
		hatProbability = 0.75,
		-- Sharper aim, faster reaction, strafes more than it pauses.
		combat = {
			Precision = 50,
			ReactionDelayMin = 0.12,
			ReactionDelayMax = 0.25,
			CombatPauseChance = 0.3,
			CombatStepMin = 0.6,
			CombatStepMax = 1.6,
			JumpChanceMult = 1.3,
		},
	},
	Whale = {
		id = "Whale",
		weight = 5,
		levelRange = { min = 30, max = 50 },
		historicalKillsRange = { min = 80, max = 124 },
		allowedRarities = { Common = true, Uncommon = true, Rare = true, Epic = true, Legendary = true },
		hatProbability = 1.0,
		-- The rare "scary" bot: best aim, near-instant reaction, very mobile.
		combat = {
			Precision = 60,
			ReactionDelayMin = 0.08,
			ReactionDelayMax = 0.18,
			CombatPauseChance = 0.2,
			CombatStepMin = 0.7,
			CombatStepMax = 1.8,
			JumpChanceMult = 1.6,
		},
	},
}

return table.freeze(BotPersonalities)
