--!strict
--[[
	Wrapper de pathfinding por bot.

	  • Path persistente (una sola asignación, reusada por ComputeAsync).
	  • Throttle same-dest (<5 studs) y cooldowns tras fallo y tras Path.Blocked
	    (BotConfig.Pathfinding), para evitar repath storms.
	  • Walk loop con humanoid:Move(direction) + check posicional. NO usa
	    MoveToFinished: es por humanoid y se dispara para CUALQUIER MoveTo, así que
	    otros sitios que llaman MoveTo lo contaminarían.
	  • ComputeAsync se encola en `PathfindingQueue` para diluir el spike de round-start.

	goTo no bloquea. Tras :Stop() la instancia no se reusa.
]]

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotConfig = require(Shared:WaitForChild("constants"):WaitForChild("BotConfig"))

local nav = script.Parent
local PathfindingQueue = require(nav:WaitForChild("PathfindingQueue"))
local StuckViz = require(nav.Parent:WaitForChild("debug"):WaitForChild("StuckViz"))

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

	-- Tras Path.Blocked: aborta el walk y bloquea recomputes PostBlockedCooldown seg.
	table.insert(self._conns, self._path.Blocked:Connect(function()
		self._postBlockedUntil = os.clock() + BotConfig.Pathfinding.PostBlockedCooldown
		self._generation += 1
		self._isMoving = false
		self:_halt()
		self._currentWaypoints = nil
		-- Limpiar _currentDest: si no, una goTo posterior al mismo destino cae en el
		-- throttle de same-dest, guarda callbacks y no hay compute que las dispare.
		self._currentDest = nil
		-- Notificar onFailed: _moveToLocation hace polling esperando callback, y
		-- StuckDetector no acumula con isMoving()=false → bot atascado.
		local cb = self._onFailed
		self._onFailed = nil
		self._onArrived = nil
		if cb then
			task.defer(cb)
		end
	end))

	return self
end

-- `Humanoid:Move` es STICKY: la dirección persiste hasta que alguien escribe otra.
-- Toda salida del walk loop debe pasar por aquí o el bot sigue corriendo, y con
-- isMoving()=false el StuckDetector no lo corrige.
--
-- El guard de `_isMoving` evita pisar a un walk sucesor: si una goTo posterior ya
-- arrancó, el coroutine viejo despertando de su task.wait no debe cancelarle la
-- dirección recién aplicada.
function Navigator:_halt()
	if self._isMoving then
		return
	end
	self._humanoid:Move(Vector3.zero, false)
end

