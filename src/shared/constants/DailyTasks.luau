--!strict
--[[
	DailyTasks.luau
	Catálogo de tareas diarias. De momento la lista es estática (las mismas
	tres tareas todos los días); el progreso por jugador se refresca cada día.

	Mapea 1:1 con los slots de UI:
	  MatchHud.LeftContainer.TaskFrame.Task1/Task2/Task3
	  Workspace.Lobby.Daily.Board.SurfaceGui.Container.TaskFrame.Task1/Task2/Task3
	Cada slot consume:
		.Title         — TextLabel
		.Value         — TextLabel "<progress>/<objective>"
		.Bar.Fill      — Frame (escalado X = progress/objective)
		.Reward.Value  — TextLabel (Cash, resuelto vía ActionRewards.GetCash("Daily"..Id))
		.Icon          — ImageLabel (rbxassetid)

	El cash que da cada tarea NO vive aquí — vive en
	`shared/constants/ActionRewards.luau` bajo las claves DailyTask1/DailyTask2/
	DailyTask3 (convención: "Daily" .. Id). Es la fuente única de verdad para
	cualquier sistema que conceda XP o Cash, vía `server/core/RewardService`.
]]

export type TaskKind = "Eliminations" | "WinMatches" | "PlayMatches"

export type TaskDefinition = {
	Id: string,         -- "Task1" / "Task2" / "Task3" — coincide con el nombre del slot UI
	Kind: TaskKind,     -- contador que incrementa esta tarea
	Title: string,
	Icon: string,       -- rbxassetid (vacío hasta que se asigne)
	Objective: number,  -- meta a alcanzar
}

local DailyTasks = {}

DailyTasks.Tasks = {
	{
		Id = "Task1",
		Kind = "Eliminations",
		Title = "Eliminations",
		Icon = "rbxassetid://87933886143928",
		Objective = 3,
	},
	{
		Id = "Task2",
		Kind = "WinMatches",
		Title = "Win Matches",
		Icon = "rbxassetid://112053349618869",
		Objective = 2,
	},
	{
		Id = "Task3",
		Kind = "PlayMatches",
		Title = "Play Matches",
		Icon = "rbxassetid://133869836581697",
		Objective = 3,
	},
} :: { TaskDefinition }

-- Lookup por Id (Task1/Task2/Task3) — coincide con los nombres de los slots UI.
DailyTasks.ById = {} :: { [string]: TaskDefinition }
for _, task in DailyTasks.Tasks do
	DailyTasks.ById[task.Id] = task
end

-- Lookup por Kind — útil para incrementar progreso desde eventos del juego
-- (RewardsService al matar, MatchService al ganar/jugar partida).
DailyTasks.ByKind = {} :: { [string]: TaskDefinition }
for _, task in DailyTasks.Tasks do
	DailyTasks.ByKind[task.Kind] = task
end

function DailyTasks.GetById(id: string): TaskDefinition?
	return DailyTasks.ById[id]
end

function DailyTasks.GetByKind(kind: string): TaskDefinition?
	return DailyTasks.ByKind[kind]
end

return table.freeze(DailyTasks)
