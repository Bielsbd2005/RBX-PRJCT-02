--!strict
--[[
	store/init.luau (Client Feature)

	Panel de la tienda (UserInterface.Store).

		Store
		  CloseBtn
		  ScrollingFrame.Container.Content
		    CoinsRow    ← Cash1…Cash5   (packs de StoreProducts.Cash)
		    GemsRow     ← Gems1…Gems5   (packs de StoreProducts.Gems)
		    PassesRow   ← VIP, BackWeapon (StoreProducts.GamePasses)
		    Bundles y los títulos/subtítulos (sin cablear)

	Los botones ya existen en Studio con el nombre de su pack; aquí solo se les
	rellenan los labels (Amount/Price) y se les cuelga el PromptProductPurchase.
	Las filas se buscan por nombre en cualquier nivel bajo Store, así que re-anidar
	el ScrollingFrame/Container/Content en Studio no rompe el binder.

	Cada pack puede traer su propio botón `Gift` (Cash1.Gift, Gems1.Gift…) que
	abre el flujo de regalo (GiftFlow) con ESE pack ya elegido. Es un GuiButton
	hijo del botón del pack: Roblox entrega el clic solo al botón más profundo,
	así que regalar no dispara además la compra del pack. Mientras la lista de
	jugadores está en pantalla la tienda se oculta, y vuelve al cerrarse el flujo.

	Los gamepasses de PassesRow no son developer products: se promptean con
	PromptGamePassPurchase, no pasan por ProcessReceipt y la posesión es
	permanente, así que su botón además refleja si el jugador ya lo tiene.

	TODO: Bundles.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Janitor = require(Packages.janitor) :: any

local PanelController = require(Client.core.ui.PanelController)
local BlurController = require(Client.core.ui.BlurController)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local StaggerReveal = require(Client.core.ui.animators.StaggerReveal)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local GiftFlow = require(Client.features.gifting.GiftFlow)
local StoreProducts = require(Shared.constants.StoreProducts)

local BLUR_KEY = "Store"

-- Fila de la GUI donde vive cada catálogo de packs.
local CASH_ROW_NAME = "CoinsRow"
local GEMS_ROW_NAME = "GemsRow"
-- Fila de los gamepasses (StoreProducts.GamePasses, en el orden del catálogo).
local PASSES_ROW_NAME = "PassesRow"

-- Botón de regalo dentro del botón de cada pack.
local GIFT_BUTTON_NAME = "Gift"

-- Entrada del panel. La tienda NO hace el pop de panel del resto (se abre con
-- animationMode = "none"): lo único que se anima al abrir son sus packs, que van
-- entrando en cascada. Las filas arrancan TODAS a la vez, así que el retardo
-- separa columnas: Cash1+Gems1+VIP, luego Cash2+Gems2+BackWeapon, y así.
local ROW_REVEAL_STAGGER = 0.05
local ROW_REVEAL_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Nodo opcional del botón de un gamepass que la GUI muestra cuando ya se posee.
local OWNED_NODE_NAME = "Owned"
-- Texto de reemplazo del precio cuando la GUI no trae ese nodo.
local OWNED_PRICE_TEXT = "Owned"

local StoreFeature = {}

function StoreFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- Botón de apertura en Menu.Container.Store
	local menuGui = menuController:getGui()
	local container = menuGui:WaitForChild("Container")
	local menuBtnInstance = container:FindFirstChild("Store")
	local menuBtn: GuiButton? = if menuBtnInstance and menuBtnInstance:IsA("GuiButton")
		then menuBtnInstance
		else nil

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local storeFrame = uiGui:WaitForChild("Store") :: Frame
	local closeBtn = storeFrame:WaitForChild("CloseBtn") :: GuiButton


	-- ── Packs de Robux (Cash y Gems) ─────────────────────────
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	-- Cascada de entrada, una lista por fila (Cash, Gems, passes). Se transponen a
	-- columnas al final: las tres filas entran en paralelo y lo que separa el
	-- retardo es la posición dentro de la fila, no la fila.
	--
	-- Solo entran los botones que la GUI trae de verdad; uno que falte no deja un
	-- hueco porque ni siquiera llega aquí.
	local revealRows: { { GuiObject } } = {}

	-- Transpone las filas a columnas. Las filas no tienen por qué medir lo mismo:
	-- una más corta deja de aportar items a partir de su última posición y las
	-- demás siguen cascadeando solas, sin huecos.
	local function toRevealColumns(rows: { { GuiObject } }): { { GuiObject } }
		local longest = 0
		for _, row in rows do
			longest = math.max(longest, #row)
		end

		local columns: { { GuiObject } } = table.create(longest)
		for i = 1, longest do
			local column: { GuiObject } = {}
			for _, row in rows do
				local item = row[i]
				if item then
					table.insert(column, item)
				end
			end
			columns[i] = column
		end
		return columns
	end

	local function resolveRow(rowName: string): GuiObject?
		local node = storeFrame:FindFirstChild(rowName, true)
		return if node and node:IsA("GuiObject") then node :: GuiObject else nil
	end

	-- ── Regalo de un pack ────────────────────────────────────
	-- El flujo vive en su propio frame (UserInterface.Gifting) y se registra
	-- como panel por su cuenta; aquí solo se le cede la pantalla al abrirlo y se
	-- recupera al cerrarlo. Se construye en el PRIMER clic de un botón Gift, no
	-- al arrancar: GiftFlow espera su frame con WaitForChild, y la tienda no
	-- debe quedarse sin cablear sus packs por una GUI de Gifting ausente.
	local giftOpen = false
	local giftFlow: any = nil

	local function ensureGiftFlow(): any
		if not giftFlow then
			giftFlow = GiftFlow.new({
				menuController = menuController,
				onOpened = function()
					giftOpen = true
					storeFrame.Visible = false
				end,
				onClosed = function()
					giftOpen = false
					storeFrame.Visible = true
				end,
			}, janitor)
		end
		return giftFlow
	end

	-- Rellena los labels del pack. Ambos son opcionales: un botón sin Amount o sin
	-- Price sigue comprando, solo no muestra ese dato.
	local function applyProductToButton(button: GuiButton, product: StoreProducts.ProductBase, amount: number)
		local amountNode = button:FindFirstChild("Amount")
		if amountNode and amountNode:IsA("TextLabel") then
			amountNode.Text = UIUtils.formatCashAmount(amount)
		end

		local priceNode = button:FindFirstChild("Price")
		if priceNode and priceNode:IsA("TextLabel") then
			priceNode.Text = product.PriceText
		end

		-- ProductId = 0 → developer product sin crear en el panel de Roblox: el
		-- botón se muestra pero no acepta clics.
		button.Active = product.ProductId > 0
		button.Selectable = product.ProductId > 0
		button.AutoButtonColor = false
	end

	-- Cablea el botón `Gift` del pack, si la GUI lo trae. `giftable` es del
	-- catálogo entero (ver bindCatalogRow) y un pack sin developer product
	-- configurado tampoco se puede regalar: en ambos casos el botón sigue ahí
	-- pero no abre nada, igual que el botón de compra de un pack sin ProductId.
	local function bindGiftButton(button: GuiButton, product: StoreProducts.ProductBase, giftable: boolean)
		local giftNode = button:FindFirstChild(GIFT_BUTTON_NAME)
		if not (giftNode and giftNode:IsA("GuiButton")) then
			return
		end
		local giftBtn = giftNode :: GuiButton

		local enabled = giftable and product.ProductId > 0
		-- `Active` se queda en true aunque el pack no sea regalable: un botón
		-- inactivo deja pasar el clic al botón del pack que hay debajo, y quien
		-- quiso regalar acabaría con el prompt de compra delante. Así el botón
		-- se lo traga y no hace nada (solo `Selectable` refleja el estado, para
		-- que la navegación por gamepad no se pare en un botón muerto).
		giftBtn.Active = true
		giftBtn.Selectable = enabled
		giftBtn.AutoButtonColor = false

		InteractiveScaleTween.bindButton(giftBtn, janitor, {
			enableHover = canUseHoverAnimations,
			hoverScale = UITheme.ButtonHoverScale,
			clickScale = UITheme.ButtonClickScale,
		})

		janitor:Add(giftBtn.Activated:Connect(function()
			if not enabled then
				return
			end
			ensureGiftFlow():openForProduct(product :: any)
		end), "Disconnect")
	end

	-- `giftable`: si el backend de regalos sabe entregar los packs de este
	-- catálogo. Hoy GiftingService solo resuelve los de Cash (la intención
	-- guarda un ProductId de `StoreProducts.Cash` y la entrega deposita
	-- `CashAmount`), así que los botones Gift de la fila de Gems quedan
	-- inactivos; cuando el server sepa entregar gems basta con pasar `true`.
	local function bindCatalogRow(
		rowName: string,
		catalog: StoreProducts.Catalog<any>,
		getAmount: (any) -> number,
		giftable: boolean
	)
		local row = resolveRow(rowName)
		if not row then
			warn(`[StoreFeature] Fila {rowName} no encontrada; packs no cableados.`)
			return
		end

		local rowItems: { GuiObject } = {}
		table.insert(revealRows, rowItems)

		for _, product in catalog.InOrder do
			local buttonNode = row:FindFirstChild(product.ButtonName)
			if not (buttonNode and buttonNode:IsA("GuiButton")) then
				warn(`[StoreFeature] {rowName}.{product.ButtonName} no encontrado.`)
				continue
			end
			local button = buttonNode :: GuiButton

			table.insert(rowItems, button)

			applyProductToButton(button, product, getAmount(product))
			bindGiftButton(button, product, giftable)
			InteractiveScaleTween.bindButton(button, janitor, {
				enableHover = canUseHoverAnimations,
				hoverScale = UITheme.ButtonHoverScale,
				clickScale = UITheme.ButtonClickScale,
			})

			janitor:Add(button.Activated:Connect(function()
				if product.ProductId <= 0 then
					warn("[StoreFeature] ProductId no configurado para", product.ButtonName)
					return
				end
				MarketplaceService:PromptProductPurchase(player, product.ProductId)
			end), "Disconnect")
		end
	end

	bindCatalogRow(CASH_ROW_NAME, StoreProducts.Cash, function(product: StoreProducts.StoreProductDefinition)
		return product.CashAmount
	end, true)
	bindCatalogRow(GEMS_ROW_NAME, StoreProducts.Gems, function(product: StoreProducts.GemProductDefinition)
		return product.GemAmount
	end, false)

	-- ── Gamepasses (PassesRow) ───────────────────────────────
	-- Binder propio y no `bindCatalogRow`: un pass no tiene cantidad que mostrar
	-- ni se regala, se promptea con otra API y encima tiene un estado que los
	-- packs no tienen (ya comprado).

	-- passId → refresco del botón, para el único listener de compras de abajo.
	local refreshOwnedByPassId: { [number]: (owned: boolean) -> () } = {}

	local function bindGamePassButton(button: GuiButton, pass: StoreProducts.GamePassDefinition)
		local priceNode = button:FindFirstChild("Price")
		local ownedNode = button:FindFirstChild(OWNED_NODE_NAME)
		local owned = false

		--[[
			El pass es permanente, así que a quien ya lo tiene no se le puede
			volver a cobrar: el botón deja de comprar y lo dice.

			Si la GUI trae un nodo `Owned` se muestra ése y el precio se esconde
			(el nodo ES su reemplazo); si no lo trae, lo dice el propio label del
			precio, para que un dueño no se quede delante de un botón muerto y sin
			explicación.
		]]
		local function refresh()
			if ownedNode and ownedNode:IsA("GuiObject") then
				ownedNode.Visible = owned
			end
			if priceNode and priceNode:IsA("TextLabel") then
				if ownedNode then
					priceNode.Text = pass.PriceText
					priceNode.Visible = not owned
				else
					priceNode.Text = if owned then OWNED_PRICE_TEXT else pass.PriceText
				end
			end

			-- PassId = 0 → gamepass sin crear en el panel de Roblox: mismo trato
			-- que un pack sin ProductId (se ve, no acepta clics).
			local buyable = pass.PassId > 0 and not owned
			button.Active = buyable
			button.Selectable = buyable
		end

		local function setOwned(nextOwned: boolean)
			if owned == nextOwned then
				return
			end
			owned = nextOwned
			refresh()
		end

		button.AutoButtonColor = false
		refresh()

		-- Sin id no queda nada que cablear: ni prompt, ni consulta de posesión,
		-- ni animación en un botón que no responde.
		if pass.PassId <= 0 then
			return
		end
		refreshOwnedByPassId[pass.PassId] = setOwned

		-- Una consulta por pass al arrancar la feature (no en cada apertura del
		-- panel): es una llamada web, y el estado sólo puede cambiar por una
		-- compra, que ya avisa por PromptGamePassPurchaseFinished.
		task.spawn(function()
			local ok, result = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.PassId)
			end)
			if not ok then
				warn(`[StoreFeature] UserOwnsGamePassAsync falló para {pass.Name}: {result}`)
				return
			end
			setOwned(result == true)
		end)

		InteractiveScaleTween.bindButton(button, janitor, {
			enableHover = canUseHoverAnimations,
			hoverScale = UITheme.ButtonHoverScale,
			clickScale = UITheme.ButtonClickScale,
		})

		janitor:Add(button.Activated:Connect(function()
			-- Re-chequeo del estado vivo (no del capturado al cablear): el
			-- `Active = false` ya frena el clic, pero un cambio de propiedades
			-- desde Studio o un pass comprado en otro sitio no deben acabar en un
			-- prompt de algo que ya se tiene.
			if owned then
				return
			end
			MarketplaceService:PromptGamePassPurchase(player, pass.PassId)
		end), "Disconnect")
	end

	local passesRow = resolveRow(PASSES_ROW_NAME)
	if passesRow then
		local passItems: { GuiObject } = {}
		table.insert(revealRows, passItems)

		for _, pass in StoreProducts.GamePasses.InOrder do
			local buttonNode = passesRow:FindFirstChild(pass.ButtonName)
			if not (buttonNode and buttonNode:IsA("GuiButton")) then
				warn(`[StoreFeature] {PASSES_ROW_NAME}.{pass.ButtonName} no encontrado.`)
				continue
			end
			table.insert(passItems, buttonNode :: GuiButton)
			bindGamePassButton(buttonNode :: GuiButton, pass)
		end
	else
		warn(`[StoreFeature] Fila {PASSES_ROW_NAME} no encontrada; gamepasses no cableados.`)
	end

	-- Una sola conexión para toda la fila: la compra se confirma con la tienda
	-- delante, así que el botón tiene que pasar a "comprado" sin reabrir el panel.
	janitor:Add(MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(purchasePlayer, passId, wasPurchased)
		if not wasPurchased or purchasePlayer ~= player then
			return
		end
		local refresh = refreshOwnedByPassId[passId]
		if refresh then
			refresh(true)
		end
	end), "Disconnect")

	-- StaggerReveal comparte el nodo "InteractiveScale" con InteractiveScaleTween
	-- (Roblox solo aplica una UIScale por instancia), así que la cascada y el
	-- hover/click de los botones no se pelean por él.
	local reveal = StaggerReveal.new({
		staggerDelay = ROW_REVEAL_STAGGER,
		tweenInfo = ROW_REVEAL_TWEEN,
		startScale = 0,
	})
	reveal:setGroups(toRevealColumns(revealRows))
	janitor:Add(reveal, "Destroy")

	-- `animationMode = "none"`: el panel entra de golpe y la única animación de
	-- apertura es la cascada de los packs. El resto de paneles hacen el pop de
	-- escala del frame entero; la tienda no.
	local panel = PanelController.new(menuController, storeFrame, menuBtn, closeBtn, {
		animationMode = "none",
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			-- Después del acquire: el animator ya dejó el frame visible al llegar
			-- aquí, así que los packs arrancan a escala 0 en el mismo frame en que
			-- se ve el panel, sin asomar a tamaño completo antes de la cascada.
			reveal:play()
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)

			-- Cerrar la tienda con el flujo de regalo delante (no pasa por la UI
			-- —la tienda está oculta— pero sí en un cierre programático o un hot
			-- reload): retirarlo en silencio. PanelController ya decidió si
			-- restauraba el menú ANTES de este callback y con el Gifting visible
			-- decidió que no, así que hay que rehacer esa decisión aquí.
			if giftOpen and giftFlow then
				giftOpen = false
				giftFlow:reset()
				if not menuController:hasOpenPanel() then
					menuController:show()
				end
			end
		end,
	})
	janitor:Add(panel, "Destroy")

	return janitor
end

return StoreFeature
