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
		local id = buffer.readu8(incomingBuffer, readCursor)
		readCursor += 1

		-- Unknown packet id: a malformed/forged buffer. We can't know the field
		-- length to skip past it, so abort this buffer (the rest is unparseable).
		local packet = ref[id]
		if not packet then
			return
		end

		-- packet.Reader throws on a truncated/garbage buffer. Guard it so one bad
		-- packet doesn't abort the whole batch with an error; discard the rest of
		-- this buffer on failure since the cursor position is no longer reliable.
		local ok, value, valueLength = pcall(packet.Reader, incomingBuffer, readCursor)
		if not ok then
			return
		end

		readCursor += valueLength

		for _, listener in packet.GetListeners() do
			runListener(listener, value, player)
		end
	end
end

return read
