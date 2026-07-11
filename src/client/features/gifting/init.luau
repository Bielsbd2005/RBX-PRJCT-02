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
		  Claim     ← botón: reclama (el server concede el cash) y cierra
		  Product   ← imagen del pack regalado (copiada del botón del Store)
		  Rays      ← imagen decorativa girando en loop
		  Message   ← mensaje del remitente (ya filtrado server-side)
		  Subtitle  ← "@Sender gifted you 3.000" (RichText: @sender y regalo
		              en color, el resto conserva el blanco de la GUI)

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
-- Fuente de verdad de la fase de partida (singleton compartido con el feature
-- de match). Es la señal "en lobby" independiente de quién ocultó el menú.
local MatchState = require(Client.features.match.MatchState)

-- Colores del Subtitle (RichText). El acento del remitente es el mismo del
-- modo regalo del Store (255, 58, 84); el regalo va en dorado.
local SENDER_COLOR_HEX = "#FF3A54"
local GIFT_COLOR_HEX = "#FFC850"
local SUBTITLE_FORMAT = `<font color="{SENDER_COLOR_HEX}">@%s</font> gifted you <font color="{GIFT_COLOR_HEX}">%s</font>`

local RAYS_ROTATION_SECONDS = 8
local SHOW_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- Si el server no responde el claim, liberamos el botón para reintentar.
local CLAIM_TIMEOUT = 5
-- Ignora clicks de Claim recién mostrado el alert (> cooldown server de 0.3s).
local CLAIM_CLICK_GUARD = 0.4

local GiftingFeature = {}

-- Escapes mínimos de RichText: un nombre no debería traerlos, pero un `<`
-- sin escapar rompería el parseo del label entero.
local function escapeRichText(text: string): string
	local escaped = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
	return escaped
end

function GiftingFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui

	-- Sin timeout, como el resto de features con GUI propia: en clientes lentos
	-- la GUI puede tardar >10s en replicar y un timeout dejaba la recepción de
	-- regalos muerta para toda la sesión.
	local alertNode = uiGui:WaitForChild("GiftAlert")
	if not alertNode:IsA("GuiObject") then
		warn("[GiftingFeature] UserInterface.GiftAlert no es un GuiObject; recepción de regalos sin UI.")
		return janitor
	end
	local alertFrame = alertNode :: GuiObject

	local claimNode = alertFrame:FindFirstChild("Claim")
	local claimBtn: GuiButton? = if claimNode and claimNode:IsA("GuiButton") then claimNode else nil
	if not claimBtn then
		warn("[GiftingFeature] Falta GiftAlert.Claim; recepción de regalos sin UI.")
		return janitor
	end

	local productNode = alertFrame:FindFirstChild("Product")
	local productImage: ImageLabel? = if productNode and productNode:IsA("ImageLabel") then productNode else nil
	local raysNode = alertFrame:FindFirstChild("Rays")
	local raysImage: GuiObject? = if raysNode and raysNode:IsA("GuiObject") then raysNode else nil
	local messageNode = alertFrame:FindFirstChild("Message")
	local messageLabel: TextLabel? = if messageNode and messageNode:IsA("TextLabel") then messageNode else nil
	local subtitleNode = alertFrame:FindFirstChild("Subtitle")
	local subtitleLabel: TextLabel? = if subtitleNode and subtitleNode:IsA("TextLabel") then subtitleNode else nil
	if subtitleLabel then
		subtitleLabel.RichText = true
	end
	if messageLabel then
		-- El mensaje es texto plano de OTRO jugador: nunca RichText. El filtro
		-- del server sustituye caracteres pero no quita '<...>'; con RichText
		-- activado en la GUI, un remitente podría inyectar markup.
		messageLabel.RichText = false
	end

	alertFrame.Visible = false
	-- El Shade detrás del alert lo gestiona el ShadeController por atributos: se
	-- espera que GiftAlert lleve el atributo `Shade=true` (y ShadeColor opcional)
	-- puesto en Studio, como el resto de paneles. Aquí no se toca — al mostrar el
	-- frame (Visible=true) el overlay aparece solo; no acoplamos los dos módulos.

	-- ── Estado ───────────────────────────────────────────────
	local menuGui = menuController:getGui() :: ScreenGui
	local dataReady = false
	-- El alert está presentándose Y nosotros ocultamos el menú por ello. 1:1 con
	-- "tenemos tomado el menú": present() lo pone, retract() lo suelta.
	local presenting = false
	local currentGiftId: string? = nil
	local claiming = false
	local claimingGiftId: string? = nil
	local claimToken = 0
	local lastShownAt = 0
	-- Regalos ya reclamados en esta sesión: el ClaimResponse puede llegar antes
	-- que la re-replicación de PendingGifts, y sin esto el evaluate re-mostraría
	-- el regalo recién reclamado durante ese hueco.
	local claimedIds: { [string]: boolean } = {}
	-- Se resuelve en la sección de señales (watchLoadingScreen).
	local loadingDone = false

	-- ── Animaciones ──────────────────────────────────────────
	local raysTween: Tween? = nil
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
		if raysTween then
			raysTween:Cancel()
			raysTween = nil
		end
		if showTween then
			showTween:Cancel()
			showTween = nil
		end
	end
	janitor:Add(stopAnimations, true)

	-- ── Presentación ─────────────────────────────────────────

	-- Imagen del pack regalado: se copia del botón correspondiente del Store
	-- (misma GUI en todos los clientes; StoreProducts no lleva asset ids).
	local function findProductImage(productId: number): string?
		local product = StoreProducts.ProductsByProductId[productId]
		if not product then
			return nil
		end
		local storeNode = uiGui:FindFirstChild("Store")
		if not storeNode then
			return nil
		end
		for _, descendant in storeNode:GetDescendants() do
			if descendant.Name == product.ButtonName and descendant:IsA("GuiButton") then
				if descendant:IsA("ImageButton") and descendant.Image ~= "" then
					return descendant.Image
				end
				local image = descendant:FindFirstChildWhichIsA("ImageLabel", true)
				return if image then image.Image else nil
			end
		end
		return nil
	end

	local function show(giftId: string, gift: any)
		if currentGiftId == giftId and alertFrame.Visible then
			return -- ya está en pantalla; no re-animar
		end
		currentGiftId = giftId

		if productImage then
			local image = findProductImage(tonumber(gift.ProductId) or 0)
			if image and image ~= "" then
				productImage.Image = image
			end
		end
		if messageLabel then
			local text = tostring(gift.Message or "")
			messageLabel.Text = text
			messageLabel.Visible = text ~= ""
		end
		if subtitleLabel then
			subtitleLabel.Text = string.format(
				SUBTITLE_FORMAT,
				escapeRichText(tostring(gift.SenderName or "???")),
				UIUtils.formatCashAmount(tonumber(gift.CashAmount) or 0)
			)
		end

		stopAnimations()

		if raysImage then
			raysImage.Rotation = 0
			raysTween = TweenService:Create(
				raysImage,
				TweenInfo.new(RAYS_ROTATION_SECONDS, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1),
				{ Rotation = 360 }
			)
			raysTween:Play()
		end

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

	-- Presenta un regalo Y toma el menú: al mostrarse el alert, el menú se oculta
	-- y el Shade aparece (atributo). `presenting` se fija ANTES de hide() porque
	-- menuController:hide() dispara evaluate() de forma reentrante — con el flag
	-- ya puesto, esa reentrada no vuelve a ocultar el menú ni retrae.
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
