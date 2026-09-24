--!native
--!optimize 2
--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local client = require(script.Parent.Parent.process.client)
local server = require(script.Parent.Parent.process.server)
local types = require(script.Parent.Parent.types)

local moduleRunContext: "server" | "client" = if RunService:IsServer() then "server" else "client"

--[[
	We use closures here instead of metatables for performance
	It's just faster to use closures than metatables
]]
local function packet(properties: types.PacketProperties<types.DataTypeInterface<any>>, id: number)
	-- Basic properties: reliability type, "unique" which is used to get the packet ID, and set up listeners
	local reliabilityType: "Reliable" | "Unreliable" = properties.ReliabilityType or "Reliable"
	local listeners = {}

	local serverSendFunction: (player: Player, id: number, writer: (value: any) -> (), data: any) -> () = if reliabilityType
			== "Reliable"
		then server.sendPlayerReliable
		else server.sendPlayerUnreliable

	local serverSendAllFunction: (id: number, writer: (value: any) -> (), data: any) -> () = if reliabilityType
			== "Reliable"
		then server.sendAllReliable
		else server.sendAllUnreliable

	local clientSendFunction: (id: number, writer: (value: any) -> (), data: any) -> () = if reliabilityType
			== "Reliable"
		then client.sendReliable
		else client.sendUnreliable

	-- shorcut to avoid indexxing
	local writer = properties.Value.Write

	local exported = {}

	-- RunContext error checking that doesn't have performance drawbacks
	setmetatable(exported, {
		__index = function(index)
			if
				(index == "SendTo" or index == "SendToAllExcept" or index == "SendToAll")
				and moduleRunContext == "client"
			then
				error("You cannot use SendTo, SendToAllExcept, or SendToAll on the client")
			elseif index == "Send" and moduleRunContext == "server" then
				error("You cannot use Send on the server")
			end
		end;
	})

	-- exposed for the reader file
	exported.Reader = properties.Value.Read
	exported.reader = properties.Value.Read

	if moduleRunContext == "server" then
		function exported.SendToList(data, players: {Player})
			for _, player in players do
				serverSendFunction(player, id, writer, data)
			end
		end

		function exported.SendTo(data, player: Player)
			serverSendFunction(player, id, writer, data)
		end

		function exported.SendToAllExcept(data, except: Player)
			for _, player: Player in Players:GetPlayers() do
				if player ~= except then
					serverSendFunction(player, id, writer, data)
				end
			end
		end

		function exported.SendToAll(data)
			serverSendAllFunction(id, writer, data)
		end
	elseif moduleRunContext == "client" then
		function exported.Send(data)
			clientSendFunction(id, writer, data)
		end
	end

	function exported.Wait()
		-- define it up here so we can use it to disconnect
		local index: number

		local runningThread = coroutine.running()
		table.insert(listeners, function(data, player)
			task.spawn(runningThread, data, player)

			-- Disconnects the listener
			table.remove(listeners, index)
		end)

		-- we connected, time to set the index for when we need to disconnect.
		index = #listeners

		-- the listener will resume the thread
		return coroutine.yield()
	end

	function exported.Listen(callback)
		table.insert(listeners, callback)
		return function()
			local index = table.find(listeners, callback)
			if index then
				table.remove(listeners, index)
			end
		end
	end
	exported.Connect = exported.Listen

	function exported.GetListeners()
		return listeners
	end

	return exported
end

return packet
