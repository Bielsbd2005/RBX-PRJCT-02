--!strict
--[[
	BotConfig.luau
	Fuente única de verdad para tuning de bots (IA).
	Antes vivía hardcoded en BotAI.luau y AI/init.luau.

	Diseño:
	  • Bloques semánticos (Movement, Combat, Pathfinding) para que un dashboard
	    externo pueda exponerlos sin acoplarse a la implementación.
	  • Combat separa VsPlayer / VsBot porque los bots son intencionalmente
	    menos letales contra humanos (UX) y muy letales entre sí (para que
	    el flow de kills entre bots ocurra rápido).
	  • Pathfinding refleja literalmente los AgentParams que consume
	    PathfindingService:CreatePath — añadir campos requiere coordinarlo
	    con el constructor de path en BotAI.
]]

export type CombatTargetProfile = {
	DamageMin: number,
	DamageMax: number,
	JumpChance: number,
}

export type BotConfigType = {
	Movement: {
		WalkSpeed: number,
		JumpHeight: number,
		WanderRadius: number,
		WaypointSmoothDistance: number,
	},
	Combat: {
		DetectRange: number,
		FireRate: number,
		Precision: number,
		VsPlayer: CombatTargetProfile,
		VsBot: CombatTargetProfile,
	},
	Pathfinding: {
		AgentRadius: number,
		AgentHeight: number,
		AgentCanJump: boolean,
		AgentMaxSlope: number,
	},
	Lifecycle: {
		RagdollCleanupDelay: number,
	},
}

local BotConfig: BotConfigType = {
	Movement = {
		WalkSpeed = 22,           -- igual que players (ShoulderCamera.normalWalkSpeed)
		JumpHeight = 5,
		WanderRadius = 40,
		WaypointSmoothDistance = 4,
	},

	Combat = {
		DetectRange = 35,
		FireRate = 0.1,           -- compartido VsPlayer/VsBot (igual que ShotCooldown del arma real)
		Precision = 40,           -- % de balas que impactan (0..100)
		VsPlayer = {
			DamageMin = 2,
			DamageMax = 5,
			JumpChance = 0.03,
		},
		VsBot = {
			DamageMin = 10,
			DamageMax = 25,
			JumpChance = 0.4,
		},
	},

	Pathfinding = {
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentMaxSlope = 45,
	},

	Lifecycle = {
		RagdollCleanupDelay = 5,
	},
}

return table.freeze(BotConfig)
