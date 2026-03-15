--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writeu16 = bufferWriter.writeu16
local writecopy = bufferWriter.writecopy
local dyn_alloc = bufferWriter.dyn_alloc
local buffer_create = buffer.create

local buff = {
	Read = function(b: buffer, cursor: number)
		local length = buffer.readu16(b, cursor)
		local freshBuffer = buffer_create(length)

		-- copy the data from the main buffer to the new buffer with an offset of 2 because of length
		buffer.copy(freshBuffer, 0, b, cursor + 2, length)

		return freshBuffer, length + 2
	end;
	Write = function(data: buffer)
		local length = buffer.len(data)
		writeu16(length)

		dyn_alloc(length)

		-- write the length of the buffer, then the buffer itself
		writecopy(data)
	end;
}

return function(): types.DataTypeInterface<buffer>
	return buff
end
