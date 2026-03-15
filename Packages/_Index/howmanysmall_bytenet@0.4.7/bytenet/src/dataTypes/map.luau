--!optimize 2
--!strict

local bufferWriter = require(script.Parent.Parent.process.bufferWriter)
local types = require(script.Parent.Parent.types)

local writeu16 = bufferWriter.writeu16

-- thanks jack :p
return function(
	keyType: types.DataTypeInterface<any>,
	valueType: types.DataTypeInterface<any>
): types.DataTypeInterface<{[any]: any}>
	-- Cache these functions to avoid the overhead of the index
	local keyWrite = keyType.Write
	local valueWrite = valueType.Write

	return {
		Read = function(b: buffer, cursor: number)
			local map = {}
			local mapCursor = cursor

			-- Read map length
			local mapLength = buffer.readu16(b, mapCursor)
			mapCursor += 2

			for _ = 1, mapLength do
				-- read key/value pairs and add them to the map
				local key, keyLength = keyType.Read(b, mapCursor)
				mapCursor += keyLength

				local value, valueLength = valueType.Read(b, mapCursor)
				mapCursor += valueLength

				map[key] = value
			end

			-- Return the map, alongside length, because mapCursor - cursor = size
			return map, mapCursor - cursor
		end;
		Write = function(map: any)
			local count = 0
			for _ in map do
				count += 1
			end

			-- Write length
			writeu16(count)

			for key, value in map do
				-- Write key/value pairs
				keyWrite(key)
				valueWrite(value)
			end
		end;
	}
end
