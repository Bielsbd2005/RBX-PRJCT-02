--!strict
--[[
	ShadeController.luau (Client UI Library)
	Gestiona `UserInterface.Shade`, un overlay que oscurece la pantalla cuando se
	abre un panel (Rewards, etc.). Es completamente dirigido por atributos: cada
	frame decide si lo usa y de qué color, sin acoplar el controlador a una lista.

	Estructura del overlay:
		Shade            ← Frame contenedor, SIEMPRE transparente; ZIndex fijo detrás
		  Background     ← Frame con el color de oscurecido
		  Shadow         ← Frame que se tiñe con el mismo `ShadeColor` (opcional)
		  CanvasGroup    ← imagen/gradiente (GroupTransparency desvanece su contenido)
		    ImageLabel, UIGradient, ...

	Atributos (se definen en Studio sobre el frame del panel):
		Shade       : boolean  → si true, mostrar el overlay mientras el frame esté visible.
		ShadeColor  : Color3   → color para `Shade.Background.BackgroundColor3` (opcional).

	Aparición/desaparición animadas con tween de transparencia: se desvanece
	`Background.BackgroundTransparency` y `CanvasGroup.GroupTransparency` entre sus
	valores diseñados (estado visible) y 1 (oculto). No toca el `Shade` en sí.

	Blur: todo frame con Shade lleva blur de fondo, así que el blur va atado al
	overlay — se activa cuando el Shade se muestra y se suelta cuando se oculta,
	vía BlurController (refcount, key única "Shade"). Los frames que usan Shade
	NO necesitan tocar el blur ellos mismos.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any
local BlurController = require(script.Parent.BlurController)

local SHADE_ATTRIBUTE = "Shade"
local COLOR_ATTRIBUTE = "ShadeColor"
-- Key del refcount de blur para el overlay del Shade.
local BLUR_KEY = "Shade"
-- ZIndex bajo y fijo: el overlay siempre detrás de cualquier panel. Asume que
-- los frames usan ZIndex >= 0 (default) y que el ScreenGui ordena por ZIndex.
local SHADE_ZINDEX = -1
local SHOW_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIDE_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local ShadeController = {}

function ShadeController.start(_menuController: any?): any
	local janitor = Janitor.new()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui

	local shade = uiGui:WaitForChild("Shade", 10) :: Frame?
	if not shade then
		warn("[ShadeController] No se encontró UserInterface.Shade — overlay deshabilitado.")
		return janitor
	end
	local background = shade:WaitForChild("Background", 10) :: Frame?
	if not background then
		warn("[ShadeController] No se encontró UserInterface.Shade.Background — overlay deshabilitado.")
		return janitor
	end

	local canvasInst = shade:FindFirstChild("CanvasGroup")
	local canvas = if canvasInst and canvasInst:IsA("CanvasGroup") then canvasInst else nil

	local shadowInst = shade:FindFirstChild("Shadow")
	local shadow = if shadowInst and shadowInst:IsA("GuiObject") then shadowInst else nil

	-- Fijar el ZIndex una sola vez para que el overlay quede siempre detrás.
	shade.ZIndex = SHADE_ZINDEX

	-- Transparencias "visibles" diseñadas en Studio: se desvanece entre éstas y 1.
	local bgVisible = background.BackgroundTransparency
	local canvasVisible = if canvas then canvas.GroupTransparency else 0
	local shadowVisible = if shadow then shadow.BackgroundTransparency else 0

	-- Estado inicial: oculto.
	background.BackgroundTransparency = 1
	if canvas then
		canvas.GroupTransparency = 1
	end
	if shadow then
		shadow.BackgroundTransparency = 1
	end
	shade.Visible = false

	local activeTweens: { Tween } = {}
	local shown = false

	local function cancelTweens()
		for _, tween in activeTweens do
			tween:Cancel()
		end
		table.clear(activeTweens)
	end
	janitor:Add(cancelTweens, true)
	-- Soltar el blur si nos destruyen con el Shade activo (hot reload).
	janitor:Add(function()
		BlurController.release(BLUR_KEY)
	end, true)

	local function tweenTo(info: TweenInfo, bgTarget: number, canvasTarget: number, shadowTarget: number)
		cancelTweens()

		local bgTween = TweenService:Create(background, info, { BackgroundTransparency = bgTarget })
		table.insert(activeTweens, bgTween)
		bgTween:Play()

		if canvas then
			local canvasTween = TweenService:Create(canvas, info, { GroupTransparency = canvasTarget })
			table.insert(activeTweens, canvasTween)
			canvasTween:Play()
		end

		if shadow then
			local shadowTween = TweenService:Create(shadow, info, { BackgroundTransparency = shadowTarget })
			table.insert(activeTweens, shadowTween)
			shadowTween:Play()
		end

		return bgTween
	end

	local function show(color: Color3?)
		if color then
			background.BackgroundColor3 = color
			if shadow then
				shadow.BackgroundColor3 = color
			end
		end
		if shown then
			return
		end
		shown = true

		-- El blur acompaña al Shade (todo frame con Shade lo lleva).
		BlurController.acquire(BLUR_KEY)

		shade.Visible = true
		tweenTo(SHOW_INFO, bgVisible, canvasVisible, shadowVisible)
	end

	local function hide()
		if not shown then
			return
		end
		shown = false

		BlurController.release(BLUR_KEY)

		local bgTween = tweenTo(HIDE_INFO, 1, 1, 1)
		bgTween.Completed:Once(function(state: Enum.PlaybackState)
			-- No ocultar si un show() canceló este fade-out en el camino.
			if state == Enum.PlaybackState.Completed and not shown then
				shade.Visible = false
			end
		end)
	end

	-- Frames que pueden disparar shade (todos los hijos GuiObject salvo el propio Shade).
	local tracked: { GuiObject } = {}

	local function refresh()
		local top: GuiObject? = nil
		for _, frame in tracked do
			if frame.Visible and frame:GetAttribute(SHADE_ATTRIBUTE) == true then
				if not top or frame.ZIndex > top.ZIndex then
					top = frame
				end
			end
		end

		if top then
			local color = top:GetAttribute(COLOR_ATTRIBUTE)
			show(if typeof(color) == "Color3" then color else nil)
		else
			hide()
		end
	end

	local function track(frame: Instance)
		if frame == shade or not frame:IsA("GuiObject") then
			return
		end
		table.insert(tracked, frame)
		-- Tanto un cambio de visibilidad como del atributo Shade re-evalúan el overlay,
		-- así que activar/desactivar Shade en runtime funciona sin más cableado.
		janitor:Add(frame:GetPropertyChangedSignal("Visible"):Connect(refresh), "Disconnect")
		janitor:Add(frame:GetAttributeChangedSignal(SHADE_ATTRIBUTE):Connect(refresh), "Disconnect")
	end

	for _, child in uiGui:GetChildren() do
		track(child)
	end
	janitor:Add(uiGui.ChildAdded:Connect(function(child: Instance)
		track(child)
		refresh()
	end), "Disconnect")

	refresh()

	return janitor
end

return ShadeController
