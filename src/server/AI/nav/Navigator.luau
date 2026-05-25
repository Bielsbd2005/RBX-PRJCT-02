--!strict
--[[
	Navigator — wrapper de pathfinding por bot.

	Encapsula:
	  • Path persistente (una sola asignación, reusada por ComputeAsync).
	  • Throttle: ignora goTo si el destino está a <5 studs del anterior Y
	    pasó <MinComputeInterval (1s) desde el último compute. Recompute
	    automático cuando cualquiera de los dos relax.
	  • Cooldown post Path.Blocked (0.3s) — evita repath storms cuando el
	    path explota mid-walk.
	  • Walk loop basado en humanoid:Move(direction) + check posicional
	    manual. NO usa MoveToFinished (evento global compartido con otros
	    sitios que llaman humanoid:MoveTo — racey con timeouts diferidos).

	Encolado de ComputeAsync vía `PathfindingQueue` global → diluye el spike
	de round-start.

	API mínima:
	  Navigator.new(humanoid, rootPart, agentParams) → Navigator
	  :goTo(dest, opts?: {onArrived, onFailed}) — no bloquea.
	  :cancel() — para el rig y descarta path activo.
	  :isMoving() → boolean
	  :Stop() — desconecta y libera. Tras Stop la instancia no se reusa.
]]

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotConfig = require(Shared:WaitForChild("constants"):WaitForChild("BotConfig"))

local nav = script.Parent
local PathfindingQueue = require(nav:WaitForChild("PathfindingQueue"))

export type GoToOpts = {
	onArrived: (() -> ())?,
	onFailed: (() -> ())?,
}

local Navigator = {}
Navigator.__index = Navigator

export type Navigator = typeof(setmetatable({} :: {
	_humanoid: Humanoid,
	_rootPart: BasePart,
	_path: Path,
	_isMoving: boolean,
	_currentDest: Vector3?,
	_currentWaypoints: { PathWaypoint }?,
	_onArrived: (() -> ())?,
	_onFailed: (() -> ())?,
	_lastComputeAt: number,
	_lastFailureAt: number,
	_postBlockedUntil: number,
	_generation: number,
	_conns: { RBXScriptConnection },
	_stopped: boolean,
}, Navigator))

function Navigator.new(humanoid: Humanoid, rootPart: BasePart, agentParams: { [string]: any }): Navigator
	local self = setmetatable({
		_humanoid = humanoid,
		_rootPart = rootPart,
		_path = PathfindingService:CreatePath(agentParams),
		_isMoving = false,
		_currentDest = nil,
		_currentWaypoints = nil,
		_onArrived = nil,
		_onFailed = nil,
		_lastComputeAt = 0,
		_lastFailureAt = 0,
		_postBlockedUntil = 0,
		_generation = 0,
		_conns = {},
		_stopped = false,
	}, Navigator) :: Navigator

	-- NOTA: NO conectamos `humanoid.MoveToFinished`. El walk loop usa
	-- `humanoid:Move(direction)` + check manual de distancia para avanzar
	-- waypoints. `MoveToFinished` es global por humanoid y se firea para
	-- CUALQUIER `humanoid:MoveTo` que termine (incluyendo MoveTos directos
	-- de BotAI en CHASE-visible y MoveTos superseded con timeouts 8s).
	-- Eliminar la dependencia hace imposible que el walk loop se "contamine"
	-- con firings espurios — la única forma robusta de evitar la race.

	-- Cooldown post Path.Blocked: aborta el walk vigente y bloquea recomputes
	-- durante PostBlockedCooldown seg. Sin esto, un bot con un path roto
	-- recomputa cada frame.
	table.insert(self._conns, self._path.Blocked:Connect(function()
		self._postBlockedUntil = os.clock() + BotConfig.Pathfinding.PostBlockedCooldown
		self._generation += 1
		self._isMoving = false
		self._currentWaypoints = nil
		-- Audit fix: limpiar _currentDest. Sin esto, una goTo posterior al
		-- mismo destino cae en el throttle de same-dest tras expirar el
		-- cooldown, almacena callbacks nuevas y retorna silently — las
		-- callbacks nunca firearán porque no hay compute en vuelo.
		self._currentDest = nil
		-- Audit fix: notificar al caller con onFailed. Sin esto,
		-- _moveToLocation hace polling forever esperando un callback que
		-- ya no llega, y StuckDetector se salta el accum porque
		-- isMoving()=false → bot atascado hasta enemigo o muerte.
		local cb = self._onFailed
		self._onFailed = nil
		self._onArrived = nil
		if cb then
			task.defer(cb)
		end
	end))

	return self
