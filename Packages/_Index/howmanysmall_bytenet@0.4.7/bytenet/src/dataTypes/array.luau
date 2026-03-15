--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writeu16 = bufferWriter.writeu16

--[[
	Create a new array with the given dataTypeInterface
]]
return function<T>(valueType: types.DataTypeInterface<T>): types.DataTypeInterface<{[number]: T}>
	local valueWrite = valueType.Write
	local valueRead = valueType.Read

	return {
		Read = function(b: buffer, cursor: number)
			local arrayLength = buffer.readu16(b, cursor)
			local arrayCursor = cursor + 2

			local array = table.create(arrayLength)

			for index = 1, arrayLength do
				local item, length = valueRead(b, arrayCursor)
				array[index] = item

				arrayCursor += length
			end

			return array, arrayCursor - cursor
		end;
		Write = function(value: any)
			writeu16(#value)

			-- numeric iteration is about 2x faster than generic iteration
			for _, item in value do
				valueWrite(item)
			end
		end;
	}
end
