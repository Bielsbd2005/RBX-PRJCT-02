--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writeu32 = bufferWriter.writeu32

local uint32 = {
	Write = writeu32;

	Read = function(b: buffer, cursor: number)
		return buffer.readu32(b, cursor), 4
	end;
}

return function(): types.DataTypeInterface<number>
	return uint32
end
