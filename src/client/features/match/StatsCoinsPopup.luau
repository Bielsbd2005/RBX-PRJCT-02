--!strict
--[[
	Popup de ganancias de cash en partida: `MatchStats.Stats` entra por la
	izquierda, lanza monedas desde `Stats.CoinsSpawn` hacia `Stats.CoinsFrame.Value`
	y suma al total según aterrizan; sale tras HOLD_SECONDS sin ganancias.

	Requisito de Studio: StarterGui.MatchStats (ScreenGui propio, lo enciende
	MatchHud:setEnabled) > Stats (también vale dentro de un Container) >
	CoinsFrame.Value (TextLabel) y CoinsSpawn (ImageLabel, origen y sprite; se oculta).
	Las monedas se clonan en el padre de Stats para que ClipsDescendants no las recorte.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local GameSounds = require(script.Parent.Parent.Parent.core.ui.GameSounds)
local Haptics = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("Haptics"))
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any

local SLIDE_IN_TWEEN_INFO = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OUT_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
-- Contado desde la última ganancia: en un multi-kill el frame no re-entra.
local HOLD_SECONDS = 2.2
local OFFSCREEN_MARGIN_PX = 12
-- Stats puede no haber replicado al construir el HUD, y hasta resolverlo no se
-- puede ocultar.
local PRIME_RETRY_SECONDS = 0.25
local PRIME_TIMEOUT_SECONDS = 10

local CASH_PER_COIN = 5
local COIN_COUNT_MIN = 2
local COIN_COUNT_MAX = 10
local COIN_STAGGER_SECONDS = 0.05
local COIN_ZINDEX_OFFSET = 10
local COIN_BURST_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COIN_FLY_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local COIN_BURST_RADIUS_MIN = 0.6 -- × lado de la moneda
local COIN_BURST_RADIUS_MAX = 1.7
local COIN_SPAWN_SCALE = 0.35
local COIN_LAND_SCALE = 0.55
local COIN_SPIN_MAX = 50 -- grados

local VALUE_POP_TWEEN_INFO = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
local VALUE_POP_SCALE = 1.16

-- `layer` (padre de Stats, donde se clonan las monedas) puede ser el ScreenGui o
-- un Frame Container: la geometría debe funcionar en ambos casos.
type PopupRefs = {
	frame: GuiObject,
	layer: Instance,
	value: TextLabel,
	spawn: ImageLabel,
}

local function _absoluteCenter(node: GuiObject): Vector2
	return node.AbsolutePosition + (node.AbsoluteSize / 2)
end

local function _layerSize(layer: Instance): Vector2
	if layer:IsA("GuiObject") then
		return (layer :: GuiObject).AbsoluteSize
	end
	if layer:IsA("LayerCollector") then
		return (layer :: LayerCollector).AbsoluteSize
	end
	return Vector2.zero
end

-- Un ScreenGui no expone AbsolutePosition y puede estar desplazado por el inset
-- de la topbar: se deduce de un hijo conocido.
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

-- Asume AnchorPoint 0.5,0.5 en el hijo.
local function _localOffset(origin: Vector2, center: Vector2): UDim2
	return UDim2.fromOffset(math.round(center.X - origin.X), math.round(center.Y - origin.Y))
end

local function _offscreenPosition(frame: GuiObject, original: UDim2): UDim2
	local parent = frame.Parent
	local parentWidth = if parent then _layerSize(parent).X else 0
	if parentWidth <= 0 then
		return UDim2.new(-0.6, original.X.Offset, original.Y.Scale, original.Y.Offset)
	end

	local width = frame.AbsoluteSize.X
	local anchorX = frame.AnchorPoint.X
	local scale = (-OFFSCREEN_MARGIN_PX - (width * (1 - anchorX)) - original.X.Offset) / parentWidth
	return UDim2.new(scale, original.X.Offset, original.Y.Scale, original.Y.Offset)
end

-- Las monedas se clonan en el layer y deben superar al frame del que salen, no
-- solo a Stats.
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

local StatsCoinsPopup = {}
StatsCoinsPopup.__index = StatsCoinsPopup

function StatsCoinsPopup.new(matchStatsGui: ScreenGui?): any
	local self = setmetatable({}, StatsCoinsPopup)
	self._gui = matchStatsGui
	self._destroyed = false
	-- hideImmediate/destroy lo suben: los hilos de monedas en vuelo se dan por cancelados.
	self._generation = 0
	self._janitor = Janitor.new()
	self._refs = nil :: PopupRefs?
	self._originalPosition = nil :: UDim2?
	-- "hidden" | "sliding-in" | "shown" | "sliding-out"
	self._state = "hidden"
	self._slideTween = nil :: Tween?
	-- `_displayedCash`: lo que muestra el label; `_targetCash`: al aterrizar todo.
	self._displayedCash = 0
	self._targetCash = 0
	self._pendingCoins = 0
	self._hideAt = 0
	self._hideWatchActive = false
	self:_primeHidden()
	return self
end

-- Perezoso y sin WaitForChild: si Stats falta, el popup es no-op sin bloquear el arranque.
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

	;(spawnNode :: ImageLabel).Visible = false

	local refs: PopupRefs = {
		frame = frame,
		layer = layer,
		value = valueNode :: TextLabel,
		spawn = spawnNode :: ImageLabel,
	}
	self._refs = refs
	self._originalPosition = frame.Position
	frame.Visible = false
	frame.Position = _offscreenPosition(frame, self._originalPosition)
	self:_renderValue()
	return refs
end

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

function StatsCoinsPopup:addCash(delta: number, total: number): number
	return self:_deliver(delta, total, nil)
end

--- Las monedas salen de (y clonan) otro nodo. Devuelve la duración de la animación
--- para que el caller espere antes de retirar su propio popup.
function StatsCoinsPopup:addCashFrom(delta: number, total: number, spawnNode: ImageLabel?): number
	return self:_deliver(delta, total, spawnNode)
end

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
	-- Pendientes desde ya, no al lanzarse: si no, el watch cerraría el frame durante el slide-in.
	self._pendingCoins += count
	self:_startHideWatch()

	local generation = self._generation
	task.spawn(function()
		self:_slideIn()
		if self._destroyed or self._generation ~= generation then
			return
		end
		self:_spawnCoins(count, gained, template, generation)
	end)

	return _flightDuration(count, needsSlideIn)
end

function StatsCoinsPopup:hideImmediate()
	self._generation += 1
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

-- Bloquea hasta que el frame está dentro.
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
		refs.frame.Position = _offscreenPosition(refs.frame, original)
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
		Position = _offscreenPosition(refs.frame, original),
	})
	self._slideTween = tween
	tween:Play()
	tween.Completed:Wait()

	if self._state ~= "sliding-out" then
		return
	end
	self._state = "hidden"
	self._slideTween = nil
	refs.frame.Visible = false
	refs.frame.Position = original
