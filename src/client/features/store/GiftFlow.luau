--!strict
--[[
	GiftFlow.luau  (Client Feature Library — Store)

	Flujo de envío de regalos (UserInterface.Gifting). Se abre desde el Store al
	pulsar el botón "Gift" de un pack de Robux concreto (Store.CashPage.<Row>.
	<Pack>.Gift): el Store se oculta y este frame toma el relevo. CloseBtn vuelve
	al Store.

	Estructura GUI:
		UserInterface.Gifting
		  Container
		    Friends
		      Container
		        Header
		          CloseBtn                   ← vuelve al Store
		        Search
		          TextBox                    ← filtro en vivo
		        ScrollingFrame               ← canvas automático según contenido
		          Template                   ← fila de amigo: Icon/Username/DisplayName/Status
		    Action                           ← visible SOLO con un amigo seleccionado
		      Container
		        Contents
		          Gift
		            Name / Price             ← qué se regala y su precio
		          Friend                     ← amigo elegido: Icon/Username/DisplayName
		        Gift                         ← botón: valida y lanza el envío

	Flujo de red (Network.Gifting):
	  SendGift → SendResponse (validación server-side; success ⇒ el server lanza
	  el prompt de compra) → [compra Robux] → GiftDelivered (regalo entregado).
	  Validación fallida o prompt cancelado dejan el frame abierto para
	  reintentar; GiftDelivered notifica éxito, vuelve al Store y avisa al
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
local Notify = require(Client.core.ui.NotificationController)
local UIUtils = require(Client.core.ui.UIUtils)
local StaggerReveal = require(Client.core.ui.animators.StaggerReveal)

type StoreProductDefinition = StoreProducts.StoreProductDefinition

local AVATAR_THUMB_FORMAT = "rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"
local STATUS_ONLINE_TEXT = "· Online"
local STATUS_OFFLINE_TEXT = "· Offline"
local STATUS_ONLINE_COLOR = Color3.fromRGB(114, 255, 114)
local STATUS_OFFLINE_COLOR = Color3.fromRGB(255, 255, 255)
local GIFT_NAME_FORMAT = "%s Cash"
local PRICE_FORMAT = "\u{E002}%d"
local RESPONSE_TIMEOUT = 5
local DELIVERY_TIMEOUT = 15
local FRIENDS_CACHE_TTL = 60

local ROW_REVEAL_STAGGER = 0.03
local ROW_REVEAL_TWEEN = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ROW_SELECT_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ROW_SELECT_FROM = 0.9
local CARD_SELECT_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CARD_SELECT_FROM = 0.82

export type GiftFlowConfig = {
	menuController: any,
	storeFrame: GuiObject,
	onDelivered: (() -> ())?,
}

type UserEntry = {
	userId: number,
	username: string,
	displayName: string,
	online: boolean,
}

local GiftFlow = {}
GiftFlow.__index = GiftFlow

local function bindRowClick(row: GuiObject, janitor: any, callback: () -> ()): ()
	if row:IsA("GuiButton") then
		janitor:Add(row.Activated:Connect(callback), "Disconnect")
		return
	end
	local button = row:FindFirstChildWhichIsA("GuiButton", true)
	if button then
		janitor:Add(button.Activated:Connect(callback), "Disconnect")
		return
	end
	row.Active = true
	janitor:Add(row.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			callback()
		end
	end), "Disconnect")
end

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

local function fetchFriendEntries(userId: number, isStale: () -> boolean): { UserEntry }
	local entries: { UserEntry } = {}

	local inServer: { [number]: boolean } = {}
	for _, other in Players:GetPlayers() do
		inServer[other.UserId] = true
	end

	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(userId)
	end)
	if not ok or not pages then
		return entries
	end

	while not isStale() do
		for _, item in pages:GetCurrentPage() do
			table.insert(entries, {
				userId = item.Id,
				username = item.Username,
				displayName = if item.DisplayName and item.DisplayName ~= "" then item.DisplayName else item.Username,
				online = item.IsOnline == true or inServer[item.Id] == true,
			})
		end
		if pages.IsFinished then
			break
		end
		local advanced = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			break
		end
	end

	table.sort(entries, function(a, b)
		if a.online ~= b.online then
			return a.online
		end
		return a.displayName:lower() < b.displayName:lower()
	end)
	return entries
