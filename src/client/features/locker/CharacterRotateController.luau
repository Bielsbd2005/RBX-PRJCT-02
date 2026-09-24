--!strict
--[[
	Arrastrar para girar un preview del locker (el personaje en Character, el arma en
	Arsenal): el ángulo se pasa al dueño del modelo vía `onYawChanged`, que lo aplica.

	Ratón y táctil por el mismo camino (patrón de SliderController): solo mueve el
	puntero que empezó el arrastre; un segundo dedo no se suma.

	La zona de arrastre es un ScreenGui propio a pantalla completa con DisplayOrder JUSTO
	POR DEBAJO de la UI del locker: tabs, grid y scroll siguen recibiendo el toque y solo
	el área libre llega aquí, sin depender de cómo esté montada la GUI en Studio.

	También se escucha UIS.InputBegan con `gameProcessed == false` por si un fondo activo
	de la GUI hundiera el toque. No hay doble conteo: el toque que cae en la superficie
	llega a UIS marcado como procesado.

	El giro es elástico (al soltar vuelve a la pose de frente) y absoluto: `onYawChanged`
	recibe el ángulo total respecto al frente, así que repetirlo cada frame no acumula deriva.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

local DEFAULT_NAME = "LockerCharacterRotate"

-- Un arrastre de ancho de pantalla completo = una vuelta entera. Al normalizar
-- por el viewport, el mismo gesto gira lo mismo en un móvil estrecho que en un
-- monitor ancho.
local TURN_PER_SCREEN_WIDTH = math.pi * 2

-- Al soltar, el personaje vuelve a la pose de frente con rebote (Back se pasa un poco
-- de largo y se asienta).
local RELEASE_RETURN_DURATION = 0.55
local RELEASE_RETURN_STYLE = Enum.EasingStyle.Back

-- Al salir de la categoría Character (cambio de pestaña) el retorno es liso: la
-- cámara está viajando a la vez y un rebote ahí solo hace ruido.
local SWITCH_RETURN_DURATION = 0.3
local SWITCH_RETURN_STYLE = Enum.EasingStyle.Quad

export type CharacterRotateConfig = {
	-- Nombre del ScreenGui y del render step: único por instancia.
	name: string?,
	playerGui: PlayerGui,
	-- ScreenGui de la UI del locker: solo se usa para quedar un DisplayOrder por
	-- debajo. Si falta, se asume 0.
	uiGui: Instance?,
	onYawChanged: (yaw: number) -> (),
}

local CharacterRotateController = {}
CharacterRotateController.__index = CharacterRotateController

local function isDragInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

-- Ángulo equivalente en (-π, π]: girar mucho en la misma dirección no deja un
-- número enorme y el retorno a 0 va siempre por el camino corto.
local function wrapAngle(angle: number): number
	return (angle + math.pi) % (math.pi * 2) - math.pi
end

local function buildSurface(name: string, playerGui: PlayerGui, uiGui: Instance?): (ScreenGui, Frame)
	-- Hot reload / re-arranque del feature: fuera la superficie anterior.
	local previous = playerGui:FindFirstChild(name)
	if previous then
		previous:Destroy()
	end

	local displayOrder = 0
	if uiGui and uiGui:IsA("ScreenGui") then
		displayOrder = uiGui.DisplayOrder
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = name
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = displayOrder - 1
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false
	pcall(function()
		screenGui.ScreenInsets = Enum.ScreenInsets.None
	end)
	screenGui.Parent = playerGui

	local surface = Instance.new("Frame")
	surface.Name = "Surface"
	surface.Size = UDim2.fromScale(1, 1)
	surface.BackgroundTransparency = 1
	surface.BorderSizePixel = 0
	-- Un Frame transparente solo recibe input si está Active; invisible no vale
	-- (Visible = false no recibe nada), por eso se apaga el ScreenGui entero.
	surface.Active = true
	surface.Parent = screenGui

	return screenGui, surface
end

function CharacterRotateController.new(config: CharacterRotateConfig): any
	local self = setmetatable({}, CharacterRotateController)
	self._janitor = Janitor.new()
	self._onYawChanged = config.onYawChanged
	self._yaw = 0
	self._enabled = false
	self._activeInput = nil :: InputObject?
	self._lastX = 0
	self._returnBound = false
	local name = config.name or DEFAULT_NAME
	self._returnStepName = name .. "Return"

	local screenGui, surface = buildSurface(name, config.playerGui, config.uiGui)
	self._gui = screenGui
	self._janitor:Add(screenGui, "Destroy")

	self._janitor:Add(surface.InputBegan:Connect(function(input: InputObject)
		self:_beginDrag(input)
	end), "Disconnect")

	self._janitor:Add(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		self:_beginDrag(input)
	end), "Disconnect")

	self._janitor:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		self:_moveDrag(input)
	end), "Disconnect")

	self._janitor:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		self:_endDrag(input)
	end), "Disconnect")

	-- Soltar el arrastre si el juego pierde el foco: sin el InputEnded del ratón
	-- el personaje seguiría girando al volver.
	self._janitor:Add(UserInputService.WindowFocusReleased:Connect(function()
		self._activeInput = nil
	end), "Disconnect")

	return self
