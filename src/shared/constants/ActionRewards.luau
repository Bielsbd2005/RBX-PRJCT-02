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
	-- Headshot y Assist a 10 desde el 2026-09-11 (antes 5): el número más
	-- pequeño que aparece en pantalla fija cuánto "pesa" la moneda, y un 5
	-- convertía el kill de 10 en "dos unidades". Ahora el átomo es 10: un kill
	-- con headshot vale 20, el doble, y se lee sin pensar. El coste (~+270
	-- Cash/h) se paga quitando Match y Defeat de ResultsRewards. Tasa de diseño
	-- (2026-09-12, jugador de GameConfig a ~90 kills/h): ~1.690 Cash/h jugando
	-- y ~2.000 con las diarias (ver docs/la-economia-de-las-40-horas.md).
	Kill = { XP = 25, Cash = 10 },
	Headshot = { XP = 15, Cash = 10 },
	Assist = { XP = 10, Cash = 10 },

	-- Daily tasks (server/features/dailyTasks). Convención: clave = "Daily" .. Key
	-- de la tarea en DailyTasks.Pool (Eliminations -> DailyEliminations); la
	-- construye DailyTasks.RewardKey y server y cliente leen el cash de aquí.
	-- El cash es de la TAREA, no del slot: la rotación diaria es un baraje, así
	-- que pagar por slot repartía el premio al azar entre tareas de esfuerzo muy
	-- distinto. Desde el 2026-09-11 las tareas piden ~3 partidas (antes se
	-- cumplían en un minuto) y el premio sigue la misma regla de coste (ronda de
	-- 8 min ≈ 210 Cash de combate a 90 kills/h): contar kills o asistencias (25 / 10, ~20-25 min) paga
	-- 80; puntería o racha (10 HS, racha de 5, ~25-35 min) 120, y "Win 3"
	-- (~6 partidas al 50 % de winrate) 200. Tres del pool al día = 280-440 Cash
	-- (media ~360, ~20k por season de 8 semanas si se hacen todas). Saltos del
	-- 50-67 %, por encima del umbral en el que un jugador distingue dos premios.
	-- La tarea de jugar partidas se quitó con su clave: pagaba por aparecer. Sin
	-- XP a propósito: todo el XP es de combate y el ritmo del pase está calibrado así.
	DailyEliminations = { XP = 0, Cash = 80 },
	DailyAssists = { XP = 0, Cash = 80 },
	DailyHeadshots = { XP = 0, Cash = 120 },
	DailyKillStreak = { XP = 0, Cash = 120 },
	DailyWinMatches = { XP = 0, Cash = 200 },

	-- Claims (server/features/rewards). A 50 desde el 2026-09-04: con 100 cada
	-- uno, más los dos códigos y el Cash inicial, un jugador nuevo entraba con
	-- 900 Cash y se llevaba las ocho Common antes de su primera partida.
	ClaimLikeJoin = { XP = 0, Cash = 50 },
	ClaimNotifications = { XP = 0, Cash = 50 },

	-- Códigos canjeables. Cada código tiene su propio ActionKey. Para añadir
	-- un código nuevo: añadir entry aquí + mapear en RewardsService.CODE_TO_ACTION.
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
