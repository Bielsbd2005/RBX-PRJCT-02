--!strict
--[[
	Fuente de verdad de todo lo que concede XP o Cash en el server. Los callers
	deben pasar por `server/core/RewardService.Award(player, actionKey, extras?)`,
	nunca aplicar XP/Cash directamente. Las acciones de combate se suman
	(kill + headshot paga ambas).
]]

export type RewardAmounts = {
	XP: number,
	Cash: number,
}

local ActionRewards = {}

ActionRewards.Amounts = {
	-- Ninguna recompensa en pantalla por debajo del Cash de un kill: fija el valor percibido de la moneda.
	Kill ={ XP = 25, Cash = 10 },
	Headshot = { XP = 15, Cash = 10 },
	Assist = { XP = 10, Cash = 10 },

	-- Clave = "Daily" .. Key de la tarea en DailyTasks.Pool (la construye
	-- DailyTasks.RewardKey). El cash es por tarea, no por slot, porque la rotación
	-- es aleatoria. Sin XP a propósito: el ritmo del pase cuenta solo XP de combate.
	DailyEliminations = { XP = 0, Cash = 80 },
	DailyAssists = { XP = 0, Cash = 80 },
	DailyHeadshots = { XP = 0, Cash = 120 },
	DailyKillStreak = { XP = 0, Cash = 120 },
	DailyWinMatches = { XP = 0, Cash = 200 },

	ClaimLikeJoin = { XP = 0, Cash = 50 },

	-- Código nuevo: añadir la entrada aquí y mapearla en RewardsService.CODE_TO_ACTION.
	CodeWelcome = { XP = 0, Cash = 50 },
	CodeRewards = { XP = 0, Cash = 50 },
} :: { [string]: RewardAmounts }

local function getField(action: string, field: string): number
	local entry = ActionRewards.Amounts[action]
	if type(entry) ~= "table" then
		return 0
	end

	local value = (entry :: any)[field]
	if type(value) == "number" and value > 0 then
		return math.floor(value)
	end
	return 0
end

function ActionRewards.GetXP(action: string): number
	return getField(action, "XP")
end

function ActionRewards.GetCash(action: string): number
	return getField(action, "Cash")
end

function ActionRewards.Get(action: string): RewardAmounts
	return {
		XP = ActionRewards.GetXP(action),
		Cash = ActionRewards.GetCash(action),
	}
end

function ActionRewards.Has(action: string): boolean
	return ActionRewards.Amounts[action] ~= nil
end

return table.freeze(ActionRewards)
