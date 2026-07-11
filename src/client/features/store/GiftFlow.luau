--!strict
--[[
	GiftFlow.luau  (Client Feature Library — Store)

	Flujo de envío de regalos (UserInterface.Gifting). Se abre desde el Store al
	pulsar el botón "Gift" de un pack de Robux concreto (Store.CashPage.<Row>.
	<Pack>.Gift): el Store se oculta y este frame toma el relevo. CloseBtn vuelve
	al Store.

	Estructura GUI esperada:
		UserInterface.Gifting
		  Container
		    Friends
		      Header.CloseBtn                ← vuelve al Store
		      ScrollingFrame                 ← canvas automático según contenido
		        Template                     ← fila de amigo: Icon/Username/DisplayName/Status
		        Search.TextBox               ← filtro en vivo (oculta filas que no matchean)
		    Action                           ← visible SOLO con un amigo seleccionado
		      Contents
		        Gift.Name / Gift.Price       ← qué se regala y su precio
		        Friend                       ← amigo elegido (misma estructura que Template)
		      GiftBtn                        ← valida y lanza el envío

	La lista muestra SIEMPRE los amigos del jugador (no hay pestaña de lobby) y el
	regalo ya no lleva mensaje adjunto.

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

local AVATAR_THUMB_FORMAT = "rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"
local STATUS_ONLINE_TEXT = "· Online"
local STATUS_OFFLINE_TEXT = "· Offline"
local STATUS_ONLINE_COLOR = Color3.fromRGB(114, 255, 114)
local STATUS_OFFLINE_COLOR = Color3.fromRGB(255, 255, 255)
local GIFT_NAME_FORMAT = "%s Cash"
-- Precio con el glifo de Robux de la fuente de Roblox (\u{E002}) + la cifra,
-- todo en el mismo TextLabel (Gift.Price no tiene icono de Robux aparte).
local PRICE_FORMAT = "\u{E002}%d"
-- Si el servidor no responde la validación en este tiempo, liberamos el GiftBtn
-- para que una respuesta perdida no deje el flujo bloqueado.
local RESPONSE_TIMEOUT = 5
-- El receipt puede tardar unos segundos tras el prompt; pasado esto soltamos
-- el guard de compra-en-vuelo (el GiftDelivered tardío se maneja igual).
local DELIVERY_TIMEOUT = 15
-- Cache de amigos: la API pagina y yielda; no re-pedimos en cada apertura.
local FRIENDS_CACHE_TTL = 60

-- Reveal escalonado de las filas (mismas curvas que los packs del Store, con un
-- stagger más corto por ser más items). Solo en (re)poblados por acción del
-- usuario (abrir el flujo), no en refrescos vivos de status.
local ROW_REVEAL_STAGGER = 0.03
local ROW_REVEAL_TWEEN = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- Pop de feedback al seleccionar: la fila clicada y la tarjeta del receptor.
local ROW_SELECT_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ROW_SELECT_FROM = 0.9
local CARD_SELECT_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CARD_SELECT_FROM = 0.82

export type GiftFlowConfig = {
	menuController: any,
	storeFrame: GuiObject,
	-- Se dispara al confirmarse la entrega (receipt procesado): el Store lo usa
	-- para cualquier limpieza posterior.
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

-- Resuelve un TextLabel por nombre dentro de un nodo: hijo directo primero,
-- luego descendientes (tolera un nivel extra de contenedor en la GUI).
local function findLabel(parent: Instance?, name: string): TextLabel?
	if not parent then
		return nil
	end
	local node = parent:FindFirstChild(name) or parent:FindFirstChild(name, true)
	return if node and node:IsA("TextLabel") then node else nil
end

local function findImage(parent: Instance?, name: string): (ImageLabel | ImageButton)?
	if not parent then
		return nil
	end
	local node = parent:FindFirstChild(name) or parent:FindFirstChild(name, true)
	if node and (node:IsA("ImageLabel") or node:IsA("ImageButton")) then
		return node :: any
	end
	return nil
end

-- Click unificado sobre una fila: la propia fila si es botón, o su primer
-- GuiButton descendiente (p. ej. un HitArea transparente); último recurso,
-- InputBegan sobre el frame.
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

-- Resuelve/crea la UIScale de un nodo reutilizando el nombre "InteractiveScale"
-- que usa StaggerReveal: Roblox aplica una sola UIScale por instancia, así que
-- el reveal y el pop de selección comparten el mismo nodo sin pelearse.
local function ensureScale(node: GuiObject): UIScale
	local named = node:FindFirstChild("InteractiveScale")
	if named and named:IsA("UIScale") then
		return named
	end
	local any = node:FindFirstChildOfClass("UIScale")
	if any then
		return any
	end
	local created = Instance.new("UIScale")
	created.Name = "InteractiveScale"
	created.Scale = 1
	created.Parent = node
	return created
end

-- Pop desde `from` (<1) hasta 1 con overshoot (Back/Out). Devuelve el tween para
-- poder cancelarlo. Un Play posterior sobre la misma propiedad cancela el
-- anterior, así que clicks rápidos no se solapan.
local function popScale(node: GuiObject, info: TweenInfo, from: number): Tween
	local scale = ensureScale(node)
	scale.Scale = from
	local tween = TweenService:Create(scale, info, { Scale = 1 })
	tween:Play()
	return tween
end

-- `isStale` corta la paginación cuando el resultado ya no interesa (re-fetch):
-- sin esto, reabrir el flujo durante un fetch lento lanzaba paginaciones
-- completas concurrentes cuyo resultado se descartaba.
local function fetchFriendEntries(userId: number, isStale: () -> boolean): { UserEntry }
	local entries: { UserEntry } = {}

	-- Presencia fiable de quien está en ESTE servidor: item.IsOnline de
	-- GetFriendsAsync es presencia de plataforma (puede ir con retraso y en
	-- Studio suele venir en false aunque el amigo esté conectado). Un amigo que
	-- está jugando aquí mismo es online con certeza, así que lo cruzamos con la
	-- lista de jugadores del servidor y forzamos online en ese caso.
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

	-- Online primero; dentro de cada grupo, alfabético por nombre visible.
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
	self._inert = true

	self._receiver = nil :: UserEntry?
	self._product = nil :: StoreProductDefinition?
	self._rows = {} :: { { row: GuiObject, entry: UserEntry, janitor: any } }
	self._sendPending = false
	self._awaitingPurchase = false
	self._pendingToken = 0
	self._friendsCache = nil :: { UserEntry }?
	self._friendsFetchedAt = 0
	self._friendsFetchToken = 0

	-- Reveal escalonado de la lista + pop de la tarjeta al seleccionar.
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
	local uiGui = playerGui:WaitForChild("UserInterface")

	local frameNode = uiGui:FindFirstChild("Gifting")
	if not (frameNode and frameNode:IsA("GuiObject")) then
		warn("[GiftFlow] Falta UserInterface.Gifting; el flujo de regalo queda inactivo.")
		return self
	end
	local frame = frameNode :: GuiObject
	self._frame = frame

	-- Resolución TOLERANTE de la estructura: cada nodo se busca por nombre —
	-- hijo directo primero, descendientes después — para aguantar niveles extra
	-- de contenedor en la GUI. Sin los nodos críticos (lista, GiftBtn, CloseBtn)
	-- el flujo queda inerte con un warn que enumera qué falta, sin colgar el Store.
	local function findNamed(name: string, predicate: ((Instance) -> boolean)?): Instance?
		local direct = frame:FindFirstChild(name)
		if direct and (predicate == nil or predicate(direct)) then
			return direct
		end
		for _, descendant in frame:GetDescendants() do
			if descendant.Name == name and (predicate == nil or predicate(descendant)) then
				return descendant
			end
		end
		return nil
	end
	local function isButton(node: Instance): boolean
		return node:IsA("GuiButton")
	end

	local scrollingNode = findNamed("ScrollingFrame", function(node)
		return node:IsA("ScrollingFrame")
	end)
	local templateNode = scrollingNode and scrollingNode:FindFirstChild("Template")
	local closeNode = findNamed("CloseBtn", isButton)
	local giftBtnNode = findNamed("GiftBtn", isButton)

	if not (scrollingNode
		and templateNode and templateNode:IsA("GuiObject")
		and closeNode
		and giftBtnNode)
	then
		warn(("[GiftFlow] UserInterface.Gifting: faltan nodos (ScrollingFrame=%s Template=%s CloseBtn=%s GiftBtn=%s); flujo inactivo."):format(
			tostring(scrollingNode ~= nil),
			tostring(templateNode ~= nil),
			tostring(closeNode ~= nil),
			tostring(giftBtnNode ~= nil)
		))
		return self
	end

	local scrolling = scrollingNode :: ScrollingFrame
	local template = templateNode :: GuiObject
	self._scrolling = scrolling
	self._template = template

	-- Canvas automático según la cantidad de filas.
	scrolling.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrolling.CanvasSize = UDim2.new(0, 0, 0, 0)
	template.Visible = false

	-- Nodos opcionales (si faltan, esa parte del flujo se omite sin romper). El
	-- TextBox de búsqueda se busca DENTRO de su contenedor "Search".
	local searchRoot = findNamed("Search")
	self._searchBox = if searchRoot
		then (if searchRoot:IsA("TextBox") then searchRoot else searchRoot:FindFirstChildWhichIsA("TextBox", true))
		else nil

	-- El panel Action solo se muestra con un receptor elegido; dentro cuelgan la
	-- tarjeta del amigo (Friend, misma estructura que Template) y los labels del
	-- regalo (Gift.Name / Gift.Price).
	local actionRoot = findNamed("Action")
	self._actionFrame = if actionRoot and actionRoot:IsA("GuiObject") then actionRoot else nil

	local friendNode = findNamed("Friend")
	self._card = if friendNode and friendNode:IsA("GuiObject") then friendNode else nil

	local giftRoot = findNamed("Gift")
	self._giftName = findLabel(giftRoot, "Name")
	self._giftPrice = findLabel(giftRoot, "Price")

	frame.Visible = false
	if self._actionFrame then
		self._actionFrame.Visible = false
	end
	self._inert = false

	-- Mientras el flujo está visible cuenta como "panel abierto" (el Store se
	-- oculta debajo): así el menú no reaparece y el GiftAlert no se cuela.
	config.menuController:registerPanel(frame)
	janitor:Add(function()
		config.menuController:unregisterPanel(frame)
	end, true)

	-- Las filas clonadas viven fuera del janitor del feature (se crean y
	-- destruyen por refresh): limpiarlas también al teardown, o quedarían
	-- clones con conexiones vivas apuntando a un controlador muerto.
	janitor:Add(function()
		self:_clearRows()
	end, true)

	-- ── Wiring ───────────────────────────────────────────────
	janitor:Add((closeNode :: GuiButton).Activated:Connect(function()
		self:close()
	end), "Disconnect")

	janitor:Add((giftBtnNode :: GuiButton).Activated:Connect(function()
		self:_onSend()
	end), "Disconnect")

	if self._searchBox then
		janitor:Add(self._searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			self:_applyFilter()
		end), "Disconnect")
	end

	-- Si el amigo elegido se va del servidor, sigue pudiendo recibir el regalo
	-- (entrega offline): solo actualizamos su status visual en la tarjeta.
	janitor:Add(Players.PlayerRemoving:Connect(function(leaving: Player)
		local receiver = self._receiver
		if receiver and receiver.userId == leaving.UserId and receiver.online then
			receiver.online = false
			self:_updateCard()
		end
	end), "Disconnect")

	-- ── Red ──────────────────────────────────────────────────
	-- ByteNet es broadcast por namespace: solo procesamos respuestas que
	-- nosotros pedimos (guards _sendPending/_awaitingPurchase).
	janitor:Add(Network.Gifting.SendResponse.Listen(function(data: any)
		if not self._sendPending then
			return
		end
		self._sendPending = false
		self._pendingToken += 1
		if data.success then
			-- El server está lanzando el prompt de compra.
			self._awaitingPurchase = true
		else
			local message = if data.message ~= "" then data.message else "That gift couldn't be sent."
			Notify.warning(message)
		end
	end), true)

	janitor:Add(Network.Gifting.GiftDelivered.Listen(function(_data: any)
		-- Solo cierra el flujo si ESTE cliente está esperando esa entrega. Un
		-- receipt reintentado de una sesión anterior puede llegar en cualquier
		-- momento (incluso componiendo OTRO regalo): en ese caso avisamos sin
		-- tocar el estado — cerrar aquí abortaría una composición ajena y el
		-- toast nombraría al receptor equivocado.
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

	-- Prompt cerrado sin comprar → liberar el guard para poder reintentar.
	janitor:Add(MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, purchased: boolean)
		if userId ~= player.UserId or not self._awaitingPurchase then
			return
		end
		local product = self._product
		if product and productId ~= product.ProductId then
			return
		end
		if purchased then
			-- Falta el receipt (GiftDelivered). Timeout de cortesía por si el
			-- packet se pierde: no dejar el GiftBtn bloqueado para siempre. Con
			-- token: un timer viejo no debe soltarle el guard a un envío
			-- posterior (double-send).
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

-- Pinta Icon/Username/DisplayName/Status de un nodo (fila o tarjeta Friend).
function GiftFlow:_applyEntryToNode(node: GuiObject, entry: UserEntry)
	local icon = findImage(node, "Icon")
	if icon then
		icon.Image = string.format(AVATAR_THUMB_FORMAT, entry.userId)
	end
	local username = findLabel(node, "Username")
	if username then
		username.Text = "@" .. entry.username
	end
	local displayName = findLabel(node, "DisplayName")
	if displayName then
		displayName.Text = entry.displayName
	end
	local status = findLabel(node, "Status")
	if status then
		-- Presencia efectiva: la del fetch (plataforma / en-servidor al poblar) O
		-- una comprobación EN VIVO del roster, por si el amigo se conectó a este
		-- servidor después de cachear la lista.
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

	-- Reveal solo de las filas realmente visibles (respeta un filtro activo) y en
	-- orden. Sin animate, aparecen sin escala (scale 1).
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
	local query = ""
	if self._searchBox then
		query = self._searchBox.Text:gsub("^%s+", ""):gsub("%s+$", ""):lower()
	end
	for _, record in self._rows do
		local entry = record.entry
		record.row.Visible = query == ""
			or entry.username:lower():find(query, 1, true) ~= nil
			or entry.displayName:lower():find(query, 1, true) ~= nil
	end
end

-- `animate` revela las filas con pop escalonado. true en la apertura del flujo y
-- en la llegada del fetch de amigos; false en refrescos vivos de status.
function GiftFlow:_refreshList(animate: boolean?)
	if self._inert then
		return
	end

	-- Cache fresco → directo; si no, fetch async (pagina + yielda) con token para
	-- descartar resultados de un fetch obsoleto.
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
			return -- fetch obsoleto (se relanzó)
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

-- `row` es la fila clicada (opcional): se le da un pop de feedback junto con la
-- tarjeta del receptor. Sin row (selección por código) solo anima la tarjeta.
function GiftFlow:_select(entry: UserEntry, row: GuiObject?)
	self._receiver = entry
	self:_updateCard()

	if row then
		popScale(row, ROW_SELECT_TWEEN, ROW_SELECT_FROM)
	end

	-- Pop de la tarjeta al "aterrizar" la selección. Cancela el anterior para
	-- que selecciones rápidas no se peleen por la misma UIScale.
	local card = self._card
	if card and card.Visible then
		if self._cardTween then
			self._cardTween:Cancel()
		end
		self._cardTween = popScale(card, CARD_SELECT_TWEEN, CARD_SELECT_FROM)
	end
end

-- Contenido + visibilidad del panel Action (sin animación): lo usan _select y
-- los refrescos de status (PlayerRemoving). El pop de selección vive en _select.
-- El panel Action solo aparece con un receptor elegido.
function GiftFlow:_updateCard()
	local receiver = self._receiver
	local card = self._card
	if card then
		if receiver then
			self:_applyEntryToNode(card, receiver)
			card.Visible = true
		else
			card.Visible = false
		end
	end
	if self._actionFrame then
		self._actionFrame.Visible = receiver ~= nil
	end
end

function GiftFlow:_onSend()
	if self._inert or not self._product then
		return
	end
	if self._sendPending or self._awaitingPurchase then
		return -- ya hay un envío/compra en vuelo
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
		-- Solo libera si seguimos esperando ESTA validación (no una posterior ni
		-- una ya respondida): una respuesta perdida no debe bloquear el GiftBtn.
		if self._sendPending and self._pendingToken == token then
			self._sendPending = false
			Notify.warning("No response from the server. Try again.")
		end
	end)

	Network.Gifting.SendGift.Send({
		receiverUserId = tostring(receiver.userId),
		productId = (self._product :: StoreProductDefinition).ProductId,
		-- El regalo ya no lleva mensaje adjunto (el server acepta cadena vacía).
		message = "",
	})
end

-- ────────────────────────────────────────────────────────────
-- APERTURA / CIERRE
-- ────────────────────────────────────────────────────────────

--[[
	Abre el flujo para un producto concreto (el pack cuyo botón "Gift" se pulsó).
	Arranca sin receptor: el panel Action queda oculto hasta elegir un amigo.
]]
function GiftFlow:openForProduct(product: StoreProductDefinition)
	if self._inert then
		return
	end

	self._product = product
	self._receiver = nil
	-- Apertura = flujo fresco: suelta guards colgados de un intento anterior
	-- (respuesta perdida, prompt zombie). Un prompt de compra real es modal,
	-- así que no se puede llegar aquí con una compra legítima en vuelo.
	self._sendPending = false
	self._awaitingPurchase = false
	self._pendingToken += 1
	self:_updateCard()

	if self._giftName then
		self._giftName.Text = string.format(GIFT_NAME_FORMAT, UIUtils.formatCashAmount(product.CashAmount))
	end
	if self._giftPrice then
		self._giftPrice.Text = string.format(PRICE_FORMAT, product.RobuxPrice)
	end
	if self._searchBox then
		self._searchBox.Text = ""
	end

	self:_refreshList(true) -- apertura del flujo → reveal escalonado de la lista

	self._storeFrame.Visible = false
	self._frame.Visible = true
end

-- Cierra el flujo y devuelve el Store (CloseBtn / entrega confirmada).
function GiftFlow:close()
	if self._inert then
		return
	end
	self._frame.Visible = false
	self._storeFrame.Visible = true
end

-- Cierre silencioso: oculta sin re-mostrar el Store. Lo usa el Store en su
-- onClose para no dejar el flujo colgado si el panel entero se cierra.
function GiftFlow:reset()
	if self._inert then
		return
	end
	self._frame.Visible = false
	self._sendPending = false
	self._pendingToken += 1
end

return GiftFlow
