--!strict
--[[
	ActionRewards.luau
	Catálogo único de recompensas (XP y Cash) por acción.

	Fuente de verdad para TODO lo que conceda cash o XP en el server. Cualquier
	caller (MatchService, WeaponsSystem, DailyTasksService, RewardsService,
	BattlePassService) debe pasar por `server/core/RewardService.Award(player,
	actionKey, extras?)` en lugar de leer/aplicar XP o Cash directamente.

	Acciones combate (aditivas — kill+headshot suma ambos).
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

	-- Daily tasks (server/features/dailyTasks). Convención: clave = "Daily" .. Key
	-- de la tarea en DailyTasks.Pool (Eliminations -> DailyEliminations); la
	-- construye DailyTasks.RewardKey y server y cliente leen el cash de aquí.
	-- El cash es de la TAREA, no del slot: la rotación diaria es un baraje, así
	-- que pagar por slot repartía el premio al azar entre tareas de esfuerzo muy
	-- distinto. Escalado al coste real (ronda de 8 min ≈ 220 Cash): las de ~½-1
	-- partida pagan 40-50, "Play 3" (~24 min) 75 y "Win 2" (~4 partidas al 50%
	-- de winrate) 100. Tres del pool al día = 130-225 Cash (media ~180 ≈ ¾ de
	-- partida, ~10k por season de 8 semanas). Sin XP a propósito: todo el XP es
	-- de combate y el ritmo del pase está calibrado así.
	DailyEliminations = { XP = 0, Cash = 40 },
	DailyAssists = { XP = 0, Cash = 40 },
	DailyHeadshots = { XP = 0, Cash = 50 },
	DailyKillStreak = { XP = 0, Cash = 50 },
	DailyPlayMatches = { XP = 0, Cash = 75 },
	DailyWinMatches = { XP = 0, Cash = 100 },

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
