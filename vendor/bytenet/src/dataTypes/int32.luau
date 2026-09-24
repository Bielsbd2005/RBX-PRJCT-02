--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writei32 = bufferWriter.writei32

local int32 = {
	Write = writei32;

	Read = function(b: buffer, cursor: number)
		return buffer.readi32(b, cursor), 4
	end;
}

return function(): types.DataTypeInterface<number>
	return int32
end