end

-- ¿El movimiento viene del puntero que empezó ESTE arrastre? Táctil: el mismo
-- dedo. Ratón: lo inicia MouseButton1 pero el movimiento llega como MouseMovement
-- (otro InputObject), así que se acepta por tipo.
function CharacterRotateController:_isActiveMove(input: InputObject): boolean
	local active = self._activeInput
	if not active then
		return false
	end
	if active.UserInputType == Enum.UserInputType.Touch then
		return input == active
	end
	return input.UserInputType == Enum.UserInputType.MouseMovement
end

function CharacterRotateController:_isActiveEnd(input: InputObject): boolean
	local active = self._activeInput
	if not active then
		return false
	end
	if active.UserInputType == Enum.UserInputType.Touch then
		return input == active
	end
	return input.UserInputType == Enum.UserInputType.MouseButton1
end

function CharacterRotateController:_beginDrag(input: InputObject)
	if not self._enabled or self._activeInput or not isDragInput(input) then
		return
	end
	self:_stopReturn()
	self._activeInput = input
	self._lastX = input.Position.X
end

function CharacterRotateController:_moveDrag(input: InputObject)
	if not self:_isActiveMove(input) then
		return
	end

	local x = input.Position.X
	local delta = x - self._lastX
	self._lastX = x
	if delta == 0 then
		return
	end

	local camera = Workspace.CurrentCamera
	local width = if camera then math.max(camera.ViewportSize.X, 1) else 1
	-- Arrastrar a la derecha acerca al espectador el costado derecho del
	-- personaje: el modelo gira con el dedo, no al revés.
	self:_setYaw(self._yaw + (delta / width) * TURN_PER_SCREEN_WIDTH)
end

function CharacterRotateController:_endDrag(input: InputObject)
	if not self:_isActiveEnd(input) then
		return
	end
	self._activeInput = nil
	self:_startReturn(RELEASE_RETURN_STYLE, RELEASE_RETURN_DURATION)
end

function CharacterRotateController:_setYaw(yaw: number)
	local wrapped = wrapAngle(yaw)
	if wrapped == self._yaw then
		return
	end
	self._yaw = wrapped
	self._onYawChanged(wrapped)
end

function CharacterRotateController:_stopReturn()
	if not self._returnBound then
		return
	end
	self._returnBound = false
	RunService:UnbindFromRenderStep(self._returnStepName)
end

-- Vuelve a 0 desde el ángulo actual. Con Back el valor se pasa de largo (eased > 1)
-- y el personaje se pasa un poco del frente antes de asentarse: ese es el rebote.
function CharacterRotateController:_startReturn(style: Enum.EasingStyle, duration: number)
	self:_stopReturn()
	if self._yaw == 0 then
		return
	end

	local from = self._yaw
	local startedAt = os.clock()
	self._returnBound = true
	RunService:BindToRenderStep(self._returnStepName, Enum.RenderPriority.Camera.Value - 1, function()
		local alpha = math.clamp((os.clock() - startedAt) / duration, 0, 1)
		local eased = TweenService:GetValue(alpha, style, Enum.EasingDirection.Out)
		self:_setYaw(from * (1 - eased))
		if alpha >= 1 then
			self:_stopReturn()
			-- El wrap deja el último paso en ±0 exacto solo si `from` era limpio;
			-- se fuerza para que la pose final sea la de frente.
			if self._yaw ~= 0 then
				self._yaw = 0
				self._onYawChanged(0)
			end
		end
	end)
end

--- Activa/desactiva el arrastre. Al desactivar, el personaje vuelve girando a su
--- pose de frente.
function CharacterRotateController:setEnabled(enabled: boolean)
	if self._enabled == enabled then
		return
	end
	self._enabled = enabled
	self._gui.Enabled = enabled

	if enabled then
		self:_stopReturn()
		return
	end

	self._activeInput = nil
	self:_startReturn(SWITCH_RETURN_STYLE, SWITCH_RETURN_DURATION)
end

--- Corta el arrastre y devuelve el personaje al frente SIN animación: para el
--- cierre del locker, donde el maniquí vuelve a ser el del lobby.
function CharacterRotateController:reset()
	self:_stopReturn()
	self._enabled = false
	self._gui.Enabled = false
	self._activeInput = nil
	if self._yaw ~= 0 then
		self._yaw = 0
		self._onYawChanged(0)
	end
end

function CharacterRotateController:Destroy()
	self:_stopReturn()
	self._janitor:Destroy()
end

return CharacterRotateController
