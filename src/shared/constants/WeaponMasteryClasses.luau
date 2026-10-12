--!strict
--[[
	Clases de arma de la maestría de wraps: el campo `MasteryClass` del arma en
	ItemsConfig elige una y Shared.data.WrapMastery adapta con ella sus desafíos.
]]

export type PrecisionKind = "Headshots" | "CloseKills" | "LongKills"

export type Class = {
	-- Multiplica los objetivos de Kills y Precision; los de Streaks no se escalan.
	GoalScale: number,
	-- Qué baja cuenta para el desafío de Precision.
	Precision: PrecisionKind,
	-- Bajas con el arma en una misma vida que completan una racha.
	StreakLength: number,
}

local Classes: { [string]: Class } = {
	Auto = { GoalScale = 1, Precision = "Headshots", StreakLength = 5 },
	Shotgun = { GoalScale = 0.7, Precision = "CloseKills", StreakLength = 3 },
	Pistol = { GoalScale = 0.6, Precision = "Headshots", StreakLength = 3 },
	Sniper = { GoalScale = 0.5, Precision = "LongKills", StreakLength = 3 },
	-- Sin headshot posible: una explosión o una zona de fuego cuentan como bodyshot.
	Explosive = { GoalScale = 0.5, Precision = "LongKills", StreakLength = 3 },
}

return table.freeze({
	-- Clase de un arma sin `MasteryClass`.
	DEFAULT = "Auto",
	Classes = Classes,
	-- Studs entre atacante y víctima en el momento de la baja.
	CloseRange = 20,
	LongRange = 100,
})