end

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

-- Reparto entero exacto: el redondeo se absorbe moneda a moneda, no al final.
local function _coinShare(total: number, count: number, index: number): number
	local upTo = math.floor((total * index / count) + 0.5)
	local upToPrevious = math.floor((total * (index - 1) / count) + 0.5)
	return upTo - upToPrevious
end

-- `landed` false = camino de fallback: solo cuadra el contador, sin sonido.
function StatsCoinsPopup:_onCoinLanded(share: number, landed: boolean?)
	if landed then
		GameSounds.play(GameSounds.Coin)
		Haptics.play("CoinLand")
	end
	self._pendingCoins = math.max(0, self._pendingCoins - 1)
	self._displayedCash = math.min(self._targetCash, self._displayedCash + share)
	if self._pendingCoins <= 0 then
		-- Cuadra con el total real por si otra fuente de cash cambió el total a la vez.
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

function StatsCoinsPopup:_spawnCoins(count: number, gained: number, template: ImageLabel, generation: number)
	for index = 1, count do
		local share = _coinShare(gained, count, index)
		task.spawn(function()
			if index > 1 then
				task.wait(COIN_STAGGER_SECONDS * (index - 1))
			end
			if self._destroyed or self._generation ~= generation then
				return
			end
			self:_launchCoin(share, template, generation)
		end)
	end
end

function StatsCoinsPopup:_launchCoin(share: number, template: ImageLabel, generation: number)
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
	-- Espera por duración, no por Completed: si el clon se destruye a mitad de
	-- vuelo la señal no es fiable y el hilo quedaría colgado.
	task.wait(COIN_BURST_TWEEN_INFO.Time)

	if self._destroyed or self._generation ~= generation then
		return
	end
	if coin.Parent == nil then
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

	-- Cancelada (hideImmediate ya cuadró el contador) o destruida en vuelo: sin sonido.
	if self._destroyed or self._generation ~= generation then
		return
	end
	if coin.Parent == nil then
		self:_onCoinLanded(share)
		return
	end
	self._janitor:Remove(coin)
	self:_onCoinLanded(share, true)
end

return StatsCoinsPopup
