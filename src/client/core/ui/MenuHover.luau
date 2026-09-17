--!strict

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any

local UITheme = require(script.Parent.UITheme)

local STROKE_DEFAULT = UITheme.StrokeDefault
local STROKE_HOVER   = UITheme.StrokeHover
local TWEEN_INFO     = UITheme.NavTweenInfo

local MenuHover = {}
MenuHover.__index = MenuHover

local function tweenStroke(buttonState: { currentTween: Tween?, isHovered: boolean }, stroke: UIStroke, color: Color3, transparency: number, enabled: boolean): ()
	if buttonState.currentTween then
		buttonState.currentTween:Cancel()
	end

	if enabled then
		stroke.Enabled = true
	end

	local tween = TweenService:Create(stroke, TWEEN_INFO, {
		Color = color,
		Transparency = transparency,
	})
	buttonState.currentTween = tween

	if not enabled then
		tween.Completed:Once(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and not buttonState.isHovered then
				stroke.Enabled = false
			end
		end)
	end

	tween:Play()
end

function MenuHover.bindButton(btn: GuiButton, janitor: any): () -> ()
	local stroke = btn:FindFirstChildOfClass("UIStroke")

	local function noop()
	end

	if not stroke then
		return noop
	end

	-- Inicialmente oculto: el stroke sólo se muestra durante el hover
	stroke.Transparency = 1
	stroke.Enabled = false

	local buttonState = {
		currentTween = nil :: Tween?,
		isHovered = false,
	}

	local function hideStroke(instant: boolean)
		buttonState.isHovered = false
		if buttonState.currentTween then
			buttonState.currentTween:Cancel()
			buttonState.currentTween = nil
		end
		if instant then
			stroke.Transparency = 1
			stroke.Enabled = false
			stroke.Color = STROKE_DEFAULT
		else
			tweenStroke(buttonState, stroke, STROKE_DEFAULT, 1, false)
		end
	end

	local function showStroke()
		buttonState.isHovered = true
		tweenStroke(buttonState, stroke, STROKE_HOVER, 0, true)
	end

	janitor:Add(btn.MouseEnter:Connect(showStroke), "Disconnect")
	janitor:Add(btn.MouseLeave:Connect(function()
		hideStroke(false)
	end), "Disconnect")

	-- Al hacer click, el stroke se oculta inmediatamente para la próxima vez
	janitor:Add(btn.Activated:Connect(function()
		hideStroke(true)
	end), "Disconnect")
	janitor:Add(btn.MouseButton1Click:Connect(function()
		hideStroke(true)
	end), "Disconnect")

	janitor:Add(function()
		if buttonState.currentTween then
			buttonState.currentTween:Cancel()
		end
	end, true)

	return function()
		hideStroke(true)
	end
end

function MenuHover.new(menuGui: ScreenGui)
	local self = setmetatable({}, MenuHover)
	self._janitor = Janitor.new()

	local container = menuGui:FindFirstChild("Container")
	if container then
		for _, descendant in ipairs(container:GetDescendants()) do
			if descendant:IsA("GuiButton") then
				MenuHover.bindButton(descendant, self._janitor)
			end
		end
	end

	return self
end

function MenuHover:Destroy(): ()
	self._janitor:Destroy()
end

return MenuHover
