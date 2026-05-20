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

export type StuckThresholds = {
	lateral: number,
	repath: number,
	jump: number,
	teleport: number,
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
		FOVDegrees: number,
		ReactionDelayMin: number,
		ReactionDelayMax: number,
		MissSpreadDegMin: number,
		MissSpreadDegMax: number,
		CombatPauseChance: number,
		CombatPauseMin: number,
		CombatPauseMax: number,
		CombatStepMin: number,
		CombatStepMax: number,
		VsPlayer: CombatTargetProfile,
		VsBot: CombatTargetProfile,
	},
	Pathfinding: {
		AgentRadius: number,
		AgentHeight: number,
		AgentCanJump: boolean,
		AgentMaxSlope: number,
		WaypointSpacing: number,
		MinComputeInterval: number,
		PostBlockedCooldown: number,
	},
	Navigation: {
		RoamMinDist: number,
		RoamMaxDist: number,
		SpawnMinDist: number,
		SpawnMaxDist: number,
		StuckThresholds: StuckThresholds,
		StuckMoveEpsilon: number,
		QueueRequestsPerHeartbeat: number,
		MaxInFlightCompute: number,
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

		-- PR1.5: combat feel polish
		FOVDegrees = 150,          -- cono frontal total (75° por lado). Solo aplica a detección normal — retaliation bypassa
		ReactionDelayMin = 0.15,   -- seg: delay aleatorio entre adquirir target y primer disparo
		ReactionDelayMax = 0.35,
		MissSpreadDegMin = 3,      -- spread angular para misses visibles (bullet pasa al lado)
		MissSpreadDegMax = 8,
		CombatPauseChance = 0.4,   -- 40% pause, 60% step — punto medio: 60% torreta era mucho, 25% era hiperactivo
		CombatPauseMin = 0.3,      -- pausas perceptibles pero breves
		CombatPauseMax = 0.9,
		CombatStepMin = 0.5,
		CombatStepMax = 1.4,

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
		AgentRadius = 2,             -- empírico: 2.5 generaba paths fallidos en pasillos estrechos
		AgentHeight = 5,
		AgentCanJump = true,
		AgentMaxSlope = 45,
		WaypointSpacing = 4,         -- default Roblox; 2 producía giros bruscos en cada wp
		MinComputeInterval = 0.5,    -- empírico: 1.0s hacía CHASE lento; 0.5 matchea throttle original
		PostBlockedCooldown = 0.3,   -- cooldown tras Path.Blocked antes de recomputar
	},

	Navigation = {
		RoamMinDist = 20,
		RoamMaxDist = 80,
		SpawnMinDist = 30,
		SpawnMaxDist = 120,
		StuckThresholds = { lateral = 1.0, repath = 2.0, jump = 4.0, teleport = 8.0 },
		StuckMoveEpsilon = 0.5,        -- studs/seg debajo de los cuales contamos stuck
		QueueRequestsPerHeartbeat = 2, -- ComputeAsync globales por Heartbeat
		MaxInFlightCompute = 4,        -- tope de ComputeAsync simultáneos (semáforo). El budget por Heartbeat sólo regula enqueues; sin tope concurrente un repath storm puede arrancar N coroutines en paralelo.
	},

	Lifecycle = {
		RagdollCleanupDelay = 5,
	},
}

return table.freeze(BotConfig)
