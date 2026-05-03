--!strict

local TweenService = game:GetService("TweenService")

local GuiAnimator = {}
GuiAnimator.__index = GuiAnimator

function GuiAnimator.new(gui: ScreenGui?, container: Frame)
	local self = setmetatable({}, GuiAnimator)
	self._gui = gui
	self._container = container
	self._currentTween = nil
	self._completionConnection = nil
	self._ownsScale = false

	local anchor = container.AnchorPoint
	if anchor.X ~= 0.5 or anchor.Y ~= 0.5 then
		local pos = container.Position
		local size = container.Size

		container.AnchorPoint = Vector2.new(0.5, 0.5)
		container.Position = UDim2.new(
			pos.X.Scale + size.X.Scale * (0.5 - anchor.X),
			pos.X.Offset + size.X.Offset * (0.5 - anchor.X),
			pos.Y.Scale + size.Y.Scale * (0.5 - anchor.Y),
			pos.Y.Offset + size.Y.Offset * (0.5 - anchor.Y)
		)
	end

	local uiScale = container:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = container
		self._ownsScale = true
	end

	self._uiScale = uiScale

	return self
end

function GuiAnimator:_clearTween(): ()
	if self._completionConnection then
		self._completionConnection:Disconnect()
		self._completionConnection = nil
	end

	if self._currentTween then
		self._currentTween:Cancel()
		self._currentTween = nil
	end
end

function GuiAnimator:open(): ()
	self:_clearTween()

	if self._gui then
		self._gui.Enabled = true
	else
		self._container.Visible = true
	end
	self._uiScale.Scale = 0

	self._currentTween = TweenService:Create(
		self._uiScale,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	)
	self._currentTween:Play()
end

function GuiAnimator:close(): ()
	self:_clearTween()

	local tween = TweenService:Create(
		self._uiScale,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Scale = 0 }
	)

	self._currentTween = tween
	self._completionConnection = tween.Completed:Connect(function(playbackState)
		if self._currentTween ~= tween then
			return
		end

		if playbackState == Enum.PlaybackState.Completed then
				if self._gui then
					self._gui.Enabled = false
				else
					self._container.Visible = false
				end
			end

		self:_clearTween()
	end)

	tween:Play()
end

function GuiAnimator:Destroy(): ()
	self:_clearTween()
	if self._ownsScale and self._uiScale.Parent ~= nil then
		self._uiScale:Destroy()
	end
end

return GuiAnimator
