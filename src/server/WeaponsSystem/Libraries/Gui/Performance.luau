--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local UPDATE_INTERVAL = 0.5

local COLOR_GOOD = Color3.fromRGB(255, 255, 255)
local COLOR_WARN = Color3.fromRGB(255, 210, 60)
local COLOR_BAD = Color3.fromRGB(235, 60, 60)
-- Ping en ms: por encima de WARN amarillo, de BAD rojo.
local PING_WARN_MS = 100
local PING_BAD_MS = 200
-- FPS: por debajo de WARN amarillo, de BAD rojo.
local FPS_WARN = 45
local FPS_BAD = 25

local Performance = {}
Performance.__index = Performance

function Performance.new()
	local self = setmetatable({}, Performance)
	self._frameConn = nil :: RBXScriptConnection?
	self._destroyed = false
	return self
end

-- Requiere en Studio WeaponsSystemGui.Performance con TextLabels "Ping" y "FPS"
-- (directos o con un TextLabel dentro) e iconos "PingIcon"/"FPSIcon". Lo que falte
-- no se pinta.
local function findLabel(parent: Instance, name: string): TextLabel?
	local node = parent:FindFirstChild(name)
	if not node then return nil end
	if node:IsA("TextLabel") then return node end
	return node:FindFirstChildWhichIsA("TextLabel", true)
end

local function setIconColor(icon: Instance?, color: Color3)
	if not icon then return end
	if icon:IsA("ImageLabel") or icon:IsA("ImageButton") then
		icon.ImageColor3 = color
	elseif icon:IsA("TextLabel") or icon:IsA("TextButton") then
		icon.TextColor3 = color
	elseif icon:IsA("GuiObject") then
		icon.BackgroundColor3 = color
	end
end

function Performance:setup(gui: ScreenGui)
	local root = gui:FindFirstChild("Performance")
	if not root then return end

	local pingLabel = findLabel(root, "Ping")
	local fpsLabel = findLabel(root, "FPS")
	local pingIcon = root:FindFirstChild("PingIcon")
	local fpsIcon = root:FindFirstChild("FPSIcon")
	if not (pingLabel or fpsLabel or pingIcon or fpsIcon) then return end

	local frameCount = 0
	self._frameConn = RunService.RenderStepped:Connect(function()
		frameCount += 1
	end)

	gui.Destroying:Once(function()
		self:Destroy()
	end)

	task.spawn(function()
		while not self._destroyed do
			local framesAtStart = frameCount
			local dt = task.wait(UPDATE_INTERVAL)
			if self._destroyed then return end
			if not gui.Enabled then continue end

			local pingMs = math.floor(LocalPlayer:GetNetworkPing() * 1000 + 0.5)
			local fps = math.floor((frameCount - framesAtStart) / dt + 0.5)

			if pingLabel then
				pingLabel.Text = string.format("%d ms", pingMs)
			end
			if fpsLabel then
				fpsLabel.Text = string.format("%d FPS", fps)
			end
			setIconColor(
				pingIcon,
				if pingMs >= PING_BAD_MS then COLOR_BAD elseif pingMs >= PING_WARN_MS then COLOR_WARN else COLOR_GOOD
			)
			setIconColor(fpsIcon, if fps < FPS_BAD then COLOR_BAD elseif fps < FPS_WARN then COLOR_WARN else COLOR_GOOD)
		end
	end)
end

function Performance:Destroy()
	self._destroyed = true
	if self._frameConn then
		self._frameConn:Disconnect()
		self._frameConn = nil
	end
end

return Performance
