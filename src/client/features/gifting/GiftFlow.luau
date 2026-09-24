--!strict
--[[
	Flujo de envío de regalos (UserInterface.Gifting). Es agnóstico de quién lo
	abre: el llamante decide desde qué GUI se lanza y le pasa el pack de Robux a
	regalar con `openForProduct(product)`.

	No toca ninguna GUI que no sea la suya. Si el panel que lo abre debe
	ocultarse mientras la lista está en pantalla, ese panel lo hace en su
	callback: `onOpened` al presentar la lista y `onClosed` cuando el flujo se
	retira (botón de cerrar o regalo entregado; `reset()` no lo dispara).

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
	  reintentar; GiftDelivered notifica éxito y cierra el flujo.
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
local GameSounds = require(Client.core.ui.GameSounds)
local Notify = require(Client.core.ui.NotificationController)
local StaggerReveal = require(Client.core.ui.animators.StaggerReveal)

type StoreProductDefinition = StoreProducts.StoreProductDefinition

local AVATAR_THUMB_FORMAT = "rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"
-- Por encima del peor caso del servidor (ViewProfileAsync acotado a 10 s): liberar antes
-- permitiría un segundo envío con el primero aún en vuelo.
local RESPONSE_TIMEOUT = 12
local DELIVERY_TIMEOUT = 15

local REAL_BUTTON_COLOR = Color3.fromRGB(64, 169, 74)
local REAL_SHADOW_COLOR = Color3.fromRGB(81, 255, 0)
local REAL_ICON = AssetIds.Images.GiftRealPlayer

local NPC_BUTTON_COLOR = Color3.fromRGB(128, 128, 128)
local NPC_SHADOW_COLOR = Color3.fromRGB(255, 255, 255)
local NPC_ICON = AssetIds.Images.GiftNpc
-- Los NPCs no muestran su nombre: la fila anuncia que no es un destino válido.
local NPC_LABEL_TEXT = "Not Eligible"

-- La lista representa los huecos de una partida, rellenos con NPCs igual que
-- MatchService al rebalancear. TotalParticipantsTarget no se usa porque el server
-- no lo lee y puede desincronizarse.
local LIST_TARGET_ROWS = GameConfig.TeamSizeTarget * 2

local ROW_REVEAL_STAGGER = 0.03
local ROW_REVEAL_TWEEN = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ROW_PRESS_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ROW_PRESS_FROM = 0.9

export type GiftFlowConfig = {
	menuController: any,
	onOpened: (() -> ())?,
	onClosed: (() -> ())?,
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

-- `UIShadow` puede ser ImageLabel, Frame o modificador (UIStroke / UIDropShadowEffect),
-- y cada uno expone el color en otra propiedad.
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
	self._onOpened = config.onOpened
	self._onClosed = config.onClosed

	self._receiver = nil :: UserEntry?
	self._product = nil :: StoreProductDefinition?
	self._rows = {} :: { { row: GuiObject, janitor: any } }
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

	-- El canvas del ScrollingFrame se configura en Studio (AutomaticCanvasSize/CanvasSize).
	template.Visible = false

	frame.Visible = false

	config.menuController:registerPanel(frame)
	janitor:Add(function()
		config.menuController:unregisterPanel(frame)
	end, true)

	janitor:Add(function()
		self:_clearRows()
	end, true)

	-- CloseBtn es opcional en la GUI: si existe se cablea.
	local closeBtn = container:FindFirstChild("CloseBtn", true)
	if closeBtn and closeBtn:IsA("GuiButton") then
		janitor:Add(closeBtn.Activated:Connect(function()
			self:close()
		end), "Disconnect")
	end

	local function onRosterChanged()
		if self._frame.Visible then
			self:_refreshList(false)
		end
	end
	janitor:Add(Players.PlayerAdded:Connect(onRosterChanged), "Disconnect")
	janitor:Add(Players.PlayerRemoving:Connect(onRosterChanged), "Disconnect")

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

	janitor:Add(Network.Gifting.GiftDelivered.Listen(function(data: any)
		if not self._awaitingPurchase then
			Notify.success("Your gift was delivered!")
			return
		end
		self._awaitingPurchase = false
		self._pendingToken += 1
		-- El receptor real lo dice el servidor; self._receiver es la selección actual de la UI.
		local receiver = self._receiver
		local deliveredTo = Players:GetPlayerByUserId(tonumber(data.receiverUserId) or 0)
		local name = if deliveredTo then deliveredTo.Name
			elseif receiver and tostring(receiver.userId) == data.receiverUserId then receiver.name
			else "your friend"
		Notify.success(`Gift sent to {name}!`)
		if frame.Visible then
			self:close()
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

function GiftFlow:_clearRows()
	for _, record in self._rows do
		record.janitor:Destroy()
		record.row:Destroy()
	end
	table.clear(self._rows)
end

-- Rellena con NPCs hasta LIST_TARGET_ROWS desde el offset fijo de la sesión, dando
-- la vuelta al pool y saltando identidades de jugadores presentes en el servidor.
function GiftFlow:_buildEntries(): { UserEntry }
	local entries = collectServerPlayers()

	local poolSize = #BotNames
	local missing = LIST_TARGET_ROWS - #entries
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
		table.insert(self._rows, { row = row, janitor = rowJanitor })
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
	-- Solo se llega desde _onGiftPressed, que acaba de fijar el receptor.
	local receiver = self._receiver :: UserEntry

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

function GiftFlow:openForProduct(product: StoreProductDefinition)
	self._product = product
	self._receiver = nil
	self._sendPending = false
	self._awaitingPurchase = false
	self._pendingToken += 1

	self:_refreshList(true)

	GameSounds.play(GameSounds.Open)
	self._frame.Visible = true
	if self._onOpened then
		self._onOpened()
	end
end

function GiftFlow:close()
	if self._frame.Visible then
		GameSounds.play(GameSounds.Close)
	end
	self._frame.Visible = false
	if self._onClosed then
		self._onClosed()
	end
end

-- Descarte silencioso para cuando el panel que abrió el flujo se cierra él mismo:
-- no dispara `onClosed` a propósito (ese callback le devuelve el protagonismo al panel).
function GiftFlow:reset()
	self._frame.Visible = false
	self._sendPending = false
	self._pendingToken += 1
end

return GiftFlow
