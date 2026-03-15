--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writef64 = bufferWriter.writef64

local float64 = {
	Write = writef64;
	Read = function(b: buffer, cursor: number)
		return buffer.readf64(b, cursor), 8
	end;
}

return function(): types.DataTypeInterface<number>
	return float64
end