end

function Navigator:goTo(dest: Vector3, opts: GoToOpts?)
	if self._stopped then
		return
	end

	local now = os.clock()

	-- Cooldown post-Blocked: silenciar goTo. CRÍTICO: notificar a la
	-- caller vía onFailed (deferred) — si no, callers que esperan en bucle
	-- por callback (PATROL._moveToLocation) se quedan colgados.
	if now < self._postBlockedUntil then
		if opts and opts.onFailed then
			task.defer(opts.onFailed)
		end
		return
	end

	-- Failure cooldown: si un compute reciente falló, no reintentamos
	-- inmediatamente (evita spam a 60Hz si la zona es inalcanzable).
	-- Notificamos onFailed para que el caller pueda elegir otro destino.
	if self._lastFailureAt > 0 and now - self._lastFailureAt < BotConfig.Pathfinding.PostBlockedCooldown then
		if opts and opts.onFailed then
			task.defer(opts.onFailed)
		end
		return
	end

	-- Throttle de same-dest. CRÍTICO: aplica sin condicionar a `_isMoving`.
	-- Antes el throttle solo gateaba con `isMoving` (true tras el callback
	-- de ComputeAsync) — entre enqueue y callback, las llamadas seguían
	-- enqueueando. A 60Hz son 60 enqueues/seg por bot al mismo target →
	-- cola saturada, computes cancelados por gen mismatch, bot en limbo
	-- con "pasos a tirones".
	-- Ahora _currentDest y _lastComputeAt se actualizan SÍNCRONAMENTE al
	-- enqueue. La próxima goTo en <MinComputeInterval con dest cercano
	-- se silencia inmediatamente y reutiliza las callbacks del compute en
	-- vuelo (que sí firearán cuando termine).
	if self._currentDest
		and (self._currentDest - dest).Magnitude < 5
		and (now - self._lastComputeAt) < BotConfig.Pathfinding.MinComputeInterval then
		self._onArrived = opts and opts.onArrived
		self._onFailed = opts and opts.onFailed
		return
	end

	self._onArrived = opts and opts.onArrived
	self._onFailed = opts and opts.onFailed

	local gen = self._generation + 1
	self._generation = gen

	-- Marcar enqueue tiempo y dest síncronamente — gates futuras llamadas.
	self._currentDest = dest
	self._lastComputeAt = now

	local origin = self._rootPart.Position
	PathfindingQueue.enqueue(self._path, origin, dest, function(ok)
		if self._stopped or self._generation ~= gen then
			return
		end

		if not ok or self._path.Status ~= Enum.PathStatus.Success then
			-- CRÍTICO: limpiar _currentDest. Si no, el throttle de same-dest
			-- bloquea futuras goTo a destinos cercanos → bot atascado sin
			-- recompute, PATROL polling colgado en `while not done`.
			self._lastFailureAt = os.clock()
			self._isMoving = false
			self._currentWaypoints = nil
			self._currentDest = nil
			local onFailed = self._onFailed
			if onFailed then
				onFailed()
			end
			return
		end

		local wps = self._path:GetWaypoints()
		if #wps < 2 then
			self._isMoving = false
			self._currentWaypoints = nil
			local onArrived = self._onArrived
			if onArrived then
				onArrived()
			end
			return
		end

		self._currentDest = dest
		self._currentWaypoints = wps
		self._isMoving = true
		self:_startWalk(gen)
	end)
end

