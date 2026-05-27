--!strict
--[[
	DataTemplate.luau
	Fuente única de verdad para el esquema de datos del jugador.
	Define tipos exportables y los valores por defecto (DEFAULT).

	Restricciones de ProfileStore:
	  - No tablas numéricas con huecos
	  - No tablas mixtas (índices número + string)
	  - No referencias a Instancias ni userdata

	Convenciones de schema:
	  - Cada sección top-level es una tabla con keys string.
	  - Counters/timestamps son `number`. Booleans para flags binarios.
	  - Strings vacíos `""` como sentinel para "no asignado" en campos requeridos.
	  - Para opcionales reales, usar `string?` y omitir del default.
	  - Mapas `{ [string]: T }` para colecciones indexadas (inventarios, flags).
	  - Las migraciones se manejan en `server/core/data/DataMigrations.luau`.
]]

local LevelingConfig = require(script.Parent.LevelingConfig)

-- ────────────────────────────────────────────────────────────
-- TIPOS EXPORTADOS
-- ────────────────────────────────────────────────────────────

--[[
	Stats: progresión y combate. Counters lifetime; los counters por-modo o
	por-sesión se llevan separados o en memoria.

	Convenciones:
	  • Headshots/Longshots/MeleeKills son SUBSETS de Kills (no se duplica).
	  • KillStreakBest es la mejor racha lifetime; la racha actual vive en
	    memoria (MatchService) y se resetea al morir.
	  • TimePlayedSeconds acumulado por DataService vía Increment atómico al
	    PlayerRemoving (la sesión se contabiliza al cierre, no en runtime).
]]
export type Stats = {
	Level: number,
	XP: number,
	XPToNextLevel: number,
	Kills: number,
	Deaths: number,
	Assists: number,
	Headshots: number,
	Longshots: number,
	MeleeKills: number,
	KillStreakBest: number,
	Wins: number,
	Losses: number,
	MatchesPlayed: number,
	TimePlayedSeconds: number,
	Cash: number,
}

-- Cada categoría es un mapa string → bool (true = desbloqueado).
-- Para metadata por-item (timestamp/source de adquisición) ver InventoryMeta.
export type Inventory = {
	Main: { [string]: boolean },
	Special: { [string]: boolean },
	WeaponWrapsByWeapon: {
		Main: { [string]: { [string]: number | boolean } },
		Special: { [string]: { [string]: number | boolean } },
	},
	KillEffects: { [string]: boolean },
	Faces: { [string]: boolean },
	Hats: { [string]: boolean },
	Outfits: { [string]: boolean },
}

--[[
	InventoryMeta: metadata por-ítem. NO duplicamos ownership (eso vive en
	Inventory); solo añadimos info opcional para UX/analytics/refunds.

	Estructura: category → itemId → { AcquiredAt, Source }
	  AcquiredAt: os.time() de adquisición.
	  Source: "Shop" | "Reward" | "Default" | "Gift" | "Code" | etc.
]]
export type InventoryItemMeta = {
	AcquiredAt: number,
	Source: string,
}
export type InventoryMeta = { [string]: { [string]: InventoryItemMeta } }

export type Loadout = {
	MainWeapon: string,
	SpecialWeapon: string,
	MainWeaponWraps: { [string]: string },
	SpecialWeaponWraps: { [string]: string },
	KillEffect: string,
	Face: string,
	Hat: string?, -- Opcional: el jugador puede no llevar sombrero
	Outfit: string,
}

-- Kills acumuladas por arma. Usado por la maestría de wraps en el Locker.
export type WeaponKills = {
	Main: { [string]: number },
	Special: { [string]: number },
}

--[[
	Settings: preferencias del cliente persistidas server-side para que sean
	consistentes entre sesiones. Whitelist de claves vive en SettingsService.

	Cambios de tipo aquí requieren actualizar el handler correspondiente
	(UpdateSlider/UpdateToggle/UpdateChoice).
]]
export type Settings = {
	-- Audio (sliders 0..1)
	MasterVolume: number,
	MusicVolume: number,
	SFXVolume: number,
	-- Cámara/aim (sliders 0..1 normalizados)
	CameraSensitivity: number,
	FOV: number,            -- 0..1 mapped a [70..110]° en cliente
	-- HUD
	HUDScale: number,       -- 0..1 mapped a [0.75..1.5] en cliente
	-- Toggles
	Vibration: boolean,
	AutoShoot: boolean,
	ShowDamageNumbers: boolean,
	-- Choices (string enums whitelisted en SettingsService)
	ColorblindMode: string, -- "None" | "Protanopia" | "Deuteranopia" | "Tritanopia"
	Language: string,       -- ISO 639-1 ("en", "es", ...)
	-- Visual ajustable. RGB 0..1.
	CrosshairColor: { R: number, G: number, B: number },
}

