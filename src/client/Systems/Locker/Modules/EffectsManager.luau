local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local EffectsManager = {}
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local guiName = "EffectsGui"
local frameName = "FadeFrame"

local function getOrCreateFadeFrame()
	local existingGui = playerGui:FindFirstChild(guiName)
	if existingGui then
		return existingGui[frameName]
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = guiName
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100 -- Por encima de todo
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = frameName
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1 -- Empieza invisible
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = gui

	return frame
end

function EffectsManager.fadeToBlack(duration)
	duration = duration or 0.5
	local frame = getOrCreateFadeFrame()

	local tween = TweenService:Create(frame, TweenInfo.new(duration), {BackgroundTransparency = 0})
	tween:Play()
	tween.Completed:Wait()
end

function EffectsManager.fadeFromBlack(duration)
	duration = duration or 0.5
	local frame = getOrCreateFadeFrame() -- Asume que ya existe

	local tween = TweenService:Create(frame, TweenInfo.new(duration), {BackgroundTransparency = 1})
	tween:Play()
	tween.Completed:Wait()

	-- Opcional: Destruir GUI después? Mejor dejarla para reusar.
end

return EffectsManager
