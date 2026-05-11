--!strict
--[[
	PulseAlert
	Animación de "alerta tipo radar": el frame crece un % (default 15%) mientras
	se va haciendo transparente; al llegar a transparente total, vuelve al tamaño
	y opacidad iniciales e instantáneamente reanuda el ciclo.

	Se monta un `UIScale` hijo (nombre "PulseScale") y se tweanea su .Scale +
	BackgroundTransparency del frame. Si el frame tiene un UIStroke directo,
	también se tweanea su Transparency para que el borde se desvanezca a la par
	(útil cuando la alerta es un "anillo" con stroke en vez de relleno).

	Devuelve un handle con :Destroy() que cancela los tweens, restaura los
	valores iniciales y elimina el UIScale creado.
]]

local TweenService = game:GetService("TweenService")

export type Options = {
	scaleAmount: number?,
	duration: number?,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?,
}

export type Handle = {
	Destroy: (Handle) -> (),
}

local DEFAULT_SCALE_AMOUNT = 1.15
local DEFAULT_DURATION = 1.0
local SCALE_NODE_NAME = "PulseScale"

local function getOrCreateScale(frame: GuiObject): UIScale
	local existing = frame:FindFirstChild(SCALE_NODE_NAME)
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Name = SCALE_NODE_NAME
	scale.Scale = 1
	scale.Parent = frame
	return scale
end

local PulseAlert = {}

function PulseAlert.bind(frame: GuiObject, options: Options?): Handle
	local scaleAmount = if options and options.scaleAmount then options.scaleAmount else DEFAULT_SCALE_AMOUNT
	local duration = if options and options.duration then options.duration else DEFAULT_DURATION
	local easingStyle = if options and options.easingStyle then options.easingStyle else Enum.EasingStyle.Quad
	local easingDirection = if options and options.easingDirection then options.easingDirection else Enum.EasingDirection.Out

	local startBg = frame.BackgroundTransparency
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	local startStroke = if stroke then stroke.Transparency else nil

	local scale = getOrCreateScale(frame)
	scale.Scale = 1

	-- RepeatCount = -1, Reverses = false → al terminar un ciclo se teletransporta
	-- a los valores iniciales y vuelve a empezar (no ping-pong).
	local info = TweenInfo.new(duration, easingStyle, easingDirection, -1, false, 0)

	local scaleTween = TweenService:Create(scale, info, { Scale = scaleAmount })
	local fadeTween = TweenService:Create(frame, info, { BackgroundTransparency = 1 })
	local strokeTween = if stroke then TweenService:Create(stroke, info, { Transparency = 1 }) else nil

	scaleTween:Play()
	fadeTween:Play()
	if strokeTween then
		strokeTween:Play()
	end

	local destroyed = false
	local handle = {} :: Handle
	function handle.Destroy(_self)
		if destroyed then return end
		destroyed = true
		scaleTween:Cancel()
		fadeTween:Cancel()
		if strokeTween then
			strokeTween:Cancel()
		end
		frame.BackgroundTransparency = startBg
		if stroke and startStroke ~= nil then
			stroke.Transparency = startStroke
		end
		if scale.Parent == frame then
			scale:Destroy()
		end
	end
	return handle
end

return PulseAlert
