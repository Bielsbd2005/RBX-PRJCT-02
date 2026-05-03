--!strict
-- IrisTransition: efecto de iris circular (círculo negro que crece/encoge) como transición de pantalla.
-- Uso:
--   local iris = IrisTransition.new(playerGui)
--   iris:close(function() ... end)  -- cierra el iris; el callback se invoca cuando la pantalla está completamente negra
--   iris:open()                      -- abre el iris (revela la pantalla)

local TweenService = game:GetService("TweenService")

local CLOSE_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local OPEN_INFO  = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local SIZE_BIG   = UDim2.new(4, 0, 4, 0)
local SIZE_SMALL = UDim2.new(0, 0, 0, 0)
local GUI_NAME   = "IrisTransitionGui"

local IrisTransition = {}
IrisTransition.__index = IrisTransition

export type IrisTransition = typeof(setmetatable(
	{} :: {
		_circle: Frame,
		_screenGui: ScreenGui,
		_activeTween: Tween?,
		_opId: number,
	},
	IrisTransition
))

function IrisTransition.new(playerGui: PlayerGui): IrisTransition
	local existing = playerGui:FindFirstChild(GUI_NAME)
	if existing and existing:IsA("ScreenGui") then
		local existingCircle = existing:FindFirstChild("IrisCircle")
		if existingCircle and existingCircle:IsA("Frame") then
			return setmetatable(
				{
					_circle = existingCircle,
					_screenGui = existing,
					_activeTween = nil,
					_opId = 0,
				},
				IrisTransition
			)
		end
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 9999
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		screenGui.ScreenInsets = Enum.ScreenInsets.None
	end)
	screenGui.Parent = playerGui

	local circle = Instance.new("Frame")
	circle.Name = "IrisCircle"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = SIZE_SMALL
	circle.BorderSizePixel = 0
	circle.BackgroundColor3 = Color3.new(0, 0, 0)
	circle.BackgroundTransparency = 0
	circle.SizeConstraint = Enum.SizeConstraint.RelativeYY
	circle.Visible = false
	circle.ZIndex = 9999

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = circle

	circle.Parent = screenGui

	return setmetatable(
		{
			_circle = circle,
			_screenGui = screenGui,
			_activeTween = nil,
			_opId = 0,
		},
		IrisTransition
	)
end

local function _beginTransition(self: IrisTransition, targetSize: UDim2): (number, Tween)
	self._opId += 1
	local opId = self._opId

	if self._activeTween then
		self._activeTween:Cancel()
		self._activeTween = nil
	end

	local circle = self._circle
	circle.Visible = true

	local tweenInfo = if targetSize == SIZE_BIG then CLOSE_INFO else OPEN_INFO
	local tween = TweenService:Create(circle, tweenInfo, { Size = targetSize })
	self._activeTween = tween
	tween:Play()

	return opId, tween
end

-- Cierra el iris (pantalla a negro). Llama onBlack cuando está completamente cubierta.
function IrisTransition.close(self: IrisTransition, onBlack: (() -> ())?): ()
	task.spawn(function()
		local circle = self._circle
		circle.Size = SIZE_SMALL
		local opId, tween = _beginTransition(self, SIZE_BIG)
		local playbackState = tween.Completed:Wait()
		if self._activeTween == tween then
			self._activeTween = nil
		end

		if self._opId ~= opId or playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		if onBlack then
			onBlack()
		end
	end)
end

-- Resetea el iris al estado abierto sin animación (para cleanup).
function IrisTransition.reset(self: IrisTransition): ()
	if self._activeTween then
		self._activeTween:Cancel()
		self._activeTween = nil
	end
	self._opId += 1
	local circle = self._circle
	circle.Size = SIZE_SMALL
	circle.Visible = false
end

-- Abre el iris (revela la pantalla). Llama onDone cuando está completamente abierta.
function IrisTransition.open(self: IrisTransition, onDone: (() -> ())?): ()
	task.spawn(function()
		local circle = self._circle
		circle.Size = SIZE_BIG
		local opId, tween = _beginTransition(self, SIZE_SMALL)
		local playbackState = tween.Completed:Wait()
		if self._activeTween == tween then
			self._activeTween = nil
		end

		if self._opId ~= opId or playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		circle.Visible = false
		if onDone then
			onDone()
		end
	end)
end

return IrisTransition
