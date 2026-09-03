--!strict
--[[
	DailyTasks.luau
	Catálogo de tareas diarias. Hay un POOL de tareas y cada día se sortean tres
	para los tres slots de UI; el progreso por jugador se refresca cada día.

	Slots (fijos, son la identidad de cara a datos y UI):
	  MatchHud.LeftContainer.TaskFrame.Task1/Task2/Task3
	  Menu.Container.Missions.1/2/3
	Cada slot consume:
		.Title         — TextLabel
		.Value         — TextLabel "<progress>/<objective>"
		.Bar.Fill      — Frame (escalado X = progress/objective)
		.Reward.Value  — TextLabel (Cash, resuelto vía ActionRewards.GetCash(DailyTasks.RewardKey(def)))
		.Icon          — ImageLabel (rbxassetid)

	Qué tarea toca en cada slot lo decide `GetRotation(dateKey)`: un baraje
	determinista sembrado con la fecha, así que server y cliente sacan la MISMA
	rotación sin replicar nada. El cash es de la TAREA, no del slot: cada
	entrada del pool tiene su clave `"Daily" .. Key` en `ActionRewards.luau`
	(la construye `RewardKey`), que es la fuente única para cualquier sistema
	que conceda XP o Cash vía `server/core/RewardService`. Así el premio escala
	con el esfuerzo de la tarea y no con el slot que le tocó en el baraje.

	El progreso se guarda por Kind (`DailyTasks.Progress[Kind]`) y el cobro por
	slot (`DailyTasks.Claimed[SlotId]`).

	Para añadir una tarea nueva: una entrada en `DailyTasks.Pool`, su clave
	`Daily<Key>` en `ActionRewards.luau` y el hook en el server que llame a
	`DailyTasksService:IncrementProgress/ReportBest` con su Kind.
]]

export type TaskKind =
	"Eliminations"
	| "WinMatches"
	| "PlayMatches"
	| "Headshots"
	| "KillStreak"
	| "Assists"

-- Cómo se acumula el contador del Kind:
--   "counter" — suma cada evento (kills, headshots, partidas…).
--   "best"    — guarda el mejor valor reportado (rachas: 4 bajas seguidas no son
--               4 eventos sumados, es un único valor "4" que solo sube).
export type TaskMode = "counter" | "best"

export type TaskDefinition = {
	Key: string,        -- id estable de la tarea (no del slot)
	Kind: TaskKind,     -- contador que la mueve
	Mode: TaskMode,
	Title: string,
	Icon: string,       -- rbxassetid (vacío = el slot conserva el icono del asset)
	Objective: number,  -- meta a alcanzar
}

-- Una tarea colocada en un slot concreto para un día concreto.
export type ActiveTask = {
	SlotId: string,
	Definition: TaskDefinition,
}

local DailyTasks = {}

-- Slots de UI = claves de Claimed = claves de cash en ActionRewards.
DailyTasks.SlotIds = { "Task1", "Task2", "Task3" } :: { string }

DailyTasks.Pool = {
	{
		Key = "Eliminations",
		Kind = "Eliminations",
		Mode = "counter",
		Title = "Eliminations",
		Icon = "rbxassetid://87933886143928",
		Objective = 3,
	},
	{
		Key = "WinMatches",
		Kind = "WinMatches",
		Mode = "counter",
		Title = "Win Matches",
		Icon = "rbxassetid://112053349618869",
		Objective = 2,
	},
	{
		Key = "PlayMatches",
		Kind = "PlayMatches",
		Mode = "counter",
		Title = "Play Matches",
		Icon = "rbxassetid://133869836581697",
		Objective = 3,
	},
	{
		Key = "Headshots",
		Kind = "Headshots",
		Mode = "counter",
		Title = "Headshots",
		Icon = "",
		Objective = 4,
	},
	{
		Key = "KillStreak",
		Kind = "KillStreak",
		Mode = "best",
		Title = "Kill Streak",
		Icon = "",
		Objective = 3,
	},
	{
		Key = "Assists",
		Kind = "Assists",
		Mode = "counter",
		Title = "Assists",
		Icon = "",
		Objective = 3,
	},
} :: { TaskDefinition }

