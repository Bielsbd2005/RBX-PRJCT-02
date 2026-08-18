--!strict
--[[
	gifting/init.luau  (Client Feature)

	Recepción de regalos. Observa PendingGifts (perfil replicado vía
	DataController) y muestra UserInterface.GiftAlert cuando el jugador está
	"idle" en el lobby, es decir:
	  • la pantalla de carga terminó (PlayerGui.LoadingScreen destruida),
	  • no hay partida en curso (MatchState.getPhase() == "Lobby"), y
	  • ningún panel está abierto (solo el lobby).
	Eso cubre los tres casos del flujo: al unirse tras la carga, al volver al
	menú desde una partida, y al cerrar el último panel con regalos pendientes.

	Al mostrar el alert se OCULTA el menú (menuController:hide). El Shade y su
	blur de fondo van por atributo: el ShadeController pinta el overlay y activa
	el blur al hacerse visible el frame, siempre que GiftAlert tenga `Shade=true`
	puesto en Studio (como el resto de paneles — este feature no toca ni el shade
	ni el blur). Al retraerse (claim, sin más regalos, o al romperse las
	condiciones) se restaura el menú, salvo que una partida o un panel se hayan
	quedado con él.

	La detección de "en lobby" se apoya en MatchState (fase de partida) y no en
	menuController:isHidden()/Menu.Enabled: como ESTE feature oculta el menú al
	presentar, usar esas señales para decidir se realimentaría (ocultar → creer
	que hay que ocultar el alert). MatchState es independiente de quién ocultó
	el menú.

	Estructura GUI:
		UserInterface.GiftAlert
		  Container
		    Claim        ← botón: reclama (el server concede el cash) y cierra
		    Product      ← imagen del pack regalado (copiada del botón del Store)
		    Description  ← "<font color="#FF3A54">@Usuario</font> just gifted you <font color="#FFC850">X</font>! What an absolute legend, claim it right now! 🎉🔥"
		    Value        ← cantidad de cash del pack ("3.000", etc.)

	Los regalos se muestran de uno en uno (el más antiguo primero). Al reclamar,
	PendingGifts se re-replica y el observer encadena el siguiente.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Fusion = require(Packages.fusion) :: any
local Janitor = require(Packages.janitor) :: any
local Network = require(Shared.networking.Network)
local StoreProducts = require(Shared.constants.StoreProducts)
local DataController = require(Client.core.data.DataController)
local Notify = require(Client.core.ui.NotificationController)
local UIUtils = require(Client.core.ui.UIUtils)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local UITheme = require(Client.core.ui.UITheme)
local MatchState = require(Client.features.match.MatchState)

local SENDER_COLOR_HEX = "#FF3A54"
local GIFT_COLOR_HEX = "#FFC850"
local DESCRIPTION_FORMAT = `<font color="{SENDER_COLOR_HEX}">@%s</font> just gifted you <font color="{GIFT_COLOR_HEX}">%s</font>! What an absolute legend, claim it right now! 🎉🔥`

local SHOW_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLAIM_TIMEOUT = 5
local CLAIM_CLICK_GUARD = 0.4

local GiftingFeature = {}

local function escapeRichText(text: string): string
	local escaped = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
	return escaped
end

function GiftingFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui

	local alertFrame = uiGui:WaitForChild("GiftAlert") :: GuiObject
	local container = alertFrame:WaitForChild("Container") :: Frame

	local claimBtn = container:WaitForChild("Claim") :: GuiButton
	local productImage = container:WaitForChild("Product") :: ImageLabel
	local descriptionLabel = container:WaitForChild("Description") :: TextLabel
	local valueLabel = container:WaitForChild("Value") :: TextLabel

	descriptionLabel.RichText = true

	alertFrame.Visible = false

	-- ── Estado ───────────────────────────────────────────────
	local menuGui = menuController:getGui() :: ScreenGui
	local dataReady = false
	local presenting = false
	local currentGiftId: string? = nil
	local claiming = false
	local claimingGiftId: string? = nil
	local claimToken = 0
	local lastShownAt = 0
	local claimedIds: { [string]: boolean } = {}
	local loadingDone = false

	-- ── Animaciones ──────────────────────────────────────────
	local showTween: Tween? = nil

	local function getAlertScale(): UIScale
		local existing = alertFrame:FindFirstChild("AlertScale")
		if existing and existing:IsA("UIScale") then
			return existing
		end
		local scale = Instance.new("UIScale")
		scale.Name = "AlertScale"
		scale.Parent = alertFrame
		return scale
	end

	local function stopAnimations()
		if showTween then
			showTween:Cancel()
			showTween = nil
		end
	end
	janitor:Add(stopAnimations, true)

	-- ── Presentación ─────────────────────────────────────────

	local function findProductImage(productId: number): string?
		local product = StoreProducts.ProductsByProductId[productId]
		if not product then
			return nil
		end
		local storeNode = uiGui:FindFirstChild("Store")
		if not storeNode then
			return nil
		end
		local cashPage = storeNode:FindFirstChild("CashPage") or storeNode:FindFirstChild("Cash")
		local rowContainer = if cashPage then cashPage:FindFirstChild(product.Row) else nil
		local button = if rowContainer then rowContainer:FindFirstChild(product.ButtonName) else nil
		if not button and cashPage then
			button = cashPage:FindFirstChild(product.ButtonName)
		end
		if button then
			if button:IsA("ImageButton") and button.Image ~= "" then
				return button.Image
			end
			local image = button:FindFirstChild("Icon") or button:FindFirstChildWhichIsA("ImageLabel")
			return if image and image:IsA("ImageLabel") then image.Image else nil
		end
		return nil
	end

	local function show(giftId: string, gift: any)
		if currentGiftId == giftId and alertFrame.Visible then
			return
		end
		currentGiftId = giftId

		local image = findProductImage(tonumber(gift.ProductId) or 0)
		if image and image ~= "" then
			productImage.Image = image
		end

		local cashAmount = tonumber(gift.CashAmount) or 0
		if cashAmount <= 0 then
			local product = StoreProducts.ProductsByProductId[tonumber(gift.ProductId) or 0]
			if product then
				cashAmount = product.CashAmount
			end
		end

		local formattedCash = UIUtils.formatCashAmount(cashAmount)
		valueLabel.Text = formattedCash
		descriptionLabel.Text = string.format(
			DESCRIPTION_FORMAT,
			escapeRichText(tostring(gift.SenderName or "???")),
			formattedCash .. " Cash"
		)

		stopAnimations()

		local scale = getAlertScale()
		scale.Scale = 0
		alertFrame.Visible = true
		lastShownAt = os.clock()
		showTween = TweenService:Create(scale, SHOW_TWEEN_INFO, { Scale = 1 })
		showTween:Play()
	end

	local function hide()
		if not alertFrame.Visible then
			return
		end
		stopAnimations()
		alertFrame.Visible = false
		currentGiftId = nil
	end

	local function present(giftId: string, gift: any)
		show(giftId, gift)
		if not presenting then
			presenting = true
			menuController:hide()
		end
	end

	-- Oculta el alert (→ Shade fuera) y, si teníamos tomado el menú, lo restaura
	-- SOLO si volvemos a un lobby limpio: si una partida arrancó o un panel se
	-- abrió, ese dueño se queda el menú (el panel lo restaura al cerrarse).
	local function retract()
		if not presenting and not alertFrame.Visible then
			return
		end
		hide()
		if presenting then
			presenting = false
			if not MatchState.shouldKeepMenuHidden() and not menuController:hasOpenPanel() then
				menuController:show()
			end
		end
	end

	-- ── Evaluación ───────────────────────────────────────────
	-- Se llama en cada señal relevante (estado del menú, Menu.Enabled,
	-- PendingGifts, fin de la carga) y decide si presentar el regalo más
	-- antiguo o retraer el alert.
	local function evaluate()
		if not dataReady then
			return
		end

		-- Bloqueado si NO estamos en lobby: carga sin terminar, partida en curso
		-- (cualquier fase ≠ Lobby, vía MatchState — independiente de nuestro
		-- propio ocultado de menú) o algún panel abierto. En esos casos se
		-- retrae SIEMPRE, incluso con un claim en vuelo (su respuesta se procesa
		-- igual): sin esto el alert quedaba sobrepuesto al entrar en partida.
		local blocked = (not loadingDone)
			or MatchState.shouldKeepMenuHidden()
			or menuController:hasOpenPanel()

		if blocked then
			retract()
			return
		end

		if claiming then
			return -- no avanzar al siguiente regalo hasta resolver el claim
		end

		local oldestId: string? = nil
		local oldestGift: any = nil
		local pending = Fusion.peek(DataController.PendingGifts)
		if type(pending) == "table" then
			for giftId, gift in pending do
				if claimedIds[giftId] then
					continue
				end
				local sentAt = tonumber(gift.SentAt) or 0
				local oldestSentAt = if oldestGift then (tonumber(oldestGift.SentAt) or 0) else math.huge
				-- Desempate por giftId: SentAt tiene resolución de segundos y
				-- la iteración del mapa no es determinista — sin orden estable,
				-- dos regalos del mismo segundo se alternaban entre réplicas.
				if oldestId == nil
					or sentAt < oldestSentAt
					or (sentAt == oldestSentAt and giftId < (oldestId :: string))
				then
					oldestId = giftId
					oldestGift = gift
				end
			end
		end

		if not oldestId then
			retract()
			return
		end

		-- Estamos en lobby limpio y hay un regalo. Si aún no presentamos, exigir
		-- que el menú esté REALMENTE visible antes de tomarlo — evita popear el
		-- alert en un microhueco entre transiciones donde el menú aún no volvió.
		-- Una vez presentando, no se re-chequea (nosotros lo ocultamos).
		if not presenting and (menuController:isHidden() or not menuGui.Enabled) then
			return
		end

		present(oldestId, oldestGift)
	end

	-- ── Claim ────────────────────────────────────────────────
	InteractiveScaleTween.bindButton(claimBtn, janitor, {
		hoverScale = UITheme.ButtonHoverScale,
		clickScale = UITheme.ButtonClickScale,
	})

	janitor:Add(claimBtn.Activated:Connect(function()
		local giftId = currentGiftId
		if not giftId or claiming then
			return
		end
		-- Anti doble-tap al encadenar regalos: el server descarta claims a
		-- <0.3s SIN responder; sin este gate local, ese silencio dejaba la UI
		-- muerta hasta el timeout de 5s.
		if os.clock() - lastShownAt < CLAIM_CLICK_GUARD then
			return
		end
		claiming = true
		claimingGiftId = giftId
		claimToken += 1
		local token = claimToken
		task.delay(CLAIM_TIMEOUT, function()
			-- Respuesta perdida: liberar el botón sin marcar el regalo como
			-- reclamado (el server decide; si concedió, la réplica lo borrará).
			if claiming and claimToken == token then
				claiming = false
				claimingGiftId = nil
				Notify.warning("No response from the server. Try again.")
				evaluate()
			end
		end)
		Network.Gifting.ClaimGift.Send({ giftId = giftId })
	end), "Disconnect")

	janitor:Add(Network.Gifting.ClaimResponse.Listen(function(data: any)
		-- Registrar SIEMPRE los claims exitosos, aunque la respuesta sea de un
		-- intento viejo (timeout + retry): el regalo no debe re-mostrarse
		-- mientras la réplica de PendingGifts se pone al día.
		if data.success then
			claimedIds[data.giftId] = true
		end
		-- Solo tratamos como "nuestra" la respuesta del gift que reclamamos:
		-- una respuesta tardía de otro intento no debe liberar/consumir el
		-- claim en vuelo (broadcast del namespace + retries).
		if claiming and data.giftId == claimingGiftId then
			claiming = false
			claimingGiftId = nil
			claimToken += 1
			if data.success then
				Notify.success(`+{UIUtils.formatCashAmount(data.cashAmount)} Cash`)
			else
				local message = if data.message ~= "" then data.message else "That gift couldn't be claimed."
				Notify.warning(message)
			end
		end
		-- No ocultamos aquí: evaluate() presenta el siguiente regalo (menú sigue
		-- oculto, sin parpadeo) o retrae si no queda ninguno (restaura el menú).
		evaluate()
	end), true)

	-- ── Señales ──────────────────────────────────────────────
	-- Pantalla de carga: el script de ReplicatedFirst destruye
	-- PlayerGui.LoadingScreen al terminar. El orden de replicación dentro de
	-- PlayerGui no está garantizado: si aún no existe cuando arrancamos, se
	-- asume terminada PERO ChildAdded re-arma el gate si aparece después (sin
	-- esto, el alert podía pintarse debajo de la pantalla de carga).
	local function watchLoadingScreen(gui: Instance)
		loadingDone = false
		janitor:Add(gui.Destroying:Connect(function()
			loadingDone = true
			evaluate()
		end), "Disconnect")
	end

	local loadingScreen = playerGui:FindFirstChild("LoadingScreen")
	if loadingScreen then
		watchLoadingScreen(loadingScreen)
	else
		loadingDone = true
		janitor:Add(playerGui.ChildAdded:Connect(function(child: Instance)
			if child.Name == "LoadingScreen" then
				watchLoadingScreen(child)
				evaluate()
			end
		end), "Disconnect")
	end

	-- Cambios de estado del menú: show/hide y paneles abriéndose/cerrándose.
	janitor:Add(menuController:onStateChanged(evaluate), true)

	-- Menu.Enabled: la fase "Joining" de partida (MatchMenu:enforceHidden)
	-- apaga el ScreenGui directamente, sin pasar por MenuController — sin esta
	-- señal el alert podía aparecer sobre la transición de entrada a partida.
	janitor:Add(menuGui:GetPropertyChangedSignal("Enabled"):Connect(evaluate), "Disconnect")

	-- Cambios de PendingGifts (regalo nuevo entregado / claim replicado).
	local fusionScope = Fusion.scoped(Fusion)
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)

	DataController:WhenReady():andThen(function()
		dataReady = true
		local observer = fusionScope:Observer(DataController.PendingGifts)
		-- onBind dispara también inmediatamente → primer evaluate tras la carga.
		janitor:Add(observer:onBind(evaluate), true)
	end)

	-- Teardown (hot reload): si nos quedamos presentando, restaurar el menú para
	-- no dejar al jugador sin lobby. (El blur lo suelta el ShadeController al
	-- ocultarse el frame.)
	janitor:Add(function()
		if presenting then
			presenting = false
			if not MatchState.shouldKeepMenuHidden() and not menuController:hasOpenPanel() then
				menuController:show()
			end
		end
	end, true)

	return janitor
end

return GiftingFeature
