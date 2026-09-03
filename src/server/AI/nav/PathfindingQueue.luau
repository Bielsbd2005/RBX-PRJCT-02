--!strict
--[[
	PathfindingQueue — FIFO global de ComputeAsync para todos los bots.

	Roblox PathfindingService:ComputeAsync es síncrono; cuando muchos bots
	intentan computar al mismo tiempo (round start con 8-16 bots), el frame
	cae varios ms. Esta cola encadena los ComputeAsync a un ritmo fijo
	(2 por Heartbeat por defecto) para diluir el spike a lo largo de varios
	frames.

	Cada request se ejecuta en `task.spawn` para que el yield del ComputeAsync
	no detenga el Heartbeat ni los otros requests del mismo tick. El callback
	recibe `ok: boolean` y debe consultar `path.Status` para verificar éxito.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotConfig = require(Shared:WaitForChild("constants"):WaitForChild("BotConfig"))

-- `originPart` en lugar de un Vector3 capturado al encolar: con backlog en la
-- cola el bot ya no está donde estaba al pedir el path, y el path arrancaba
-- detrás de él. La posición se lee al momento de lanzar ComputeAsync.
type Entry = {
	path: Path,
	originPart: BasePart,
	dest: Vector3,
	callback: (ok: boolean) -> (),
}

local PathfindingQueue = {}

-- Audit: head/tail pointer en lugar de table.remove(_queue, 1) que era
-- O(n). Con 16 bots en round-start, la cola encola ~16 entries y drainar
-- a 2/Heartbeat producía 16+14+12+... shifts. Trivial en absoluto pero
-- innecesario.
local _queue: { Entry } = {}
local _head = 1
local _tail = 0
-- Semáforo de in-flight: el budget per-Heartbeat sólo limita enqueues. Sin
-- tope concurrente, un repath storm spawnea N coroutines paralelas que ceden
-- mid-ComputeAsync y el spike se acumula en lugar de diluirse.
local _inFlight = 0
-- Per-Path serialization: ComputeAsync is not reentrant on the same Path
-- object. A Navigator can have two queued entries for its single shared Path
-- (e.g., recomputeLast while the first entry is still queued during a
-- backlog); running both concurrently makes the first pcall fail spuriously.
-- Entries whose Path is mid-compute are requeued instead of spawned.
-- Self-cleaning: each compute clears its own flag on completion, so paths of
-- dead Navigators never linger here.
local _busyPaths: { [Path]: boolean } = {}

function PathfindingQueue.enqueue(path: Path, originPart: BasePart, dest: Vector3, callback: (ok: boolean) -> ())
	_tail += 1
	_queue[_tail] = {
		path = path,
		originPart = originPart,
		dest = dest,
		callback = callback,
	}
end

function PathfindingQueue.getDepth(): number
	return _tail - _head + 1
end

-- Purga la cola al OnRoundEnd. Las callbacks pendientes verifican
-- Navigator._stopped, así que no es funcionalmente necesario, pero libera
-- los closures (que retienen refs a Path + Navigator) sin esperar al
-- drain natural a 2/Heartbeat.
function PathfindingQueue.clear()
	table.clear(_queue)
	_head = 1
	_tail = 0
end

RunService.Heartbeat:Connect(function()
	local budget = BotConfig.Navigation.QueueRequestsPerHeartbeat
	local maxInFlight = BotConfig.Navigation.MaxInFlightCompute
	local processed = 0
	-- Cap scans to the entries present at the start of this Heartbeat so the
	-- busy-path requeue below can't cycle the same entry forever in one frame.
	local scans = _tail - _head + 1
	while processed < budget and scans > 0 and _head <= _tail and _inFlight < maxInFlight do
		scans -= 1
		local entry = _queue[_head]
		_queue[_head] = nil
		_head += 1
		if not entry then
			break
		end
		if _busyPaths[entry.path] then
			-- This Path is mid-compute. Push to the back; retried once the
			-- in-flight compute clears the flag (usually next Heartbeat).
			_tail += 1
			_queue[_tail] = entry
		else
			processed += 1
			_inFlight += 1
			_busyPaths[entry.path] = true
			task.spawn(function()
				local origin = entry.originPart.Position
				local ok = pcall(function()
					entry.path:ComputeAsync(origin, entry.dest)
				end)
				_busyPaths[entry.path] = nil
				_inFlight -= 1
				entry.callback(ok)
			end)
		end
	end
	-- Compact: si la cola se drenó completa, reseteamos punteros para evitar
	-- crecimiento monotónico de los índices (irrelevante en práctica con
	-- doubles, pero higiene).
	if _head > _tail then
		_head = 1
		_tail = 0
	end
end)

return PathfindingQueue
