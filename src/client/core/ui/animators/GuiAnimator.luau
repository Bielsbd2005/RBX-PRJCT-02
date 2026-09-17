--!strict

local TweenService = game:GetService("TweenService")

export type AnimatorMode = "scale" | "none"

export type GuiAnimatorOptions = {
	mode: AnimatorMode?,
}

local SCALE_OPEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local GuiAnimator = {}
GuiAnimator.__index = GuiAnimator

function GuiAnimator.new(container: GuiObject, options: GuiAnimatorOptions?)
	local self = setmetatable({}, GuiAnimator)
	self._container = container
	self._currentTween = nil
	self._ownsScale = false
	self._mode = (options and options.mode) or "scale"

	if self._mode == "scale" then
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
	end
	-- "none": snap puro en open/close, sin setup adicional.

	return self
end

function GuiAnimator:_clearTween(): ()
	if self._currentTween then
		self._currentTween:Cancel()
		self._currentTween = nil
	end
end

function GuiAnimator:open(): ()
	self:_clearTween()
	self._container.Visible = true

	if self._mode == "scale" then
		self._uiScale.Scale = 0
		self._currentTween = TweenService:Create(self._uiScale, SCALE_OPEN_INFO, { Scale = 1 })
		self._currentTween:Play()
	end
end

-- Cierre instantáneo en todos los modos; `onComplete` se llama síncrono al ocultar.
function GuiAnimator:close(onComplete: (() -> ())?): ()
	self:_clearTween()

	self._container.Visible = false

	if onComplete then
		onComplete()
	end
end

function GuiAnimator:Destroy(): ()
	self:_clearTween()
	if self._mode == "scale" and self._ownsScale and self._uiScale.Parent ~= nil then
		self._uiScale:Destroy()
	end
end

return GuiAnimator
