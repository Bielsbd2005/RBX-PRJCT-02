--!strict
--[[
	MatchNotificationsQueue.luau
	Queue + animaciones de notificaciones in-match: level up (de cuenta y de pase
	de batalla, mismo frame con distinto título) y maestría de armas (hitos +
	completar). Extraído de MatchHud para que ese módulo no orqueste tanto. Los
	frames y sus posiciones originales se cachean por instancia.

	Frames esperados bajo `MatchHud.Container`, igual que el resto del HUD:
		LevelUp.{Title, TitleBG, Level, LevelBG}
		Maestry.{Title, Value, Bar.Fill, Reward.ItemViewport}

	API:
		MatchNotificationsQueue.new(matchHudGui: ScreenGui?)
		:playLevelUpAnimation(newLevel: number)
		:playBattlePassLevelUpAnimation(newLevel: number)
		:playMasteryAnimation(progress: MasteryProgress)
		:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Confetti = require(script.Parent.Parent.Parent.core.ui.Confetti)
local Fireworks = require(script.Parent.Parent.Parent.core.ui.Fireworks)
local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local WeaponWrapPreviewer = require(script.Parent.Parent.locker.Previewers.WeaponWrapPreviewer)
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any

-- ── Tipos públicos ───────────────────────────────────────────

-- Progreso de maestría de un arma hacia el siguiente tier (o el recién completado).
-- `current`/`target` se muestran como "current/target" y rellenan la barra.
-- `isComplete` = true cuando se acaba de ganar el wrap (100%, con confeti).
export type MasteryProgress = {
	current: number,
	target: number,
	name: string,
	isComplete: boolean?,
	-- Preview 3D del wrap de maestría (siguiente tier o el recién ganado).
	previewWeaponCategory: string?,
	previewWeaponId: string?,
	itemId: string?,
	category: string?,
	textureID: string?,
	baseColor: Color3?,
	material: Enum.Material?,
	animated: boolean?,
	studsPerTile: number?,
}

-- ── Constantes ───────────────────────────────────────────────

-- Coreografía del popup de level up (t = 0 al empezar la animación):
--   0.00  arranca el slide-in y salen los cohetes de los fuegos artificiales
--   0.45  el frame aterriza justo cuando el confeti llega a su apex
--   0.55  primer estallido; se encadenan hasta ~2.35
--   2.45  cae el último confeti
--   4.05  se apaga la última chispa → un beat de calma antes de irse
--   5.45  empieza el slide-out
-- Si se toca el hold hay que revisar la duración de Fireworks (ver ese módulo).
local LEVEL_UP_TWEEN_IN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local LEVEL_UP_TWEEN_OUT_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local LEVEL_UP_HOLD_SECONDS = 5.0
-- Cap defensivo: si se enchufan muchas notificaciones (drops, level-ups en
-- cadena), tirar las más antiguas todavía sin reproducir antes que dejar
-- crecer la cola indefinidamente.
local NOTIFICATION_QUEUE_CAP = 20

-- El cañón de confeti tiene que sonar a "pop": una volea corta en vez de un
-- goteo largo, disparada al empezar el slide-in para que las piezas estén
-- cayendo por el centro justo cuando el frame aterriza. Las piezas viven lo
-- suficiente para seguir revoloteando hasta que entran los primeros estallidos.
local CONFETTI_COUNT = 60
local CONFETTI_SPAWN_DURATION = 0.25
local CONFETTI_LIFETIME_MIN = 1.4
local CONFETTI_LIFETIME_MAX = 2.2

-- Título del frame LevelUp según de qué progresión venga la subida.
local LEVEL_UP_TITLE = "LEVEL UP!"
local BATTLEPASS_LEVEL_UP_TITLE = "FAME PASS!"

local LEVEL_UP_CONFETTI_COLORS = {
	Color3.fromRGB(40, 130, 255),
	Color3.fromRGB(80, 170, 255),
	Color3.fromRGB(120, 200, 255),
	Color3.fromRGB(20, 90, 200),
	Color3.fromRGB(170, 220, 255),
}

-- BattlePass usa paleta verde para diferenciar visualmente del level up de
-- character (azul). Mismo frame y timing, distinto título y color.
local BATTLEPASS_LEVEL_UP_CONFETTI_COLORS = {
	Color3.fromRGB(60, 200, 100),
	Color3.fromRGB(40, 220, 80),
	Color3.fromRGB(100, 230, 130),
	Color3.fromRGB(20, 160, 60),
	Color3.fromRGB(140, 240, 160),
}

-- Maestría de armas usa paleta dorada (logro/achievement). Solo se lanza confeti
-- al completar un tier (100%), no en los hitos intermedios.
local MASTERY_CONFETTI_COLORS = {
	Color3.fromRGB(255, 205, 70),
	Color3.fromRGB(255, 175, 30),
	Color3.fromRGB(255, 230, 140),
	Color3.fromRGB(230, 150, 20),
	Color3.fromRGB(255, 245, 200),
}
-- Tween de la barra de progreso de maestría (se rellena tras entrar el frame).
local MASTERY_BAR_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)



-- Calcula el tamaño objetivo de un Fill horizontal para un ratio [0,1], cacheando
-- la escala/offset base del asset (igual criterio que MatchHud._setHorizontalFill).
local function _targetFillSize(fillNode: GuiObject, ratio: number): UDim2
	local clampedRatio = math.min(1, math.max(0, ratio))
	local baseScale = fillNode:GetAttribute("BaseFillScale")
	local baseOffset = fillNode:GetAttribute("BaseFillOffset")
	local currentSize = fillNode.Size
	if type(baseScale) ~= "number" then
		baseScale = currentSize.X.Scale
		fillNode:SetAttribute("BaseFillScale", baseScale)
	end
	if type(baseOffset) ~= "number" then
		baseOffset = currentSize.X.Offset
		fillNode:SetAttribute("BaseFillOffset", baseOffset)
	end
	local nextScale = baseScale + ((1 - baseScale) * clampedRatio)
	return UDim2.new(nextScale, baseOffset, currentSize.Y.Scale, currentSize.Y.Offset)
end

-- Preview 3D de un wrap dentro de un ViewportFrame, con el MISMO encuadre que las
-- cards del locker (ver LockerGrid:_applyWeaponWrapViewportPreview): sin
-- PreviewWeapon* para que caiga al modelo genérico `ReplicatedStorage.Wrap`, y
-- `reframeCentered` después de Render para dejarlo centrado con margen en vez del
-- encuadre cerrado y descentrado de las cards de arma.
-- Solo toca los hijos no-GUI del viewport (WorldModel/Camera): el background y
-- demás estilo son del asset y se dejan intactos.
local function _renderWrapPreview(itemViewport: ViewportFrame, wrap: any): any
	for _, child in itemViewport:GetChildren() do
		if not child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local previewJanitor = Janitor.new()
	local ok = WeaponWrapPreviewer.Render(itemViewport, {
		TextureID = wrap.textureID,
		BaseColor = wrap.baseColor,
		Material = wrap.material,
		isAnimated = wrap.animated,
		StudsPerTile = wrap.studsPerTile,
	}, previewJanitor)
	if ok then
		WeaponWrapPreviewer.reframeCentered(itemViewport)
	end
	return previewJanitor
end

-- Escribe el mismo texto en un label y en su copia de sombra (`<name>BG`): el
-- asset duplica Title/Level desplazados para simular sombra, así que los dos
-- tienen que ir sincronizados. Recorremos descendientes para no depender de si
-- la sombra es hermana o padre del label.
local function _setLabelWithShadow(frame: GuiObject, name: string, text: string)
	local shadowName = name .. "BG"
	for _, descendant in frame:GetDescendants() do
		if descendant:IsA("TextLabel") and (descendant.Name == name or descendant.Name == shadowName) then
			descendant.Text = text
		end
	end
end

-- ── Módulo ───────────────────────────────────────────────────

local MatchNotificationsQueue = {}
MatchNotificationsQueue.__index = MatchNotificationsQueue

function MatchNotificationsQueue.new(matchHudGui: ScreenGui?): any
	local self = setmetatable({}, MatchNotificationsQueue)
	self._gui = matchHudGui
	self._destroyed = false
	self._queue = {} :: { (onDone: () -> ()) -> () }
	self._active = false
	-- "Notifying" = hay una notificación en pantalla o en cola. Avisamos en cada
	-- transición (con detección de cambio para no parpadear entre notificaciones
	-- consecutivas). Lo usa MatchHud para ocultar las filas de jugadores.
	self._notifying = false
	self._onNotifyingChanged = nil :: ((notifying: boolean) -> ())?
	-- Cache de posiciones originales de cada frame (se setean en el primer play).
	-- LevelUp lo comparten el level up de cuenta y el del pase, así que basta una.
	self._levelUpOriginalPosition = nil :: UDim2?
	self._maestryOriginalPosition = nil :: UDim2?
	return self
end

-- Los popups cuelgan de MatchHud.Container igual que el resto del HUD; se pintan
-- encima sin ocultar nada, así que solo necesitan el Container.
function MatchNotificationsQueue:_resolveContainer(): GuiObject?
	if not self._gui then
		return nil
	end
	return self._gui:WaitForChild("Container") :: GuiObject
end

-- Registra un callback que recibe `true` cuando empieza a haber notificaciones y
-- `false` cuando se vacía la cola (sin parpadeo entre notificaciones encadenadas).
function MatchNotificationsQueue:setOnNotifyingChanged(callback: ((notifying: boolean) -> ())?)
	self._onNotifyingChanged = callback
end

function MatchNotificationsQueue:_refreshNotifying()
	local notifying = self._active or #self._queue > 0
	if notifying == self._notifying then
		return
	end
	self._notifying = notifying
	if self._onNotifyingChanged then
		self._onNotifyingChanged(notifying)
	end
end

function MatchNotificationsQueue:_processQueue()
	if self._active or self._destroyed then
		return
	end
	local nextRun = table.remove(self._queue, 1)
	if not nextRun then
		return
	end

	self._active = true
	self:_refreshNotifying()
	task.spawn(function()
		nextRun(function()
			self._active = false
			if not self._destroyed then
				self:_processQueue()
			end
			self:_refreshNotifying()
		end)
	end)
end

function MatchNotificationsQueue:_enqueue(runFn: (onDone: () -> ()) -> ())
	if self._destroyed then
		return
	end
	while #self._queue >= NOTIFICATION_QUEUE_CAP do
		table.remove(self._queue, 1)
	end
	table.insert(self._queue, runFn)
	self:_processQueue()
end

-- Patrón común de notificación: cachea la posición original del frame, lo mete
-- fuera de pantalla (arriba), lo muestra, desliza dentro, opcionalmente lanza
-- confeti y corre `afterShown`, mantiene `LEVEL_UP_HOLD_SECONDS`, y sale. `cacheKey`
-- es el campo de self donde se cachea la Position original. Bloquea hasta terminar
-- (se llama dentro del runFn de la cola).
function MatchNotificationsQueue:_playFrameSlide(frame: GuiObject, cacheKey: string, confettiColors: { Color3 }?, spawnDuration: number?, afterShown: (() -> ())?)
	local matchHudGui = self._gui
	local originalPosition = (self :: any)[cacheKey]
	if not originalPosition then
		originalPosition = frame.Position
		;(self :: any)[cacheKey] = originalPosition
	end

	local aboveScreenPosition = UDim2.new(
		originalPosition.X.Scale,
		originalPosition.X.Offset,
		-1,
		originalPosition.Y.Offset
	)

	frame.Position = aboveScreenPosition
	frame.Visible = true

	if confettiColors and matchHudGui then
		Confetti.Rain(matchHudGui, {
			colors = confettiColors,
			count = CONFETTI_COUNT,
			minLifetime = CONFETTI_LIFETIME_MIN,
			maxLifetime = CONFETTI_LIFETIME_MAX,
			spawnDuration = spawnDuration or CONFETTI_SPAWN_DURATION,
		})
	end

	local tweenIn = TweenService:Create(frame, LEVEL_UP_TWEEN_IN_INFO, { Position = originalPosition })
	tweenIn:Play()
	tweenIn.Completed:Wait()

	if afterShown then
		afterShown()
	end

	task.wait(LEVEL_UP_HOLD_SECONDS)

	local tweenOut = TweenService:Create(frame, LEVEL_UP_TWEEN_OUT_INFO, { Position = aboveScreenPosition })
	tweenOut:Play()
	tweenOut.Completed:Wait()

	frame.Visible = false
	frame.Position = originalPosition
end

-- Level up de cuenta y de pase comparten el frame Container.LevelUp: Title/TitleBG
-- dicen de cuál se trata y Level/LevelBG el nivel alcanzado. Solo cambian título y
-- paleta (que comparten confeti y fuegos artificiales).
function MatchNotificationsQueue:_playLevelUpFrame(newLevel: number, title: string, palette: { Color3 })
	self:_enqueue(function(onDone)
		local container = self:_resolveContainer()
		if not container then onDone() return end
		local frame = container:WaitForChild("LevelUp") :: GuiObject

		_setLabelWithShadow(frame, "Title", title)
		_setLabelWithShadow(frame, "Level", tostring(math.max(0, math.floor(newLevel))))

		local matchHudGui = self._gui
		if matchHudGui then
			Fireworks.Burst(matchHudGui)
		end

		self:_playFrameSlide(frame, "_levelUpOriginalPosition", palette)

		onDone()
	end)
end

function MatchNotificationsQueue:playLevelUpAnimation(newLevel: number)
	self:_playLevelUpFrame(newLevel, LEVEL_UP_TITLE, LEVEL_UP_CONFETTI_COLORS)
end

function MatchNotificationsQueue:playBattlePassLevelUpAnimation(newLevel: number)
	self:_playLevelUpFrame(newLevel, BATTLEPASS_LEVEL_UP_TITLE, BATTLEPASS_LEVEL_UP_CONFETTI_COLORS)
end

-- Maestría de arma → frame Container.Maestry. Title lleva el nombre del desafío,
-- Value el "actual/objetivo", Bar.Fill se rellena con tween hasta el ratio, y
-- Reward.ItemViewport muestra el preview del wrap (siguiente tier o el recién
-- ganado). Solo lanza confeti al completar un tier (progress.isComplete).
function MatchNotificationsQueue:playMasteryAnimation(progress: MasteryProgress)
	self:_enqueue(function(onDone)
		local container = self:_resolveContainer()
		if not container then onDone() return end
		local frame = container:WaitForChild("Maestry") :: GuiObject

		local current = math.max(0, math.floor(progress.current))
		local target = math.max(1, math.floor(progress.target))
		local ratio = math.min(1, current / target)
		local isComplete = progress.isComplete == true

		local titleLabel = frame:WaitForChild("Title") :: TextLabel
		titleLabel.Text = progress.name

		local valueLabel = frame:WaitForChild("Value") :: TextLabel
		valueLabel.RichText = true
		valueLabel.Text = UIUtils.formatProgressValue(current, target)

		local rewardNode = frame:WaitForChild("Reward")
		local itemViewport = rewardNode:WaitForChild("ItemViewport") :: ViewportFrame
		local previewJanitor: any = _renderWrapPreview(itemViewport, progress)

		local barNode = frame:WaitForChild("Bar")
		local barFill = barNode:WaitForChild("Fill") :: GuiObject
		barFill.Size = _targetFillSize(barFill, 0)

		local confettiColors = if isComplete then MASTERY_CONFETTI_COLORS else nil
		self:_playFrameSlide(frame, "_maestryOriginalPosition", confettiColors, 0.4, function()
			local tween = TweenService:Create(barFill, MASTERY_BAR_TWEEN_INFO, {
				Size = _targetFillSize(barFill, ratio),
			})
			tween:Play()
		end)

		if previewJanitor then
			previewJanitor:Cleanup()
		end
		itemViewport.CurrentCamera = nil

		onDone()
	end)
end

function MatchNotificationsQueue:destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	table.clear(self._queue)
	self._active = false
	self:_refreshNotifying()
end

return MatchNotificationsQueue
