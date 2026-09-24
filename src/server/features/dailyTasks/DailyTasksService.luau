--!strict
--[[
	Pool y rotación del día: `shared/constants/DailyTasks.luau`. El cash lo pone la
	TAREA (clave `DailyTasks.RewardKey(def)` en `ActionRewards.luau`); el slot solo
	identifica el cobro (`Claimed[SlotId]`). Reset por día UTC.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyTasks = require(Shared.constants.DailyTasks)
local ActionRewards = require(Shared.constants.ActionRewards)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule
local RewardService = require(script.Parent.Parent.Parent.core.RewardService)

local DailyTasksService = {}
DailyTasksService.__index = DailyTasksService

local _dataService: DataService = nil :: any
local _started = false
-- En memoria: solo interesa el mejor valor del día, que va a Progress vía ReportBest.
local _killStreakByUserId: { [number]: number } = {}

local _todayKey = DailyTasks.TodayKey

-- TODOS los Kind del pool: la rotación de mañana no debe heredar contadores viejos.
local function _zeroedProgress(): { [string]: number }
	local zeroed: { [string]: number } = {}
	for _, kind in DailyTasks.Kinds do
		zeroed[kind] = 0
	end
	return zeroed
end

local function _resetForToday(player: Player, dateKey: string)
	if not _dataService then return end
	local claimed: { [string]: boolean } = {}
	for _, slotId in DailyTasks.SlotIds do
		claimed[slotId] = false
	end
	_dataService:BatchUpdate(player, {
		{ path = { "DailyTasks", "DateKey" }, value = dateKey },
		{ path = { "DailyTasks", "Progress" }, value = _zeroedProgress() },
		{ path = { "DailyTasks", "Claimed" }, value = claimed },
	})
end

local function _ensureToday(player: Player): boolean
	if not _dataService then return false end
	local profile = _dataService:GetProfile(player)
	if not profile then return false end

	local today = _todayKey()
	local stored = profile.Data.DailyTasks and profile.Data.DailyTasks.DateKey or ""
	if stored ~= today then
		_resetForToday(player, today)
	end
	return true
end

-- `dateKey` sale del perfil ya reseteado, así que se paga exactamente la rotación
-- que el cliente está pintando.
local function _applyProgress(
	player: Player,
	kind: string,
	resolveProgress: (current: number, objective: number) -> number
): ()
	if not _dataService or not player then return end
	if not _ensureToday(player) then return end

	local profile = _dataService:GetProfile(player)
	if not profile then return end

	local state = profile.Data.DailyTasks
	local dateKey = if type(state.DateKey) == "string" then state.DateKey else _todayKey()
	local taskDef, slotId = DailyTasks.FindActive(dateKey, kind)
	-- Kind fuera de la rotación de hoy: no hay slot, no se escribe progreso.
	if not taskDef or not slotId then return end

	local progress = state.Progress or {}
	local claimed = state.Claimed or {}

	local objective = math.max(1, math.floor(taskDef.Objective))
	local current = math.max(0, math.floor((progress :: any)[kind] or 0))
	local newProgress = math.clamp(math.floor(resolveProgress(current, objective)), 0, objective)

	local wasClaimed = (claimed :: any)[slotId] == true
	local justCompleted = newProgress >= objective and not wasClaimed
	if newProgress == current and not justCompleted then
		return
	end

	local progressUpdate = { path = { "DailyTasks", "Progress", kind }, value = newProgress }
	if justCompleted then
		-- Award mete Cash + Progress + Claimed en un único BatchUpdate atómico.
		RewardService.Award(player, DailyTasks.RewardKey(taskDef), {
			progressUpdate,
			{ path = { "DailyTasks", "Claimed", slotId }, value = true },
		}, taskDef.Kind)
	else
		_dataService:BatchUpdate(player, { progressUpdate })
	end
end

function DailyTasksService:IncrementProgress(player: Player, kind: string, amount: number?): ()
	local delta = math.max(0, math.floor(amount or 1))
	if delta <= 0 then return end
	_applyProgress(player, kind, function(current)
		return current + delta
	end)
end

-- Para tareas de racha: se queda con el máximo, no suma.
function DailyTasksService:ReportBest(player: Player, kind: string, value: number): ()
	local reported = math.max(0, math.floor(value or 0))
	if reported <= 0 then return end
	_applyProgress(player, kind, function(current)
		return math.max(current, reported)
	end)
end

-- Hooks semánticos: los callers no conocen los Kind internos.
function DailyTasksService:OnKill(player: Player): ()
	if not player then return end
	self:IncrementProgress(player, "Eliminations", 1)
	-- Única racha del server; la de StreakDisplay (cliente) es puramente visual.
	local streak = (_killStreakByUserId[player.UserId] or 0) + 1
	_killStreakByUserId[player.UserId] = streak
	self:ReportBest(player, "KillStreak", streak)
end

function DailyTasksService:OnHeadshot(player: Player): ()
	if not player then return end
	self:IncrementProgress(player, "Headshots", 1)
end

function DailyTasksService:OnAssist(player: Player): ()
	if not player then return end
	self:IncrementProgress(player, "Assists", 1)
end

function DailyTasksService:OnDeath(player: Player): ()
	if not player then return end
	_killStreakByUserId[player.UserId] = nil
end

-- La racha es de una vida en partida: salir al menú o acabar la ronda también la corta.
function DailyTasksService:ResetStreak(player: Player): ()
	_killStreakByUserId[player.UserId] = nil
end

function DailyTasksService:ResetAllStreaks(): ()
	table.clear(_killStreakByUserId)
end

function DailyTasksService:OnMatchWon(player: Player): ()
	if not player then return end
	self:IncrementProgress(player, "WinMatches", 1)
end

function DailyTasksService:Start(dataService: DataService): ()
	if _started then return end
	_started = true
	_dataService = dataService

	for _, def in DailyTasks.Pool do
		local rewardKey = DailyTasks.RewardKey(def)
		if not ActionRewards.Has(rewardKey) then
			warn(("[DailyTasksService] La tarea %q no tiene clave %q en ActionRewards: no pagará nada"):format(def.Key, rewardKey))
		end
	end

	for _, player in Players:GetPlayers() do
		task.spawn(_ensureToday, player)
	end

	Players.PlayerAdded:Connect(function(player)
		if _dataService:GetProfile(player) then
			_ensureToday(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		_killStreakByUserId[player.UserId] = nil
	end)
	if _dataService.ProfileLoaded then
		_dataService.ProfileLoaded:Connect(function(player)
			if player and player.Parent then
				_ensureToday(player)
			end
		end)
	end

	-- Sesiones que cruzan medianoche UTC.
	task.spawn(function()
		while _started do
			task.wait(60)
			local today = _todayKey()
			for _, player in Players:GetPlayers() do
				local profile = _dataService:GetProfile(player)
				if profile and profile.Data.DailyTasks and profile.Data.DailyTasks.DateKey ~= today then
					_resetForToday(player, today)
				end
			end
		end
	end)
end

return DailyTasksService