DailyTasks.ByKey = {} :: { [string]: TaskDefinition }
DailyTasks.ByKind = {} :: { [string]: TaskDefinition }
-- Todos los Kind del pool: el reset diario pone a 0 este set completo, no solo
-- el de las tareas que tocaban ayer.
DailyTasks.Kinds = {} :: { string }
for _, task in DailyTasks.Pool do
	DailyTasks.ByKey[task.Key] = task
	DailyTasks.ByKind[task.Kind] = task
	table.insert(DailyTasks.Kinds, task.Kind)
end

-- Día UTC actual como "YYYY-MM-DD". UTC evita saltos por la timezone del server
-- (los de Roblox pueden estar en cualquier región): todos comparten el mismo día.
function DailyTasks.TodayKey(): string
	return os.date("!%Y-%m-%d") :: string
end

-- Semilla numérica de una fecha "YYYY-MM-DD" → 20260903. Sin fecha válida (datos
-- todavía sin sembrar) cae en la de hoy.
local function _seedFromDateKey(dateKey: string?): number
	local digits = if type(dateKey) == "string" then (string.gsub(dateKey, "%D", "")) else ""
	local seed = tonumber(digits)
	if not seed or seed <= 0 then
		seed = tonumber((string.gsub(DailyTasks.TodayKey(), "%D", ""))) or 1
	end
	return seed :: number
end

-- Baraje Fisher-Yates con un LCG propio (Lehmer, el mismo de MINSTD). No usamos
-- Random a propósito: así la rotación depende SOLO de la fecha y sale idéntica en
-- server y cliente pase lo que pase con el RNG del engine.
local function _shuffledPool(seed: number): { TaskDefinition }
	local order = table.clone(DailyTasks.Pool)
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	for i = #order, 2, -1 do
		state = (state * 48271) % 2147483647
		local j = (state % i) + 1
		order[i], order[j] = order[j], order[i]
	end
	return order
end

-- Cache por fecha: la rotación se pide en cada repintado de UI y es pura.
local _rotationCache: { [string]: { ActiveTask } } = {}

--- Las tres tareas del día `dateKey` ("YYYY-MM-DD"), en orden de slot.
function DailyTasks.GetRotation(dateKey: string?): { ActiveTask }
	local seed = _seedFromDateKey(dateKey)
	local cacheKey = tostring(seed)
	local cached = _rotationCache[cacheKey]
	if cached then
		return cached
	end

	local order = _shuffledPool(seed)
	local rotation: { ActiveTask } = {}
	for index, slotId in DailyTasks.SlotIds do
		local def = order[index]
		if def then
			table.insert(rotation, { SlotId = slotId, Definition = def })
		end
	end
	_rotationCache[cacheKey] = rotation
	return rotation
end

--- Definición que le toca hoy al slot "Task1"/"Task2"/"Task3".
function DailyTasks.GetForSlot(dateKey: string?, slotId: string): TaskDefinition?
	for _, active in DailyTasks.GetRotation(dateKey) do
		if active.SlotId == slotId then
			return active.Definition
		end
	end
	return nil
end

--- Tarea activa hoy para un Kind (y en qué slot). nil si ese Kind no salió hoy:
--- lo que se cuente para él ese día no tiene dónde pagarse.
function DailyTasks.FindActive(dateKey: string?, kind: string): (TaskDefinition?, string?)
	for _, active in DailyTasks.GetRotation(dateKey) do
		if active.Definition.Kind == kind then
			return active.Definition, active.SlotId
		end
	end
	return nil, nil
end

function DailyTasks.GetByKey(key: string): TaskDefinition?
	return DailyTasks.ByKey[key]
end

--- Clave de `ActionRewards` que paga esta tarea ("Daily" .. Key). Única
--- construcción de la convención: server (al pagar) y cliente (al pintar el
--- premio) pasan por aquí para no hablar de claves distintas.
function DailyTasks.RewardKey(def: TaskDefinition): string
	return "Daily" .. def.Key
end

return table.freeze(DailyTasks)
