--!strict
--[[
	NotificationController.luau (Client UI Library)
	Notificaciones de transacción apilables. Frames pre-hechos en la GUI usados
	como plantillas:

		UserInterface.Notifications
		  Success
		    Message   ← TextLabel
		  Warning
		    Message   ← TextLabel

	Llamable desde cualquier módulo cliente sin instanciar nada:

		local Notify = require(Client.core.ui.NotificationController)
		Notify.success("Code redeemed. +500 Cash")
		Notify.warning("You already redeemed that code.")

	Comportamiento:
	  • Cada llamada clona su plantilla → un toast independiente.
	  • Se apilan hasta MAX_VISIBLE (2) en un contenedor "Stack" con UIListLayout.
	    Sin cola: si llegan más, el más viejo se retira al instante para dejar sitio.
	  • Entrada: pop de tamaño con rebote (UIScale 0→1, Back/Out) + fade-in.
	  • Salida: shrink (Back/In) + fade-out.

	El fade respeta las transparencias originales del frame (no fuerza un fondo
	opaco), usando GroupTransparency si es CanvasGroup. Las plantillas quedan
	ocultas y fuera del Stack para no estorbar el layout; el Stack se crea una vez
	y se reutiliza (reload-safe).

	El Stack lleva además un UIScale "DeviceScale" proporcional al viewport (ver
	`computeDeviceScale`), para que el toast tenga un tamaño razonable tanto en un
	teléfono como en un monitor grande. Se recalcula al rotar el dispositivo o
	redimensionar la ventana.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local SHOW_SCALE = TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SHOW_FADE = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIDE_SCALE = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local HIDE_FADE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOLD_TIME = 2.5
local MAX_VISIBLE = 2
local STACK_PADDING = 6

-- ── Escalado por dispositivo ─────────────────────────────────
-- Las plantillas del asset están medidas en offsets sobre un viewport de diseño
-- de 1920x1080. Tal cual, en un teléfono (viewport ~900x420) el toast se come un
-- tercio de la pantalla, y en un monitor grande queda diminuto. El Stack lleva
-- por eso su propio UIScale, proporcional al viewport.
--
-- Va en el Stack y no en cada toast porque el UIScale del toast ya lo usa la
-- animación de entrada/salida (0 → 1 → 0): Roblox solo aplica un UIScale por
-- objeto, pero el del ancestro y el del descendiente se multiplican, así que
-- ambos conviven sin pisarse. Al colgar del Stack también escala el padding del
-- UIListLayout, y las plantillas (que viven fuera del Stack) se quedan intactas.
local REFERENCE_VIEWPORT = Vector2.new(1920, 1080)
-- Mezcla entre tamaño fijo en píxeles (0) y totalmente proporcional al viewport
-- (1). Seguir el viewport al 100% deja el texto ilegible en un teléfono, así que
-- solo aplicamos parte de la diferencia. Cuanto más alto, más encogen las
-- pantallas pequeñas (el escritorio a 1080p se queda en 1 sea cual sea el peso).
local VIEWPORT_SCALE_WEIGHT = 0.8
-- En táctil la pantalla se mira desde más lejos y el dedo tapa parte del toast:
-- un empujón extra sobre lo que dicte el viewport.
local TOUCH_SCALE_BOOST = 1.15
-- Suelo pensado para teléfonos, que es donde el ratio de viewport toca fondo.
local MIN_DEVICE_SCALE = 0.5
-- Tope por arriba: el frame Notifications del asset puede venir ajustado (y con
-- ClipsDescendants), así que no lo desbordamos en pantallas muy grandes.
local MAX_DEVICE_SCALE = 1.25

-- Misma heurística que TouchControlsController/BlurController: táctil "de
-- verdad", no un portátil con pantalla táctil y ratón.
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

type Entry = {
	root: GuiObject,
	scale: UIScale,
	message: TextLabel?,
	isCanvas: boolean,
	tBg: number, -- transparencia "visible" del fondo (o GroupTransparency)
	tText: number, -- transparencia "visible" del texto
	tStroke: number, -- transparencia "visible" del stroke del texto
	dismissed: boolean,
}

local NotificationController = {}

local _ready = false
local _stack: GuiObject? = nil
local _templates: { [string]: GuiObject } = {}
local _active: { Entry } = {}
local _order = 0
local _deviceScale: UIScale? = nil
local _viewportConn: RBXScriptConnection? = nil

local present: (kind: string, text: string) -> ()
local dismiss: (entry: Entry) -> ()

-- Fade agnóstico: CanvasGroup → GroupTransparency; si no, fondo + texto. Siempre
-- hacia la transparencia original (tBg/tText) para no alterar el diseño.
local function tweenFade(entry: Entry, info: TweenInfo, hidden: boolean)
	if entry.isCanvas then
		local target = if hidden then 1 else entry.tBg
		TweenService:Create(entry.root, info, { GroupTransparency = target }):Play()
		return
	end

	TweenService:Create(entry.root, info, {
		BackgroundTransparency = if hidden then 1 else entry.tBg,
	}):Play()

	if entry.message then
		TweenService:Create(entry.message, info, {
			TextTransparency = if hidden then 1 else entry.tText,
			TextStrokeTransparency = if hidden then 1 else entry.tStroke,
		}):Play()
	end
end

local function setFaded(entry: Entry)
	if entry.isCanvas then
		(entry.root :: CanvasGroup).GroupTransparency = 1
		return
	end
	entry.root.BackgroundTransparency = 1
	if entry.message then
		entry.message.TextTransparency = 1
		entry.message.TextStrokeTransparency = 1
	end
end

-- Escala del Stack para el viewport actual. Tomamos el MENOR de los dos ejes para
-- que un toast ancho tampoco se salga por los lados en un teléfono; el resultado
-- se acota para no encoger hasta lo ilegible ni desbordar el frame del asset.
local function computeDeviceScale(): number
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.zero
	if viewport.X <= 0 or viewport.Y <= 0 then
		-- Durante una transición la cámara puede reportar 0: dejamos el diseño
		-- base y ya reajustará el listener de ViewportSize.
		return 1
	end

	local ratio = math.min(viewport.X / REFERENCE_VIEWPORT.X, viewport.Y / REFERENCE_VIEWPORT.Y)
	local scale = 1 + (VIEWPORT_SCALE_WEIGHT * (ratio - 1))
	if IS_TOUCH then
		scale *= TOUCH_SCALE_BOOST
	end
	return math.clamp(scale, MIN_DEVICE_SCALE, MAX_DEVICE_SCALE)
end

local function applyDeviceScale()
	local node = _deviceScale
	if node then
		node.Scale = computeDeviceScale()
	end
end

-- El viewport cambia al rotar el móvil o redimensionar la ventana, y la cámara
-- entera puede sustituirse (respawn, cinemáticas), así que reenganchamos el
-- listener en cada cambio de CurrentCamera en vez de conectarlo una sola vez.
local function watchViewport()
	if _viewportConn then
		_viewportConn:Disconnect()
		_viewportConn = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		_viewportConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyDeviceScale)
	end
	applyDeviceScale()
end

local function ensureDeviceScale(stack: GuiObject): UIScale
	local existing = stack:FindFirstChild("DeviceScale")
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local created = Instance.new("UIScale")
	created.Name = "DeviceScale"
	created.Parent = stack
	return created
end

local function buildStack(notifications: GuiObject): GuiObject
	local existing = notifications:FindFirstChild("Stack")
	if existing and existing:IsA("GuiObject") then
		return existing
	end

	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.BackgroundTransparency = 1
	stack.Size = UDim2.fromScale(1, 1)
	-- Anclado arriba y al centro (equivalente a 0,0 mientras la escala es 1): así
	-- el UIScale crece y encoge el Stack alrededor de donde salen los toasts, en
	-- vez de arrastrarlos hacia la derecha.
	stack.AnchorPoint = Vector2.new(0.5, 0)
	stack.Position = UDim2.fromScale(0.5, 0)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, STACK_PADDING)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Parent = stack

	stack.Parent = notifications
	return stack
