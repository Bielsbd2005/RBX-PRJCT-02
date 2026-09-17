--!strict
--[[
	Tiers de personalidad de bots: sesgan apariencia, nivel fingido y habilidad.
	Pirámide de población (weight): la mayoría Noob/Casual con ítems Common, pocos
	con rarezas altas, para que los Legendary sean tan raros en bots como en jugadores.
]]

export type LevelRange = { min: number, max: number }
export type RaritySet = { [string]: boolean }

-- Campos opcionales: lo que falte sale de BotConfig.Combat. JumpChanceMult es
-- multiplicador porque el JumpChance base es distinto contra jugadores y contra bots.
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
	allowedRarities: RaritySet,
	-- Banner de la tarjeta de muerte: no-Default con probabilidad bannerProbability
	-- y de las rarezas de bannerRarities (exacto: vacío no significa "todas"; si no
	-- hay banner de esas rarezas, Default).
	bannerProbability: number,
	bannerRarities: RaritySet,
	hatProbability: number,
	combat: CombatOverrides?,
}

local BotPersonalities: { [string]: Personality } = {
	Noob = {
		id = "Noob",
		weight = 50,
		levelRange = { min = 1, max = 5 },
		allowedRarities = { Common = true },
		bannerProbability = 0,
		bannerRarities = {},
		hatProbability = 0.1,
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
		allowedRarities = { Common = true },
		bannerProbability = 0,
		bannerRarities = {},
		hatProbability = 0.4,
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
		allowedRarities = { Common = true, Rare = true, Epic = true },
		bannerProbability = 0.15,
		bannerRarities = { Rare = true, Epic = true },
		hatProbability = 0.75,
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
		allowedRarities = { Common = true, Rare = true, Epic = true, Legendary = true },
		bannerProbability = 0.4,
		bannerRarities = { Epic = true, Legendary = true },
		hatProbability = 1.0,
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
