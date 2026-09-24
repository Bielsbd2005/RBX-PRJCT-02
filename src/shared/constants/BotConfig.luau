--!strict
--[[
	Tuning de bots. Combat separa VsPlayer / VsBot: a propósito poco letales contra
	humanos y muy letales entre sí para que las kills entre bots fluyan.
	Pathfinding refleja los AgentParams de PathfindingService:CreatePath: un campo
	nuevo hay que añadirlo también al constructor de path en BotAI.
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
		WaypointVerticalTolerance: number,
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
		StationaryPrecisionBonus: number,
		StationarySpeedThreshold: number,
		CombatPauseChance: number,
		CombatPauseMin: number,
		CombatPauseMax: number,
		CombatStepMin: number,
		CombatStepMax: number,
		MaxLosChecksPerEval: number,
		TargetMemoryGrace: number,
		RetaliationWindow: number,
		RetaliationRange: number,
		GraceRangeBonus: number,
		PlayerPriorityBias: number,
		FarPrecisionMult: number,
		MinEngageDistance: number,
		MaxEngageDistance: number,
		ChaseStandoffDistance: number,
		ChaseResumeDistance: number,
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
		RoamDestJitter: number,
		StuckThresholds: StuckThresholds,
		StuckMoveEpsilon: number,
		StuckSpawnGrace: number,
		QueueRequestsPerHeartbeat: number,
		MaxInFlightCompute: number,
	},
	Lifecycle: {
		RagdollCleanupDelay: number,
		RespawnDelay: number,
	},
}

local BotConfig: BotConfigType = {
	Movement = {
		WalkSpeed = 22,           -- igual que players (ShoulderCamera.normalWalkSpeed)
		JumpHeight = 5,
		WanderRadius = 40,
		-- Radio de llegada a un waypoint, solo en XZ. Techo: menor que la separación XZ
		-- entre waypoints en la pendiente máxima (WaypointSpacing·cos(AgentMaxSlope) =
		-- 2.83), o los consume en cadena sin visitarlos. Suelo ~1.5: a WalkSpeed y tick
		-- de 0.05s avanza 1.1 studs por iteración y podría sobrepasarlo.
		WaypointSmoothDistance = 2.5,
		-- Los waypoints están a ras de navmesh y el HumanoidRootPart ~2-3 studs por
		-- encima: la llegada se mide aparte en Y. Hasta AgentHeight cuenta como el mismo nivel.
		WaypointVerticalTolerance = 5,
	},

	Combat = {
		DetectRange = 45,
		FireRate = 0.1,           -- seg; compartido VsPlayer/VsBot
		Precision = 40,           -- % de balas que impactan (0..100)

		FOVDegrees = 150,          -- cono frontal total. La represalia lo ignora
		ReactionDelayMin = 0.15,   -- seg entre adquirir target y primer disparo
		ReactionDelayMax = 0.35,
		MissSpreadDegMin = 3,      -- grados; los fallos pasan visiblemente al lado
		MissSpreadDegMax = 8,
		-- Precision extra contra un objetivo quieto, interpolada a 0 al llegar a
		-- StationarySpeedThreshold (Precision se clampa a 100).
		StationaryPrecisionBonus = 25,
		-- studs/s
		StationarySpeedThreshold = 8,
		CombatPauseChance = 0.4,   -- probabilidad de pausa frente a paso lateral
		CombatPauseMin = 0.3,      -- seg
		CombatPauseMax = 0.9,
		CombatStepMin = 0.5,
		CombatStepMax = 1.4,
		MaxLosChecksPerEval = 3,   -- raycasts por _getBestTarget sobre los candidatos más cercanos

		TargetMemoryGrace = 6,       -- seg que un target perdido sigue "recordado" (CHASE sin LoS)
		RetaliationWindow = 8,       -- seg que un bot dañado fuerza targeting a su atacante. Cada impacto lo renueva.
		-- Rango ABSOLUTO (no bonus sobre DetectRange) en el que un bot ve y dispara a su atacante.
		RetaliationRange = 150,
		GraceRangeBonus = 15,        -- studs extra sobre DetectRange para mantener el target en memoria
		-- Studs que se restan a la distancia de un humano al ordenar candidatos.
		PlayerPriorityBias = 30,
		-- Multiplica Precision más allá de DetectRange (solo en represalia).
		FarPrecisionMult = 0.6,
		-- Banda en ATTACK: por debajo el strafe retrocede, por encima se acerca, en medio es lateral.
		MinEngageDistance = 12,
		MaxEngageDistance = 30,
		-- En CHASE, a menos de esta distancia corta el path y hace strafe: caminar hasta
		-- el cuerpo del jugador lo empuja y el StuckDetector escala hasta teleport.
		ChaseStandoffDistance = 10,
		-- Histéresis del standoff; debe ser > MinEngageDistance para que el retroceso
		-- del strafe no reactive el path enseguida.
		ChaseResumeDistance = 18,

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
		AgentRadius = 2,             -- 2.5 falla en pasillos estrechos
		AgentHeight = 5,
		AgentCanJump = true,
		AgentMaxSlope = 45,
		WaypointSpacing = 4,         -- default Roblox; 2 produce giros bruscos
		MinComputeInterval = 0.5,    -- seg; 1.0 hace CHASE lento
		PostBlockedCooldown = 0.3,   -- seg tras Path.Blocked antes de recomputar
	},

	Navigation = {
		RoamMinDist = 20,
		RoamMaxDist = 80,
		-- ±studs XZ para que dos bots no apunten al mismo punto. Valores altos sacan del
		-- navmesh los puntos junto a paredes (NoPath + backoff).
		RoamDestJitter = 2,
		StuckThresholds = { lateral = 1.0, repath = 2.0, jump = 4.0, teleport = 8.0 },
		StuckMoveEpsilon = 0.5,        -- studs/seg debajo de los cuales contamos stuck
		StuckSpawnGrace = 4,           -- seg tras spawnear sin contar stuck: caída, cola de pathfinding saturada y bots empujándose en el pad
		QueueRequestsPerHeartbeat = 2, -- ComputeAsync globales por Heartbeat
		MaxInFlightCompute = 4,        -- ComputeAsync simultáneos; el budget por Heartbeat solo limita enqueues
	},

	Lifecycle = {
		-- Segundos mínimos del cadáver (RagdollCleanup.minTime); el tope duro es +1.
		-- Bajo porque cada ragdoll son ~15 parts con física replicada a todos.
		RagdollCleanupDelay = 3,
		RespawnDelay = 0,         -- seg; 0 = instantáneo (los jugadores usan GameConfig.RespawnCooldown)
	},
}

return table.freeze(BotConfig)
