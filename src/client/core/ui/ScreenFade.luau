--!strict
--[[
	ScreenFade
	Fundido a negro liso a pantalla completa (sin iris ni figuras): se cubre,
	se hace el cambio con la pantalla en negro, y se descubre.

	Uso:
		local fade = ScreenFade.new(playerGui)
		fade:cover(function()
			-- pantalla completamente negra: mover cámara, cambiar preset…
			fade:reveal()
		end)

	Cubre por encima de todo (DisplayOrder alto): la UI del panel que haya debajo
	aparece al descubrir, no durante el viaje de la cámara.

	Llamar `cover` mientras hay otra transición en curso cancela la anterior y su
	callback ya no se ejecuta (un contador de operación descarta las obsoletas),
	así que abrir y cerrar rápido no deja la pantalla en negro ni ejecuta el
	cambio de cámara del panel que ya se cerró.
]]

local TweenService = game:GetService("TweenService")

local COVER_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REVEAL_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GUI_NAME = "ScreenFadeGui"

local ScreenFade = {}
ScreenFade.__index = ScreenFade

export type ScreenFade = typeof(setmetatable(
	{} :: {
		_veil: Frame,
		_screenGui: ScreenGui,
		_activeTween: Tween?,
		_opId: number,
	},
	ScreenFade
))

local function _build(playerGui: PlayerGui): (ScreenGui, Frame)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 9999
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		screenGui.ScreenInsets = Enum.ScreenInsets.None
	end)
	screenGui.Parent = playerGui

	local veil = Instance.new("Frame")
	veil.Name = "Veil"
	veil.Size = UDim2.fromScale(1, 1)
	veil.BorderSizePixel = 0
	veil.BackgroundColor3 = Color3.new(0, 0, 0)
	veil.BackgroundTransparency = 1
	veil.Visible = false
	veil.ZIndex = 9999
	veil.Parent = screenGui

	return screenGui, veil
end

-- Singleton por playerGui, igual que IrisTransition: reusa el GUI si otra
-- feature ya lo creó, en vez de apilar overlays negros.
function ScreenFade.new(playerGui: PlayerGui): ScreenFade
	local existing = playerGui:FindFirstChild(GUI_NAME)
	if existing and existing:IsA("ScreenGui") then
		local existingVeil = existing:FindFirstChild("Veil")
		if existingVeil and existingVeil:IsA("Frame") then
			return setmetatable({
				_veil = existingVeil,
				_screenGui = existing,
				_activeTween = nil,
				_opId = 0,
			}, ScreenFade)
		end
		existing:Destroy()
	end

	local screenGui, veil = _build(playerGui)
	return setmetatable({
		_veil = veil,
		_screenGui = screenGui,
		_activeTween = nil,
		_opId = 0,
	}, ScreenFade)
end

function ScreenFade:_beginTransition(targetTransparency: number, tweenInfo: TweenInfo): (number, Tween)
	self._opId += 1
	local opId = self._opId

	if self._activeTween then
		self._activeTween:Cancel()
		self._activeTween = nil
	end

	local veil = self._veil
	veil.Visible = true
	-- No interceptar el input mientras cubre: el panel de debajo sigue vivo y sus
	-- botones no deben quedarse muertos si algo interrumpe el fundido.
	veil.Active = false

	local tween = TweenService:Create(veil, tweenInfo, { BackgroundTransparency = targetTransparency })
	self._activeTween = tween
	tween:Play()

	return opId, tween
end

--- Funde a negro. `onBlack` se llama con la pantalla completamente cubierta.
function ScreenFade:cover(onBlack: (() -> ())?): ()
	task.spawn(function()
		local opId, tween = self:_beginTransition(0, COVER_INFO)
		local playbackState = tween.Completed:Wait()
		if self._activeTween == tween then
			self._activeTween = nil
		end

		-- Otra transición tomó el relevo (o el fundido se canceló): el cambio que
		-- pedía este cover ya no toca hacerlo.
		if self._opId ~= opId or playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		if onBlack then
			onBlack()
		end
	end)
end

--- Descubre la pantalla.
function ScreenFade:reveal(): ()
	task.spawn(function()
		local opId, tween = self:_beginTransition(1, REVEAL_INFO)
		local playbackState = tween.Completed:Wait()
		if self._activeTween == tween then
			self._activeTween = nil
		end
		if self._opId ~= opId or playbackState ~= Enum.PlaybackState.Completed then
			return
		end
		self._veil.Visible = false
	end)
end

--- Deja la pantalla descubierta sin animación.
function ScreenFade:reset(): ()
	self._opId += 1
	if self._activeTween then
		self._activeTween:Cancel()
		self._activeTween = nil
	end
	self._veil.BackgroundTransparency = 1
	self._veil.Visible = false
end

return ScreenFade
