--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writeu16 = bufferWriter.writeu16

local uint16 = {
	Write = writeu16;

	Read = function(b: buffer, cursor: number)
		return buffer.readu16(b, cursor), 2
	end;
}

return function(): types.DataTypeInterface<number>
	return uint16
end
