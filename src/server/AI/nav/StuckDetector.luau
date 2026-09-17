--!strict
--[[
	Escalada de 4 niveles (umbrales en BotConfig.Navigation.StuckThresholds)
	cuando el bot no progresa mientras navigator:isMoving(); con el Navigator
	idle no acumula. Debug: BoolValue ServerStorage.ShowStuckMarkers = true deja
	una esfera en cada atasco de nivel >= VIZ_MIN_LEVEL (ver debug/StuckViz).
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

-- Los niveles NO llaman humanoid:MoveTo: cancelaría el MoveTo del walk loop del
-- Navigator y dispararía MoveToFinished espurio (avanza a waypoints no
-- alcanzados). Operan vía cancel/recomputeLast y el caller decide el movimiento.
local function _applyLevel(self, level: number)
	-- Marcar antes de actuar: el teleport de nivel 4 mueve el rootPart.
	if level >= VIZ_MIN_LEVEL then
		StuckViz.mark(self._rootPart.Position, level, self._botName)
	end

	if level == 1 then
		-- cancel(true) dispara onFailed deferred: PATROL elige otro destino y
		-- CHASE reintenta tras su failure cooldown. Resuelve la mayoría de
		-- bloqueos transitorios contra otros NPC.
		self._navigator:cancel(true)
	elseif level == 2 then
		-- Recompute al mismo destino por si el bloqueo era dinámico.
		self._navigator:recomputeLast()
	elseif level == 3 then
		-- El jump ayuda con escalones pequeños que el pathfinder no vio.
		self._humanoid.Jump = true
		self._navigator:cancel(true)
	elseif level == 4 then
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
		self._stuckAccum = 0
		table.clear(self._triggered)
	end
end

function StuckDetector:tick(now: number)
	local dt = now - self._lastTickT
	self._lastTickT = now

	-- Gracia de spawn: el bot cae sobre el pad, espera la cola de pathfinding
	-- (saturada en round-start) y se empuja con otros bots; no es geometría.
	if now - self._spawnedAt < BotConfig.Navigation.StuckSpawnGrace then
		self._lastPos = self._rootPart.Position
		return
	end

	local navigator = self._navigator
	local moving = navigator:isMoving()

	if not moving then
		-- No acumula pero TAMPOCO resetea: _stuckAccum sobrevive a los ciclos
		-- cancel→walk para que la escalada llegue a nivel 4 aunque el bot
		-- cicle entre nivel 1 y un nuevo walk.
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
		-- Único reset legítimo de los contadores.
		_resetCounters(self)
		return
	end

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
