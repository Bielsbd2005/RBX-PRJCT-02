--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writeu16 = bufferWriter.writeu16
local writestring = bufferWriter.writestring

local dyn_alloc = bufferWriter.dyn_alloc

local str = {
	-- 2 bytes for the length, then the string

	Read = function(b: buffer, cursor: number)
		local length = buffer.readu16(b, cursor)

		return buffer.readstring(b, cursor + 2, length), length + 2
	end;
	Write = function(data: string)
		local length = #data
		writeu16(length)

		dyn_alloc(length)
		writestring(data)
	end;
}

return function(): types.DataTypeInterface<string>
	return str
end