function Navigator:goTo(dest: Vector3, opts: GoToOpts?)
	if self._stopped then
		return
	end

	local now = os.clock()

	-- Cooldown post-Blocked. Hay que notificar onFailed (deferred): callers que
	-- esperan en bucle por callback (PATROL._moveToLocation) se quedarían colgados.
	if now < self._postBlockedUntil then
		if opts and opts.onFailed then
			task.defer(opts.onFailed)
		end
		return
	end

	-- Un compute reciente falló: no reintentar ya (evita spam si la zona es
	-- inalcanzable); onFailed deja al caller elegir otro destino.
	if self._lastFailureAt > 0 and now - self._lastFailureAt < BotConfig.Pathfinding.PostBlockedCooldown then
		if opts and opts.onFailed then
			task.defer(opts.onFailed)
		end
		return
	end

	-- Throttle de same-dest. _currentDest y _lastComputeAt se fijan al ENCOLAR (no en
	-- el callback), así las llamadas repetidas (CHASE a 20Hz) no saturan la cola.
	-- Ambos casos reutilizan las callbacks del compute/walk en vuelo:
	--   • Ya CAMINANDO hacia ese dest: nunca recomputar por tiempo (relanzar pierde el
	--     impulso). Un path obsoleto lo recupera StuckDetector vía recomputeLast, que
	--     pone _isMoving=false antes y así pasa este gate.
	--   • Compute todavía en cola/vuelo: gate temporal, para que un compute colgado
	--     se relance.
	if self._currentDest and (self._currentDest - dest).Magnitude < 5 then
		if self._isMoving or (now - self._lastComputeAt) < BotConfig.Pathfinding.MinComputeInterval then
			self._onArrived = opts and opts.onArrived
			self._onFailed = opts and opts.onFailed
			return
		end
	end

	self._onArrived = opts and opts.onArrived
	self._onFailed = opts and opts.onFailed

	local gen = self._generation + 1
	self._generation = gen

	self._currentDest = dest
	self._lastComputeAt = now

	-- Se pasa el rootPart: la cola lee la posición al lanzar ComputeAsync, así el
	-- path arranca donde el bot ESTÁ y no donde estaba al encolar.
	PathfindingQueue.enqueue(self._path, self._rootPart, dest, function(ok)
		if self._stopped or self._generation ~= gen then
			return
		end

		if not ok or self._path.Status ~= Enum.PathStatus.Success then
			-- Limpiar _currentDest: si no, el throttle de same-dest bloquea futuras
			-- goTo a destinos cercanos y PATROL se queda colgado.
			self._lastFailureAt = os.clock()
			self._isMoving = false
			-- Cortar la marcha del path anterior o el bot entra al backoff de PATROL
			-- trotando con la dirección vieja.
			self:_halt()
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
			self:_halt()
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

		local arrivalRadius = BotConfig.Movement.WaypointSmoothDistance
		local arrivalVertical = BotConfig.Movement.WaypointVerticalTolerance
		-- Un tramo entre waypoints se recorre en <0.2s y el contador se resetea con
		-- cada 0.5 studs de progreso: agotar esto ya significa "no va a llegar".
		local stallTimeout = 3.0
		-- Delta-gate de humanoid:Move: cada Move replica MoveDirection a todos los
		-- clientes. No se escribe si la dir cambió <~5°. Vector3.zero como sentinel
		-- fuerza el primer Move.
		local lastAppliedMoveDir: Vector3 = Vector3.zero

		for i = 2, #waypoints do
			if self._stopped or self._generation ~= gen then
				-- Abort entre dos waypoints: hay que cortar la marcha también aquí.
				self:_halt()
				return
			end

			local wp = waypoints[i]
			if wp.Action == Enum.PathWaypointAction.Jump then
				self._humanoid.Jump = true
			end

			local target = wp.Position
			local lastProgressAt = os.clock()
			local lastProgressDist = (self._rootPart.Position - target).Magnitude

			-- Dirección XZ de aproximación, congelada al activar el waypoint, para
			-- detectar que lo hemos PASADO (overshoot): el cambio de signo del producto
			-- escalar lo caza aunque el bot cruce la zona de llegada en un solo tick.
			local approach = target - self._rootPart.Position
			local approachFlat = Vector3.new(approach.X, 0, approach.Z)
			local approachDir = if approachFlat.Magnitude > 0.001
				then approachFlat.Unit
				else Vector3.zero

			while true do
				if self._stopped or self._generation ~= gen then
					-- Vía _halt (no Move directo): si una goTo posterior ya arrancó su
					-- walk, este coroutine zombie le borraría la dirección recién aplicada.
					self:_halt()
					return
				end

				local pos = self._rootPart.Position
				local toTarget = target - pos
				-- Llegada en XZ con la altura acotada aparte: en 3D un waypoint con
				-- desnivel >= arrivalRadius es inalcanzable y el bot orbita su proyección.
				-- StuckDetector no lo detecta (solo mira velocidad neta, no progreso).
				local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
				local flatDist = flatToTarget.Magnitude
				if flatDist < arrivalRadius and math.abs(toTarget.Y) < arrivalVertical then
					break
				end

				-- Overshoot: ya cruzamos el plano perpendicular a la aproximación que pasa
				-- por el waypoint. Volver sería dar media vuelta (el orbitado). Se ignora
				-- Y a propósito: el desnivel lo resuelve el siguiente waypoint.
				if approachDir ~= Vector3.zero and flatToTarget:Dot(approachDir) <= 0 then
					break
				end

				-- Anti-deadlock: `stallTimeout`s sin acercarse >0.5 studs → abandonar el
				-- wp (path roto en vuelo, NPC bloqueando). El progreso se mide en 3D a
				-- propósito: subir una escalera acerca en Y aunque el avance XZ sea lento.
				local dist = toTarget.Magnitude
				if lastProgressDist - dist > 0.5 then
					lastProgressAt = os.clock()
					lastProgressDist = dist
				elseif os.clock() - lastProgressAt > stallTimeout then
					-- Abandonar por stall es SIEMPRE anómalo (mapa no navegable o path
					-- roto): se marca en el mapa de calor de StuckViz
					-- (ServerStorage.ShowStuckMarkers = true).
					StuckViz.mark(
						self._rootPart.Position,
						2,
						self._rootPart.Parent and self._rootPart.Parent.Name or "?",
						StuckViz.KIND_STALL
					)
					break
				end

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

		self._humanoid:Move(Vector3.zero, false)

		-- Limpiar _currentDest también al llegar: si no, el throttle de same-dest
		-- podría bloquear una goTo cercana dentro de MinComputeInterval.
		self._isMoving = false
		self._currentWaypoints = nil
		self._currentDest = nil
		local onArrived = self._onArrived
		if onArrived then
			onArrived()
		end
	end)
end

-- notifyFailed: dispara onFailed (deferred). Lo usa StuckDetector para abandonar
-- avisando al caller (PATROL polling); sin él es silenciosa (transiciones de BotAI).
function Navigator:cancel(notifyFailed: boolean?)
	if self._stopped then
		return
	end
	self._generation += 1
	self._isMoving = false
	-- Cortar la marcha aquí y no delegarlo al walk loop: hasta su próximo despertar
	-- (o nunca, si estaba entre waypoints) el rig seguiría corriendo. BotAI llama
	-- cancel() constantemente en combate.
	self:_halt()
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

-- Recompute al último destino saltándose el throttle (StuckDetector nivel 2).
-- Preserva callbacks para que el caller no se quede esperando.
function Navigator:recomputeLast()
	if self._stopped or not self._currentDest then
		return
	end
	local dest = self._currentDest
	local onArrived = self._onArrived
	local onFailed = self._onFailed
	-- Bumpear gen aborta el walk en curso; isMoving=false salta el throttle de goTo.
	self._generation += 1
	self._isMoving = false
	self:goTo(dest, { onArrived = onArrived, onFailed = onFailed })
end

function Navigator:Stop()
	self._stopped = true
	self._generation += 1
	self._isMoving = false
	self:_halt()
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
