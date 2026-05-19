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

local _queue: { Entry } = {}
local _onEnqueue: ((depth: number) -> ())? = nil

function PathfindingQueue.enqueue(path: Path, origin: Vector3, dest: Vector3, callback: (ok: boolean) -> ())
	table.insert(_queue, {
		path = path,
		origin = origin,
		dest = dest,
		callback = callback,
	})
	if _onEnqueue then
		_onEnqueue(#_queue)
	end
end

function PathfindingQueue.getDepth(): number
	return #_queue
end

-- Hook usado por NavMetrics (commit 2). En commit 1 queda como no-op.
function PathfindingQueue.setOnEnqueue(hook: ((depth: number) -> ())?)
	_onEnqueue = hook
end

RunService.Heartbeat:Connect(function()
	local budget = BotConfig.Navigation.QueueRequestsPerHeartbeat
	local processed = 0
	while processed < budget and #_queue > 0 do
		local entry = table.remove(_queue, 1)
		if not entry then
			break
		end
		processed += 1
		task.spawn(function()
			local ok = pcall(function()
				entry.path:ComputeAsync(entry.origin, entry.dest)
			end)
			entry.callback(ok)
		end)
	end
end)

return PathfindingQueue
