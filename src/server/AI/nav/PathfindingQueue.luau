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

type Entry = {
	path: Path,
	origin: Vector3,
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
local _onEnqueue: ((depth: number) -> ())? = nil
-- Semáforo de in-flight: el budget per-Heartbeat sólo limita enqueues. Sin
-- tope concurrente, un repath storm spawnea N coroutines paralelas que ceden
-- mid-ComputeAsync y el spike se acumula en lugar de diluirse.
local _inFlight = 0

function PathfindingQueue.enqueue(path: Path, origin: Vector3, dest: Vector3, callback: (ok: boolean) -> ())
	_tail += 1
	_queue[_tail] = {
		path = path,
		origin = origin,
		dest = dest,
		callback = callback,
	}
	if _onEnqueue then
		_onEnqueue(_tail - _head + 1)
	end
end

function PathfindingQueue.getDepth(): number
	return _tail - _head + 1
end

-- Hook usado por NavMetrics (commit 2). En commit 1 queda como no-op.
function PathfindingQueue.setOnEnqueue(hook: ((depth: number) -> ())?)
	_onEnqueue = hook
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
	while processed < budget and _head <= _tail and _inFlight < maxInFlight do
		local entry = _queue[_head]
		_queue[_head] = nil
		_head += 1
		if not entry then
			break
		end
		processed += 1
		_inFlight += 1
		task.spawn(function()
			local ok = pcall(function()
				entry.path:ComputeAsync(entry.origin, entry.dest)
			end)
			_inFlight -= 1
			entry.callback(ok)
		end)
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
