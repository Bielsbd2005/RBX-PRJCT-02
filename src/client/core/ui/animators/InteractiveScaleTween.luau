--!strict

local TweenService = game:GetService("TweenService")

local HOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

export type BindOptions = {
	defaultScale: number?,
	hoverScale: number?,
	clickScale: number?,
	hoverTweenInfo: TweenInfo?,
	clickTweenInfo: TweenInfo?,
	enableHover: boolean?,
	scaleTarget: GuiObject?,
}

type TweenState = {
	activeTweens: { [GuiObject]: Tween },
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
	local currentTween = state.activeTweens[target]
	if currentTween then
		currentTween:Cancel()
		state.activeTweens[target] = nil
	end

	local tween = TweenService:Create(scaleNode, tweenInfo, { Scale = toScale })
	state.activeTweens[target] = tween
	tween.Completed:Connect(function()
		if state.activeTweens[target] == tween then
			state.activeTweens[target] = nil
		end
	end)
	tween:Play()
end

function InteractiveScaleTween.bindButton(button: GuiButton, janitor: any, options: BindOptions?): ()
	local defaultScale = if options and options.defaultScale then options.defaultScale else 1
	local hoverScale = if options and options.hoverScale then options.hoverScale else 1.04
	local clickScale = if options and options.clickScale then options.clickScale else 0.96
	local hoverTweenInfo = if options and options.hoverTweenInfo then options.hoverTweenInfo else HOVER_TWEEN_INFO
	local clickTweenInfo = if options and options.clickTweenInfo then options.clickTweenInfo else CLICK_TWEEN_INFO
	local enableHover = if options and options.enableHover ~= nil then options.enableHover else true
	local scaleTarget = if options and options.scaleTarget then options.scaleTarget else button

	local state: TweenState = {
		activeTweens = {},
	}
	local hovered = false

	tweenScale(state, scaleTarget, defaultScale, hoverTweenInfo)

	if enableHover then
		janitor:Add(button.MouseEnter:Connect(function()
			hovered = true
			tweenScale(state, scaleTarget, hoverScale, hoverTweenInfo)
		end), "Disconnect")

		janitor:Add(button.MouseLeave:Connect(function()
			hovered = false
			tweenScale(state, scaleTarget, defaultScale, hoverTweenInfo)
		end), "Disconnect")
	end

	janitor:Add(button.MouseButton1Down:Connect(function()
		tweenScale(state, scaleTarget, clickScale, clickTweenInfo)
	end), "Disconnect")

	janitor:Add(button.MouseButton1Up:Connect(function()
		local targetScale = if enableHover and hovered then hoverScale else defaultScale
		tweenScale(state, scaleTarget, targetScale, hoverTweenInfo)
	end), "Disconnect")

	janitor:Add(function()
		for _, tween in state.activeTweens do
			tween:Cancel()
		end
		table.clear(state.activeTweens)
	end, true)
end

return InteractiveScaleTween
