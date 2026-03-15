--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writef32NoAlloc = bufferWriter.writef32NoAlloc
local alloc = bufferWriter.alloc

local vec2 = {
	--[[
		2 float32s, one for X, one for Y
	]]

	Read = function(b: buffer, cursor: number)
		return Vector2.new(buffer.readf32(b, cursor), buffer.readf32(b, cursor + 4)), 8
	end;

	Write = function(value: Vector2)
		alloc(8)
		writef32NoAlloc(value.X)
		writef32NoAlloc(value.Y)
	end;
}

return function(): types.DataTypeInterface<Vector2>
	return vec2
end
