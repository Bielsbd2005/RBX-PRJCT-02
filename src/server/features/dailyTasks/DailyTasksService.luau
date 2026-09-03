--!strict
--[[
	DailyTasksService.luau  (Server)

	Mantiene el progreso de tareas diarias por jugador y otorga el cash
	cuando se completan. El pool de tareas y la rotación del día viven en
	`shared/constants/DailyTasks.luau`; el cash lo pone la TAREA (clave
	`DailyTasks.RewardKey(def)` = "Daily" .. Key en `ActionRewards.luau`), y el
	slot solo identifica el cobro (`Claimed[SlotId]`).

	Responsabilidades:
	  • Reset diario por jugador: al cargar el perfil o al cambiar el día UTC
	    durante la sesión, resetea Progress (todos los Kind del pool) y Claimed.
	  • IncrementProgress(player, kind, amount): suma al contador del Kind.
	  • ReportBest(player, kind, value): deja el mejor valor reportado (tareas de
	    racha, donde el progreso no es una suma de eventos sino un máximo).
	    Los dos, si alcanzan el objetivo y el slot no está claimed, conceden Cash
	    vía RewardService y marcan Claimed atómicamente. Idempotentes respecto a
	    llamadas extra (no pagan doble). Si el Kind no salió en la rotación de hoy
	    no se escribe nada: no hay slot que pagar.
	  • Hooks expuestos: OnKill, OnHeadshot, OnAssist, OnDeath, OnMatchPlayed,
	    OnMatchWon — hooks semánticos para que WeaponsSystem y MatchService no
	    tengan que conocer Kind.
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
-- Racha de bajas sin morir, en memoria. No se persiste: de la racha solo interesa
-- el mejor valor del día, y eso ya va a Progress vía ReportBest.
local _killStreakByUserId: { [number]: number } = {}

-- Devuelve el día UTC actual como "YYYY-MM-DD". Usar UTC evita saltos por
-- timezone del servidor (los servidores de Roblox pueden estar en cualquier
-- región). Todos los jugadores comparten el mismo "día".
local function _todayKey(): string
	return os.date("!%Y-%m-%d") :: string
end

-- Progreso a 0 para TODOS los Kind del pool (no solo los que tocaban ayer): la
-- rotación de mañana puede traer cualquiera y no debe heredar contadores viejos.
local function _zeroedProgress(): { [string]: number }
	local zeroed: { [string]: number } = {}
	for _, kind in DailyTasks.Kinds do
		zeroed[kind] = 0
	end
	return zeroed
end

-- Resetea Progress + Claimed y graba la fecha actual. Una sola escritura por
-- sección DailyTasks (BatchUpdate genera 1 mensaje de red).
local function _resetForToday(player: Player, dateKey: string)
	if not _dataService then return end
	_dataService:BatchUpdate(player, {
		{ path = { "DailyTasks", "DateKey" }, value = dateKey },
		{ path = { "DailyTasks", "Progress" }, value = _zeroedProgress() },
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

-- Núcleo común de progreso: resuelve la tarea que ocupa hoy ese Kind, calcula el
-- nuevo valor con `resolveProgress` (sumar o quedarse con el máximo) y procesa el
-- claim si toca. `dateKey` sale del perfil ya reseteado, así que la rotación que
-- se paga es exactamente la que el cliente está pintando.
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
	-- Ese Kind no salió en la rotación de hoy: no hay slot al que pagarlo, así que
	-- tampoco se escribe progreso.
	if not taskDef or not slotId then return end

	local progress = state.Progress or {}
	local claimed = state.Claimed or {}

	local objective = math.max(1, math.floor(taskDef.Objective))
	local current = math.max(0, math.floor((progress :: any)[kind] or 0))
	-- Capear al objetivo: no tiene sentido seguir contando una vez completada
	-- (también evita números cosméticamente "9999/10" en UI).
	local newProgress = math.clamp(math.floor(resolveProgress(current, objective)), 0, objective)

	local wasClaimed = (claimed :: any)[slotId] == true
	-- Reglas de claim: progreso completo + no claimed previamente.
	local justCompleted = newProgress >= objective and not wasClaimed
	if newProgress == current and not justCompleted then
		return
	end

	local progressUpdate = { path = { "DailyTasks", "Progress", kind }, value = newProgress }
	if justCompleted then
		-- RewardService.Award resuelve el cash (clave de la tarea en
		-- ActionRewards), mete Cash + Progress + Claimed en un único BatchUpdate
		-- (atómico) y aplica XP por separado vía AddXP. Cash delta evita TOCTOU
		-- con compras/kills.
		RewardService.Award(player, DailyTasks.RewardKey(taskDef), {
			progressUpdate,
			{ path = { "DailyTasks", "Claimed", slotId }, value = true },
		}, taskDef.Kind)
	else
		_dataService:BatchUpdate(player, { progressUpdate })
	end
end

-- Incrementa el contador del Kind y procesa el claim si corresponde.
function DailyTasksService:IncrementProgress(player: Player, kind: string, amount: number?): ()
	local delta = math.max(0, math.floor(amount or 1))
	if delta <= 0 then return end
	_applyProgress(player, kind, function(current)
		return current + delta
	end)
end

-- Deja el MEJOR valor reportado para el Kind (tareas de racha).
function DailyTasksService:ReportBest(player: Player, kind: string, value: number): ()
	local reported = math.max(0, math.floor(value or 0))
	if reported <= 0 then return end
	_applyProgress(player, kind, function(current)
		return math.max(current, reported)
	end)
end

-- Hooks semánticos — los callers no conocen los Kind internos.
function DailyTasksService:OnKill(player: Player): ()
	if not player then return end
	self:IncrementProgress(player, "Eliminations", 1)
	-- La racha vive aquí porque el server ya no la lleva en ningún sitio (la
	-- lógica vieja de rachas se eliminó de MatchService); el popup del cliente
	-- (StreakDisplay) tiene la suya, puramente visual.
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

-- Morir corta la racha (misma semántica que el popup de racha del cliente).
function DailyTasksService:OnDeath(player: Player): ()
	if not player then return end
	_killStreakByUserId[player.UserId] = nil
end

function DailyTasksService:OnMatchPlayed(player: Player): ()
	if not player then return end
	self:IncrementProgress(player, "PlayMatches", 1)
end

function DailyTasksService:OnMatchWon(player: Player): ()
	if not player then return end
	self:IncrementProgress(player, "WinMatches", 1)
end

-- Inicialización: arranca un loop que comprueba el cambio de día UTC para
-- jugadores activos (relevante para sesiones largas que cruzan medianoche).
function DailyTasksService:Start(dataService: DataService): ()
	if _started then return end
	_started = true
	_dataService = dataService

	-- Guard de configuración: cada tarea del pool necesita su clave en
	-- ActionRewards o Award avisará "Acción desconocida" y la tarea pagará 0.
	for _, def in DailyTasks.Pool do
		local rewardKey = DailyTasks.RewardKey(def)
		if not ActionRewards.Has(rewardKey) then
			warn(("[DailyTasksService] La tarea %q no tiene clave %q en ActionRewards: no pagará nada"):format(def.Key, rewardKey))
		end
	end

	-- Reset al cargar perfiles ya presentes (rejoin entre días).
	for _, player in Players:GetPlayers() do
		task.spawn(_ensureToday, player)
	end

	-- Audit mobile: signal-driven en lugar de polling cada 1s × 30 iteraciones.
	-- DataService.ProfileLoaded dispara una vez por player cuando su Replica
	-- está lista. Si el profile ya está cargado al subscribir, fast-path.
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
