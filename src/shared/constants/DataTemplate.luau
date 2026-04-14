--!strict
--[[
	DataTemplate.luau
	Fuente única de verdad para el esquema de datos del jugador.
	Define tipos exportables y los valores por defecto (DEFAULT).

	Restricciones de ProfileStore:
	  - No tablas numéricas con huecos
	  - No tablas mixtas (índices número + string)
	  - No referencias a Instancias ni userdata
]]

local LevelingConfig = require(script.Parent.LevelingConfig)

-- ────────────────────────────────────────────────────────────
-- TIPOS EXPORTADOS
-- ────────────────────────────────────────────────────────────

export type Stats = {
	Level: number,
	XP: number,
	XPToNextLevel: number,
	Kills: number,
	Deaths: number,
	Wins: number,
	Losses: number,
	Cash: number,
	Gems: number,
}

-- Cada categoría es un mapa string → bool (true = desbloqueado)
export type Inventory = {
	Main: { [string]: boolean },
	Special: { [string]: boolean },
	WeaponSkins: { [string]: boolean },
	WeaponSkinsByWeapon: {
		Main: { [string]: { [string]: number | boolean } },
		Special: { [string]: { [string]: number | boolean } },
	},
	KillEffects: { [string]: boolean },
	Faces: { [string]: boolean },
	Hats: { [string]: boolean },
	Outfits: { [string]: boolean },
}

export type Loadout = {
	MainWeapon: string,
	PrimaryWeapon: string?, -- Legacy slot kept for backward compatibility
	SpecialWeapon: string,
	MainWeaponWraps: { [string]: string },
	SpecialWeaponWraps: { [string]: string },
	KillEffect: string,
	Face: string,
	Hat: string?, -- Opcional: el jugador puede no llevar sombrero
	Outfit: string,
	-- Legacy: se mantiene temporalmente para migrar perfiles previos.
	ActiveSkin: string,
}

export type Settings = {
	MusicVolume: number,
	CameraSensitivity: number,
	Vibration: boolean,
	AimAssist: boolean,
}

export type CasesData = {
	PityCounters: { [string]: number },   -- caseId → tiradas sin pity drop
	LuckyExpiresAt: number,                -- os.time() cuando expira el lucky boost (0 = inactivo)
}

export type Rewards = {
	LikeState: string,
	LikePendingSessionToken: string,
	GroupClaimed: boolean,
	NotificationsClaimed: boolean,
	ClaimedCodes: { [string]: boolean },
}

export type Metadata = {
	CreatedAt: number,  -- os.time() de la primera sesión
	LastSeen: number,   -- os.time() de la última sesión
	Version: number,    -- Versión del schema; útil para migraciones futuras
	TotalPlaytime: number, -- Segundos totales en sesión
}

export type PlayerProfile = {
	Stats: Stats,
	Inventory: Inventory,
	Loadout: Loadout,
	Settings: Settings,
	Rewards: Rewards,
	Cases: CasesData,
	Metadata: Metadata,
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
		Wins = 0,
		Losses = 0,
		Cash = 500,
		Gems = 0,
	},

	Inventory = {
		Main = { Default = true },
		Special = { Default = true },
		WeaponSkins = { Default = true, Skin_Red = true },
		WeaponSkinsByWeapon = {
			Main = {
				Default = {
					Default = true,
				},
			},
			Special = {
				Default = {
					Default = true,
					Skin_Red = true,
				},
			},
		},
		KillEffects = { Default = true },
		Faces = { Default = true },
		Hats = {},
		Outfits = { Default = true },
	},

	Loadout = {
		MainWeapon = "Default",
		PrimaryWeapon = "Default",
		SpecialWeapon = "Default",
		MainWeaponWraps = {
			Default = "Default",
		},
		SpecialWeaponWraps = {
			Default = "Default",
		},
		KillEffect = "Default",
		Face = "Default",
		Hat = nil,
		Outfit = "Default",
		ActiveSkin = "Default",
	},

	Settings = {
		MusicVolume = 0.5,
		CameraSensitivity = 0.5,
		Vibration = true,
		AimAssist = true,
	},

	Rewards = {
		LikeState = "None",
		LikePendingSessionToken = "",
		GroupClaimed = false,
		NotificationsClaimed = false,
		ClaimedCodes = {},
	},

	Cases = {
		PityCounters = {},
		LuckyExpiresAt = 0,
	},

	Metadata = {
		CreatedAt = 0,
		LastSeen = 0,
		Version = 1,
		TotalPlaytime = 0,
	},
}

-- Congelado para prevenir mutaciones accidentales del template.
-- ProfileStore hace una deep-copy al crear un nuevo perfil.
return table.freeze(DEFAULT)
