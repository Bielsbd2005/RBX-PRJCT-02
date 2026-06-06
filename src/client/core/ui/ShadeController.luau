--!strict
--[[
	ShadeController.luau (Client UI Library)
	Gestiona `UserInterface.Shade`, un overlay que oscurece la pantalla cuando se
	abre un panel (Rewards, etc.). Es completamente dirigido por atributos: cada
	frame decide si lo usa y de qué color, sin acoplar el controlador a una lista.

	Estructura del overlay:
		Shade            ← Frame contenedor, SIEMPRE transparente; ZIndex fijo detrás
		  Background     ← Frame con el color de oscurecido
		  CanvasGroup    ← imagen/gradiente (GroupTransparency desvanece su contenido)
		    ImageLabel, UIGradient, ...

	Atributos (se definen en Studio sobre el frame del panel):
		Shade       : boolean  → si true, mostrar el overlay mientras el frame esté visible.
		ShadeColor  : Color3   → color para `Shade.Background.BackgroundColor3` (opcional).

	Aparición/desaparición animadas con tween de transparencia: se desvanece
	`Background.BackgroundTransparency` y `CanvasGroup.GroupTransparency` entre sus
	valores diseñados (estado visible) y 1 (oculto). No toca el `Shade` en sí.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

local SHADE_ATTRIBUTE = "Shade"
local COLOR_ATTRIBUTE = "ShadeColor"
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

	-- Fijar el ZIndex una sola vez para que el overlay quede siempre detrás.
	shade.ZIndex = SHADE_ZINDEX

	-- Transparencias "visibles" diseñadas en Studio: se desvanece entre éstas y 1.
	local bgVisible = background.BackgroundTransparency
	local canvasVisible = if canvas then canvas.GroupTransparency else 0

	-- Estado inicial: oculto.
	background.BackgroundTransparency = 1
	if canvas then
		canvas.GroupTransparency = 1
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

	local function tweenTo(info: TweenInfo, bgTarget: number, canvasTarget: number)
		cancelTweens()

		local bgTween = TweenService:Create(background, info, { BackgroundTransparency = bgTarget })
		table.insert(activeTweens, bgTween)
		bgTween:Play()

		if canvas then
			local canvasTween = TweenService:Create(canvas, info, { GroupTransparency = canvasTarget })
			table.insert(activeTweens, canvasTween)
			canvasTween:Play()
		end

		return bgTween
	end

	local function show(color: Color3?)
		if color then
			background.BackgroundColor3 = color
		end
		if shown then
			return
		end
		shown = true

		shade.Visible = true
		tweenTo(SHOW_INFO, bgVisible, canvasVisible)
	end

	local function hide()
		if not shown then
			return
		end
		shown = false

		local bgTween = tweenTo(HIDE_INFO, 1, 1)
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
