--!strict
--[[
	StatsCoinsPopup.luau
	Popup de ganancias in-match. Cada vez que el jugador gana cash (kill,
	headshot, asistencia) el frame `MatchHud.Container.Stats` entra deslizando
	desde la izquierda, escupe monedas desde `Stats.CoinsSpawn` hacia
	`Stats.CoinsFrame.Value` y va sumando la ganancia al total conforme cada
	moneda aterriza. Tras un beat sin ganancias nuevas se va por la izquierda.

	Estructura esperada (Stats cuelga de la raíz del ScreenGui, hermano de
	Container; también se acepta dentro de Container):
		Stats.CoinsFrame.Value   TextLabel con el cash total
		Stats.CoinsSpawn         ImageLabel: punto de salida Y sprite de las
		                         monedas (se clona por moneda). Se oculta al
		                         resolverlo, igual que los `Template` de las
		                         fichas de jugador: solo es plantilla + origen.

	El frame arranca OCULTO y solo se ve mientras hay ganancias: entra al ganar
	cash y vuelve a esconderse tras el hold. Las monedas se clonan bajo el PADRE
	de Stats (no dentro), así el ClipsDescendants del frame no las recorta y
	quedan por encima vía ZIndex.

	API:
		StatsCoinsPopup.new(matchHudGui: ScreenGui?)
		:setCash(total: number)             -- sincroniza el label sin animar
		:addCash(delta: number, total: number)
		:addCashFrom(delta, total, spawnNode) -- monedas desde OTRO nodo (p. ej.
		                                      -- Maestry.CoinsSpawn al completar un
		                                      -- desafío); devuelve la duración
		:hideImmediate()
		:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any

-- ── Slide del frame ──────────────────────────────────────────
local SLIDE_IN_TWEEN_INFO = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OUT_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
-- Beat que aguanta en pantalla tras la ÚLTIMA ganancia: en un multi-kill las
-- ganancias encadenan y el frame se queda sin re-entrar (ver _hideAt).
local HOLD_SECONDS = 2.2
local OFFSCREEN_MARGIN_PX = 12
-- El HUD se construye antes de que Stats haya replicado del todo, así que
-- reintentamos resolverlo un rato: hasta que no se resuelve no podemos ocultarlo,
-- y sin kills el frame no debe verse.
local PRIME_RETRY_SECONDS = 0.25
local PRIME_TIMEOUT_SECONDS = 10

-- ── Monedas ──────────────────────────────────────────────────
-- Una moneda por cada CASH_PER_COIN de la ganancia (kill = 10, headshot = +5,
-- asistencia = 5 → entre 2 y 3 monedas en el caso típico), acotado para que un
-- premio gordo no llene la pantalla de clones.
local CASH_PER_COIN = 5
local COIN_COUNT_MIN = 2
local COIN_COUNT_MAX = 10
local COIN_STAGGER_SECONDS = 0.05
local COIN_ZINDEX_OFFSET = 10
-- Coreografía de cada moneda: sale con un "pop" hacia un punto aleatorio
-- alrededor del spawn (creciendo de COIN_SPAWN_SCALE a su tamaño real) y desde
-- ahí acelera hacia el Value, encogiendo al entrar.
local COIN_BURST_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COIN_FLY_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local COIN_BURST_RADIUS_MIN = 0.6 -- × lado de la moneda
local COIN_BURST_RADIUS_MAX = 1.7
local COIN_SPAWN_SCALE = 0.35
local COIN_LAND_SCALE = 0.55
local COIN_SPIN_MAX = 50 -- grados

-- Punch del label al absorber cada moneda (reverses = ida y vuelta).
local VALUE_POP_TWEEN_INFO = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
local VALUE_POP_SCALE = 1.16

-- `layer` es el padre de Stats: un Frame si Stats cuelga de Container, o el
-- propio ScreenGui en el layout actual (Stats es hermano de Container). Ahí es
-- donde se clonan las monedas, así que la geometría tiene que funcionar con los
-- dos casos.
type PopupRefs = {
	frame: GuiObject,
	layer: Instance,
	value: TextLabel,
	spawn: ImageLabel,
}

-- Centro absoluto de un nodo, en píxeles de pantalla.
local function _absoluteCenter(node: GuiObject): Vector2
	return node.AbsolutePosition + (node.AbsoluteSize / 2)
end

-- Tamaño del espacio de coordenadas de `layer` (GuiObject o ScreenGui).
local function _layerSize(layer: Instance): Vector2
	if layer:IsA("GuiObject") then
		return (layer :: GuiObject).AbsoluteSize
	end
	if layer:IsA("LayerCollector") then
		return (layer :: LayerCollector).AbsoluteSize
	end
	return Vector2.zero
end

-- Origen absoluto (esquina superior izquierda) de `layer`. Un ScreenGui no expone
-- AbsolutePosition y además puede estar desplazado por el inset de la topbar, así
-- que lo deducimos de un hijo conocido: absoluta del hijo − su posición local.
local function _layerOrigin(layer: Instance, child: GuiObject): Vector2
	if layer:IsA("GuiObject") then
		return (layer :: GuiObject).AbsolutePosition
	end
	local size = _layerSize(layer)
	local position = child.Position
	local localX = (position.X.Scale * size.X) + position.X.Offset - (child.AnchorPoint.X * child.AbsoluteSize.X)
	local localY = (position.Y.Scale * size.Y) + position.Y.Offset - (child.AnchorPoint.Y * child.AbsoluteSize.Y)
	return child.AbsolutePosition - Vector2.new(localX, localY)
end

-- Posición (en offsets) que deja el centro de un hijo del layer sobre `center`.
-- Asume AnchorPoint 0.5,0.5 en el hijo.
local function _localOffset(origin: Vector2, center: Vector2): UDim2
	return UDim2.fromOffset(math.round(center.X - origin.X), math.round(center.Y - origin.Y))
end

-- Posición del frame justo fuera de la pantalla por un lado u otro, respetando el
-- AnchorPoint y el offset originales: el borde que mira a la pantalla queda a
-- OFFSCREEN_MARGIN_PX del borde. Entra y sale por la izquierda.
local function _offscreenPosition(frame: GuiObject, original: UDim2, side: "right" | "left"): UDim2
	local parent = frame.Parent
	local parentWidth = if parent then _layerSize(parent).X else 0
	if parentWidth <= 0 then
		local fallbackScale = if side == "right" then 1.6 else -0.6
		return UDim2.new(fallbackScale, original.X.Offset, original.Y.Scale, original.Y.Offset)
	end

	local width = frame.AbsoluteSize.X
	local anchorX = frame.AnchorPoint.X
	local scale = if side == "right"
		then (parentWidth + OFFSCREEN_MARGIN_PX + (width * anchorX) - original.X.Offset) / parentWidth
		else (-OFFSCREEN_MARGIN_PX - (width * (1 - anchorX)) - original.X.Offset) / parentWidth
	return UDim2.new(scale, original.X.Offset, original.Y.Scale, original.Y.Offset)
end

-- ZIndex del ancestro de `node` que cuelga directo de `layer` (o el del propio
-- nodo si no lo encuentra). Las monedas se clonan en el layer, así que necesitan
-- superar al frame desde el que salen, no solo al de Stats.
local function _topLevelZIndex(layer: Instance, node: GuiObject): number
	local current: Instance? = node
	while current do
		local parent = current.Parent
		if parent == layer then
			return if current:IsA("GuiObject") then (current :: GuiObject).ZIndex else node.ZIndex
		end
		current = parent
	end
	return node.ZIndex
end

-- Devuelve un UIScale hijo del label (creándolo si no existe).
local function _ensureValueScale(label: TextLabel): UIScale
	local scaleNode = label:FindFirstChildOfClass("UIScale")
	if scaleNode then
		return scaleNode
	end
	local created = Instance.new("UIScale")
	created.Name = "CoinsValueScale"
	created.Scale = 1
	created.Parent = label
	return created
end

-- ── Módulo ───────────────────────────────────────────────────

local StatsCoinsPopup = {}
StatsCoinsPopup.__index = StatsCoinsPopup

function StatsCoinsPopup.new(matchHudGui: ScreenGui?): any
	local self = setmetatable({}, StatsCoinsPopup)
	self._gui = matchHudGui
	self._destroyed = false
	self._janitor = Janitor.new()
	self._refs = nil :: PopupRefs?
	self._originalPosition = nil :: UDim2?
	-- "hidden" | "sliding-in" | "shown" | "sliding-out"
	self._state = "hidden"
	self._slideTween = nil :: Tween?
	-- Cash: `_displayed` es lo que pone el label ahora mismo y `_target` el
	-- total al que llegará cuando aterricen las monedas en vuelo.
	self._displayedCash = 0
	self._targetCash = 0
	self._pendingCoins = 0
	self._hideAt = 0
	self._hideWatchActive = false
	self:_primeHidden()
	return self
end

-- Resolución perezosa: el frame Stats puede no haber replicado todavía cuando se
-- construye el HUD, y si falta (place antiguo) el popup se degrada a no-op en vez
-- de bloquear el arranque con un WaitForChild.
function StatsCoinsPopup:_resolveRefs(): PopupRefs?
	if self._refs then
		return self._refs
	end
	local gui = self._gui
	if not gui or self._destroyed then
		return nil
	end

	local container = gui:FindFirstChild("Container")
	local statsNode = (if container then container:FindFirstChild("Stats") else nil) or gui:FindFirstChild("Stats")
	if not statsNode or not statsNode:IsA("GuiObject") then
		return nil
	end
	local frame = statsNode :: GuiObject

	local coinsFrame = frame:FindFirstChild("CoinsFrame")
	local valueNode = if coinsFrame then coinsFrame:FindFirstChild("Value") else nil
	local spawnNode = frame:FindFirstChild("CoinsSpawn")
	local layer = frame.Parent
	if
		not valueNode
		or not valueNode:IsA("TextLabel")
		or not spawnNode
		or not spawnNode:IsA("ImageLabel")
		or not layer
	then
		return nil
	end

	-- CoinsSpawn solo marca el origen y presta su sprite a los clones.
	;(spawnNode :: ImageLabel).Visible = false

	local refs: PopupRefs = {
		frame = frame,
		layer = layer,
		value = valueNode :: TextLabel,
		spawn = spawnNode :: ImageLabel,
	}
	self._refs = refs
	self._originalPosition = frame.Position
	-- Sin ganancias no hay popup: nace oculto y esperando fuera por la izquierda.
	frame.Visible = false
	frame.Position = _offscreenPosition(frame, self._originalPosition, "left")
	self:_renderValue()
	return refs
end

-- Resuelve cuanto antes (reintentando mientras Stats replica) para dejar el frame
-- oculto sin esperar a la primera lectura de cash.
function StatsCoinsPopup:_primeHidden()
	if self:_resolveRefs() then
		return
	end
	task.spawn(function()
		local deadline = os.clock() + PRIME_TIMEOUT_SECONDS
		while not self._destroyed and os.clock() < deadline do
			task.wait(PRIME_RETRY_SECONDS)
			if self:_resolveRefs() then
				return
			end
		end
	end)
end

function StatsCoinsPopup:_renderValue()
	local refs = self._refs
	if refs then
		refs.value.Text = UIUtils.formatCashAmount(math.max(0, math.floor(self._displayedCash)))
	end
end

-- ── API pública ──────────────────────────────────────────────

--- Sincroniza el total sin animar (arranque de partida, o bajadas de cash).
--- Con monedas en vuelo solo mueve el objetivo: el label lo alcanzan ellas.
function StatsCoinsPopup:setCash(total: number)
	local cash = math.max(0, math.floor(if type(total) == "number" then total else 0))
	self._targetCash = cash
	if self._pendingCoins > 0 then
		return
	end
	self._displayedCash = cash
	self:_resolveRefs()
	self:_renderValue()
end

--- Ganancia de `delta` que deja el total en `total`: entra el frame (si no está),
--- salen las monedas desde `Stats.CoinsSpawn` y el label sube según aterrizan.
function StatsCoinsPopup:addCash(delta: number, total: number): number
	return self:_deliver(delta, total, nil)
end

--- Igual que addCash pero las monedas salen de OTRO nodo de la interfaz (su
--- imagen es la que se clona), p. ej. `Maestry.CoinsSpawn` cuando se completa un
--- desafío diario. Devuelve cuánto dura la animación, para que el caller pueda
--- esperar antes de retirar su propio popup.
function StatsCoinsPopup:addCashFrom(delta: number, total: number, spawnNode: ImageLabel?): number
	return self:_deliver(delta, total, spawnNode)
end

-- Duración aproximada de una tanda de monedas (para el valor devuelto arriba).
local function _flightDuration(count: number, needsSlideIn: boolean): number
	local slide = if needsSlideIn then SLIDE_IN_TWEEN_INFO.Time else 0
	return slide
		+ (COIN_STAGGER_SECONDS * math.max(0, count - 1))
		+ COIN_BURST_TWEEN_INFO.Time
		+ COIN_FLY_TWEEN_INFO.Time
end

function StatsCoinsPopup:_deliver(delta: number, total: number, spawnNode: ImageLabel?): number
	if self._destroyed then
		return 0
	end
	local gained = math.max(0, math.floor(if type(delta) == "number" then delta else 0))
	local cash = math.max(0, math.floor(if type(total) == "number" then total else 0))
	self._targetCash = cash

	local refs = self:_resolveRefs()
	if not refs or gained <= 0 then
		self:setCash(cash)
		return 0
	end

	local template = if spawnNode and spawnNode.Parent then spawnNode else refs.spawn
	local needsSlideIn = self._state ~= "shown"
	self._hideAt = os.clock() + HOLD_SECONDS
	local count = math.clamp(math.floor(gained / CASH_PER_COIN + 0.5), COIN_COUNT_MIN, COIN_COUNT_MAX)
	-- Las monedas cuentan como pendientes desde YA (no cuando se lanzan): así el
	-- watch de salida no puede cerrar el frame mientras esperamos el slide-in.
	self._pendingCoins += count
	self:_startHideWatch()

	task.spawn(function()
		self:_slideIn()
		if self._destroyed then
			return
		end
		self:_spawnCoins(count, gained, template)
	end)

	return _flightDuration(count, needsSlideIn)
end

--- Corta cualquier animación y deja el frame fuera de pantalla (fin de partida,
--- HUD deshabilitado). El total queda sincronizado en el label.
function StatsCoinsPopup:hideImmediate()
	self._janitor:Cleanup()
	self._pendingCoins = 0
	self._hideAt = 0
	if self._slideTween then
		self._slideTween:Cancel()
		self._slideTween = nil
	end
	self._state = "hidden"

	local refs = self._refs
	if refs and self._originalPosition then
		refs.frame.Visible = false
		refs.frame.Position = self._originalPosition
	end
	self._displayedCash = self._targetCash
	self:_renderValue()
end

function StatsCoinsPopup:destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._slideTween then
		self._slideTween:Cancel()
		self._slideTween = nil
	end
	if self._janitor then
		self._janitor:Destroy()
		self._janitor = nil
	end
	self._refs = nil
end

-- ── Slide del frame ──────────────────────────────────────────

-- Bloquea hasta que el frame está dentro (entra por la IZQUIERDA). Si ya hay un
-- slide-in en curso (dos ganancias seguidas) espera a ese en vez de reiniciarlo;
-- si estaba saliendo, cancela la salida y vuelve a entrar desde donde esté.
function StatsCoinsPopup:_slideIn()
	local refs = self._refs
	local original = self._originalPosition
	if not refs or not original or self._destroyed then
		return
	end

	if self._state == "shown" then
		return
	end
	if self._state == "sliding-in" then
		local pending = self._slideTween
		if pending then
			pending.Completed:Wait()
		end
		return
	end
	if self._state == "sliding-out" then
		local outTween = self._slideTween
		if outTween then
			outTween:Cancel()
		end
	elseif self._state == "hidden" then
		refs.frame.Position = _offscreenPosition(refs.frame, original, "left")
	end

	self._state = "sliding-in"
	refs.frame.Visible = true
	local tween = TweenService:Create(refs.frame, SLIDE_IN_TWEEN_INFO, { Position = original })
	self._slideTween = tween
	tween:Play()
	tween.Completed:Wait()

	if self._state == "sliding-in" then
		self._state = "shown"
		self._slideTween = nil
	end
end

function StatsCoinsPopup:_slideOut()
	local refs = self._refs
	local original = self._originalPosition
	if not refs or not original or self._destroyed or self._state ~= "shown" then
		return
	end

	self._state = "sliding-out"
	local tween = TweenService:Create(refs.frame, SLIDE_OUT_TWEEN_INFO, {
		Position = _offscreenPosition(refs.frame, original, "left"),
	})
	self._slideTween = tween
	tween:Play()
	tween.Completed:Wait()

	if self._state ~= "sliding-out" then
		-- Entró una ganancia nueva y _slideIn se apropió del frame.
		return
	end
	self._state = "hidden"
	self._slideTween = nil
	refs.frame.Visible = false
	refs.frame.Position = original
end

-- Un único bucle vivo mientras el frame está en pantalla: sale por la izquierda
-- cuando pasa el hold desde la última ganancia y no queda ninguna moneda en vuelo.
function StatsCoinsPopup:_startHideWatch()
	if self._hideWatchActive or self._destroyed then
		return
	end
	self._hideWatchActive = true

	task.spawn(function()
		while not self._destroyed do
			local remaining = self._hideAt - os.clock()
			if remaining <= 0 and self._pendingCoins <= 0 then
				break
			end
			task.wait(if remaining > 0 then math.min(remaining, 0.25) else 0.1)
		end
		self._hideWatchActive = false
		if not self._destroyed then
			self:_slideOut()
		end
	end)
end

-- ── Monedas ──────────────────────────────────────────────────

-- Reparto entero exacto de `total` entre `count` monedas (las diferencias por
-- redondeo se absorben moneda a moneda, no al final).
local function _coinShare(total: number, count: number, index: number): number
	local upTo = math.floor((total * index / count) + 0.5)
	local upToPrevious = math.floor((total * (index - 1) / count) + 0.5)
	return upTo - upToPrevious
end

function StatsCoinsPopup:_onCoinLanded(share: number)
	self._pendingCoins = math.max(0, self._pendingCoins - 1)
	self._displayedCash = math.min(self._targetCash, self._displayedCash + share)
	if self._pendingCoins <= 0 then
		-- Última moneda: cuadra el label con el total real por si el delta y las
		-- monedas no sumaban exactamente (p. ej. otra fuente de cash a la vez).
		self._displayedCash = self._targetCash
	end
	self:_renderValue()

	local refs = self._refs
	if refs then
		local scaleNode = _ensureValueScale(refs.value)
		scaleNode.Scale = 1
		TweenService:Create(scaleNode, VALUE_POP_TWEEN_INFO, { Scale = VALUE_POP_SCALE }):Play()
	end
end

function StatsCoinsPopup:_spawnCoins(count: number, gained: number, template: ImageLabel)
	local refs = self._refs
	if not refs then
		-- Sin frame no hay monedas que lanzar: saldamos los pendientes para que el
		-- watch de salida no se quede esperando a un vuelo que nunca ocurre.
		self._pendingCoins = math.max(0, self._pendingCoins - count)
		self._displayedCash = self._targetCash
		return
	end

	for index = 1, count do
		local share = _coinShare(gained, count, index)
		task.spawn(function()
			if index > 1 then
				task.wait(COIN_STAGGER_SECONDS * (index - 1))
			end
			if self._destroyed then
				return
			end
			self:_launchCoin(share, template)
		end)
	end
end

-- Clona el nodo de spawn (el propio CoinsSpawn de Stats, o el que pase el caller),
-- lo lanza en dos tiempos (pop + vuelo al Value) y suma su parte al aterrizar.
-- Cada moneda es un clon suelto trackeado en el janitor, así un destroy() a mitad
-- de vuelo no deja imágenes colgando en el HUD.
function StatsCoinsPopup:_launchCoin(share: number, template: ImageLabel)
	local refs = self._refs
	if not refs or self._destroyed or not template.Parent then
		self:_onCoinLanded(share)
		return
	end

	local layer = refs.layer
	local layerOrigin = _layerOrigin(layer, refs.frame)
	local coinSize = template.AbsoluteSize
	local startCenter = _absoluteCenter(template)
	local targetCenter = _absoluteCenter(refs.value)

	local coin = template:Clone()
	coin.Name = "CoinFx"
	coin.AnchorPoint = Vector2.new(0.5, 0.5)
	coin.Rotation = 0
	-- Por encima tanto del frame de Stats como del popup del que salen.
	coin.ZIndex = math.max(refs.frame.ZIndex, _topLevelZIndex(layer, template)) + COIN_ZINDEX_OFFSET
	coin.Size = UDim2.fromOffset(
		math.round(coinSize.X * COIN_SPAWN_SCALE),
		math.round(coinSize.Y * COIN_SPAWN_SCALE)
	)
	coin.Position = _localOffset(layerOrigin, startCenter)
	coin.Visible = true
	coin.Parent = layer
	self._janitor:Add(coin, "Destroy", coin)

	local burstAngle = math.random() * math.pi * 2
	local burstRadius = coinSize.X
		* (COIN_BURST_RADIUS_MIN + (math.random() * (COIN_BURST_RADIUS_MAX - COIN_BURST_RADIUS_MIN)))
	local burstCenter = startCenter + (Vector2.new(math.cos(burstAngle), math.sin(burstAngle)) * burstRadius)

	local burst = TweenService:Create(coin, COIN_BURST_TWEEN_INFO, {
		Position = _localOffset(layerOrigin, burstCenter),
		Size = UDim2.fromOffset(math.round(coinSize.X), math.round(coinSize.Y)),
		Rotation = ((math.random() * 2) - 1) * COIN_SPIN_MAX,
	})
	burst:Play()
	-- Esperamos por duración y no por `Completed`: un hideImmediate/destroy a
	-- mitad de vuelo destruye el clon, y ahí la señal del tween ya no es fiable
	-- (dejaría el hilo colgado para siempre).
	task.wait(COIN_BURST_TWEEN_INFO.Time)

	if self._destroyed or coin.Parent == nil then
		self:_onCoinLanded(share)
		return
	end

	local fly = TweenService:Create(coin, COIN_FLY_TWEEN_INFO, {
		Position = _localOffset(layerOrigin, targetCenter),
		Size = UDim2.fromOffset(
			math.round(coinSize.X * COIN_LAND_SCALE),
			math.round(coinSize.Y * COIN_LAND_SCALE)
		),
		Rotation = 0,
	})
	fly:Play()
	task.wait(COIN_FLY_TWEEN_INFO.Time)

	if self._destroyed then
		return
	end
	if coin.Parent ~= nil then
		self._janitor:Remove(coin)
	end
	self:_onCoinLanded(share)
end

return StatsCoinsPopup
