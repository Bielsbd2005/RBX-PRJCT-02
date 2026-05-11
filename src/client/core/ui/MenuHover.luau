--!strict

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any

local UITheme = require(script.Parent.UITheme)

-- Constantes locales delegan a UITheme — single source of truth para colores
-- de stroke y la curva de hover. Antes este archivo tenía duplicación con
-- UITheme.NavTweenInfo (mismo 0.15 Quad Out).
local STROKE_DEFAULT = UITheme.StrokeDefault
local STROKE_HOVER   = UITheme.StrokeHover
local TWEEN_INFO     = UITheme.NavTweenInfo

local MenuHover = {}
MenuHover.__index = MenuHover

local function tweenStroke(buttonState: { currentTween: Tween? }, stroke: UIStroke, color: Color3): ()
	if buttonState.currentTween then
		buttonState.currentTween:Cancel()
	end

	buttonState.currentTween = TweenService:Create(stroke, TWEEN_INFO, { Color = color })
	buttonState.currentTween:Play()
end

function MenuHover.bindButton(btn: GuiButton, janitor: any): () -> ()
	local stroke = btn:FindFirstChildOfClass("UIStroke")

	local function noop()
	end

	if not stroke or not stroke:IsA("UIStroke") then
		return noop
	end

	local buttonState = {
		currentTween = nil :: Tween?,
	}

	local function reset()
		tweenStroke(buttonState, stroke, STROKE_DEFAULT)
	end

	janitor:Add(btn.MouseEnter:Connect(function()
		tweenStroke(buttonState, stroke, STROKE_HOVER)
	end), "Disconnect")

	janitor:Add(btn.MouseLeave:Connect(reset), "Disconnect")
	janitor:Add(btn.Activated:Connect(reset), "Disconnect")

	janitor:Add(function()
		if buttonState.currentTween then
			buttonState.currentTween:Cancel()
		end
	end, true)

	return reset
end

function MenuHover.new(menuGui: ScreenGui)
	local self = setmetatable({}, MenuHover)
	self._janitor = Janitor.new()

	local bottom = menuGui:FindFirstChild("Bottom")

	local function bindContainer(container: Instance)
		for _, descendant in ipairs(container:GetDescendants()) do
			if descendant:IsA("GuiButton") then
				MenuHover.bindButton(descendant, self._janitor)
			end
		end
	end

	if bottom then
		bindContainer(bottom)
	end

	return self
end

function MenuHover:Destroy(): ()
	self._janitor:Destroy()
end

return MenuHover
