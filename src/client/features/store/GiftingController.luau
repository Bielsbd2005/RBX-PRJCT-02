--!strict
--[[
	GiftingController.luau  (Client Feature Library)

	Máquina de estados de la pestaña Store ▸ Gifting (selección del destinatario
	de un regalo). Dos estados:

	  "search"    (default) — TextBox visible, el jugador escribe un nombre.
	                ActionBtn = "SHOP". Profile/Title ocultos.
	                Al presionar ActionBtn → valida contra el servidor.

	  "confirmed"           — TextBox oculto/deshabilitado. Profile visible con el
	                avatar del destinatario. Title = "SHOPPING FOR <name>".
	                ActionBtn = "EXIT". Al presionar ActionBtn → reset() a "search".

	La validación (existencia del usuario + filtro de texto) es server-authoritative
	vía Network.Gifting. El destinatario persiste entre tabs del Store; solo se
	cancela al cerrar el panel (el store llama a :reset() en onClose).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network = require(Shared.networking.Network)
local Notify = require(Client.core.ui.NotificationController)

local SEARCH_BTN_TEXT = "SHOP"
local CONFIRMED_BTN_TEXT = "EXIT"
-- Si el servidor no responde la validación en este tiempo, liberamos el botón
-- para que una respuesta perdida no deje el SHOP bloqueado hasta cerrar el panel.
local RESPONSE_TIMEOUT = 5
local TITLE_FORMAT = "SHOPPING FOR %s"
local AVATAR_THUMB_FORMAT = "rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"

export type Recipient = { userId: number, username: string }

export type GiftingConfig = {
	frame: GuiObject,        -- Store.Gifting
	textBox: TextBox,        -- Store.Gifting.TextBox
	actionBtn: GuiButton,    -- Store.Gifting.ActionBtn
	profile: GuiObject,      -- Store.Gifting.Profile (contenedor de la imagen)
	title: GuiObject,        -- Store.Gifting.Title (TextLabel o contenedor)
}

local GiftingController = {}
GiftingController.__index = GiftingController

-- Asigna texto al destino correcto: si el nodo es Text*, su .Text; si no, el
-- primer TextLabel/TextButton hijo. Tolera ambas estructuras de GUI.
local function setText(node: Instance, text: string)
	if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
		(node :: any).Text = text
		return
	end
	for _, child in node:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			(child :: any).Text = text
			return
		end
	end
end

-- Resuelve el ImageLabel/ImageButton donde cargar el avatar: el propio Profile
-- si ya es de imagen, o el primer descendiente de imagen.
local function resolveImage(profile: GuiObject): (ImageLabel | ImageButton)?
	if profile:IsA("ImageLabel") or profile:IsA("ImageButton") then
		return profile :: any
	end
	for _, child in profile:GetDescendants() do
		if child:IsA("ImageLabel") or child:IsA("ImageButton") then
			return child :: any
		end
	end
	return nil
end

function GiftingController.new(config: GiftingConfig, janitor: any)
	local self = setmetatable({}, GiftingController)
	self._textBox = config.textBox
	self._actionBtn = config.actionBtn
	self._profile = config.profile
	self._title = config.title
	self._profileImage = resolveImage(config.profile)

	self._state = "search" :: "search" | "confirmed"
	self._recipient = nil :: Recipient?
	self._pending = false -- hay una validación en vuelo (debounce + filtra respuestas viejas)
	self._pendingToken = 0 -- token incremental para que un timeout obsoleto no libere un pending nuevo

	janitor:Add(self._actionBtn.Activated:Connect(function()
		self:_onActionPressed()
	end), "Disconnect")

	-- Respuesta de validación. Solo relevante si nosotros pedimos una (_pending);
	-- ByteNet es broadcast por namespace, así que ignoramos respuestas no pedidas.
	janitor:Add(Network.Gifting.Response.Listen(function(data)
		if not self._pending then return end
		self._pending = false
		self._pendingToken += 1 -- invalida el timeout en vuelo
		if data.success then
			local userId = tonumber(data.userId)
			if userId then
				self:_enterConfirmed(userId, data.username)
				return
			end
		end
		local message = if data.message ~= "" then data.message else "That user isn't available."
		Notify.warning(message)
	end), true)

	self:reset()
	return self
end

function GiftingController:_onActionPressed()
	if self._state == "confirmed" then
		self:reset()
		return
	end

	-- Estado "search": validar el nombre escrito.
	if self._pending then return end -- ya hay una en vuelo
	local username = (self._textBox.Text:gsub("^%s+", ""):gsub("%s+$", ""))
	if username == "" then
		Notify.warning("Enter a username.")
		return
	end

	self._pending = true
	self._pendingToken += 1
	local token = self._pendingToken
	task.delay(RESPONSE_TIMEOUT, function()
		-- Sólo libera si seguimos esperando ESTA validación (no una posterior ni
		-- una ya respondida). Evita bloquear el botón si la respuesta se pierde.
		if self._pending and self._pendingToken == token then
			self._pending = false
			Notify.warning("No response from the server. Try again.")
		end
	end)
	Network.Gifting.ValidateUser.Send({ username = username })
end

function GiftingController:_enterConfirmed(userId: number, username: string)
	self._state = "confirmed"
	self._recipient = { userId = userId, username = username }

	self._textBox.Visible = false
	self._textBox.TextEditable = false

	if self._profileImage then
		self._profileImage.Image = string.format(AVATAR_THUMB_FORMAT, userId)
	end
	self._profile.Visible = true

	setText(self._title, string.format(TITLE_FORMAT, username))
	self._title.Visible = true

	setText(self._actionBtn, CONFIRMED_BTN_TEXT)
end

-- Vuelve al estado de búsqueda. Llamado por el botón "EXIT" y por el store al
-- cerrar el panel (CloseBtn) → cancela el regalo en curso.
function GiftingController:reset()
	self._state = "search"
	self._recipient = nil
	self._pending = false
	self._pendingToken += 1 -- invalida cualquier timeout en vuelo

	self._profile.Visible = false
	self._title.Visible = false

	self._textBox.Text = ""
	self._textBox.TextEditable = true
	self._textBox.Visible = true

	setText(self._actionBtn, SEARCH_BTN_TEXT)
end

-- Destinatario confirmado (o nil en búsqueda). Lo consume el flujo de compra
-- para dirigir el regalo.
function GiftingController:getRecipient(): Recipient?
	return self._recipient
end

return GiftingController
