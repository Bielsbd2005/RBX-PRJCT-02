--!strict
--[[
	Esquema y valores por defecto del perfil del jugador (ProfileStore).

	Restricciones de ProfileStore: sin tablas numéricas con huecos, sin tablas
	mixtas número+string, sin Instances ni userdata.
	`""` es el sentinel de "no asignado"; los opcionales reales (`T?`) se omiten del default.
	Migraciones destructivas: server/core/data/DataMigrations.luau.
]]

local LevelingConfig = require(script.Parent.LevelingConfig)

--[[
	Counters lifetime.
	  • Headshots/Longshots/MeleeKills son SUBSETS de Kills.
	  • La racha actual vive en memoria (MatchService); aquí solo la mejor.
	  • TimePlayedSeconds se suma al PlayerRemoving, no en runtime.
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
	DoubleKills: number,
	TripleKills: number,
	KillStreakBest: number,
	DamageDealt: number,
	ShotsFired: number,
	ShotsHit: number,
	Wins: number,
	Losses: number,
	MatchesPlayed: number,
	TimePlayedSeconds: number,
	Cash: number,
	TotalCashEarned: number,
	-- Parte de TotalCashEarned que NO salió de jugar (packs con Robux y regalos
	-- recibidos). La telemetría lo resta para medir Cash por hora jugada.
	-- Perfiles antiguos lo tienen a 0 aunque hubieran comprado.
	TotalCashPurchased: number,
	-- Moneda premium: solo Battle Pass o packs con Robux. Un faucet de Gems en
	-- ActionRewards sería un bug de diseño.
	Gems: number,
	TotalGemsEarned: number,
	TotalRobuxSpent: number,
	FriendsInvited: number,
}

-- Mapas itemId → true (desbloqueado). Metadata por ítem en InventoryMeta.
export type Inventory = {
	Main: { [string]: boolean },
	Special: { [string]: boolean },
	WeaponWrapsByWeapon: {
		Main: { [string]: { [string]: number | boolean } },
		Special: { [string]: { [string]: number | boolean } },
	},
	KillEffects: { [string]: boolean },
	Emotes: { [string]: boolean },
	Faces: { [string]: boolean },
	Hats: { [string]: boolean },
	Outfits: { [string]: boolean },
	Banners: { [string]: boolean },
}

--[[
	category → itemId → meta. No es fuente de ownership (eso es Inventory).
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
	Emote: string, -- Se reproduce en partida con la tecla E (ver EmoteController)
	Face: string,
	Hat: string?,
	Outfit: string,
	-- Banner de la tarjeta de muerte: lo ve quien muere a manos de este jugador.
	Banner: string,
}

-- Kills por arma, para la maestría de wraps.
export type WeaponKills = {
	Main: { [string]: number },
	Special: { [string]: number },
}

--[[
	Whitelist de claves en SettingsService: un cambio de tipo aquí requiere tocar
	su handler (UpdateSlider/UpdateToggle).
]]
export type Settings = {
	-- Sliders 0..1
	MasterVolume: number,
	MusicVolume: number,
	SFXVolume: number,
	CameraSensitivity: number,
	FOV: number, -- 0..1 mapeado a [70..110]° en cliente
	HUDScale: number, -- 0..1 mapeado a [0.75..1.5] en cliente
	Vibration: boolean,
	AutoShoot: boolean,
	ShowDamageNumbers: boolean,
	GiftsEnabled: boolean, -- acepta recibir regalos
}

export type Rewards = {
	GroupClaimed: boolean,
	ClaimedCodes: { [string]: boolean },
	VIPWelcomeClaimed: boolean, -- Gems de bienvenida del VIP ya concedidas (VIPItemsService)
}

-- DataService la actualiza al cargar comparando LastLoginDateKey con el día UTC.
export type LoginStreak = {
	Current: number,
	Best: number,
	LastLoginDateKey: string, -- "YYYY-MM-DD" UTC
}

-- Cash JUGADO (combate + bonus de fin de partida) cobrado en el día UTC `DateKey`.
-- RewardService lo usa para el techo diario por tramos (GameConfig.DailyPlayedCashTiers).
export type PlayedCash = {
	DateKey: string, -- "YYYY-MM-DD" UTC
	Amount: number,
}

export type Metadata = {
	CreatedAt: number,
	LastSeen: number,
	Version: number, -- versión del schema (DataMigrations)
	JoinCount: number,
	FirstSessionVersion: string,
	LastClientVersion: string,
	Country: string, -- ISO 3166-1 alpha-2, best-effort ("" si no se conoce)
}

-- PurchaseId → os.time(). Idempotencia de ProcessReceipt: Roblox reintenta el
-- receipt y un duplicado devuelve PurchaseGranted sin re-otorgar.
export type ProcessedReceipts = { [string]: number }

--[[
	Regalos RECIBIDOS sin reclamar. Key = PurchaseId del comprador: una re-entrega
	sobrescribe la misma key en vez de duplicar. ClaimGift (GiftingService) concede
	y borra la entrada.
]]
export type PendingGift = {
	SenderUserId: number,
	SenderName: string,
	CashAmount: number,
	ProductId: number,
	SentAt: number,
}
export type PendingGifts = { [string]: PendingGift }

--[[
	PurchaseId → os.time() del claim. Evita que un receipt/message re-entregado
	vuelva a crear un PendingGift ya reclamado. DataService lo poda por edad al cargar.
]]
export type ClaimedGifts = { [string]: number }

--[[
	Intención de regalo del COMPRADOR: la escribe SendGift antes del prompt y la
	consume ProcessReceipt para dar el producto al receptor. En el perfil y no en
	memoria para sobrevivir reintentos del receipt en otro servidor.
	ReceiverUserId = 0 ⇒ sin intención (ProfileStore no persiste nils). Expira por
	CreatedAt (INTENT_TTL en GiftingService).
]]
export type GiftIntent = {
	ReceiverUserId: number,
	ProductId: number,
	CreatedAt: number,
}

--[[
	PurchaseId → entrega de regalo YA intentada (en el perfil del comprador). Se escribe
	antes de depositar/enviar el message: un reintento del receipt vuelve a entregar al
	mismo receptor aunque GiftIntent haya caducado o cambiado. DataService la poda al cargar.
]]
export type GiftDelivery = {
	ReceiverUserId: number,
	ProductId: number,
	At: number,
}
export type GiftDeliveries = { [string]: GiftDelivery }

-- Definición de tareas en shared/constants/DailyTasks.luau.
--   DateKey: "YYYY-MM-DD" UTC del último reset.
--   Claimed: por slot; evita pagar dos veces aunque el contador siga subiendo.
export type DailyTasksState = {
	DateKey: string,
	-- Kind → contador del día. Mapa y no registro fijo: la rotación puede traer cualquier Kind.
	Progress: { [string]: number },
	Claimed: {
		Task1: boolean,
		Task2: boolean,
		Task3: boolean,
	},
}

--[[
	Config en shared/constants/BattlePassConfig.luau.
	  • CurrentTier = N: tiers 1..N-1 completados. MaxTier+1 = pase completado (XP = 0).
	  • XP es el progreso DENTRO del tier actual.
	  • TotalXPEarned no baja al subir de tier; cada claim valida CurrentTier contra él.
	  • PremiumOwned se resetea al cambiar de season.
	  • Claimed usa tostring(level) como key (ProfileStore prohíbe huecos numéricos).
	  • SeasonId distinto de la season activa al cargar ⇒ reset.
]]
export type BattlePassState = {
	SeasonId: string,
	CurrentTier: number,
	XP: number,
	TotalXPEarned: number,
	PremiumOwned: boolean,
	Claimed: { [string]: boolean },
	GrantedSkips: { [string]: boolean }, -- PurchaseId → true (idempotencia del Skip)
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
	PlayedCash: PlayedCash,
	DailyTasks: DailyTasksState,
	BattlePass: BattlePassState,
	Metadata: Metadata,
	ProcessedReceipts: ProcessedReceipts,
	PendingGifts: PendingGifts,
	ClaimedGifts: ClaimedGifts,
	GiftIntent: GiftIntent,
	GiftDeliveries: GiftDeliveries,
}

-- Reconcile() rellena claves faltantes en perfiles existentes, pero no borra las que sobran.

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
		DoubleKills = 0,
		TripleKills = 0,
		KillStreakBest = 0,
		DamageDealt = 0,
		ShotsFired = 0,
		ShotsHit = 0,
		Wins = 0,
		Losses = 0,
		MatchesPlayed = 0,
		TimePlayedSeconds = 0,
		-- Mantener POR DEBAJO del ítem más barato del catálogo y a menos de una
		-- partida de él: la primera compra se gana jugando, no se regala.
		Cash = 80,
		TotalCashEarned = 0,
		TotalCashPurchased = 0,
		Gems = 0,
		TotalGemsEarned = 0,
		TotalRobuxSpent = 0,
		FriendsInvited = 0,
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
				},
			},
		},
		KillEffects = { Default = true },
		Emotes = { Default = true },
		Faces = { Default = true },
		Hats = {},
		Outfits = { Default = true },
		Banners = { Default = true },
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
		Emote = "Default",
		Face = "Default",
		-- Hat omitido a propósito: es opcional.
		Outfit = "Default",
		Banner = "Default",
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
		GiftsEnabled = true,
	},

	Rewards = {
		GroupClaimed = false,
		ClaimedCodes = {},
		VIPWelcomeClaimed = false,
	},

	LoginStreak = {
		Current = 0,
		Best = 0,
		LastLoginDateKey = "",
	},

	PlayedCash = {
		DateKey = "",
		Amount = 0,
	},


	DailyTasks = {
		DateKey = "",
		Progress = {
			Eliminations = 0,
			WinMatches = 0,
			Headshots = 0,
			KillStreak = 0,
			Assists = 0,
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
		Claimed = {},
		GrantedSkips = {},
	},

	Metadata = {
		CreatedAt = 0,
		LastSeen = 0,
		-- Bumpear CURRENT_VERSION en DataMigrations solo para migraciones destructivas;
		-- los campos nuevos los rellena Reconcile.
		Version = 3,
		JoinCount = 0,
		FirstSessionVersion = "",
		LastClientVersion = "",
		Country = "",
	},

	ProcessedReceipts = {},

	PendingGifts = {},

	ClaimedGifts = {},

	GiftIntent = {
		ReceiverUserId = 0,
		ProductId = 0,
		CreatedAt = 0,
	},

	GiftDeliveries = {},
}

-- ProfileStore hace deep-copy al crear un perfil.
return table.freeze(DEFAULT)