export type Rewards = {
	LikeState: string,
	LikePendingSessionToken: string,
	GroupClaimed: boolean,
	NotificationsClaimed: boolean,
	ClaimedCodes: { [string]: boolean },
	FirstPurchaseClaimed: boolean,
}

--[[
	LoginStreak: racha de logins diarios consecutivos. DataService la actualiza
	en _loadPlayer comparando LastLoginDateKey con el día UTC actual.

	Semántica:
	  • Mismo día que LastLogin → no-op.
	  • Día siguiente exacto → Current += 1.
	  • Gap > 1 día → Current = 1 (reset).
	  • Best = max(Best, Current).
]]
export type LoginStreak = {
	Current: number,
	Best: number,
	LastLoginDateKey: string, -- "YYYY-MM-DD" UTC
}

--[[
	NewItemFlags: marcadores "NEW!" para UX del Locker. El cliente los pinta y
	llama a `Locker.MarkItemSeen(category, itemId)` cuando el jugador los abre.
	Server los setea al granteear el ítem.

	Estructura: category → itemId → true (presencia = no visto).
]]
export type NewItemFlags = { [string]: { [string]: boolean } }

export type Metadata = {
	CreatedAt: number,           -- os.time() de la primera sesión
	LastSeen: number,            -- os.time() de la última sesión
	Version: number,             -- Versión del schema (gestionada por DataMigrations)
	JoinCount: number,           -- Sesiones lifetime
	FirstSessionVersion: string, -- Versión del juego en la primera sesión
	LastClientVersion: string,   -- Versión del juego en la sesión más reciente
	Country: string,             -- ISO 3166-1 alpha-2 (best-effort, vacío si no se conoce)
}

-- ProcessedReceipts: PurchaseId → os.time() de cuando se procesó.
-- Usado para idempotencia de MarketplaceService.ProcessReceipt: si Roblox
-- reintenta el receipt (p. ej. crash entre Increment y PurchaseGranted),
-- detectamos el duplicado y devolvemos PurchaseGranted sin re-otorgar.
export type ProcessedReceipts = { [string]: number }

-- DailyTasks: progreso diario por jugador. La definición de las tareas vive
-- en `shared/constants/DailyTasks.luau`. Aquí solo se almacena el estado.
--   DateKey: "YYYY-MM-DD" (UTC) — cuándo fue el último reset.
--   Progress: contador acumulado por Kind del día actual.
--   Claimed: marca por slot UI (Task1/Task2/Task3). Una vez que progress alcanza
--            el objetivo, se otorga el cash y se setea Claimed[Id] = true para
--            no pagar dos veces aunque el contador siga subiendo.
export type DailyTasksState = {
	DateKey: string,
	Progress: {
		Eliminations: number,
		WinMatches: number,
		PlayMatches: number,
	},
	Claimed: {
		Task1: boolean,
		Task2: boolean,
		Task3: boolean,
	},
}

--[[
	BattlePass: progresión por temporada. La config (tiers, rewards, productId
	de Robux) vive en `shared/constants/BattlePassConfig.luau`.

	Semántica:
	  • CurrentTier = N significa "tiers 1..N-1 completados; estoy progresando
	    hacia el N". Cuando se supera el último tier, CurrentTier = MaxTier+1
	    (sentinel "completado") y XP queda en 0.
	  • XP es el progreso DENTRO del tier actual. No se acumula entre tiers
	    (la cascada en _applyXP descuenta XPRequired y sube CurrentTier).
	  • TotalXPEarned es el contador acumulativo de XP ganada en la season
	    (nunca se decrementa al subir de tier). Sirve como fuente de verdad
	    independiente para validar CurrentTier en cada claim: si CurrentTier
	    se corrompe a un valor mayor al derivable de TotalXPEarned, el claim
	    se rechaza (defense-in-depth).
	  • PremiumOwned se setea al procesar el receipt de Robux. Se RESETEA al
	    cambiar de season (cada season requiere su propia compra).
	  • ClaimedFree/ClaimedPremium usan `tostring(level)` como key porque
	    ProfileStore prohíbe tablas numéricas con huecos.
	  • GrantedSkips[PurchaseId] = true marca cada compra de "Skip Tier"
	    aplicada. Permite idempotencia per-receipt: si BatchUpdate de la
	    sección BattlePass tiene éxito pero ProcessedReceipts falla, el
	    retry de Roblox no re-aplica el skip (a diferencia de Premium que
	    es idempotente naturalmente con value=true).
	  • SeasonId se compara contra BattlePassConfig.GetActiveSeason().Id en
	    el load del perfil; mismatch dispara reset.
]]
export type BattlePassState = {
	SeasonId: string,
	CurrentTier: number,
	XP: number,
	TotalXPEarned: number,
	PremiumOwned: boolean,
	ClaimedFree: { [string]: boolean },
	ClaimedPremium: { [string]: boolean },
	GrantedSkips: { [string]: boolean },
}

