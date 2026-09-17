--!strict
--[[
	Toggle reutilizable. Estructura GUI esperada (relativa a `root`; Knob posicionado por escala):
		root
		  ToggleContainer   ← pista (cambia de color)
		    Knob            ← bola que se desliza
		    HitArea         ← TextButton transparente, zona clicable
		  Title             ← etiqueta del ajuste (ignorada por la lógica)

	Callbacks (mismo contrato que SliderController):
		onChange(state)  — en cada cambio de estado, incluido :set().
		                   Aquí se aplica el efecto inmediato (atributo, etc.).
		onCommit(state)  — solo en interacción del usuario. Aquí se persiste (red).
]]

local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any
local GameSounds = require(script.Parent.GameSounds)

local TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local KNOB_ON_POS = UDim2.new(0.55, 0, 0.5, 0)
local KNOB_OFF_POS = UDim2.new(0.05, 0, 0.5, 0)
local TRACK_ON = Color3.fromRGB(0, 140, 255)
local TRACK_OFF = Color3.fromRGB(80, 80, 80)
-- Debounce contra el doble evento por tap en móvil (toque + click emulado), que
-- alternaba el estado dos veces.
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

	-- `Activated` unifica ratón, táctil y mando (y deduplica touch + click emulado).
	-- Si falta HitArea, se cae a InputBegan sobre la pista.
	local hitArea = track:FindFirstChild("HitArea")
	if hitArea and hitArea:IsA("GuiButton") then
		-- El toggle tiene sonido propio: sin esto UISoundsController añadiría su click
		-- genérico y cada toque sonaría dos veces.
		hitArea:SetAttribute("NoClickSound", true)
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

function ToggleController:_apply(state: boolean, animate: boolean)
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

	if self._onChange then
		self._onChange(state)
	end
end

function ToggleController:_toggle()
	local now = os.clock()
	if now - self._lastToggleAt < TOGGLE_DEBOUNCE then
		return
	end
	self._lastToggleAt = now

	-- Solo aquí, no en `set()`: ese lo llama la carga de settings y no debe
	-- sonar (si no, abrir Settings dispararía un toggle por cada opción).
	GameSounds.play(GameSounds.Toggle)

	self:_apply(not self._state, true)
	if self._onCommit then
		self._onCommit(self._state)
	end
end

-- Fija el estado por código (carga de settings). Dispara onChange; nunca
-- dispara onCommit.
function ToggleController:set(state: boolean)
	if self._inert then
		return
	end
	self:_apply(state, false)
end

function ToggleController:Destroy()
	self._janitor:Destroy()
end

return ToggleController