end

function GiftFlow.new(config: GiftFlowConfig, janitor: any)
	local self = setmetatable({}, GiftFlow)
	self._janitor = janitor
	self._storeFrame = config.storeFrame
	self._onDelivered = config.onDelivered

	self._receiver = nil :: UserEntry?
	self._product = nil :: StoreProductDefinition?
	self._rows = {} :: { { row: GuiObject, entry: UserEntry, janitor: any } }
	self._sendPending = false
	self._awaitingPurchase = false
	self._pendingToken = 0
	self._friendsCache = nil :: { UserEntry }?
	self._friendsFetchedAt = 0
	self._friendsFetchToken = 0

	self._reveal = StaggerReveal.new({
		staggerDelay = ROW_REVEAL_STAGGER,
		tweenInfo = ROW_REVEAL_TWEEN,
		startScale = 0,
	})
	janitor:Add(self._reveal, "Destroy")
	self._cardTween = nil :: Tween?
	janitor:Add(function()
		if self._cardTween then
			self._cardTween:Cancel()
			self._cardTween = nil
		end
	end, true)

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui

	local frame = uiGui:WaitForChild("Gifting") :: Frame
	self._frame = frame

	local container = frame:WaitForChild("Container") :: Frame

	-- Friends
	local friends = container:WaitForChild("Friends") :: Frame
	local friendsContainer = friends:WaitForChild("Container") :: Frame

	local header = friendsContainer:WaitForChild("Header")
	local closeBtn = header:WaitForChild("CloseBtn") :: GuiButton

	local search = friendsContainer:WaitForChild("Search")
	self._searchBox = (if search:IsA("TextBox") then search else search:WaitForChild("TextBox")) :: TextBox

	local scrolling = friendsContainer:WaitForChild("ScrollingFrame") :: ScrollingFrame
	local template = scrolling:WaitForChild("Template") :: GuiObject
	self._scrolling = scrolling
	self._template = template

	scrolling.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrolling.CanvasSize = UDim2.new(0, 0, 0, 0)
	template.Visible = false

	-- Action
	local action = container:WaitForChild("Action") :: Frame
	self._actionFrame = action

	local actionContainer = action:WaitForChild("Container") :: Frame
	local contents = actionContainer:WaitForChild("Contents") :: Frame

	local friendCard = contents:WaitForChild("Friend") :: GuiObject
	self._card = friendCard

	local giftCard = contents:WaitForChild("Gift") :: GuiObject
	self._giftName = giftCard:WaitForChild("Name") :: TextLabel
	self._giftPrice = giftCard:WaitForChild("Price") :: TextLabel

	local giftBtn = (actionContainer:FindFirstChild("Gift") or actionContainer:WaitForChild("Gift")) :: GuiButton

	frame.Visible = false
	action.Visible = false

	config.menuController:registerPanel(frame)
	janitor:Add(function()
		config.menuController:unregisterPanel(frame)
	end, true)

	janitor:Add(function()
		self:_clearRows()
	end, true)

	-- ── Wiring ───────────────────────────────────────────────
	janitor:Add(closeBtn.Activated:Connect(function()
		self:close()
	end), "Disconnect")

	janitor:Add(giftBtn.Activated:Connect(function()
		self:_onSend()
	end), "Disconnect")

	janitor:Add(self._searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		self:_applyFilter()
	end), "Disconnect")

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
		local name = if receiver then "@" .. receiver.username else "your friend"
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
-- LISTA DE AMIGOS
-- ────────────────────────────────────────────────────────────

function GiftFlow:_clearRows()
	for _, record in self._rows do
		record.janitor:Destroy()
		record.row:Destroy()
	end
	table.clear(self._rows)
end

