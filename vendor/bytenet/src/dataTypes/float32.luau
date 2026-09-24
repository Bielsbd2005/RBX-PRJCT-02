--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local f32 = bufferWriter.writef32

local float32 = {
	Write = f32;

	Read = function(b: buffer, cursor: number)
		return buffer.readf32(b, cursor), 4
	end;
}

return function(): types.DataTypeInterface<number>
	return float32
end
