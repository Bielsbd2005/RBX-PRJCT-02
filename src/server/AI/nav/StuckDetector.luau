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

	Los primeros BotConfig.Navigation.StuckSpawnGrace segundos de vida del
	detector no acumulan: recién spawneado el bot cae sobre el pad, espera
	path en la cola y se empuja con los otros bots del mismo spawn.

	Debug de mapa: si el BoolValue ServerStorage.ShowStuckMarkers está en true,
	cada escalada de nivel >= 2 deja una esfera neon rosa en el punto del
	atasco (ver debug/StuckViz).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotConfig = require(Shared:WaitForChild("constants"):WaitForChild("BotConfig"))
local StuckViz = require(script.Parent.Parent:WaitForChild("debug"):WaitForChild("StuckViz"))

-- Nivel mínimo que deja marker en el mapa. El nivel 1 (1s) dispara también con
-- atascos transitorios entre bots, que no son un problema de geometría.
local VIZ_MIN_LEVEL = 2

type Navigator = {
	isMoving: (self: any) -> boolean,
	recomputeLast: (self: any) -> (),
	cancel: (self: any, notifyFailed: boolean?) -> (),
}

type RoamGraph = {
	nearestPoint: (self: any, pos: Vector3) -> Vector3?,
}

local StuckDetector = {}
StuckDetector.__index = StuckDetector

export type StuckDetector = typeof(setmetatable({} :: {
	_rootPart: BasePart,
	_humanoid: Humanoid,
	_navigator: Navigator,
	_roamGraph: RoamGraph?,
	_botName: string,
	_lastPos: Vector3,
	_lastTickT: number,
	_spawnedAt: number,
	_stuckAccum: number,
	_triggered: { [number]: boolean },
}, StuckDetector))

function StuckDetector.new(
	rootPart: BasePart,
	humanoid: Humanoid,
	navigator: Navigator,
	roamGraph: RoamGraph?,
	botName: string?
): StuckDetector
	local self = setmetatable({
		_rootPart = rootPart,
		_humanoid = humanoid,
		_navigator = navigator,
		_roamGraph = roamGraph,
		_botName = botName or rootPart.Parent and rootPart.Parent.Name or "?",
		_lastPos = rootPart.Position,
		_lastTickT = os.clock(),
		_spawnedAt = os.clock(),
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

-- Las acciones de cada nivel NO emiten `humanoid:MoveTo` directos: hacerlo
-- cancela el MoveTo del walk loop del Navigator y dispara MoveToFinished
-- espuriamente, lo que hace que el walk loop avance a waypoints que el
-- bot nunca alcanzó (síntoma visible: "pasos a tirones").
--
-- En cambio, cada nivel opera sobre el Navigator vía API limpia
-- (cancel/recomputeLast) y deja que el caller (PATROL/CHASE) decida el
-- siguiente movimiento.
local function _applyLevel(self, level: number)
	-- Antes de tocar nada: el marker debe quedar donde el bot ESTÁ atascado.
	-- En nivel 4 el teleport mueve el rootPart, así que marcar aquí (y no al
	-- final) es lo que hace que el punto señalado sea el problemático.
	if level >= VIZ_MIN_LEVEL then
		StuckViz.mark(self._rootPart.Position, level, self._botName)
	end

	if level == 1 then
		-- 1s sin progreso: abandonar la navegación actual. cancel(true)
		-- dispara onFailed deferred → PATROL polling sale del bucle y
		-- elige otro destino. CHASE retrocede 0.3s (failure cooldown)
		-- antes de reintentar. La mayoría de stucks transitorios
		-- (bot bloqueado contra otro NPC) se resuelven aquí porque al
		-- pedir otro destino el path va por otra ruta.
		self._navigator:cancel(true)
	elseif level == 2 then
		-- 2s: recompute al mismo destino. Si la ruta original tenía un
		-- problema dinámico (otro bot bloqueando), una nueva ComputeAsync
		-- puede encontrar otra forma.
		self._navigator:recomputeLast()
	elseif level == 3 then
		-- 4s: jump + abandonar + onFailed. El jump puede ayudar si el bot
		-- está atascado contra un escalón pequeño que el pathfinder no vio.
		self._humanoid.Jump = true
		self._navigator:cancel(true)
	elseif level == 4 then
		-- 8s: teleport al roam point navegable más cercano. Última opción.
		local roamGraph = self._roamGraph
		local nearest: Vector3? = nil
		if roamGraph then
			nearest = roamGraph:nearestPoint(self._rootPart.Position)
		end
		if nearest then
			self._rootPart.CFrame = CFrame.new(nearest + Vector3.new(0, 3, 0))
			self._lastPos = self._rootPart.Position
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

	-- Gracia de spawn: durante los primeros segundos el bot cae desde +4 studs
	-- sobre el pad, espera su turno en la cola de pathfinding (saturada en
	-- round-start) y se empuja con los otros bots del mismo spawn. Nada de eso
	-- es un problema de geometría del mapa, pero el detector lo veía como
	-- "moving sin progreso" y escalaba en cada spawn.
	if now - self._spawnedAt < BotConfig.Navigation.StuckSpawnGrace then
		self._lastPos = self._rootPart.Position
		return
	end

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
