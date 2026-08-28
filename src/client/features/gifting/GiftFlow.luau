--!strict
--[[
	GiftFlow.luau  (Client Feature Library — Gifting)

	Flujo de envío de regalos (UserInterface.Gifting). Es agnóstico de quién lo
	abre: el llamante decide desde qué GUI se lanza y le pasa el pack de Robux a
	regalar con `openForProduct(product)`.

	No toca ninguna GUI que no sea la suya. Si el panel que lo abre debe
	ocultarse mientras la lista está en pantalla, ese panel lo hace en su
	callback: `onOpened` al presentar la lista y `onClosed` cuando el flujo se
	retira (botón de cerrar, regalo entregado o `reset()`).

	Lista los jugadores del servidor. Cuando hay pocos jugadores reales la lista
	se rellena con NPCs (identidades de `BotNames`) para que nunca se vea vacía;
	los NPCs NO son regalables — su botón Gift se pinta en gris y con otro icono.

	Estructura GUI:
		UserInterface.Gifting
		  Container
		    Divider
		    ScrollingFrame              ← canvas automático según contenido
		      UIListLayout
		      Template                  ← fila de jugador
		        Thumbnail               ← ImageLabel (headshot)
		        Name                    ← TextLabel (displayName / nombre del NPC)
		        Gift                    ← botón de envío
		          Icon                  ← ImageLabel (glifo según real/NPC)
		          UIShadow              ← sombra teñida según real/NPC

	Flujo de red (Network.Gifting):
	  SendGift → SendResponse (validación server-side; success ⇒ el server lanza
	  el prompt de compra) → [compra Robux] → GiftDelivered (regalo entregado).
	  Validación fallida o prompt cancelado dejan el frame abierto para
	  reintentar; GiftDelivered notifica éxito, cierra el flujo y avisa al
	  feature (onDelivered).
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Network = require(Shared.networking.Network)
local StoreProducts = require(Shared.constants.StoreProducts)
local BotNames = require(Shared.constants.BotNames)
local GameConfig = require(Shared.GameConfig)
local AssetIds = require(Shared.constants.AssetIds)
local Notify = require(Client.core.ui.NotificationController)
local StaggerReveal = require(Client.core.ui.animators.StaggerReveal)

type StoreProductDefinition = StoreProducts.StoreProductDefinition

local AVATAR_THUMB_FORMAT = "rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"
local RESPONSE_TIMEOUT = 5
local DELIVERY_TIMEOUT = 15

-- Estados del botón Gift de cada fila. Los NPCs comparten la fila pero se
-- pintan en gris con otro icono: no son un destino válido de regalo.
local REAL_BUTTON_COLOR = Color3.fromRGB(64, 169, 74)
local REAL_SHADOW_COLOR = Color3.fromRGB(81, 255, 0)
local REAL_ICON = AssetIds.Images.GiftRealPlayer

local NPC_BUTTON_COLOR = Color3.fromRGB(128, 128, 128)
local NPC_SHADOW_COLOR = Color3.fromRGB(255, 255, 255)
local NPC_ICON = AssetIds.Images.GiftNpc
-- Los NPCs no muestran su nombre: la fila anuncia que no es un destino válido.
local NPC_LABEL_TEXT = "Not Eligible"

-- La lista representa los huecos de una partida: los que no cubren jugadores
-- reales se rellenan con NPCs, igual que hace MatchService al rebalancear
-- (TeamSizeTarget por equipo, dos equipos). No se usa TotalParticipantsTarget
-- porque hoy nadie lo lee en el server y puede desincronizarse.
local LIST_TARGET_ROWS = GameConfig.TeamSizeTarget * 2

local ROW_REVEAL_STAGGER = 0.03
local ROW_REVEAL_TWEEN = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ROW_PRESS_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ROW_PRESS_FROM = 0.9

export type GiftFlowConfig = {
	menuController: any,
	-- Se invocan al presentar y al retirar la lista, para que el panel que abre
	-- el flujo gestione su propia visibilidad sin que GiftFlow la conozca.
	onOpened: (() -> ())?,
	onClosed: (() -> ())?,
	onDelivered: (() -> ())?,
}

type UserEntry = {
	userId: number,
	name: string,
	thumbnail: string,
	isNpc: boolean,
}

local GiftFlow = {}
GiftFlow.__index = GiftFlow

local function ensureScale(node: GuiObject): UIScale
	local named = node:FindFirstChild("InteractiveScale")
	if named and named:IsA("UIScale") then
		return named
	end
	local anyClass = node:FindFirstChildOfClass("UIScale")
	if anyClass then
		return anyClass
	end
	local created = Instance.new("UIScale")
	created.Name = "InteractiveScale"
	created.Scale = 1
	created.Parent = node
	return created
end

local function popScale(node: GuiObject, info: TweenInfo, from: number): Tween
	local scale = ensureScale(node)
	scale.Scale = from
	local tween = TweenService:Create(scale, info, { Scale = 1 })
	tween:Play()
	return tween
end

-- `UIShadow` puede ser un ImageLabel, un Frame, o un modificador de UI
-- (UIStroke / UIDropShadowEffect); cada uno expone el color en otra propiedad.
-- Los modificadores usan `Color`, así que ese es el último recurso.
local function applyTint(inst: Instance?, color: Color3): ()
	if not inst then
		return
	end
	if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
		inst.ImageColor3 = color
		return
	end
	if inst:IsA("GuiObject") then
		inst.BackgroundColor3 = color
		return
	end
	local target = inst :: any
	pcall(function()
		target.Color = color
	end)
end

-- Las identidades del pool son usuarios reales de Roblox. Si uno de ellos está
-- en el servidor (incluido el local player), su identidad no puede usarse como
-- relleno: aparecería dos veces, una regalable y otra como "Not Eligible".
local function isIdentityTakenByRealPlayer(source: BotNames.BotIdentity): boolean
	for _, player in Players:GetPlayers() do
		if player.UserId == source.userId then
			return true
		end
		if player.Name:lower() == source.name:lower()
			or player.DisplayName:lower() == source.name:lower() then
			return true
		end
	end
	return false
end

-- Jugadores reales del servidor, sin el local player, ordenados por nombre.
local function collectServerPlayers(): { UserEntry }
	local entries: { UserEntry } = {}
	local localPlayer = Players.LocalPlayer

	for _, other in Players:GetPlayers() do
		if other == localPlayer then
			continue
		end
		table.insert(entries, {
			userId = other.UserId,
			name = if other.DisplayName ~= "" then other.DisplayName else other.Name,
			thumbnail = string.format(AVATAR_THUMB_FORMAT, other.UserId),
			isNpc = false,
		})
	end

	table.sort(entries, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return entries
end

function GiftFlow.new(config: GiftFlowConfig, janitor: any)
	local self = setmetatable({}, GiftFlow)
	self._janitor = janitor
	self._onOpened = config.onOpened
	self._onClosed = config.onClosed
	self._onDelivered = config.onDelivered

	self._receiver = nil :: UserEntry?
	self._product = nil :: StoreProductDefinition?
	self._rows = {} :: { { row: GuiObject, entry: UserEntry, janitor: any } }
	self._sendPending = false
	self._awaitingPurchase = false
	self._pendingToken = 0

	-- Offset fijo por sesión: los NPCs de relleno no deben barajarse cada vez
	-- que se abre el panel.
	self._npcOffset = if #BotNames > 0 then math.random(1, #BotNames) else 1

	self._reveal = StaggerReveal.new({
		staggerDelay = ROW_REVEAL_STAGGER,
		tweenInfo = ROW_REVEAL_TWEEN,
		startScale = 0,
	})
	janitor:Add(self._reveal, "Destroy")

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui

	local frame = uiGui:WaitForChild("Gifting") :: Frame
	self._frame = frame

	local container = frame:WaitForChild("Container") :: Frame

	local scrolling = container:WaitForChild("ScrollingFrame") :: ScrollingFrame
	local template = scrolling:WaitForChild("Template") :: GuiObject
	self._scrolling = scrolling
	self._template = template

	-- El ScrollingFrame se configura en Studio (AutomaticCanvasSize/CanvasSize);
	-- aquí solo se ocultan la plantilla y se parentean las filas.
	template.Visible = false

	frame.Visible = false

	config.menuController:registerPanel(frame)
	janitor:Add(function()
		config.menuController:unregisterPanel(frame)
	end, true)

	janitor:Add(function()
		self:_clearRows()
	end, true)

	-- ── Wiring ───────────────────────────────────────────────
	-- El template no trae CloseBtn propio; si la GUI lo añade en el futuro se
	-- cablea solo.
	local closeBtn = container:FindFirstChild("CloseBtn", true)
	if closeBtn and closeBtn:IsA("GuiButton") then
		janitor:Add(closeBtn.Activated:Connect(function()
			self:close()
		end), "Disconnect")
	end

	-- La lista refleja quién está en el servidor: repintar al entrar/salir.
	local function onRosterChanged()
		if self._frame.Visible then
			self:_refreshList(false)
		end
	end
	janitor:Add(Players.PlayerAdded:Connect(onRosterChanged), "Disconnect")
	janitor:Add(Players.PlayerRemoving:Connect(onRosterChanged), "Disconnect")

	-- ── Red ──────────────────────────────────────────────────
	janitor:Add(Network.Gifting.SendResponse.Listen(function(data: any)
		if not self._sendPending then
			return
		end
		self._sendPending = false
		self._pendingToken += 1
		if data.success then
			self._awaitingPurchase = true
		else
			local message = if data.message ~= "" then data.message else "That gift couldn't be sent."
			Notify.warning(message)
		end
	end), true)

	janitor:Add(Network.Gifting.GiftDelivered.Listen(function(_data: any)
		if not self._awaitingPurchase then
			Notify.success("Your gift was delivered!")
			return
		end
		self._awaitingPurchase = false
		self._pendingToken += 1
		local receiver = self._receiver
		local name = if receiver then receiver.name else "your friend"
		Notify.success(`Gift sent to {name}!`)
		if frame.Visible then
			self:close()
		end
		if self._onDelivered then
			self._onDelivered()
		end
	end), true)

	janitor:Add(MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, purchased: boolean)
		if userId ~= player.UserId or not self._awaitingPurchase then
			return
		end
		local product = self._product
		if product and productId ~= product.ProductId then
			return
		end
		if purchased then
			self._pendingToken += 1
			local token = self._pendingToken
			task.delay(DELIVERY_TIMEOUT, function()
				if self._awaitingPurchase and self._pendingToken == token then
					self._awaitingPurchase = false
				end
			end)
		else
			self._awaitingPurchase = false
		end
	end), "Disconnect")

	return self
end

-- ────────────────────────────────────────────────────────────
-- LISTA DE JUGADORES
-- ────────────────────────────────────────────────────────────

function GiftFlow:_clearRows()
	for _, record in self._rows do
		record.janitor:Destroy()
		record.row:Destroy()
	end
	table.clear(self._rows)
end

-- Rellena la lista con NPCs hasta LIST_TARGET_ROWS, empezando en el offset fijo
-- de la sesión y dando la vuelta al pool.
function GiftFlow:_buildEntries(): { UserEntry }
	local entries = collectServerPlayers()

	local poolSize = #BotNames
	local missing = LIST_TARGET_ROWS - #entries
	-- Recorre el pool desde el offset de la sesión saltando las identidades que
	-- pertenezcan a alguien presente en el servidor, hasta cubrir los huecos o
	-- agotar el pool.
	for i = 0, poolSize - 1 do
		if missing <= 0 then
			break
		end
		local identity = BotNames[(self._npcOffset + i - 1) % poolSize + 1]
		if not isIdentityTakenByRealPlayer(identity) then
			table.insert(entries, {
				-- Los NPCs no son destino válido: el server rechaza cualquier
				-- userId no positivo, así que nunca se envía nada por ellos.
				userId = 0,
				name = identity.name,
				thumbnail = identity.image,
				isNpc = true,
			})
			missing -= 1
		end
	end

	return entries
end

function GiftFlow:_applyEntryToNode(node: GuiObject, entry: UserEntry)
	local thumbnail = node:FindFirstChild("Thumbnail")
	if thumbnail and thumbnail:IsA("ImageLabel") then
		thumbnail.Image = entry.thumbnail
	end

	local nameLabel = node:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = if entry.isNpc then NPC_LABEL_TEXT else entry.name
	end

	local giftNode = node:FindFirstChild("Gift")
	if giftNode and giftNode:IsA("GuiObject") then
		giftNode.BackgroundColor3 = if entry.isNpc then NPC_BUTTON_COLOR else REAL_BUTTON_COLOR

		local icon = giftNode:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			icon.Image = if entry.isNpc then NPC_ICON else REAL_ICON
		end

		applyTint(giftNode:FindFirstChild("UIShadow"), if entry.isNpc then NPC_SHADOW_COLOR else REAL_SHADOW_COLOR)
	end
end

function GiftFlow:_populate(entries: { UserEntry }, animate: boolean?)
	self:_clearRows()

	for index, entry in entries do
		local row = self._template:Clone() :: GuiObject
		row.Name = entry.name
		row.LayoutOrder = index
		self:_applyEntryToNode(row, entry)

		local rowJanitor = Janitor.new()
		local giftNode = row:FindFirstChild("Gift")
		if giftNode and giftNode:IsA("GuiButton") then
			rowJanitor:Add(giftNode.Activated:Connect(function()
				self:_onGiftPressed(entry, giftNode)
			end), "Disconnect")
		end

		row.Visible = true
		row.Parent = self._scrolling
		table.insert(self._rows, { row = row, entry = entry, janitor = rowJanitor })
	end

	local visibleRows: { GuiObject } = {}
	for _, record in self._rows do
		table.insert(visibleRows, record.row)
	end
	self._reveal:setItems(visibleRows)
	if animate then
		self._reveal:play()
	end
end

function GiftFlow:_refreshList(animate: boolean?)
	self:_populate(self:_buildEntries(), animate)
end

-- ────────────────────────────────────────────────────────────
-- ENVÍO
-- ────────────────────────────────────────────────────────────

function GiftFlow:_onGiftPressed(entry: UserEntry, button: GuiObject)
	popScale(button, ROW_PRESS_TWEEN, ROW_PRESS_FROM)

	if entry.isNpc then
		Notify.warning("You can't send a gift to that player.")
		return
	end

	self._receiver = entry
	self:_onSend()
end

function GiftFlow:_onSend()
	if not self._product then
		return
	end
	if self._sendPending or self._awaitingPurchase then
		return
	end
	local receiver = self._receiver
	if not receiver then
		Notify.warning("Select a player to send the gift to.")
		return
	end

	self._sendPending = true
	self._pendingToken += 1
	local token = self._pendingToken
	task.delay(RESPONSE_TIMEOUT, function()
		if self._sendPending and self._pendingToken == token then
			self._sendPending = false
			Notify.warning("No response from the server. Try again.")
		end
	end)

	Network.Gifting.SendGift.Send({
		receiverUserId = tostring(receiver.userId),
		productId = (self._product :: StoreProductDefinition).ProductId,
	})
end

-- ────────────────────────────────────────────────────────────
-- APERTURA / CIERRE
-- ────────────────────────────────────────────────────────────

function GiftFlow:openForProduct(product: StoreProductDefinition)
	self._product = product
	self._receiver = nil
	self._sendPending = false
	self._awaitingPurchase = false
	self._pendingToken += 1

	self:_refreshList(true)

	self._frame.Visible = true
	if self._onOpened then
		self._onOpened()
	end
end

function GiftFlow:close()
	self._frame.Visible = false
	if self._onClosed then
		self._onClosed()
	end
end

-- Descarte silencioso: lo llama el panel que abre el flujo cuando él mismo se
-- está cerrando. No dispara `onClosed` a propósito — ese callback existe para
-- devolverle el protagonismo al panel, y aquí el panel se va con nosotros.
function GiftFlow:reset()
	self._frame.Visible = false
	self._sendPending = false
	self._pendingToken += 1
end

return GiftFlow
