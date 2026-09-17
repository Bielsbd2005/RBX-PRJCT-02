--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(script.Parent.Parent.UITheme)
local Retween = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("Retween"))

local HOVER_TWEEN_INFO = UITheme.HoverTweenInfo
local CLICK_TWEEN_INFO = UITheme.ClickTweenInfo
local DEFAULT_SCALE = 1

export type BindOptions = {
	hoverScale: number?,
	clickScale: number?,
	enableHover: boolean?,
	scaleTarget: GuiObject?,
}

type TweenState = {
	scaleSlot: Retween.Slot,
}

local InteractiveScaleTween = {}

local function getOrCreateScaleNode(target: GuiObject): UIScale
	local node = target:FindFirstChild("InteractiveScale")
	if node and node:IsA("UIScale") then
		return node
	end

	local created = Instance.new("UIScale")
	created.Name = "InteractiveScale"
	created.Scale = 1
	created.Parent = target
	return created
end

local function tweenScale(state: TweenState, target: GuiObject, toScale: number, tweenInfo: TweenInfo)
	local scaleNode = getOrCreateScaleNode(target)
	Retween.run(state.scaleSlot, scaleNode, tweenInfo, { Scale = toScale })
end

function InteractiveScaleTween.bindButton(button: GuiButton, janitor: any, options: BindOptions?): ()
	local hoverScale = if options and options.hoverScale then options.hoverScale else 1.04
	local clickScale = if options and options.clickScale then options.clickScale else 0.96
	local enableHover = if options and options.enableHover ~= nil then options.enableHover else true
	local scaleTarget = if options and options.scaleTarget then options.scaleTarget else button

	local state: TweenState = {
		scaleSlot = { current = nil },
	}
	local isHovered = false

	tweenScale(state, scaleTarget, DEFAULT_SCALE, HOVER_TWEEN_INFO)

	if enableHover then
		janitor:Add(button.MouseEnter:Connect(function()
			isHovered = true
			tweenScale(state, scaleTarget, hoverScale, HOVER_TWEEN_INFO)
		end), "Disconnect")

		janitor:Add(button.MouseLeave:Connect(function()
			isHovered = false
			tweenScale(state, scaleTarget, DEFAULT_SCALE, HOVER_TWEEN_INFO)
		end), "Disconnect")
	end

	janitor:Add(button.MouseButton1Down:Connect(function()
		tweenScale(state, scaleTarget, clickScale, CLICK_TWEEN_INFO)
	end), "Disconnect")

	janitor:Add(button.MouseButton1Up:Connect(function()
		local targetScale = if enableHover and isHovered then hoverScale else DEFAULT_SCALE
		tweenScale(state, scaleTarget, targetScale, HOVER_TWEEN_INFO)
	end), "Disconnect")

	janitor:Add(function()
		Retween.cancel(state.scaleSlot)
	end, true)
end

return InteractiveScaleTween
