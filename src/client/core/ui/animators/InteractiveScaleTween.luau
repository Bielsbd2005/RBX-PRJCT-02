--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(script.Parent.Parent.UITheme)
local Retween = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("Retween"))

-- Hover/Click TweenInfos delegan a UITheme (eran duplicados literales de
-- UITheme.HoverTweenInfo / UITheme.ClickTweenInfo). Si el caller pasa su
-- propio tweenInfo en BindOptions, ese override sigue funcionando.
local HOVER_TWEEN_INFO = UITheme.HoverTweenInfo
local CLICK_TWEEN_INFO = UITheme.ClickTweenInfo

export type BindOptions = {
	defaultScale: number?,
	hoverScale: number?,
	clickScale: number?,
	hoverTweenInfo: TweenInfo?,
	clickTweenInfo: TweenInfo?,
	enableHover: boolean?,
	scaleTarget: GuiObject?,
	-- Si se define, en hover el botón sube `liftOffset` px (Position Y -= liftOffset)
	-- y vuelve a su posición original al salir del hover. Solo aplica al `button`
	-- (no al scaleTarget) — el lift y el scale viven en nodos distintos.
	liftOffset: number?,
}

type TweenState = {
	scaleSlot: Retween.Slot,
	positionSlot: Retween.Slot,
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

local function tweenPosition(state: TweenState, target: GuiObject, toPosition: UDim2, tweenInfo: TweenInfo)
	Retween.run(state.positionSlot, target, tweenInfo, { Position = toPosition })
end

function InteractiveScaleTween.bindButton(button: GuiButton, janitor: any, options: BindOptions?): ()
	local defaultScale = if options and options.defaultScale then options.defaultScale else 1
	local hoverScale = if options and options.hoverScale then options.hoverScale else 1.04
	local clickScale = if options and options.clickScale then options.clickScale else 0.96
	local hoverTweenInfo = if options and options.hoverTweenInfo then options.hoverTweenInfo else HOVER_TWEEN_INFO
	local clickTweenInfo = if options and options.clickTweenInfo then options.clickTweenInfo else CLICK_TWEEN_INFO
	local enableHover = if options and options.enableHover ~= nil then options.enableHover else true
	local scaleTarget = if options and options.scaleTarget then options.scaleTarget else button
	local liftOffset = if options and options.liftOffset then options.liftOffset else 0

	local state: TweenState = {
		scaleSlot = { current = nil },
		positionSlot = { current = nil },
	}
	local isHovered = false

	-- Cachear la Position default antes del primer hover para poder restaurarla
	-- al MouseLeave. Si otro animador la cambia más adelante el lift seguirá
	-- volviendo a este valor — el caso esperado es Position estática asignada
	-- en Studio.
	local defaultPosition = button.Position
	local liftedPosition = if liftOffset ~= 0
		then UDim2.new(defaultPosition.X.Scale, defaultPosition.X.Offset, defaultPosition.Y.Scale, defaultPosition.Y.Offset - liftOffset)
		else defaultPosition

	tweenScale(state, scaleTarget, defaultScale, hoverTweenInfo)

	if enableHover then
		janitor:Add(button.MouseEnter:Connect(function()
			isHovered = true
			tweenScale(state, scaleTarget, hoverScale, hoverTweenInfo)
			if liftOffset ~= 0 then
				tweenPosition(state, button, liftedPosition, hoverTweenInfo)
			end
		end), "Disconnect")

		janitor:Add(button.MouseLeave:Connect(function()
			isHovered = false
			tweenScale(state, scaleTarget, defaultScale, hoverTweenInfo)
			if liftOffset ~= 0 then
				tweenPosition(state, button, defaultPosition, hoverTweenInfo)
			end
		end), "Disconnect")
	end

	janitor:Add(button.MouseButton1Down:Connect(function()
		tweenScale(state, scaleTarget, clickScale, clickTweenInfo)
	end), "Disconnect")

	janitor:Add(button.MouseButton1Up:Connect(function()
		local targetScale = if enableHover and isHovered then hoverScale else defaultScale
		tweenScale(state, scaleTarget, targetScale, hoverTweenInfo)
	end), "Disconnect")

	janitor:Add(function()
		Retween.cancel(state.scaleSlot)
		Retween.cancel(state.positionSlot)
	end, true)
end

return InteractiveScaleTween
