--!strict
--[[
	FIFO global de ComputeAsync para todos los bots.

	ComputeAsync es caro y en round start muchos bots computan a la vez: la cola los
	reparte a QueueRequestsPerHeartbeat por Heartbeat. Cada request va en `task.spawn`
	para que su yield no detenga el Heartbeat. El callback recibe `ok` y debe
	consultar `path.Status` para verificar éxito.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotConfig = require(Shared:WaitForChild("constants"):WaitForChild("BotConfig"))

-- `originPart` y no un Vector3: con backlog el bot ya no está donde pidió el path.
-- La posición se lee al lanzar ComputeAsync.
type Entry = {
	path: Path,
	originPart: BasePart,
	dest: Vector3,
	callback: (ok: boolean) -> (),
}

local PathfindingQueue = {}

local _queue: { Entry } = {}
local _head = 1
local _tail = 0
-- Tope de in-flight: el budget por Heartbeat solo limita lanzamientos; sin tope, un
-- repath storm acumula coroutines que ceden mid-ComputeAsync.
local _inFlight = 0
-- ComputeAsync is not reentrant on the same Path, and a Navigator can have two
-- queued entries for its single Path (e.g. recomputeLast during a backlog). Entries
-- whose Path is mid-compute are requeued. Each compute clears its own flag.
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

-- Las callbacks pendientes ya comprueban Navigator._stopped; purgar solo libera los
-- closures sin esperar al drain.
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
	if _head > _tail then
		_head = 1
		_tail = 0
	end
end)

return PathfindingQueue
