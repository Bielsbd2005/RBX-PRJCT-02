--!strict
--[[
	ActionRewards.luau
	Catálogo de recompensas (XP y Cash) por cada acción registrada.
	Fuente única de verdad: cualquier sistema que reparta recompensas debe
	leerlas de aquí en lugar de hardcodear los valores.
]]

export type RewardAction = "Kill" | "Headshot" | "Assist" | "Streak3" | "Streak5"

export type RewardAmounts = {
	XP: number,
	Cash: number,
}

local ActionRewards = {}

-- Cantidades aditivas: las acciones se suman (un kill con headshot otorga
-- Kill + Headshot; alcanzar streak 3 otorga Kill + Streak3 ese turno).
ActionRewards.Amounts = {
	Kill = { XP = 25, Cash = 10 },
	Headshot = { XP = 15, Cash = 5 },
	Assist = { XP = 10, Cash = 5 },
	Streak3 = { XP = 30, Cash = 15 },
	Streak5 = { XP = 60, Cash = 30 },
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

return table.freeze(ActionRewards)
