--!strict
--[[
	Flags de depuración como BoolValues en ReplicatedStorage.Debug (cliente) o
	ServerStorage.Debug (solo servidor). Fuera de Studio siempre dan false, aunque
	el BoolValue publicado con el place esté en true. La función devuelta por
	bind() está cacheada (se puede llamar cada frame) y engancha valores creados tarde.
]]

local RunService = game:GetService("RunService")

local FOLDER_NAME = "Debug"
local IS_STUDIO = RunService:IsStudio()

local DebugFlags = {}

local function _alwaysFalse(): boolean
	return false
end

local function _whenChild(parent: Instance, name: string, className: string, onFound: (Instance) -> ())
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA(className) then
		onFound(existing)
		return
	end
	if existing then
		warn(string.format(
			"[DebugFlags] %s.%s existe pero no es %s (%s) — se ignora.",
			parent:GetFullName(),
			name,
			className,
			existing.ClassName
		))
	end

	local conn: RBXScriptConnection
	conn = parent.ChildAdded:Connect(function(child)
		if child.Name == name and child:IsA(className) then
			conn:Disconnect()
			onFound(child)
		end
	end)
end

function DebugFlags.bind(root: Instance, name: string): () -> boolean
	if not IS_STUDIO then
		return _alwaysFalse
	end

	local enabled = false
	_whenChild(root, FOLDER_NAME, "Instance", function(folder)
		_whenChild(folder, name, "BoolValue", function(child)
			local flag = child :: BoolValue
			enabled = flag.Value
			flag.Changed:Connect(function(value: boolean)
				enabled = value
			end)
		end)
	end)

	return function(): boolean
		return enabled
	end
end

return DebugFlags
