--!strict
--[[
	Estructura GUI esperada (relativa a `root`):
		root
		  SliderFrame   ← pista / zona de arrastre
		    Slider      ← knob
		  Value         ← TextLabel "45%"

	Input directo (ratón + táctil) en vez de UIDragDetector, para que funcione en móvil
	y tocar la pista salte ahí. Valor normalizado [0, 1]; el consumidor lo mapea.
	onChange: continuo (arrastre y :set), para aplicar el efecto.
	onCommit: al soltar, para persistir.
]]

local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

local RESOLVE_TIMEOUT = 5

export type SliderConfig = {
	root: Instance,
	onChange: ((value: number) -> ())?,
	onCommit: ((value: number) -> ())?,
}

local SliderController = {}
SliderController.__index = SliderController

-- Lock global entre todas las instancias: un solo slider en arrastre a la vez, para
-- que un segundo dedo (multi-touch) no arrastre otro slider.
local _activeSlider: any = nil

local function resolve(parent: Instance, name: string): Instance?
	local child = parent:WaitForChild(name, RESOLVE_TIMEOUT)
	if not child then
		warn(`[SliderController] Falta '{name}' en {parent:GetFullName()}`)
	end
	return child
end

local function isDragInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

function SliderController.new(config: SliderConfig)
	local self = setmetatable({}, SliderController)

	self._janitor = Janitor.new()
	self._onChange = config.onChange
	self._onCommit = config.onCommit
	self._value = 0
	self._dragging = false
	self._inert = false
	self._activeInput = nil :: InputObject?

	-- Si la estructura no coincide, queda inerte en vez de colgar con WaitForChild infinito.
	local track = resolve(config.root, "SliderFrame")
	local handle = track and resolve(track, "Slider")
	local valueLabel = resolve(config.root, "Value")
	if not (track and handle and valueLabel) then
		self._inert = true
		return self
	end

	self._track = track :: GuiObject
	self._handle = handle :: GuiObject
	self._valueLabel = valueLabel :: TextLabel

	self._handle.AnchorPoint = Vector2.new(0.5, self._handle.AnchorPoint.Y)
	self._track.Active = true

	local function beginDrag(input: InputObject)
		if not isDragInput(input) then
			return
		end
		if _activeSlider ~= nil and _activeSlider ~= self then
			return
		end
		if self._dragging then
			return
		end
		_activeSlider = self
		self._dragging = true
		self._activeInput = input
		self:_updateFromX(input.Position.X)
	end

	-- También en el knob por si éste hunde el input de la pista.
	self._janitor:Add(self._track.InputBegan:Connect(beginDrag), "Disconnect")
	self._janitor:Add(self._handle.InputBegan:Connect(beginDrag), "Disconnect")

	self._janitor:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		if self._dragging and self:_isActiveMove(input) then
			self:_updateFromX(input.Position.X)
		end
	end), "Disconnect")

	self._janitor:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		if self._dragging and self:_isActiveEnd(input) then
			self._dragging = false
			self._activeInput = nil
			if _activeSlider == self then
				_activeSlider = nil
			end
			if self._onCommit then
				self._onCommit(self._value)
			end
		end
	end), "Disconnect")

	-- Un valor cargado con el panel oculto se coloca mal hasta tener tamaño real.
	self._janitor:Add(self._track:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_positionHandle(self._value)
	end), "Disconnect")

	return self
end

-- Táctil: mismo InputObject (mismo dedo). Ratón: el movimiento llega como
-- MouseMovement (otro objeto que el MouseButton1 inicial), así que se acepta por tipo.
function SliderController:_isActiveMove(input: InputObject): boolean
	local active = self._activeInput
	if not active then
		return false
	end
	if active.UserInputType == Enum.UserInputType.Touch then
		return input == active
	end
	return input.UserInputType == Enum.UserInputType.MouseMovement
end

function SliderController:_isActiveEnd(input: InputObject): boolean
	local active = self._activeInput
	if not active then
		return false
	end
	if active.UserInputType == Enum.UserInputType.Touch then
		return input == active
	end
	return input.UserInputType == Enum.UserInputType.MouseButton1
end

function SliderController:_positionHandle(value: number)
	local handleWidth = self._handle.AbsoluteSize.X
	local travel = self._track.AbsoluteSize.X - handleWidth
	local centerPos = (travel * value) + (handleWidth / 2)
	self._handle.Position = UDim2.new(
		0,
		centerPos,
		self._handle.Position.Y.Scale,
		self._handle.Position.Y.Offset
	)
end

function SliderController:_updateFromX(x: number)
	local handleWidth = self._handle.AbsoluteSize.X
	local travel = self._track.AbsoluteSize.X - handleWidth
	if travel <= 0 then
		return
	end

	local relative = x - self._track.AbsolutePosition.X - (handleWidth / 2)
	local value = math.clamp(relative / travel, 0, 1)

	self._value = value
	self:_positionHandle(value)
	self._valueLabel.Text = math.round(value * 100) .. "%"

	if self._onChange then
		self._onChange(value)
	end
end

-- Dispara onChange (aplica el efecto al cargar settings) pero nunca onCommit.
function SliderController:set(value: number)
	if self._inert then
		return
	end

	local clamped = math.clamp(value, 0, 1)
	self._value = clamped
	self:_positionHandle(clamped)
	self._valueLabel.Text = math.round(clamped * 100) .. "%"

	if self._onChange then
		self._onChange(clamped)
	end
end

function SliderController:Destroy()
	if _activeSlider == self then
		_activeSlider = nil
	end
	self._janitor:Destroy()
end

return SliderController