end

-- Resolución lazy: la GUI puede no existir en el primer frame, pero sí al
-- disparar la primera notificación.
local function init(): boolean
	if _ready then
		return _stack ~= nil
	end
	_ready = true

	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChild("PlayerGui")
	local ui = playerGui and playerGui:FindFirstChild("UserInterface")
	local notifications = ui and ui:FindFirstChild("Notifications")
	if not (notifications and notifications:IsA("GuiObject")) then
		warn("[NotificationController] Falta UserInterface.Notifications")
		return false
	end

	for _, kind in { "Success", "Warning" } do
		local template = notifications:FindFirstChild(kind)
		if template and template:IsA("GuiObject") then
			template.Visible = false
			_templates[kind] = template
		else
			warn(`[NotificationController] Falta plantilla Notifications.{kind}`)
		end
	end

	local stack = buildStack(notifications)
	_stack = stack
	_deviceScale = ensureDeviceScale(stack)
	watchViewport()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchViewport)
	return next(_templates) ~= nil
end

function present(kind: string, text: string)
	local template = _templates[kind]
	local stack = _stack
	if not (template and stack) then
		return
	end

	local clone = template:Clone()

	local messageInst = clone:FindFirstChild("Message")
	local message = if messageInst and messageInst:IsA("TextLabel") then messageInst else nil
	if message then
		message.Text = text
	end

	local scale = clone:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = clone
	end

	local isCanvas = clone:IsA("CanvasGroup")
	local entry: Entry = {
		root = clone,
		scale = scale :: UIScale,
		message = message,
		isCanvas = isCanvas,
		tBg = if isCanvas then (clone :: CanvasGroup).GroupTransparency else clone.BackgroundTransparency,
		tText = if message then message.TextTransparency else 0,
		tStroke = if message then message.TextStrokeTransparency else 0,
		dismissed = false,
	}

	-- Estado inicial: encogido y transparente, luego anima a visible.
	entry.scale.Scale = 0
	setFaded(entry)

	clone.Visible = true
	clone.LayoutOrder = _order
	_order += 1
	clone.Parent = stack

	table.insert(_active, entry)

	TweenService:Create(entry.scale, SHOW_SCALE, { Scale = 1 }):Play()
	tweenFade(entry, SHOW_FADE, false)

	task.delay(HOLD_TIME, function()
		dismiss(entry)
	end)
end

function dismiss(entry: Entry)
	if entry.dismissed then
		return
	end
	entry.dismissed = true

	local index = table.find(_active, entry)
	if index then
		table.remove(_active, index)
	end

	tweenFade(entry, HIDE_FADE, true)

	local shrink = TweenService:Create(entry.scale, HIDE_SCALE, { Scale = 0 })
	shrink:Play()
	shrink.Completed:Once(function()
		entry.root:Destroy()
	end)
end

local function show(kind: string, text: string)
	if not init() then
		return
	end

	-- Sin cola: si está lleno, retira el más viejo al instante para hacer hueco.
	if #_active >= MAX_VISIBLE then
		dismiss(_active[1])
	end

	present(kind, text)
end

function NotificationController.success(message: string)
	show("Success", message)
end

function NotificationController.warning(message: string)
	show("Warning", message)
end

return NotificationController
