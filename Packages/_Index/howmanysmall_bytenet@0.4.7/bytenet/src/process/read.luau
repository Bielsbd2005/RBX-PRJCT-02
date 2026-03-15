--!native
--!optimize 2
--!strict

local packetIDs = require(script.Parent.Parent.namespaces.packetIDs)
local readRefs = require(script.Parent.readRefs)

local ref = packetIDs.ref()
local freeThread: thread?

local function functionPasser(fn, ...)
	local acquiredThread = freeThread
	freeThread = nil
	fn(...)
	freeThread = acquiredThread
end

local function yielder()
	while true do
		functionPasser(coroutine.yield())
	end
end

local function runListener(fn, ...)
	if freeThread == nil then
		freeThread = coroutine.create(yielder)
		coroutine.resume(freeThread :: thread)
	end

	task.spawn(freeThread :: thread, fn, ...)
end

local function read(incomingBuffer: buffer, references: {[number]: unknown}?, player: Player?)
	local length = buffer.len(incomingBuffer)
	local readCursor = 0

	readRefs.set(references)

	while readCursor < length do
		local packet = ref[buffer.readu8(incomingBuffer, readCursor)]
		readCursor += 1

		local value, valueLength = packet.Reader(incomingBuffer, readCursor)

		readCursor += valueLength

		for _, listener in packet.GetListeners() do
			runListener(listener, value, player)
		end
	end
end

return read
