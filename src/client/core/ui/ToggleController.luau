--!strict
--[[
	ToggleController.luau (Client UI Library)
	Toggle (interruptor) reutilizable. `Toggle` es la pista clicable cuyo color
	cambia según el estado; `Circle` es el knob que se desliza izquierda/derecha.

	Estructura GUI esperada (relativa a `root`):
		root
		  Toggle        ← pista clicable (cambia de color)
		    Circle      ← knob que se desliza
		  Title         ← etiqueta (ignorada por la lógica)

	Callbacks (mismo contrato que SliderController):
		onChange(state)  — en cada cambio de estado, incluido :set() no silencioso.
		                   Aquí se aplica el efecto inmediato (atributo, etc.).
		onCommit(state)  — solo en interacción del usuario. Aquí se persiste (red).
]]

local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any
local Client = script.Parent.Parent.Parent
local UITheme = require(Client.core.ui.UITheme)

local TWEEN_INFO = UITheme.HoverMedium
-- ON: pista naranja, bola blanca. OFF (deshabilitado): pista blanca, bola negra.
local TRACK_ON = Color3.fromRGB(255, 139, 0)
local TRACK_OFF = Color3.fromRGB(255, 255, 255)
local KNOB_ON = Color3.fromRGB(255, 255, 255)
local KNOB_OFF = Color3.fromRGB(0, 0, 0)
-- Margen en px entre la bola y los bordes de la pista en cada extremo.
local KNOB_PADDING = 8

export type ToggleConfig = {
	root: Instance,
	onChange: ((state: boolean) -> ())?,
	onCommit: ((state: boolean) -> ())?,
}

local RESOLVE_TIMEOUT = 5

local ToggleController = {}
ToggleController.__index = ToggleController

local function resolve(parent: Instance, name: string): Instance?
	local child = parent:WaitForChild(name, RESOLVE_TIMEOUT)
	if not child then
		warn(`[ToggleController] Falta '{name}' en {parent:GetFullName()}`)
	end
	return child
end

function ToggleController.new(config: ToggleConfig)
	local self = setmetatable({}, ToggleController)

	self._janitor = Janitor.new()
	self._onChange = config.onChange
	self._onCommit = config.onCommit
	self._state = false
	self._activeTweens = {} :: { Tween }
	self._inert = false

	-- Resolución tolerante: avisa y queda inerte si falta Toggle/Circle.
	local track = resolve(config.root, "Toggle")
	local knob = track and resolve(track, "Circle")
	if not (track and knob) then
		self._inert = true
		return self
	end

	self._track = track :: GuiObject
	self._knob = knob :: GuiObject

	self._knob.AnchorPoint = Vector2.new(0.5, 0.5)

	self._janitor:Add(function()
		self:_cancelTweens()
	end, true)

	-- `Activated` cubre ratón y táctil para GuiButton; para un Frame caemos a
	-- InputBegan. Así el toggle funciona sea botón o frame en el diseño nuevo.
	if self._track:IsA("GuiButton") then
		self._janitor:Add((self._track :: GuiButton).Activated:Connect(function()
			self:_toggle()
		end), "Disconnect")
	else
		self._janitor:Add(self._track.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				self:_toggle()
			end
		end), "Disconnect")
	end

	-- Reposicionar la bola al obtener tamaño real (p. ej. al abrir el panel
	-- oculto): si se colocó con medidas 0, el margen quedaría nulo.
	self._janitor:Add(self._track:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_apply(self._state, false, false)
	end), "Disconnect")

	return self
end

function ToggleController:_cancelTweens()
	for _, tween in self._activeTweens do
		tween:Cancel()
	end
	table.clear(self._activeTweens)
end

function ToggleController:_knobPositions(): (UDim2, UDim2)
	local trackWidth = self._track.AbsoluteSize.X
	local knobWidth = self._knob.AbsoluteSize.X
	local inset = if trackWidth > 0 and knobWidth > 0 then (knobWidth / 2) + KNOB_PADDING else 0
	local onPos = UDim2.new(1, -inset, 0.5, 0)
	local offPos = UDim2.new(0, inset, 0.5, 0)
	return onPos, offPos
end

function ToggleController:_apply(state: boolean, animate: boolean, fireChange: boolean)
	self._state = state

	local onPos, offPos = self:_knobPositions()
	local targetPos = if state then onPos else offPos
	local trackColor = if state then TRACK_ON else TRACK_OFF
	local knobColor = if state then KNOB_ON else KNOB_OFF

	self:_cancelTweens()

	if animate then
		local knobTween = TweenService:Create(self._knob, TWEEN_INFO, {
			Position = targetPos,
			BackgroundColor3 = knobColor,
		})
		local trackTween = TweenService:Create(self._track, TWEEN_INFO, { BackgroundColor3 = trackColor })
		table.insert(self._activeTweens, knobTween)
		table.insert(self._activeTweens, trackTween)
		knobTween:Play()
		trackTween:Play()
	else
		self._knob.Position = targetPos
		self._knob.BackgroundColor3 = knobColor
		self._track.BackgroundColor3 = trackColor
	end

	if fireChange and self._onChange then
		self._onChange(state)
	end
end

function ToggleController:_toggle()
	self:_apply(not self._state, true, true)
	if self._onCommit then
		self._onCommit(self._state)
	end
end

-- Fija el estado por código (carga de settings). Dispara onChange salvo
-- `silent`; nunca dispara onCommit.
function ToggleController:set(state: boolean, silent: boolean?)
	if self._inert then
		return
	end
	self:_apply(state, false, not silent)
end

function ToggleController:get(): boolean
	return self._state
end

function ToggleController:Destroy()
	self._janitor:Destroy()
end

return ToggleController
