--!strict
--[[
	DailyTasksService.luau  (Server)

	Mantiene el progreso de tareas diarias por jugador y otorga el cash
	cuando se completan. La definición de las tareas vive en
	`shared/constants/DailyTasks.luau` (Id, Kind, Title, Objective, Cash).

	Responsabilidades:
	  • Reset diario por jugador: al cargar el perfil o al cambiar el día UTC
	    durante la sesión, resetea Progress y Claimed.
	  • IncrementProgress(player, kind, amount): suma al contador del Kind y,
	    si supera el objetivo y la tarea no está claimed, otorga Cash y marca
	    Claimed. Idempotente respecto a llamadas extra (no paga doble).
	  • Hooks expuestos: OnKill, OnMatchPlayed, OnMatchWon — hooks semánticos
	    para que WeaponsSystem y MatchService no tengan que conocer Kind.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyTasks = require(Shared.constants.DailyTasks)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local DailyTasksService = {}
DailyTasksService.__index = DailyTasksService

local _dataService: DataService = nil :: any
local _started = false

-- Devuelve el día UTC actual como "YYYY-MM-DD". Usar UTC evita saltos por
-- timezone del servidor (los servidores de Roblox pueden estar en cualquier
-- región). Todos los jugadores comparten el mismo "día".
local function _todayKey(): string
	return os.date("!%Y-%m-%d") :: string
end

-- Resetea Progress + Claimed y graba la fecha actual. Una sola escritura por
-- sección DailyTasks (BatchUpdate genera 1 mensaje de red).
local function _resetForToday(player: Player, dateKey: string)
	if not _dataService then return end
	_dataService:BatchUpdate(player, {
		{ path = { "DailyTasks", "DateKey" }, value = dateKey },
		{ path = { "DailyTasks", "Progress" }, value = {
			Eliminations = 0,
			WinMatches = 0,
			PlayMatches = 0,
		} },
		{ path = { "DailyTasks", "Claimed" }, value = {
			Task1 = false,
			Task2 = false,
			Task3 = false,
		} },
	})
end

-- Lazy: si el día UTC cambió desde la última escritura, resetea antes de leer.
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

-- Incrementa el contador del Kind y procesa el claim si corresponde.
function DailyTasksService:IncrementProgress(player: Player, kind: string, amount: number?): ()
	if not _dataService then return end
	local taskDef = DailyTasks.GetByKind(kind)
	if not taskDef then return end

	local delta = math.max(0, math.floor(amount or 1))
	if delta <= 0 then return end

	if not _ensureToday(player) then return end

	local profile = _dataService:GetProfile(player)
	if not profile then return end

	local state = profile.Data.DailyTasks
	local progress = state.Progress or {}
	local claimed = state.Claimed or {}

	local current = math.max(0, math.floor((progress :: any)[kind] or 0))
	-- Capear al objetivo: no tiene sentido seguir contando una vez completada
	-- (también evita números cosméticamente "9999/10" en UI).
	local newProgress = math.min(taskDef.Objective, current + delta)

	-- Si ya estaba al máximo y claimed, no hacer nada.
	local wasClaimed = (claimed :: any)[taskDef.Id] == true
	if newProgress == current and wasClaimed then
		return
	end

	local updates = {
		{ path = { "DailyTasks", "Progress", kind }, value = newProgress },
	}

	-- Reglas de claim: progreso completo + no claimed previamente.
	local justCompleted = newProgress >= taskDef.Objective and not wasClaimed
	if justCompleted then
		table.insert(updates, { path = { "DailyTasks", "Claimed", taskDef.Id }, value = true })
		-- Cash con delta: evita TOCTOU si una compra/kill muta Stats.Cash
		-- entre este punto y el apply del BatchUpdate.
		table.insert(updates, { path = { "Stats", "Cash" }, delta = taskDef.Cash })
	end

	_dataService:BatchUpdate(player, updates)
end

-- Hooks semánticos — los callers no conocen los Kind internos.
function DailyTasksService:OnKill(player: Player): ()
	self:IncrementProgress(player, "Eliminations", 1)
end

function DailyTasksService:OnMatchPlayed(player: Player): ()
	self:IncrementProgress(player, "PlayMatches", 1)
end

function DailyTasksService:OnMatchWon(player: Player): ()
	self:IncrementProgress(player, "WinMatches", 1)
end

-- Inicialización: arranca un loop que comprueba el cambio de día UTC para
-- jugadores activos (relevante para sesiones largas que cruzan medianoche).
function DailyTasksService:Start(dataService: DataService): ()
	if _started then return end
	_started = true
	_dataService = dataService

	-- Reset al cargar perfiles ya presentes (rejoin entre días).
	for _, player in Players:GetPlayers() do
		task.spawn(_ensureToday, player)
	end

	-- Reset al cargar nuevos perfiles. PlayerAdded se dispara antes de que el
	-- profile esté listo; reintentamos hasta que GetProfile devuelva no-nil.
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			for _ = 1, 30 do
				if not player.Parent then return end
				if _dataService:GetProfile(player) then
					_ensureToday(player)
					return
				end
				task.wait(1)
			end
		end)
	end)

	-- Loop ligero: cada 60s, si el día cambió, resetea para todos los activos.
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
