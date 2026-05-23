--!strict
--[[
	NavMetrics — telemetría de la capa de navegación.

	v1 sin dashboard externo. Dos canales:

	  • Summary periódico (cada 30s): print agregado por tag de los contadores
	    acumulados. Si todos están en 0, silencio.

	  • Print inmediato: para tags donde la rareza del evento implica que
	    queremos verlo en el momento con contexto (botName, position, mapName)
	    — niveles 3-4 de escalada de stuck, queue depth anómala.

	Ring buffer interno de 256 eventos (drop oldest). API GetSnapshot()
	permite inspección desde Command Bar.

	Threshold dinámico de queue_depth_high:
	  El "depth normal" en round-start es `activeBotCount` (cada bot encola
	  1 ComputeAsync). El threshold dispara cuando depth > 2 × activeBotCount,
	  que indica repath storm o re-spawn anómalo — NO el round-start típico.
	  AIService llama SetActiveBotCount(n) cada vez que cambia el roster.
]]

local RunService = game:GetService("RunService")

-- Audit mobile: telemetría desactivada en producción. En Studio sí grabamos
-- ring buffer + counters + summary cada 30s. En servidores live `record` es
-- no-op (cero allocs de payload tables, cero string concats). Counters de
-- lifecycle siguen siendo baratos cuando enabled = false porque el early
-- return ocurre antes de la insertion.
local ENABLED = RunService:IsStudio()

local SUMMARY_INTERVAL_SECONDS = 30
local RING_CAPACITY = 256

local IMMEDIATE_TAGS: { [string]: boolean } = {
	stuck_jump = true,
	stuck_teleport = true,
	queue_depth_high = true,
}

type Event = {
	tag: string,
	payload: { [string]: any },
	t: number,
}

local NavMetrics = {}

local _ring: { Event } = {}
local _ringHead = 1
local _counts: { [string]: number } = {}
local _activeBotCount = 0

local function _ringPush(event: Event)
	if #_ring < RING_CAPACITY then
		table.insert(_ring, event)
	else
		_ring[_ringHead] = event
		_ringHead = (_ringHead % RING_CAPACITY) + 1
	end
end

local function _payloadToString(payload: { [string]: any }): string
	local parts = {} :: { string }
	for k, v in payload do
		table.insert(parts, tostring(k) .. "=" .. tostring(v))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

function NavMetrics.record(tag: string, payload: { [string]: any }, immediate: boolean?)
	if not ENABLED then
		return
	end
	local event: Event = {
		tag = tag,
		payload = payload,
		t = os.clock(),
	}
	_ringPush(event)
	_counts[tag] = (_counts[tag] or 0) + 1

	if immediate or IMMEDIATE_TAGS[tag] then
		print(string.format("[NavMetrics] %s %s", tag, _payloadToString(payload)))
	end
end

function NavMetrics.SetActiveBotCount(n: number)
	_activeBotCount = math.max(0, n)
end

function NavMetrics.GetActiveBotCount(): number
	return _activeBotCount
end

-- Lifecycle counters: sin payload (acumulan en _counts vía record). Útiles
-- para health del sistema en summaries y para sanity-check de re-spawn rate.
function NavMetrics.RecordBotSpawned()
	NavMetrics.record("bots_spawned", {})
end

function NavMetrics.RecordBotDied()
	NavMetrics.record("bots_died", {})
end

-- queueDepth > 2 × activeBotCount → repath storm / re-spawn anómalo. Si no
-- hay bots activos, ignorar (la cola está abierta pero vacía de forma
-- natural).
function NavMetrics.CheckQueueDepth(queueDepth: number)
	if _activeBotCount <= 0 then
		return
	end
	if queueDepth > 2 * _activeBotCount then
		NavMetrics.record("queue_depth_high", {
			depth = queueDepth,
			activeBots = _activeBotCount,
		}, true)
	end
end

function NavMetrics.GetSnapshot(): { counts: { [string]: number }, recent: { Event } }
	local recent = {} :: { Event }
	-- Devolver eventos en orden cronológico desde el head del ring.
	if #_ring < RING_CAPACITY then
		for _, e in _ring do
			table.insert(recent, e)
		end
	else
		for i = 0, RING_CAPACITY - 1 do
			local idx = ((_ringHead - 1 + i) % RING_CAPACITY) + 1
			local e = _ring[idx]
			if e then
				table.insert(recent, e)
			end
		end
	end
	local countsCopy = {} :: { [string]: number }
	for k, v in _counts do
		countsCopy[k] = v
	end
	return { counts = countsCopy, recent = recent }
end

-- Resumen periódico. Solo activo en Studio (ENABLED). En producción este
-- coroutine nunca se crea — el while no corre y los contadores quedan vacíos.
if ENABLED then
	task.spawn(function()
		while true do
			task.wait(SUMMARY_INTERVAL_SECONDS)
			-- Skip si no hay bots activos: en lobby/menu el summary no aporta.
			if _activeBotCount == 0 then
				continue
			end
			local any = false
			local parts = {} :: { string }
			for tag, n in _counts do
				if n > 0 then
					any = true
					table.insert(parts, tag .. "=" .. tostring(n))
				end
			end
			if any then
				table.sort(parts)
				print(string.format("[NavMetrics] summary (%ds): %s", SUMMARY_INTERVAL_SECONDS, table.concat(parts, ", ")))
			end
			-- No vaciamos los contadores — son acumulados de ronda. AIService los
			-- limpia en OnRoundEnd vía ResetCounts().
		end
	end)
end

function NavMetrics.ResetCounts()
	table.clear(_counts)
	table.clear(_ring)
	_ringHead = 1
end

-- PathfindingQueue puede notificar enqueues si lo cableamos. En commit 2
-- conectamos el hook para alimentar CheckQueueDepth.
do
	local nav = script.Parent.Parent:WaitForChild("nav")
	local PathfindingQueue = require(nav:WaitForChild("PathfindingQueue"))
	PathfindingQueue.setOnEnqueue(function(depth: number)
		NavMetrics.CheckQueueDepth(depth)
	end)
end

return NavMetrics
