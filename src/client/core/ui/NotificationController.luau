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
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local SHOW_SCALE = TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SHOW_FADE = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIDE_SCALE = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local HIDE_FADE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOLD_TIME = 2.5
local MAX_VISIBLE = 2
local STACK_PADDING = 6

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

local function buildStack(notifications: GuiObject): GuiObject
	local existing = notifications:FindFirstChild("Stack")
	if existing and existing:IsA("GuiObject") then
		return existing
	end

	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.BackgroundTransparency = 1
	stack.Size = UDim2.fromScale(1, 1)
	stack.Position = UDim2.fromScale(0, 0)

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

	_stack = buildStack(notifications)
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
