--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local replicatedValue = require(script.Parent.replicatedValue)

local runContext: "server" | "client" = if RunService:IsServer() then "server" else "client"
local valueFolder: Folder
local valueDictionary: {
	[string]: replicatedValue.replicatedValueType,
} = {}

local values = {}

function values.start()
	if runContext == "server" then
		local storage = Instance.new("Folder")
		storage.Name = "BytenetStorage"
		storage.Parent = ReplicatedStorage

		valueFolder = storage
	elseif runContext == "client" then
		valueFolder = ReplicatedStorage:WaitForChild("BytenetStorage")
	end
end

function values.access(name: string): replicatedValue.replicatedValueType
	-- caching
	if valueDictionary[name] then
		return valueDictionary[name]
	end

	if runContext == "client" then
		-- The server creates these StringValues; on the client they may not have
		-- replicated yet when Network is first required. FindFirstChild (no wait)
		-- would return nil here and kill all networking for the session, so wait.
		local potentialValueInstance = valueFolder:WaitForChild(name, 10)
		if not potentialValueInstance or not potentialValueInstance:IsA("StringValue") then
			error(
				`[ByteNet] namespace value "{name}" failed to replicate to the client `
					.. `(not found or not a StringValue after 10s)`,
				2
			)
		end

		-- set up the value and return it
		local value = replicatedValue(potentialValueInstance)

		valueDictionary[name] = value

		return value
	elseif runContext == "server" then
		-- create the value and return it
		local newValueInstance = Instance.new("StringValue")
		newValueInstance.Name = name
		newValueInstance.Parent = valueFolder

		local value = replicatedValue(newValueInstance)

		valueDictionary[name] = value

		return value
	end

	return valueDictionary[name]
end

return values
