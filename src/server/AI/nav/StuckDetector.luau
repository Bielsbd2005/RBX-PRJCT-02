--!strict
--[[
	StuckDetector — escalada de 4 niveles cuando un bot deja de progresar.

	Tickeado por el bot cada loop iter en PATROL/CHASE. El detector consulta
	`navigator:isMoving()` directamente — no se pasa flag externo. Si el
	Navigator no está moviendo (Engage parado, Roam idle post-arrive), el
	contador no acumula.

	Mientras Navigator está moving, mide displacement contra la última
	muestra. Si la velocidad neta es < StuckMoveEpsilon studs/seg, acumula
	tiempo. Al cruzar cada threshold de BotConfig.Navigation.StuckThresholds
	dispara la acción correspondiente:

	  1.0s lateral  → MoveTo offset ±4 studs (XZ). Tag stuck_lateral.
	  2.0s repath   → navigator:recomputeLast(). Tag stuck_repath.
	  4.0s jump     → Humanoid.Jump = true + offset ±8 studs. Tag stuck_jump
	                  (print inmediato).
	  8.0s teleport → rootPart.CFrame = roamGraph:nearestPoint + Y3.
	                  Tag stuck_teleport (print inmediato).

	El roamGraph es opcional en commit 2 (no existe todavía); cuando es nil
	el nivel 4 hace log de stuck_teleport_unavailable y no teleporta. Commit
	3 introduce RoamGraph y nivel 4 queda funcional.

	Cuando el bot vuelve a moverse (speed >= epsilon) los contadores y
	triggers se resetean automáticamente.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotConfig = require(Shared:WaitForChild("constants"):WaitForChild("BotConfig"))

type Navigator = {
	isMoving: (self: any) -> boolean,
	recomputeLast: (self: any) -> (),
	cancel: (self: any, notifyFailed: boolean?) -> (),
}

type RoamGraph = {
	nearestPoint: (self: any, pos: Vector3) -> Vector3?,
}

type MetricsSink = {
	record: (tag: string, payload: { [string]: any }, immediate: boolean?) -> (),
}

local StuckDetector = {}
StuckDetector.__index = StuckDetector

export type StuckDetector = typeof(setmetatable({} :: {
	_rootPart: BasePart,
	_humanoid: Humanoid,
	_navigator: Navigator,
	_roamGraph: RoamGraph?,
	_metrics: MetricsSink?,
	_botName: string,
	_mapName: string,
	_lastPos: Vector3,
	_lastTickT: number,
	_stuckAccum: number,
	_triggered: { [number]: boolean },
}, StuckDetector))

function StuckDetector.new(
	rootPart: BasePart,
	humanoid: Humanoid,
	navigator: Navigator,
	roamGraph: RoamGraph?,
	metrics: MetricsSink?,
	botName: string?,
	mapName: string?
): StuckDetector
	local self = setmetatable({
		_rootPart = rootPart,
		_humanoid = humanoid,
		_navigator = navigator,
		_roamGraph = roamGraph,
		_metrics = metrics,
		_botName = botName or rootPart.Parent and rootPart.Parent.Name or "?",
		_mapName = mapName or "?",
		_lastPos = rootPart.Position,
		_lastTickT = os.clock(),
		_stuckAccum = 0,
		_triggered = {},
	}, StuckDetector) :: StuckDetector
	return self
end

local function _resetCounters(self)
	self._stuckAccum = 0
	table.clear(self._triggered)
end

function StuckDetector:reset()
	_resetCounters(self)
	self._lastPos = self._rootPart.Position
	self._lastTickT = os.clock()
end

local function _emit(self, tag: string, level: number, immediate: boolean)
	if not self._metrics then
		return
	end
	self._metrics.record(tag, {
		bot = self._botName,
		map = self._mapName,
		level = level,
		pos = self._rootPart.Position,
	}, immediate)
end

-- Las acciones de cada nivel NO emiten `humanoid:MoveTo` directos: hacerlo
-- cancela el MoveTo del walk loop del Navigator y dispara MoveToFinished
-- espuriamente, lo que hace que el walk loop avance a waypoints que el
-- bot nunca alcanzó (síntoma visible: "pasos a tirones").
--
-- En cambio, cada nivel opera sobre el Navigator vía API limpia
-- (cancel/recomputeLast) y deja que el caller (PATROL/CHASE) decida el
-- siguiente movimiento.
local function _applyLevel(self, level: number)
	if level == 1 then
		-- 1s sin progreso: abandonar la navegación actual. cancel(true)
		-- dispara onFailed deferred → PATROL polling sale del bucle y
		-- elige otro destino. CHASE retrocede 0.3s (failure cooldown)
		-- antes de reintentar. La mayoría de stucks transitorios
		-- (bot bloqueado contra otro NPC) se resuelven aquí porque al
		-- pedir otro destino el path va por otra ruta.
		self._navigator:cancel(true)
		_emit(self, "stuck_lateral", level, false)
	elseif level == 2 then
		-- 2s: recompute al mismo destino. Si la ruta original tenía un
		-- problema dinámico (otro bot bloqueando), una nueva ComputeAsync
		-- puede encontrar otra forma.
		self._navigator:recomputeLast()
		_emit(self, "stuck_repath", level, false)
	elseif level == 3 then
		-- 4s: jump + abandonar + onFailed. El jump puede ayudar si el bot
		-- está atascado contra un escalón pequeño que el pathfinder no vio.
		self._humanoid.Jump = true
		self._navigator:cancel(true)
		_emit(self, "stuck_jump", level, true)
	elseif level == 4 then
		-- 8s: teleport al roam point navegable más cercano. Última opción.
		local roamGraph = self._roamGraph
		local nearest: Vector3? = nil
		if roamGraph then
			nearest = roamGraph:nearestPoint(self._rootPart.Position)
		end
		if nearest then
			self._rootPart.CFrame = CFrame.new(nearest + Vector3.new(0, 3, 0))
			_emit(self, "stuck_teleport", level, true)
			self._lastPos = self._rootPart.Position
		else
			_emit(self, "stuck_teleport_unavailable", level, true)
		end
		self._navigator:cancel(true)
		-- Reset post-teleport: el bot está en nuevo sitio, los contadores
		-- empiezan de cero (igual que cualquier movimiento real).
		self._stuckAccum = 0
		table.clear(self._triggered)
	end
end

function StuckDetector:tick(now: number)
	local dt = now - self._lastTickT
	self._lastTickT = now

	local navigator = self._navigator
	local moving = navigator:isMoving()

	if not moving then
		-- Navigator idle: el bot no debería estar moviéndose (entre paths,
		-- en ATTACK, post-cancel esperando nuevo path...). No acumulamos
		-- stuck pero TAMPOCO reseteamos — _stuckAccum se mantiene entre
		-- ciclos cancel→walk para que la escalada pueda llegar a level 4
		-- aunque el bot esté ciclando entre level 1 y nuevo walk.
		self._lastPos = self._rootPart.Position
		return
	end

	if dt <= 0 then
		return
	end

	local pos = self._rootPart.Position
	local displacement = (pos - self._lastPos).Magnitude
	local speed = displacement / dt
	self._lastPos = pos

	if speed >= BotConfig.Navigation.StuckMoveEpsilon then
		-- Bot SE ESTÁ MOVIENDO. Esto es el único reset legítimo:
		-- recompenza un walk exitoso o un escape lateral. Limpia
		-- _stuckAccum y _triggered para que próximos stucks empiecen
		-- desde cero.
		_resetCounters(self)
		return
	end

	-- Navigator dice "moving" pero el bot no progresa. Acumular.
	self._stuckAccum += dt
	local stuckDur = self._stuckAccum
	local thresholds = BotConfig.Navigation.StuckThresholds

	if stuckDur >= thresholds.teleport and not self._triggered[4] then
		self._triggered[4] = true
		_applyLevel(self, 4)
	elseif stuckDur >= thresholds.jump and not self._triggered[3] then
		self._triggered[3] = true
		_applyLevel(self, 3)
	elseif stuckDur >= thresholds.repath and not self._triggered[2] then
		self._triggered[2] = true
		_applyLevel(self, 2)
	elseif stuckDur >= thresholds.lateral and not self._triggered[1] then
		self._triggered[1] = true
		_applyLevel(self, 1)
	end
end

return StuckDetector