function Navigator:_startWalk(gen: number)
	task.spawn(function()
		local waypoints = self._currentWaypoints
		if not waypoints then
			return
		end

		-- Walk loop basado en Move() + check posicional, sin MoveTo ni
		-- MoveToFinished. Razón: eliminar la race con MoveToFinished
		-- compartido entre Navigator y BotAI (CHASE-visible direct). Move()
		-- setea una dirección de marcha continua y no emite eventos, así
		-- que es seguro contra interferencia externa.
		local arrivalRadius = BotConfig.Movement.WaypointSmoothDistance
		local stallTimeout = 8.0 -- seg sin moverse hacia el wp: forzamos avance
		-- Delta-gate de humanoid:Move. Cada Move replica MoveDirection al
		-- cliente de cualquier observador (16 bots × N clientes a 60Hz).
		-- Si la dir no cambió >~5° desde el último, no escribir. Vector3.zero
		-- como sentinel hace que el primer Move siempre triggere
		-- (dot(unit, zero) = 0 < 0.9962).
		local lastAppliedMoveDir: Vector3 = Vector3.zero

		for i = 2, #waypoints do
			if self._stopped or self._generation ~= gen then
				return
			end

			local wp = waypoints[i]
			if wp.Action == Enum.PathWaypointAction.Jump then
				self._humanoid.Jump = true
			end

			local target = wp.Position
			local lastProgressAt = os.clock()
			local lastProgressDist = (self._rootPart.Position - target).Magnitude

			while true do
				if self._stopped or self._generation ~= gen then
					self._humanoid:Move(Vector3.zero, false)
					return
				end

				local pos = self._rootPart.Position
				local dist = (pos - target).Magnitude

				-- Alcanzado el wp (umbral = smooth distance).
				if dist < arrivalRadius then
					break
				end

				-- Anti-deadlock: si llevamos `stallTimeout`s sin acercarnos
				-- al wp (dist no mejora >0.5 studs), abandonar este wp.
				-- Cubre wps inalcanzables (path roto en mid-walk, otro NPC
				-- bloqueando crónicamente). El StuckDetector externo también
				-- escala pero esto cierra el bucle del walk loop.
				if lastProgressDist - dist > 0.5 then
					lastProgressAt = os.clock()
					lastProgressDist = dist
				elseif os.clock() - lastProgressAt > stallTimeout then
					break
				end

				-- Dirección plana XZ hacia el wp. Move(unit) → humanoid
				-- camina a WalkSpeed constante.
				local toTarget = target - pos
				local dir = Vector3.new(toTarget.X, 0, toTarget.Z)
				if dir.Magnitude > 0.001 then
					local unit = dir.Unit
					-- Gate por delta angular: cos(5°) ≈ 0.9962.
					if unit:Dot(lastAppliedMoveDir) < 0.9962 then
						self._humanoid:Move(unit, false)
						lastAppliedMoveDir = unit
					end
				end

				task.wait(0.05)
			end
		end

		if self._stopped or self._generation ~= gen then
			return
		end

		-- Detener movimiento al llegar al último wp.
		self._humanoid:Move(Vector3.zero, false)

		-- Limpiar _currentDest también al llegar: si no, el throttle de
		-- same-dest podría bloquear la próxima goTo si el caller pide un
		-- destino cercano dentro de MinComputeInterval.
		self._isMoving = false
		self._currentWaypoints = nil
		self._currentDest = nil
		local onArrived = self._onArrived
		if onArrived then
			onArrived()
		end
	end)
end

-- notifyFailed: si true, dispara onFailed (deferred) antes de limpiar las
-- callbacks. Lo usa StuckDetector para abandonar la navegación actual
-- avisando al caller (PATROL polling). Sin notify, la cancelación es
-- silenciosa (uso normal desde BotAI cuando transiciona de estado).
function Navigator:cancel(notifyFailed: boolean?)
	if self._stopped then
		return
	end
	self._generation += 1
	self._isMoving = false
	self._currentWaypoints = nil
	self._currentDest = nil
	local onFailed = self._onFailed
	self._onArrived = nil
	self._onFailed = nil
	if notifyFailed and onFailed then
		task.defer(onFailed)
	end
end

function Navigator:isMoving(): boolean
	return self._isMoving
end

-- Forzar recompute al último destino conocido bypasseando el throttle.
-- Usado por StuckDetector nivel 2 cuando el bot lleva 2s sin moverse.
-- Preserva callbacks (onArrived/onFailed) para que el caller no se quede
-- esperando indefinidamente.
function Navigator:recomputeLast()
	if self._stopped or not self._currentDest then
		return
	end
	local dest = self._currentDest
	local onArrived = self._onArrived
	local onFailed = self._onFailed
	-- Bumpear gen aborta el walk en curso; isMoving=false desactiva el
	-- throttle de same-dest en goTo.
	self._generation += 1
	self._isMoving = false
	self:goTo(dest, { onArrived = onArrived, onFailed = onFailed })
end

function Navigator:Stop()
	self._stopped = true
	self._generation += 1
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self._currentWaypoints = nil
	self._currentDest = nil
	self._onArrived = nil
	self._onFailed = nil
	self._isMoving = false
end

return Navigator
