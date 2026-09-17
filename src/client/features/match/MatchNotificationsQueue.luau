--!strict
--[[
	Cola + animaciones de notificaciones in-match (level up de cuenta y de pase,
	maestría de armas, misiones diarias). Se reproducen de una en una.

	Frames esperados bajo `MatchHud.Container.MainFrame`:
		LevelUp.{Title, Level, Image}
		(Image es la flecha que sube por detrás del texto)
		Progress.{ItemViewport, Title, Value, Bar.Fill}
		Completed.{Title, Subtitle}
		CoinsSpawn
		(dentro de Progress y Completed los nodos se buscan por nombre en
		 profundidad, así que pueden ir anidados)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Confetti = require(script.Parent.Parent.Parent.core.ui.Confetti)
local GameSounds = require(script.Parent.Parent.Parent.core.ui.GameSounds)
local Fireworks = require(script.Parent.Parent.Parent.core.ui.Fireworks)
local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local WeaponWrapPreviewer = require(script.Parent.Parent.locker.Previewers.WeaponWrapPreviewer)
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any

-- `isComplete` = true cuando se acaba de ganar el wrap (100%).
export type MasteryProgress = {
	current: number,
	target: number,
	name: string,
	isComplete: boolean?,
	-- Wrap del preview 3D: siguiente tier o el recién ganado.
	textureID: string?,
	baseColor: Color3?,
	material: Enum.Material?,
	animated: boolean?,
	studsPerTile: number?,
}

-- Solo se notifica con `isComplete`; `rewardCash` vuela en monedas hacia Stats.
export type DailyTaskProgress = {
	current: number,
	target: number,
	name: string,
	isComplete: boolean?,
	rewardCash: number?,
}

-- Entrada de los popups Progress/Completed (el level up no se desliza).
local LEVEL_UP_TWEEN_IN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local POPUP_SHRINK_OUT_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local LEVEL_UP_HOLD_SECONDS = 5.0

-- Flecha LevelUp.Image: sube desde RISE_FROM por debajo (Cubic Out), pausa y sale
-- hasta RISE_PAST por encima (Cubic In). Distancias en altos de la propia imagen.
local LEVEL_UP_ARROW_RISE_FROM = 0.7
local LEVEL_UP_ARROW_RISE_PAST = 0.3
local LEVEL_UP_ARROW_ENTER_SECONDS = 0.95
local LEVEL_UP_ARROW_PAUSE_SECONDS = 1.2
local LEVEL_UP_ARROW_EXIT_SECONDS = 0.35
local LEVEL_UP_FADE_IN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LEVEL_UP_FADE_OUT_INFO =
	TweenInfo.new(LEVEL_UP_ARROW_EXIT_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
-- Paso máximo por frame: el popup aparece en el mismo frame (largo) en que se
-- crean confeti y fuegos, y la flecha pegaría un salto.
local LEVEL_UP_ARROW_MAX_STEP = 1 / 30
-- Con Rotation 0 la UI se alinea a píxel y los tramos lentos avanzarían a saltitos.
local LEVEL_UP_ARROW_SUBPIXEL_ROTATION = 0.01
-- Pop de tamaño (UIScale) relativo al Scale que traiga el asset.
local LEVEL_UP_POP_FROM = 0.6
local LEVEL_UP_POP_IN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local LEVEL_UP_POP_EXIT = 1.1
-- Al superarlo se descartan las más antiguas sin reproducir.
local NOTIFICATION_QUEUE_CAP = 20

local CONFETTI_COUNT = 60
local CONFETTI_SPAWN_DURATION = 0.25
local CONFETTI_LIFETIME_MIN = 1.4
local CONFETTI_LIFETIME_MAX = 2.2

local LEVEL_UP_TITLE = "LEVEL UP!"
local BATTLEPASS_LEVEL_UP_TITLE = "FAME PASS!"

local LEVEL_UP_CONFETTI_COLORS = {
	Color3.fromRGB(30, 110, 255),
	Color3.fromRGB(0, 85, 230),
	Color3.fromRGB(60, 150, 255),
	Color3.fromRGB(15, 60, 190),
	Color3.fromRGB(90, 175, 255),
}

local BATTLEPASS_LEVEL_UP_CONFETTI_COLORS = {
	Color3.fromRGB(60, 200, 100),
	Color3.fromRGB(40, 220, 80),
	Color3.fromRGB(100, 230, 130),
	Color3.fromRGB(20, 160, 60),
	Color3.fromRGB(140, 240, 160),
}

local MASTERY_CONFETTI_COLORS = {
	Color3.fromRGB(255, 205, 70),
	Color3.fromRGB(255, 175, 30),
	Color3.fromRGB(255, 230, 140),
	Color3.fromRGB(230, 150, 20),
	Color3.fromRGB(255, 245, 200),
}
local MASTERY_BAR_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local DAILY_CONFETTI_COLORS = {
	Color3.fromRGB(60, 200, 90),
	Color3.fromRGB(120, 230, 140),
	Color3.fromRGB(255, 205, 70),
	Color3.fromRGB(255, 235, 150),
	Color3.fromRGB(30, 160, 70),
}
local DAILY_COMPLETE_HOLD_SECONDS = 1.0
local CONTRACT_COMPLETED_TITLE = "Contract Completed!"
local MASTERY_COMPLETED_TITLE = "Mastery Completed!"
local POPUP_WAIT_SECONDS = 5

-- Cachea la escala/offset base del asset en atributos (igual que MatchHud._setHorizontalFill).
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

-- CoinsSpawn es a la vez origen y sprite de las monedas: se oculta al resolverlo
-- y se clona por moneda.
local function _resolveCoinsSpawn(frame: GuiObject): ImageLabel?
	local node = frame:FindFirstChild("CoinsSpawn")
	if node and node:IsA("ImageLabel") then
		node.Visible = false
		return node
	end
	return nil
end

-- Sin PreviewWeapon* para que caiga al modelo genérico `ReplicatedStorage.Templates.Wrap`
-- (como LockerGrid:_applyWeaponWrapViewportPreview). Solo toca hijos no-GUI del viewport.
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

-- Por descendientes: el asset anida Title/Level a distinta profundidad según el frame.
local function _setLabel(frame: GuiObject, name: string, text: string)
	for _, descendant in frame:GetDescendants() do
		if descendant:IsA("TextLabel") and descendant.Name == name then
			descendant.Text = text
		end
	end
end

local function _findNamed(root: Instance, name: string, className: string): Instance?
	for _, descendant in root:GetDescendants() do
		if descendant.Name == name and descendant:IsA(className) then
			return descendant
		end
	end
	return nil
end

type FadeTarget = {
	object: Instance,
	property: string,
	original: number,
}

-- Guarda las transparencias de Studio para hacer fade sin asumir que todo estaba a 0.
local function _collectFadeTargets(root: GuiObject): { FadeTarget }
	local targets: { FadeTarget } = {}
	local function add(object: Instance, property: string)
		table.insert(targets, { object = object, property = property, original = (object :: any)[property] })
	end

	if root:IsA("CanvasGroup") then
		add(root, "GroupTransparency")
		return targets
	end

	add(root, "BackgroundTransparency")
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") then
			add(descendant, "BackgroundTransparency")
		end
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			add(descendant, "TextTransparency")
			add(descendant, "TextStrokeTransparency")
		elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			add(descendant, "ImageTransparency")
		elseif descendant:IsA("UIStroke") then
			add(descendant, "Transparency")
		end
	end
	return targets
end

local function _setFade(targets: { FadeTarget }, hidden: boolean)
	for _, target in targets do
		(target.object :: any)[target.property] = if hidden then 1 else target.original
	end
end

local function _tweenFade(targets: { FadeTarget }, info: TweenInfo, hidden: boolean)
	for _, target in targets do
		TweenService:Create(target.object, info, {
			[target.property] = if hidden then 1 else target.original,
		}):Play()
	end
end

-- En altos de imagen, positivo = por debajo.
local function _arrowOffset(t: number): number
	if t < LEVEL_UP_ARROW_ENTER_SECONDS then
		local remaining = 1 - t / LEVEL_UP_ARROW_ENTER_SECONDS
		return LEVEL_UP_ARROW_RISE_FROM * remaining ^ 3
	end
	local exitStart = LEVEL_UP_ARROW_ENTER_SECONDS + LEVEL_UP_ARROW_PAUSE_SECONDS
	if t < exitStart then
		return 0
	end
	local progress = math.min(1, (t - exitStart) / LEVEL_UP_ARROW_EXIT_SECONDS)
	return -LEVEL_UP_ARROW_RISE_PAST * progress ^ 3
end

-- Por frame en Scale y no con tween de Offset: Offset es entero y los tramos lentos
-- se verían a saltos de píxel.
local function _playArrowRise(arrow: GuiObject, basePosition: UDim2): () -> ()
	local elapsed = 0
	local function apply()
		local parent = arrow.Parent
		if not (parent and parent:IsA("GuiBase2d")) then
			return
		end
		local parentHeight = parent.AbsoluteSize.Y
		if parentHeight <= 0 then
			return
		end
		local offsetScale = _arrowOffset(elapsed) * arrow.AbsoluteSize.Y / parentHeight
		arrow.Position = UDim2.new(
			basePosition.X.Scale,
			basePosition.X.Offset,
			basePosition.Y.Scale + offsetScale,
			basePosition.Y.Offset
		)
	end

	local designedRotation = arrow.Rotation
	if designedRotation == 0 then
		arrow.Rotation = LEVEL_UP_ARROW_SUBPIXEL_ROTATION
	end

	apply()
	local connection = RunService.RenderStepped:Connect(function(dt: number)
		elapsed += math.min(dt, LEVEL_UP_ARROW_MAX_STEP)
		apply()
	end)
	return function()
		connection:Disconnect()
		arrow.Position = basePosition
		arrow.Rotation = designedRotation
	end
end

type ScalePop = {
	node: UIScale,
	designed: number,
}

-- Pivote al centro porque UIScale escala desde el AnchorPoint; se recoloca para que
-- el frame no se mueva en pantalla.
local function _prepareScalePop(frame: GuiObject): ScalePop
	local anchor = frame.AnchorPoint
	if anchor.X ~= 0.5 or anchor.Y ~= 0.5 then
		local pos = frame.Position
		local size = frame.Size
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.new(
			pos.X.Scale + size.X.Scale * (0.5 - anchor.X),
			pos.X.Offset + size.X.Offset * (0.5 - anchor.X),
			pos.Y.Scale + size.Y.Scale * (0.5 - anchor.Y),
			pos.Y.Offset + size.Y.Offset * (0.5 - anchor.Y)
		)
	end

	local node = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	node.Parent = frame
	return { node = node, designed = node.Scale }
end

local MatchNotificationsQueue = {}
MatchNotificationsQueue.__index = MatchNotificationsQueue

function MatchNotificationsQueue.new(matchHudGui: ScreenGui?): any
	local self = setmetatable({}, MatchNotificationsQueue)
	self._gui = matchHudGui
	self._destroyed = false
	self._queue = {} :: { (onDone: () -> ()) -> () }
	self._active = false
	-- "Notifying" = notificación en pantalla o en cola. MatchHud lo usa para ocultar
	-- las filas de jugadores.
	self._notifying = false
	self._onNotifyingChanged = nil :: ((notifying: boolean) -> ())?
	-- Valores de Studio cacheados en el primer play (LevelUp es compartido por cuenta y pase).
	self._levelUpFadeTargets = nil :: { FadeTarget }?
	self._levelUpArrowPosition = nil :: UDim2?
	self._levelUpPop = nil :: ScalePop?
	self._framePops = {} :: { [GuiObject]: ScalePop }
	self._progressOriginalPosition = nil :: UDim2?
	self._completedOriginalPosition = nil :: UDim2?
	-- Lo conecta MatchHud al popup de Stats. Devuelve cuánto tarda el vuelo de las
	-- monedas, que se espera antes de retirar el popup.
	self._onChallengeReward = nil :: ((spawnNode: ImageLabel, amount: number) -> number?)?

	-- CoinsSpawn cuelga de MainFrame, no de un popup: se oculta al arrancar.
	if matchHudGui then
		task.spawn(function()
			local container = self:_resolveContainer()
			if container then
				_resolveCoinsSpawn(container)
			end
		end)
	end
	return self
end

function MatchNotificationsQueue:setOnChallengeReward(
	callback: ((spawnNode: ImageLabel, amount: number) -> number?)?
)
	self._onChallengeReward = callback
end

function MatchNotificationsQueue:_resolveContainer(): GuiObject?
	local gui = self._gui
	if not gui then
		return nil
	end
	return gui:WaitForChild("Container"):WaitForChild("MainFrame") :: GuiObject
end

-- Sin parpadeo entre notificaciones encadenadas.
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

function MatchNotificationsQueue:_rainConfetti(colors: { Color3 }, spawnDuration: number?)
	Confetti.Rain(self._gui, {
		colors = colors,
		count = CONFETTI_COUNT,
		minLifetime = CONFETTI_LIFETIME_MIN,
		maxLifetime = CONFETTI_LIFETIME_MAX,
		spawnDuration = spawnDuration or CONFETTI_SPAWN_DURATION,
	})
end

-- `cacheKey` es el campo de self donde se cachea la Position original. Bloquea
-- hasta terminar, así que un `afterShown` que bloquee retrasa el hold.
function MatchNotificationsQueue:_playFrameSlide(
	frame: GuiObject,
	cacheKey: string,
	confettiColors: { Color3 }?,
	spawnDuration: number?,
	afterShown: (() -> ())?,
	holdSeconds: number?
)
	-- Antes de cachear la posición: _prepareScalePop recoloca el frame.
	local pop: ScalePop? = self._framePops[frame]
	if not pop then
		pop = _prepareScalePop(frame)
		self._framePops[frame] = pop
	end

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

	if confettiColors then
		self:_rainConfetti(confettiColors, spawnDuration)
	end

	local tweenIn = TweenService:Create(frame, LEVEL_UP_TWEEN_IN_INFO, { Position = originalPosition })
	tweenIn:Play()
	tweenIn.Completed:Wait()

	if afterShown then
		afterShown()
	end

	task.wait(holdSeconds or LEVEL_UP_HOLD_SECONDS)

	local popNode = (pop :: ScalePop).node
	local tweenOut = TweenService:Create(popNode, POPUP_SHRINK_OUT_INFO, { Scale = 0 })
	tweenOut:Play()
	tweenOut.Completed:Wait()

	frame.Visible = false
	frame.Position = originalPosition
	popNode.Scale = (pop :: ScalePop).designed
end

-- Level up de cuenta y de pase comparten el frame MainFrame.LevelUp.
function MatchNotificationsQueue:_playLevelUpFrame(
	newLevel: number,
	title: string,
	palette: { Color3 },
	soundKey: string
)
	self:_enqueue(function(onDone)
		local container = self:_resolveContainer()
		if not container then onDone() return end
		-- Dentro del closure: `_enqueue` puede retrasarlo y el sonido va cuando el frame ENTRA.
		GameSounds.play(soundKey)
		local frame = container:WaitForChild("LevelUp") :: GuiObject

		_setLabel(frame, "Title", title)
		_setLabel(frame, "Level", tostring(math.max(0, math.floor(newLevel))))

		-- Se cachean en el primer play, antes de que el fade o la subida las toquen.
		if not self._levelUpFadeTargets then
			self._levelUpFadeTargets = _collectFadeTargets(frame)
		end
		local fadeTargets = self._levelUpFadeTargets
		local arrowInst = frame:FindFirstChild("Image")
		local arrow = if arrowInst and arrowInst:IsA("GuiObject") then arrowInst else nil
		if arrow and not self._levelUpArrowPosition then
			self._levelUpArrowPosition = arrow.Position
		end
		if not self._levelUpPop then
			self._levelUpPop = _prepareScalePop(frame)
		end
		local pop: ScalePop = self._levelUpPop

		_setFade(fadeTargets, true)
		pop.node.Scale = pop.designed * LEVEL_UP_POP_FROM
		frame.Visible = true
		local stopArrow = if arrow then _playArrowRise(arrow, self._levelUpArrowPosition) else nil
		_tweenFade(fadeTargets, LEVEL_UP_FADE_IN_INFO, false)
		TweenService:Create(pop.node, LEVEL_UP_POP_IN_INFO, { Scale = pop.designed }):Play()
		Fireworks.Burst(self._gui)
		self:_rainConfetti(palette)

		task.wait(LEVEL_UP_ARROW_ENTER_SECONDS + LEVEL_UP_ARROW_PAUSE_SECONDS)
		_tweenFade(fadeTargets, LEVEL_UP_FADE_OUT_INFO, true)
		TweenService:Create(pop.node, LEVEL_UP_FADE_OUT_INFO, { Scale = pop.designed * LEVEL_UP_POP_EXIT }):Play()
		task.wait(LEVEL_UP_ARROW_EXIT_SECONDS)

		if stopArrow then
			stopArrow()
		end
		frame.Visible = false
		_setFade(fadeTargets, false)
		pop.node.Scale = pop.designed

		onDone()
	end)
end

function MatchNotificationsQueue:playLevelUpAnimation(newLevel: number)
	self:_playLevelUpFrame(newLevel, LEVEL_UP_TITLE, LEVEL_UP_CONFETTI_COLORS, GameSounds.LevelUp)
end

function MatchNotificationsQueue:playBattlePassLevelUpAnimation(newLevel: number)
	-- El pase se llama FamePass en la UI.
	self:_playLevelUpFrame(
		newLevel,
		BATTLEPASS_LEVEL_UP_TITLE,
		BATTLEPASS_LEVEL_UP_CONFETTI_COLORS,
		GameSounds.FamePassUp
	)
end

-- Con timeout: si el asset cambia de forma, se salta la notificación en vez de colgar la cola.
function MatchNotificationsQueue:_resolvePopup(name: string): GuiObject?
	local container = self:_resolveContainer()
	if not container then
		return nil
	end
	local node = container:WaitForChild(name, POPUP_WAIT_SECONDS)
	if not (node and node:IsA("GuiObject")) then
		warn(`[MatchNotificationsQueue] No se encontró MainFrame.{name}: se salta la notificación`)
		return nil
	end
	return node
end

-- Devuelve false si no hay tarjeta, para que el caller entregue igual lo pendiente.
function MatchNotificationsQueue:_playCompletedCard(
	title: string,
	subtitle: string,
	confettiColors: { Color3 },
	afterShown: (() -> ())?,
	holdSeconds: number?
): boolean
	local frame = self:_resolvePopup("Completed")
	if not frame then
		return false
	end
	_setLabel(frame, "Title", title)
	_setLabel(frame, "Subtitle", subtitle)
	self:_playFrameSlide(frame, "_completedOriginalPosition", confettiColors, 0.4, afterShown, holdSeconds)
	return true
end

-- Hito intermedio → MainFrame.Progress; tier completado → tarjeta Completed.
function MatchNotificationsQueue:playMasteryAnimation(progress: MasteryProgress)
	self:_enqueue(function(onDone)
		GameSounds.play(GameSounds.Notification)
		if progress.isComplete == true then
			self:_playCompletedCard(MASTERY_COMPLETED_TITLE, progress.name, MASTERY_CONFETTI_COLORS)
			onDone()
			return
		end

		local frame = self:_resolvePopup("Progress")
		if not frame then
			onDone()
			return
		end

		local current = math.max(0, math.floor(progress.current))
		local target = math.max(1, math.floor(progress.target))
		local ratio = math.min(1, current / target)

		_setLabel(frame, "Title", progress.name)
		local valueLabel = _findNamed(frame, "Value", "TextLabel") :: TextLabel?
		if valueLabel then
			valueLabel.RichText = true
			valueLabel.Text = UIUtils.formatProgressValue(current, target)
		end

		local itemViewport = _findNamed(frame, "ItemViewport", "ViewportFrame") :: ViewportFrame?
		local previewJanitor: any = if itemViewport then _renderWrapPreview(itemViewport, progress) else nil

		local barNode = _findNamed(frame, "Bar", "GuiObject")
		local fillNode = if barNode then barNode:FindFirstChild("Fill") else nil
		local barFill = if fillNode and fillNode:IsA("GuiObject") then fillNode else nil
		if barFill then
			barFill.Size = _targetFillSize(barFill, 0)
		end

		self:_playFrameSlide(frame, "_progressOriginalPosition", nil, nil, function()
			if barFill then
				TweenService:Create(barFill, MASTERY_BAR_TWEEN_INFO, {
					Size = _targetFillSize(barFill, ratio),
				}):Play()
			end
		end)

		if previewJanitor then
			previewJanitor:Cleanup()
		end
		if itemViewport then
			itemViewport.CurrentCamera = nil
		end

		onDone()
	end)
end

-- Sin `isComplete` no se muestra nada: el progreso ya se ve en MatchHud.Container.Missions.
function MatchNotificationsQueue:playDailyTaskAnimation(progress: DailyTaskProgress)
	if progress.isComplete ~= true then
		return
	end
	self:_enqueue(function(onDone)
		GameSounds.play(GameSounds.Notification)
		local container = self:_resolveContainer()
		local coinsSpawn = if container then _resolveCoinsSpawn(container) else nil
		local rewardCash = math.max(0, math.floor(tonumber(progress.rewardCash) or 0))

		-- Bloquea hasta que aterrizan las monedas.
		local function deliverReward()
			if self._destroyed then
				return
			end
			local deliver = self._onChallengeReward
			if deliver and coinsSpawn and rewardCash > 0 then
				local flightSeconds = deliver(coinsSpawn, rewardCash)
				if type(flightSeconds) == "number" and flightSeconds > 0 then
					task.wait(flightSeconds)
				end
			end
		end

		local shown = self:_playCompletedCard(
			CONTRACT_COMPLETED_TITLE,
			progress.name,
			DAILY_CONFETTI_COLORS,
			deliverReward,
			DAILY_COMPLETE_HOLD_SECONDS
		)
		-- Sin tarjeta se entrega igual: ese cash está reservado (reserveChallengeCash) y
		-- Stats no lo enseñaría por su cuenta.
		if not shown then
			deliverReward()
		end

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
