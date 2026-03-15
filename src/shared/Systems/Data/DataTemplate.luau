local DataTemplate: ProfileData = {
	-- Versión del esquema de datos (Incrementar si haces cambios estructurales grandes)
	SchemaVersion = 1,

	-- Economía y Progreso
	level = 1,
	xp = 0,
	cash = 100,
	gems = 0,
	luckySpins = 0,
	caseSpins = {["Wood"] = 2,}, -- Ej: { ["Wood"] = 2, ["Metal"] = 0 }

	-- Estadísticas
	stats = {
		kills = 0,
		deaths = 0,
		headshotKills = 0,
		highestStreak = 0,
		playTime = 0,
	},

	-- Fusión en curso ({endTime: number, resultSkin: string, sourceSkins: {string}})
	activeFusion = nil,

	-- Inventario (Arrays de strings con nombres de items)
	inventory = {
		KillEffects = {},
		Faces = {},
		Outfits = { "Default" },
		Hats = {},
		Weapons = { "Default" },
		WeaponSkins = { "Default" },
	},

	-- Items Equipados (String vacío "" significa nada equipado, "Default" es item base)
	equipped = {
		KillEffects = "",
		Faces = "",
		Outfits = "Default",
		Hats = "",
		Weapons = "Default",
		WeaponSkins = "Default",
	},

	-- Configuración del Cliente
	settings = {
		mouseSensitivity = 1,
		musicVolume = 0.8,
		sfxVolume = 1,
	},

	-- Metadatos del Sistema
	meta = {
		createdAt = 0, -- Se rellena en DataManager
		updatedAt = 0,
		lastDailyReward = 0,
		isBanned = false,
	},
}

-- OPTIMIZACIÓN DE SEGURIDAD:
table.freeze(DataTemplate)

return DataTemplate
