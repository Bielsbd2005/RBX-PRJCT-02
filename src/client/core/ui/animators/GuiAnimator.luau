--!strict

local TweenService = game:GetService("TweenService")

export type AnimatorMode = "scale" | "fade" | "none"

export type GuiAnimatorOptions = {
	mode: AnimatorMode?,
}

local SCALE_OPEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE_OPEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local GuiAnimator = {}
GuiAnimator.__index = GuiAnimator

local function isImageObject(instance: Instance): boolean
	return instance:IsA("ImageLabel") or instance:IsA("ImageButton")
end

function GuiAnimator.new(gui: ScreenGui?, container: GuiObject, options: GuiAnimatorOptions?)
	local self = setmetatable({}, GuiAnimator)
	self._gui = gui
	self._container = container
	self._currentTween = nil
	self._completionConnection = nil
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
	elseif self._mode == "fade" then
		-- Fade mode: solo tweena bg+image del root en open. Close es snap
		-- instantáneo (Visible=false) sin tween — los hijos no se tocan.
		self._authoredBackgroundTransparency = container.BackgroundTransparency
		if isImageObject(container) then
			self._authoredImageTransparency = (container :: any).ImageTransparency
		end
	end
	-- "none": snap puro en open/close, sin setup adicional.

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

function GuiAnimator:_setVisible(visible: boolean): ()
	if self._gui then
		self._gui.Enabled = visible
	else
		self._container.Visible = visible
	end
end

function GuiAnimator:open(): ()
	self:_clearTween()
	self:_setVisible(true)

	if self._mode == "scale" then
		self._uiScale.Scale = 0
		self._currentTween = TweenService:Create(self._uiScale, SCALE_OPEN_INFO, { Scale = 1 })
		self._currentTween:Play()
		return
	elseif self._mode == "none" then
		return
	end

	local container = self._container
	container.BackgroundTransparency = 1
	local goal: { [string]: number } = {
		BackgroundTransparency = self._authoredBackgroundTransparency,
	}
	if self._authoredImageTransparency ~= nil then
		(container :: any).ImageTransparency = 1
		goal.ImageTransparency = self._authoredImageTransparency
	end

	self._currentTween = TweenService:Create(container, FADE_OPEN_INFO, goal)
	self._currentTween:Play()
end

-- Cierre instantáneo (sin tween) en todos los modos. `onComplete` se invoca al
-- ocultar, para que el caller encadene trabajo (p. ej. reaparecer el menú).
function GuiAnimator:close(onComplete: (() -> ())?): ()
	self:_clearTween()

	-- En modo scale dejamos el UIScale listo para el próximo open (que lo pone
	-- a 0 igualmente); no animamos la salida.
	self:_setVisible(false)

	if onComplete then
		onComplete()
	end
end

function GuiAnimator:Destroy(): ()
	self:_clearTween()
	if self._mode == "fade" then
		-- Restauramos las transparencias autoradas: si nos destruyen mid-tween,
		-- el siguiente ciclo de vida (hot-reload) las leerá correctas.
		self._container.BackgroundTransparency = self._authoredBackgroundTransparency
		if self._authoredImageTransparency ~= nil then
			(self._container :: any).ImageTransparency = self._authoredImageTransparency
		end
	elseif self._mode == "scale" and self._ownsScale and self._uiScale.Parent ~= nil then
		self._uiScale:Destroy()
	end
end

return GuiAnimator