function GiftFlow:_applyEntryToNode(node: GuiObject, entry: UserEntry)
	local icon = node:WaitForChild("Icon") :: ImageLabel
	icon.Image = string.format(AVATAR_THUMB_FORMAT, entry.userId)

	local username = node:WaitForChild("Username") :: TextLabel
	username.Text = "@" .. entry.username

	local displayName = node:WaitForChild("DisplayName") :: TextLabel
	displayName.Text = entry.displayName

	local status = node:FindFirstChild("Status")
	if status and status:IsA("TextLabel") then
		local online = entry.online or Players:GetPlayerByUserId(entry.userId) ~= nil
		status.Text = if online then STATUS_ONLINE_TEXT else STATUS_OFFLINE_TEXT
		status.TextColor3 = if online then STATUS_ONLINE_COLOR else STATUS_OFFLINE_COLOR
	end
end

function GiftFlow:_populate(entries: { UserEntry }, animate: boolean?)
	self:_clearRows()

	for index, entry in entries do
		local row = self._template:Clone() :: GuiObject
		row.Name = entry.username
		row.LayoutOrder = index
		self:_applyEntryToNode(row, entry)

		local rowJanitor = Janitor.new()
		bindRowClick(row, rowJanitor, function()
			self:_select(entry, row)
		end)

		row.Visible = true
		row.Parent = self._scrolling
		table.insert(self._rows, { row = row, entry = entry, janitor = rowJanitor })
	end

	self:_applyFilter()

	local visibleRows: { GuiObject } = {}
	for _, record in self._rows do
		if record.row.Visible then
			table.insert(visibleRows, record.row)
		end
	end
	self._reveal:setItems(visibleRows)
	if animate then
		self._reveal:play()
	end
end

function GiftFlow:_applyFilter()
	local query = self._searchBox.Text:gsub("^%s+", ""):gsub("%s+$", ""):lower()
	for _, record in self._rows do
		local entry = record.entry
		record.row.Visible = query == ""
			or entry.username:lower():find(query, 1, true) ~= nil
			or entry.displayName:lower():find(query, 1, true) ~= nil
	end
end

function GiftFlow:_refreshList(animate: boolean?)
	local now = os.clock()
	if self._friendsCache and now - self._friendsFetchedAt < FRIENDS_CACHE_TTL then
		self:_populate(self._friendsCache, animate)
		return
	end

	self:_populate({}, false)
	self._friendsFetchToken += 1
	local token = self._friendsFetchToken
	task.spawn(function()
		local entries = fetchFriendEntries(Players.LocalPlayer.UserId, function()
			return token ~= self._friendsFetchToken
		end)
		if token ~= self._friendsFetchToken then
			return
		end
		self._friendsCache = entries
		self._friendsFetchedAt = os.clock()
		if self._frame.Visible then
			self:_populate(entries, animate)
		end
	end)
end

-- ────────────────────────────────────────────────────────────
-- RECEPTOR + ENVÍO
-- ────────────────────────────────────────────────────────────

function GiftFlow:_select(entry: UserEntry, row: GuiObject?)
	self._receiver = entry
	self:_updateCard()

	if row then
		popScale(row, ROW_SELECT_TWEEN, ROW_SELECT_FROM)
	end

	local card = self._card
	if card and card.Visible then
		if self._cardTween then
			self._cardTween:Cancel()
		end
		self._cardTween = popScale(card, CARD_SELECT_TWEEN, CARD_SELECT_FROM)
	end
end

function GiftFlow:_updateCard()
	local receiver = self._receiver
	if receiver then
		self:_applyEntryToNode(self._card, receiver)
		self._card.Visible = true
		self._actionFrame.Visible = true
	else
		self._card.Visible = false
		self._actionFrame.Visible = false
	end
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
	self:_updateCard()

	self._giftName.Text = string.format(GIFT_NAME_FORMAT, UIUtils.formatCashAmount(product.CashAmount))
	self._giftPrice.Text = string.format(PRICE_FORMAT, product.RobuxPrice)
	self._searchBox.Text = ""

	self:_refreshList(true)

	self._storeFrame.Visible = false
	self._frame.Visible = true
end

function GiftFlow:close()
	self._frame.Visible = false
	self._storeFrame.Visible = true
end

function GiftFlow:reset()
	self._frame.Visible = false
	self._sendPending = false
	self._pendingToken += 1
end

return GiftFlow
