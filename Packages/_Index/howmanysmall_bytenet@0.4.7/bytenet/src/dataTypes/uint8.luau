--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writeu8 = bufferWriter.writeu8

local uint8 = {
	Write = writeu8;
	Read = function(b: buffer, cursor: number)
		return buffer.readu8(b, cursor), 1
	end;
}

return function(): types.DataTypeInterface<number>
	return uint8
end
