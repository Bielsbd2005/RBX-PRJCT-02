--!strict
--[[
	ActionRewards.luau
	Catálogo único de recompensas (XP y Cash) por acción.

	Fuente de verdad para TODO lo que conceda cash o XP en el server. Cualquier
	caller (MatchService, WeaponsSystem, DailyTasksService, RewardsService,
	BattlePassService) debe pasar por `server/core/RewardService.Award(player,
	actionKey, extras?)` en lugar de leer/aplicar XP o Cash directamente.

	Acciones combate (aditivas — kill+headshot suma ambos; streak alcanzado
	suma Kill + StreakN ese turno).
	Acciones no-combate: XP=0 por ahora (cash only); estructura preparada para
	añadir XP cambiando solo el número aquí.
]]

export type RewardAmounts = {
	XP: number,
	Cash: number,
}

local ActionRewards = {}

ActionRewards.Amounts = {
	-- Combate (server/features/match + server/WeaponsSystem)
	Kill = { XP = 25, Cash = 10 },
	Headshot = { XP = 15, Cash = 5 },
	Assist = { XP = 10, Cash = 5 },
	Streak3 = { XP = 30, Cash = 15 },
	Streak5 = { XP = 60, Cash = 30 },

	-- Daily tasks (server/features/dailyTasks). Convención: clave = "Daily" .. Id
	-- (Task1 -> DailyTask1). El cliente y el server resuelven el cash leyendo
	-- de aquí en vez de duplicarlo en DailyTasks.luau.
	DailyTask1 = { XP = 0, Cash = 20 },
	DailyTask2 = { XP = 0, Cash = 25 },
	DailyTask3 = { XP = 0, Cash = 20 },

	-- Claims (server/features/rewards)
	ClaimLikeJoin = { XP = 0, Cash = 100 },
	ClaimNotifications = { XP = 0, Cash = 100 },

	-- Códigos canjeables. Cada código tiene su propio ActionKey. Para añadir
	-- un código nuevo: añadir entry aquí + mapear en RewardsService.CODE_TO_ACTION.
	CodeWelcome = { XP = 0, Cash = 100 },
	CodeRewards = { XP = 0, Cash = 100 },
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
