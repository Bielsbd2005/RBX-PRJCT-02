--!native
--!optimize 2
--!strict

--[[
	Exists so that the namespace can set the ID of the packet

	Packet shouldnt need to care about making its own ID
]]
local packet = require(script.Parent.packet)
local types = require(script.Parent.Parent.types)

local function definePacket(properties: types.PacketProperties<any>)
	return function(id: number)
		return packet(properties, id)
	end
end

return definePacket