export type PlayerProfile = {
	Stats: Stats,
	Inventory: Inventory,
	InventoryMeta: InventoryMeta,
	Loadout: Loadout,
	WeaponKills: WeaponKills,
	Settings: Settings,
	Rewards: Rewards,
	LoginStreak: LoginStreak,
	NewItemFlags: NewItemFlags,
	DailyTasks: DailyTasksState,
	BattlePass: BattlePassState,
	Metadata: Metadata,
	ProcessedReceipts: ProcessedReceipts,
}

-- ────────────────────────────────────────────────────────────
-- VALORES POR DEFECTO
-- Reconcile() de ProfileStore llenará claves faltantes con estos valores,
-- garantizando compatibilidad hacia adelante al agregar nuevos campos.
-- ────────────────────────────────────────────────────────────

local DEFAULT: PlayerProfile = {
	Stats = {
		Level = 0,
		XP = 0,
		XPToNextLevel = LevelingConfig.GetXPToNextLevel(0),
		Kills = 0,
		Deaths = 0,
		Assists = 0,
		Headshots = 0,
		Longshots = 0,
		MeleeKills = 0,
		KillStreakBest = 0,
		Wins = 0,
		Losses = 0,
		MatchesPlayed = 0,
		TimePlayedSeconds = 0,
		Cash = 500,
	},

	Inventory = {
		Main = { Default = true },
		Special = { Default = true },
		WeaponWrapsByWeapon = {
			Main = {
				Default = {
					Default = true,
				},
			},
			Special = {
				Default = {
					Default = true,
					Wrap_Red = true,
				},
			},
		},
		KillEffects = { Default = true },
		Faces = { Default = true },
		Hats = {},
		Outfits = { Default = true },
	},

	InventoryMeta = {},

	Loadout = {
		MainWeapon = "Default",
		SpecialWeapon = "Default",
		MainWeaponWraps = {
			Default = "Default",
		},
		SpecialWeaponWraps = {
			Default = "Default",
		},
		KillEffect = "Default",
		Face = "Default",
		-- Hat es opcional (Loadout.Hat: string?). No se incluye literal aquí
		-- porque `nil` en una tabla es lo mismo que ausencia de clave; añadirlo
		-- solo confunde y `Reconcile` no lo rellenaría tampoco.
		Outfit = "Default",
	},

	WeaponKills = {
		Main = {},
		Special = {},
	},

	Settings = {
		MasterVolume = 1,
		MusicVolume = 0.5,
		SFXVolume = 0.8,
		CameraSensitivity = 0.5,
		FOV = 0.5,
		HUDScale = 0.5,
		Vibration = true,
		AutoShoot = true,
		ShowDamageNumbers = true,
		ColorblindMode = "None",
		Language = "en",
		CrosshairColor = { R = 1, G = 1, B = 1 },
	},

	Rewards = {
		LikeState = "None",
		LikePendingSessionToken = "",
		GroupClaimed = false,
		NotificationsClaimed = false,
		ClaimedCodes = {},
		FirstPurchaseClaimed = false,
	},

	LoginStreak = {
		Current = 0,
		Best = 0,
		LastLoginDateKey = "",
	},

	NewItemFlags = {},

	DailyTasks = {
		DateKey = "",
		Progress = {
			Eliminations = 0,
			WinMatches = 0,
			PlayMatches = 0,
		},
		Claimed = {
			Task1 = false,
			Task2 = false,
			Task3 = false,
		},
	},

	BattlePass = {
		SeasonId = "",
		CurrentTier = 1,
		XP = 0,
		TotalXPEarned = 0,
		PremiumOwned = false,
		ClaimedFree = {},
		ClaimedPremium = {},
		GrantedSkips = {},
	},

	Metadata = {
		CreatedAt = 0,
		LastSeen = 0,
		-- Schema version. Manejada por DataMigrations: bumpear CURRENT_VERSION
		-- ahí cuando añadas una migración destructiva (renames, splits, etc.).
		-- Para campos nuevos basta con añadirlos al template — Reconcile los
		-- rellena en perfiles existentes con su default.
		Version = 2,
		JoinCount = 0,
		FirstSessionVersion = "",
		LastClientVersion = "",
		Country = "",
	},

	ProcessedReceipts = {},
}

-- Congelado para prevenir mutaciones accidentales del template.
-- ProfileStore hace una deep-copy al crear un nuevo perfil.
return table.freeze(DEFAULT)
