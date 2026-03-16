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
	Weapons: { [string]: boolean },
	WeaponSkins: { [string]: boolean },
	KillEffects: { [string]: boolean },
	Faces: { [string]: boolean },
	Hats: { [string]: boolean },
	Outfits: { [string]: boolean },
}

export type Loadout = {
	PrimaryWeapon: string,
	KillEffect: string,
	Face: string,
	Hat: string?, -- Opcional: el jugador puede no llevar sombrero
	Outfit: string,
	ActiveSkin: string,
}

export type Settings = {
	MusicVolume: number,
	SFXVolume: number,
	CameraFOV: number,
	CameraSensitivity: number,
	ShowKillFeed: boolean,
	ShowDamageNumbers: boolean,
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
	Metadata: Metadata,
}

-- ────────────────────────────────────────────────────────────
-- VALORES POR DEFECTO
-- Reconcile() de ProfileStore llenará claves faltantes con estos valores,
-- garantizando compatibilidad hacia adelante al agregar nuevos campos.
-- ────────────────────────────────────────────────────────────

local DEFAULT: PlayerProfile = {
	Stats = {
		Level = 1,
		XP = 0,
		XPToNextLevel = 100,
		Kills = 0,
		Deaths = 0,
		Wins = 0,
		Losses = 0,
		Cash = 500,
		Gems = 0,
	},

	Inventory = {
		Weapons = { Default = true },
		WeaponSkins = { Default = true },
		KillEffects = { Default = true },
		Faces = { Default = true },
		Hats = {},
		Outfits = { Default = true },
	},

	Loadout = {
		PrimaryWeapon = "Default",
		KillEffect = "Default",
		Face = "Default",
		Hat = nil,
		Outfit = "Default",
		ActiveSkin = "Default",
	},

	Settings = {
		MusicVolume = 0.5,
		SFXVolume = 1.0,
		CameraFOV = 70,
		CameraSensitivity = 1.0,
		ShowKillFeed = true,
		ShowDamageNumbers = true,
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
