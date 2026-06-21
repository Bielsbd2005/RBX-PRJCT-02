--!strict
--[[
	SliderController.luau (Client UI Library)
	Slider reutilizable de knob arrastrable. `Slider` es el knob que se desliza
	dentro de `SliderFrame`; el valor se deriva de su posición y `Value` muestra
	el porcentaje.

	El arrastre se maneja por input directo (ratón + táctil) en vez de un
	UIDragDetector de Studio: así no depende de la clase del instance, funciona en
	móvil, y tocar cualquier punto de la pista salta a esa posición.

	Estructura GUI esperada (relativa a `root`):
		root
		  SliderFrame   ← pista / zona de arrastre
		    Slider      ← knob que se desliza
		  Value         ← TextLabel "45%"

	El valor siempre vive en el rango normalizado [0, 1]; el consumidor mapea a
	unidades reales (volumen, sensibilidad, etc.) en su callback.

	Callbacks:
		onChange(value)  — continuo: durante el arrastre y en :set() no silencioso.
		                   Aquí se aplica el efecto inmediato (volumen, etc.).
		onCommit(value)  — al soltar el arrastre. Aquí se persiste (red).
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

-- Lock global compartido entre TODAS las instancias: solo un slider puede estar
-- en arrastre a la vez. Evita que, mientras mueves uno, un segundo dedo que toca
-- otro slider cercano lo arrastre también (multi-touch en móvil).
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
	-- Puntero (InputObject) que inició el arrastre activo. En táctil identifica el
	-- dedo concreto; en ratón es el MouseButton1 que lo comenzó.
	self._activeInput = nil :: InputObject?

	-- Resolución tolerante: si la estructura no coincide, avisa y queda inerte
	-- en vez de colgar el feature entero con un WaitForChild infinito.
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

	-- El knob se posiciona por su centro a lo largo del eje X de la pista.
	self._handle.AnchorPoint = Vector2.new(0.5, self._handle.AnchorPoint.Y)
	self._track.Active = true

	local function beginDrag(input: InputObject)
		if not isDragInput(input) then
			return
		end
		-- Si otro slider ya posee el arrastre, no reaccionar. Si el dueño quedó
		-- obsoleto (no soltó limpio), liberar el lock y continuar.
		if _activeSlider ~= nil and _activeSlider ~= self then
			if _activeSlider._dragging then
				return
			end
			_activeSlider = nil
		end
		if self._dragging then
			return
		end
		_activeSlider = self
		self._dragging = true
		self._activeInput = input
		self:_updateFromX(input.Position.X, true)
	end

	-- Escuchamos en pista y knob: tocar cualquier punto de la pista salta ahí, y
	-- empezar el arrastre sobre el knob también funciona si éste hunde el input.
	self._janitor:Add(self._track.InputBegan:Connect(beginDrag), "Disconnect")
	self._janitor:Add(self._handle.InputBegan:Connect(beginDrag), "Disconnect")

	self._janitor:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		if self._dragging and self:_isActiveMove(input) then
			self:_updateFromX(input.Position.X, true)
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

	-- Reposicionar al obtener tamaño real (p. ej. al abrir el panel oculto) para
	-- que un valor cargado mientras estaba invisible quede bien colocado.
	self._janitor:Add(self._track:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_positionHandle(self._value)
	end), "Disconnect")

	return self
end

-- ¿El input que cambió corresponde al puntero que inició ESTE arrastre? Táctil:
-- debe ser el mismo InputObject (mismo dedo) — así un segundo dedo no lo mueve.
-- Ratón: el arrastre lo inicia el botón pero el movimiento llega como
-- MouseMovement (otro objeto), así que se acepta por tipo.
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

-- ¿El input que terminó cierra ESTE arrastre? Táctil: el mismo dedo. Ratón: el
-- MouseButton1 que lo inició.
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

-- Coloca el knob para un valor [0,1] (su centro a lo largo de la banda de viaje).
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

-- Deriva el valor [0,1] de una coordenada X absoluta del puntero y aplica.
function SliderController:_updateFromX(x: number, fireChange: boolean)
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

	if fireChange and self._onChange then
		self._onChange(value)
	end
end

-- Fija el valor por código. `silent` evita disparar onChange (uso raro); por
-- defecto sí lo dispara para aplicar el efecto al cargar settings guardados.
-- Nunca dispara onCommit: persistir es responsabilidad del consumidor.
function SliderController:set(value: number, silent: boolean?)
	if self._inert then
		return
	end

	local clamped = math.clamp(value, 0, 1)
	self._value = clamped
	self:_positionHandle(clamped)
	self._valueLabel.Text = math.round(clamped * 100) .. "%"

	if not silent and self._onChange then
		self._onChange(clamped)
	end
end

function SliderController:get(): number
	return self._value
end

function SliderController:Destroy()
	-- Si este slider tenía el lock global, liberarlo para no bloquear a los demás.
	if _activeSlider == self then
		_activeSlider = nil
	end
	self._janitor:Destroy()
end

return SliderController
