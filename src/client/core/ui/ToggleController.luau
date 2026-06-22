--!strict
--[[
	ToggleController.luau (Client UI Library)
	Toggle (interruptor) reutilizable. `ToggleContainer` es la pista cuyo color
	cambia según el estado; `Knob` es la bola que se desliza izquierda/derecha
	(posicionada por escala); `HitArea` es el botón transparente que recibe el tap.

	Estructura GUI esperada (relativa a `root`):
		root
		  ToggleContainer   ← pista (cambia de color)
		    Knob            ← bola que se desliza
		    HitArea         ← TextButton transparente, zona clicable
		  Title             ← etiqueta del ajuste (ignorada por la lógica)

	Callbacks (mismo contrato que SliderController):
		onChange(state)  — en cada cambio de estado, incluido :set() no silencioso.
		                   Aquí se aplica el efecto inmediato (atributo, etc.).
		onCommit(state)  — solo en interacción del usuario. Aquí se persiste (red).
]]

local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

-- Tween y estados visuales (knob por escala, color en el container).
local TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local KNOB_ON_POS = UDim2.new(0.55, 0, 0.5, 0)
local KNOB_OFF_POS = UDim2.new(0.05, 0, 0.5, 0)
local TRACK_ON = Color3.fromRGB(0, 140, 255)
local TRACK_OFF = Color3.fromRGB(80, 80, 80)
-- Debounce contra el doble-evento por tap en móvil (toque + click emulado), que
-- alternaba el estado dos veces y dejaba el toggle "al revés" respecto al tap.
local TOGGLE_DEBOUNCE = 0.1

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
	self._lastToggleAt = 0

	-- Resolución tolerante: avisa y queda inerte si falta la pista o la bola.
	local track = resolve(config.root, "ToggleContainer")
	local knob = track and resolve(track, "Knob")
	if not (track and knob) then
		self._inert = true
		return self
	end

	self._track = track :: GuiObject
	self._knob = knob :: GuiObject

	self._janitor:Add(function()
		self:_cancelTweens()
	end, true)

	-- HitArea (TextButton transparente) recibe el tap. `Activated` cubre ratón,
	-- táctil y selección por mando de forma unificada (y deduplica touch + click
	-- emulado). Si faltara, caemos a InputBegan sobre la pista.
	local hitArea = track:FindFirstChild("HitArea")
	if hitArea and hitArea:IsA("GuiButton") then
		self._janitor:Add((hitArea :: GuiButton).Activated:Connect(function()
			self:_toggle()
		end), "Disconnect")
	else
		self._track.Active = true
		self._janitor:Add(self._track.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				self:_toggle()
			end
		end), "Disconnect")
	end

	return self
end

function ToggleController:_cancelTweens()
	for _, tween in self._activeTweens do
		tween:Cancel()
	end
	table.clear(self._activeTweens)
end

function ToggleController:_apply(state: boolean, animate: boolean, fireChange: boolean)
	self._state = state

	local targetPos = if state then KNOB_ON_POS else KNOB_OFF_POS
	local trackColor = if state then TRACK_ON else TRACK_OFF

	self:_cancelTweens()

	if animate then
		local knobTween = TweenService:Create(self._knob, TWEEN_INFO, { Position = targetPos })
		local trackTween = TweenService:Create(self._track, TWEEN_INFO, { BackgroundColor3 = trackColor })
		table.insert(self._activeTweens, knobTween)
		table.insert(self._activeTweens, trackTween)
		knobTween:Play()
		trackTween:Play()
	else
		-- Aplicación instantánea (carga de settings): las posiciones son por escala,
		-- así que funcionan aunque el panel esté oculto (sin medidas reales).
		self._knob.Position = targetPos
		self._track.BackgroundColor3 = trackColor
	end

	if fireChange and self._onChange then
		self._onChange(state)
	end
end

function ToggleController:_toggle()
	-- Debounce contra el doble-evento por tap en móvil.
	local now = os.clock()
	if now - self._lastToggleAt < TOGGLE_DEBOUNCE then
		return
	end
	self._lastToggleAt = now

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
