--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writei16 = bufferWriter.writei16

local int16 = {
	Write = writei16;

	Read = function(b: buffer, cursor: number)
		return buffer.readi16(b, cursor), 2
	end;
}

return function(): types.DataTypeInterface<number>
	return int16
end
