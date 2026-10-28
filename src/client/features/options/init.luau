--!strict
--[[
	UserInterface.Options se muestra mientras el menú de Roblox (Esc / botón de
	Roblox) está abierto y el resto de ScreenGuis de PlayerGui se apaga (con blur de
	fondo) hasta que el menú se cierra. Los textos se escriben letra a letra.

	Options.Warning (Frame con `Text` y `Value`) solo aparece si salir ahora le cuesta
	Cash de bonus: `Value` muestra cuánto y el Frame late en bucle. `Text` es el de Studio.

	Roblox pinta su menú por encima de cualquier ScreenGui del juego: en Studio,
	Options debe quedar en una zona que el menú no tape.

	Se apagan ScreenGuis (GuiSuppression) y nunca paneles (Visible): varios features
	reaccionan al Visible de su panel (el Locker se cierra al ocultarse). Por eso
	Options se mueve a su propia ScreenGui y UserInterface se apaga entera.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any
local GuiSuppression = require(Shared.utils.GuiSuppression)
local BlurController = require(Client.core.ui.BlurController)
local UIUtils = require(Client.core.ui.UIUtils)

local CHARS_PER_SECOND = 80
local OVERLAY_NAME = "OptionsOverlay"
local BLUR_KEY = "Options"

-- Latido de Warning: dos golpes seguidos (el segundo más flojo) y una pausa.
local BEAT_SCALES = { 1.12, 1.06 }
local BEAT_EXPAND_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BEAT_CONTRACT_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BEAT_REST_SECONDS = 0.35

-- Atributo de Player que publica MatchService: debe coincidir con el de allí.
local BONUS_AT_STAKE_ATTRIBUTE = "MatchBonusAtStake"

local OptionsFeature = {}

-- ContentText ya viene sin etiquetas RichText, igual que cuenta MaxVisibleGraphemes.
local function countGraphemes(text: string): number
	local count = 0
	for _ in utf8.graphemes(text) do
		count += 1
	end
	return count
end

function OptionsFeature.start(_menuController: any): any
	local janitor = Janitor.new()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local frame = uiGui:WaitForChild("Options") :: GuiObject
	local label = frame:WaitForChild("Text") :: TextLabel
	local warning = frame:WaitForChild("Warning") :: GuiObject
	local warningText = warning:WaitForChild("Text") :: TextLabel
	local warningValue = warning:WaitForChild("Value") :: TextLabel

	-- Mismo encuadre que UserInterface para que Options no se mueva al cambiar de padre.
	local overlay = Instance.new("ScreenGui")
	overlay.Name = OVERLAY_NAME
	overlay.ResetOnSpawn = false
	overlay.DisplayOrder = uiGui.DisplayOrder
	overlay.ZIndexBehavior = uiGui.ZIndexBehavior
	overlay.IgnoreGuiInset = uiGui.IgnoreGuiInset
	overlay.ScreenInsets = uiGui.ScreenInsets
	overlay.ClipToDeviceSafeArea = uiGui.ClipToDeviceSafeArea
	overlay.SafeAreaCompatibility = uiGui.SafeAreaCompatibility
	overlay.Parent = playerGui
	janitor:Add(overlay, "Destroy")
	frame.Parent = overlay

	-- UIScale propio o el que ya traiga de Studio; el latido escala desde su AnchorPoint.
	local warningScale = warning:FindFirstChildOfClass("UIScale")
	if not warningScale then
		local created = Instance.new("UIScale")
		created.Parent = warning
		janitor:Add(created, "Destroy")
		warningScale = created
	end
	local scale = warningScale :: UIScale
	local baseScale = scale.Scale

	local typingTweens: { Tween } = {}
	local pulseTween: Tween? = nil
	local heartbeatThread: thread? = nil

	-- MaxVisibleGraphemes es entero: se tweenea un NumberValue y se redondea.
	local function typeLabel(target: TextLabel, onDone: (() -> ())?)
		local total = countGraphemes(target.ContentText)
		local progress = Instance.new("NumberValue")
		progress.Changed:Connect(function(value: number)
			target.MaxVisibleGraphemes = math.floor(value)
		end)
		target.MaxVisibleGraphemes = 0

		local tween = TweenService:Create(
			progress,
			TweenInfo.new(total / CHARS_PER_SECOND, Enum.EasingStyle.Linear),
			{ Value = total }
		)
		tween.Completed:Connect(function(state)
			progress:Destroy()
			if state ~= Enum.PlaybackState.Completed then
				return
			end
			-- -1 al acabar: si el texto cambia después, no se queda recortado.
			target.MaxVisibleGraphemes = -1
			if onDone then
				onDone()
			end
		end)
		table.insert(typingTweens, tween)
		tween:Play()
	end

	local function pulseTo(target: number, info: TweenInfo)
		local tween = TweenService:Create(scale, info, { Scale = target })
		pulseTween = tween
		tween:Play()
		tween.Completed:Wait()
	end

	local function stopHeartbeat()
		if heartbeatThread then
			task.cancel(heartbeatThread)
			heartbeatThread = nil
		end
		if pulseTween then
			pulseTween:Cancel()
			pulseTween = nil
		end
		scale.Scale = baseScale
	end

	local function startHeartbeat()
		stopHeartbeat()
		heartbeatThread = task.spawn(function()
			while true do
				for _, beatScale in BEAT_SCALES do
					pulseTo(baseScale * beatScale, BEAT_EXPAND_INFO)
					pulseTo(baseScale, BEAT_CONTRACT_INFO)
				end
				task.wait(BEAT_REST_SECONDS)
			end
		end)
	end

	local function stopAnimations()
		for _, tween in typingTweens do
			tween:Cancel()
		end
		table.clear(typingTweens)
		stopHeartbeat()
	end
	janitor:Add(stopAnimations, true)

	-- Fuera de partida MatchService borra el atributo: sin bonus en juego no hay aviso.
	local function refreshWarning()
		local atStake = player:GetAttribute(BONUS_AT_STAKE_ATTRIBUTE)
		local hasBonus = type(atStake) == "number" and atStake > 0
		local wasVisible = warning.Visible
		warning.Visible = hasBonus
		if hasBonus then
			warningValue.Text = UIUtils.formatCashAmount(atStake :: number)
		end

		-- Cambios con el menú ya abierto (una kill de un compañero): sin volver a escribir.
		if frame.Visible and hasBonus and not wasVisible then
			startHeartbeat()
		elseif not hasBonus then
			stopHeartbeat()
		end
	end
	janitor:Add(player:GetAttributeChangedSignal(BONUS_AT_STAKE_ATTRIBUTE):Connect(refreshWarning), "Disconnect")

	-- Todo se escribe a la vez; Warning empieza a latir cuando acaban sus dos textos.
	local function playAnimations()
		stopAnimations()
		typeLabel(label)
		if not warning.Visible then
			return
		end
		local pending = 2
		local function onWarningTyped()
			pending -= 1
			if pending == 0 then
				startHeartbeat()
			end
		end
		typeLabel(warningText, onWarningTyped)
		typeLabel(warningValue, onWarningTyped)
	end

	janitor:Add(function()
		if frame.Visible then
			BlurController.release(BLUR_KEY)
			GuiSuppression.restore()
		end
	end, true)

	local function setOpen(open: boolean)
		if frame.Visible == open then
			return
		end
		frame.Visible = open
		if open then
			GuiSuppression.suppress(playerGui, overlay)
			BlurController.acquire(BLUR_KEY)
			refreshWarning()
			playAnimations()
		else
			stopAnimations()
			BlurController.release(BLUR_KEY)
			GuiSuppression.restore()
		end
	end

	frame.Visible = false
	janitor:Add(GuiService.MenuOpened:Connect(function()
		setOpen(true)
	end), "Disconnect")
	janitor:Add(GuiService.MenuClosed:Connect(function()
		setOpen(false)
	end), "Disconnect")
	setOpen(GuiService.MenuIsOpen)

	return janitor
end

return OptionsFeature
