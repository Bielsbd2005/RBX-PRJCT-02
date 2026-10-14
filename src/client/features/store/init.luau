--!strict
--[[
	Panel de la tienda (UserInterface.Store).

		Store
		  CloseBtn
		  ScrollingFrame.Container.Content
		    CoinsRow    ← slots 1…5 (packs de StoreProducts.Cash, en orden de InOrder)
		    GemsRow     ← slots 1…5 (packs de StoreProducts.Gems, en orden de InOrder)
		    PassesRow   ← slots VIP, BackWeapon (ButtonName de StoreProducts.GamePasses)
		    BundlesRow  ← slots Bundle01… (ButtonName de StoreProducts.Bundles)
		    Títulos/subtítulos (sin cablear)

	Slot (Frame) de pack, pass o bundle:
		MainButton (GuiButton, compra)
		  Ammount.Value  ← cantidad del pack / DisplayName del pass
		  Stock.Value    ← solo bundles, opcional: unidades que quedan o "SOLD OUT"
		Price.Value      ← precio
		Gift             ← regalo (hermano de MainButton, no lo pisa)
		Owned            ← passes y bundles, opcional: visible si ya se posee
	El título de un bundle (MainButton.Title) es arte de la GUI: no se toca.

	Los slots ya existen en Studio; aquí solo se rellenan los labels y se cuelga la
	compra. Las filas se buscan por nombre en cualquier nivel bajo Store, así que
	re-anidar el ScrollingFrame/Container/Content en Studio no rompe el binder.

	`Gift` abre GiftFlow con ESE producto. Con la lista de jugadores en pantalla la
	tienda se oculta y vuelve al cerrarse el flujo.

	Los gamepasses de PassesRow no son developer products: se promptean con
	PromptGamePassPurchase, no pasan por ProcessReceipt y la posesión es
	permanente, así que su slot además refleja si el jugador ya lo tiene (comprado
	o regalado). Su `Gift` cobra el developer product `GiftProductId` del pass.

	Los bundles limitados no se promptean desde aquí: se piden al servidor
	(Network.Store.BuyBundle), que comprueba stock y posesión y lanza él el prompt.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Fusion = require(Packages.fusion) :: any
local Janitor = require(Packages.janitor) :: any

local DataController = require(Client.core.data.DataController)
local PanelController = require(Client.core.ui.PanelController)
local BlurController = require(Client.core.ui.BlurController)
local GameSounds = require(Client.core.ui.GameSounds)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local StaggerReveal = require(Client.core.ui.animators.StaggerReveal)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local GiftFlow = require(Client.features.gifting.GiftFlow)
local Notify = require(Client.core.ui.NotificationController)
local Network = require(Shared.networking.Network)
local LimitedBundles = require(Shared.data.LimitedBundles)
local StoreProducts = require(Shared.constants.StoreProducts)
local DebugFlags = require(Shared.utils.DebugFlags)

local BLUR_KEY = "Store"

-- En Studio la posesión no se pregunta a Roblox: mismo flag que GamePassService.
local IS_STUDIO = RunService:IsStudio()
local noGamePasses = DebugFlags.bind(ReplicatedStorage, "NoGamePasses")

local CASH_ROW_NAME = "CoinsRow"
local GEMS_ROW_NAME = "GemsRow"
local PASSES_ROW_NAME = "PassesRow"
local BUNDLES_ROW_NAME = "BundlesRow"
local SLOT_STOCK_NAME = "Stock"
local STOCK_TEXT_FORMAT = "%d LEFT"
local SOLD_OUT_TEXT = "SOLD OUT"

local GIFT_BUTTON_NAME = "Gift"
local SLOT_BUY_BUTTON_NAME = "MainButton"
-- "Ammount" con doble m: así se llama el nodo en Studio.
local SLOT_AMOUNT_NAME = "Ammount"
local SLOT_PRICE_NAME = "Price"
local SLOT_VALUE_LABEL_NAME = "Value"

-- La tienda NO hace el pop de panel (animationMode = "none"): solo se animan sus packs
-- en cascada. Las filas arrancan a la vez, así que el retardo separa columnas
-- (Cash1+Gems1+VIP, luego Cash2+Gems2+BackWeapon…).
local ROW_REVEAL_STAGGER = 0.05
local ROW_REVEAL_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Nodo opcional del slot de un gamepass o bundle que la GUI muestra cuando ya se posee.
local OWNED_NODE_NAME = "Owned"
-- Texto de reemplazo del precio cuando la GUI no trae ese nodo.
local OWNED_PRICE_TEXT = "Owned"

-- Más suave que UITheme.ButtonHoverScale: los slots son grandes y el 4% del tema se
-- comía el hueco con el vecino.
local SLOT_HOVER_SCALE = 1.015

local StoreFeature = {}

function StoreFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local menuGui = menuController:getGui()
	local container = menuGui:WaitForChild("Container")
	local menuBtnInstance = container:FindFirstChild("Store")
	local menuBtn: GuiButton? = if menuBtnInstance and menuBtnInstance:IsA("GuiButton")
		then menuBtnInstance
		else nil

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local storeFrame = uiGui:WaitForChild("Store") :: Frame
	local closeBtn = storeFrame:WaitForChild("CloseBtn") :: GuiButton

	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	-- Cascada de entrada, una lista por fila (Cash, Gems, passes), transpuesta a columnas al
	-- final. Solo entran los botones que la GUI trae de verdad: uno que falte no deja hueco.
	local revealRows: { { GuiObject } } = {}

	-- Las filas no tienen por qué medir lo mismo: una más corta deja de aportar items y
	-- las demás siguen cascadeando sin huecos.
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

	-- GiftFlow vive en su propio frame (UserInterface.Gifting) y se registra como panel por
	-- su cuenta. Se construye en el PRIMER clic de Gift, no al arrancar: espera su frame con
	-- WaitForChild y la tienda no debe quedarse sin cablear por una GUI de Gifting ausente.
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

	local function findValueLabel(parent: Instance, containerName: string): TextLabel?
		local holder = parent:FindFirstChild(containerName)
		local label = holder and holder:FindFirstChild(SLOT_VALUE_LABEL_NAME)
		return if label and label:IsA("TextLabel") then label else nil
	end

	-- `sku` solo para el warn: con slots por posición, el nombre no dice qué pack falta.
	local function resolveSlot(row: Instance, rowName: string, slotName: string, sku: string): (GuiObject?, GuiButton?)
		local slot = row:FindFirstChild(slotName)
		local button = slot and slot:FindFirstChild(SLOT_BUY_BUTTON_NAME)
		if not (slot and slot:IsA("GuiObject") and button and button:IsA("GuiButton")) then
			warn(`[StoreFeature] {rowName}.{slotName}.{SLOT_BUY_BUTTON_NAME} no encontrado ({sku}).`)
			return nil, nil
		end
		return slot, button
	end

	-- Rellena los labels del pack. Ambos son opcionales: un slot sin cantidad o sin
	-- precio sigue comprando, solo no muestra ese dato.
	local function applyProductToSlot(
		slot: GuiObject,
		button: GuiButton,
		product: StoreProducts.ProductBase,
		amount: number
	)
		local amountLabel = findValueLabel(button, SLOT_AMOUNT_NAME)
		if amountLabel then
			amountLabel.Text = UIUtils.formatCashAmount(amount)
		end

		local priceLabel = findValueLabel(slot, SLOT_PRICE_NAME)
		if priceLabel then
			priceLabel.Text = product.PriceText
		end

		-- ProductId = 0 → developer product sin crear en el panel de Roblox: el
		-- botón se muestra pero no acepta clics.
		button.Active = product.ProductId > 0
		button.Selectable = product.ProductId > 0
		button.AutoButtonColor = false
	end

	-- `giftProductId` = developer product que se cobra al regalar; 0 = no se regala (el
	-- botón sigue ahí pero no abre nada).
	local function bindGiftButton(giftNode: Instance?, giftProductId: number)
		if not (giftNode and giftNode:IsA("GuiButton")) then
			return
		end
		local giftBtn = giftNode :: GuiButton

		local enabled = giftProductId > 0
		-- `Active` se queda en true aunque no sea regalable: un botón inactivo deja pasar el
		-- clic al botón de compra de debajo y saldría el prompt. `Selectable` refleja
		-- el estado para que el gamepad no se pare en un botón muerto.
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
			ensureGiftFlow():openForProduct(giftProductId)
		end), "Disconnect")
	end

	-- `giftable`: si GiftingService sabe entregar los packs de este catálogo. Hoy solo
	-- resuelve los de Cash (entrega `CashAmount` de `StoreProducts.Cash`); cuando sepa
	-- entregar gems basta con pasar `true` en la fila de Gems.
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

		for index, product in catalog.InOrder do
			local slot, button = resolveSlot(row, rowName, tostring(index), product.ButtonName)
			if not (slot and button) then
				continue
			end

			table.insert(rowItems, slot)

			applyProductToSlot(slot, button, product, getAmount(product))
			bindGiftButton(slot:FindFirstChild(GIFT_BUTTON_NAME), if giftable then product.ProductId else 0)
			InteractiveScaleTween.bindButton(button, janitor, {
				enableHover = canUseHoverAnimations,
				hoverScale = SLOT_HOVER_SCALE,
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

	-- Binder propio y no `bindCatalogRow`: un pass no tiene cantidad que mostrar, se
	-- promptea con otra API, se regala con otro producto y encima tiene un estado que
	-- los packs no tienen (ya poseído).

	-- passId → refresco del slot, para el único listener de compras de abajo.
	local setRobloxOwnedByPassId: { [number]: (owned: boolean) -> () } = {}
	-- `GamePassDefinition.Name` → refresco del slot, para el observer de GiftedPasses.
	local setGiftedByPassName: { [string]: (gifted: boolean) -> () } = {}

	local function bindGamePassSlot(slot: GuiObject, button: GuiButton, pass: StoreProducts.GamePassDefinition)
		local priceNode = findValueLabel(slot, SLOT_PRICE_NAME)
		local ownedNode = slot:FindFirstChild(OWNED_NODE_NAME)
		-- Dos fuentes: Roblox solo conoce el pass comprado; el regalado vive en el perfil.
		local robloxOwned = false
		local gifted = false

		--[[
			El pass es permanente: a quien ya lo tiene el botón deja de comprar y lo dice. Si la
			GUI trae nodo `Owned` se muestra y el precio se esconde; si no, lo dice el label del
			precio, para que un dueño no quede ante un botón muerto sin explicación. Se oculta
			el Frame `Price` entero, no solo su texto, para no dejar la píldora vacía.
		]]
		local function refresh()
			local owned = robloxOwned or gifted
			if ownedNode and ownedNode:IsA("GuiObject") then
				ownedNode.Visible = owned
			end
			if priceNode then
				if ownedNode then
					priceNode.Text = pass.PriceText
					local pricePill = priceNode.Parent
					if pricePill and pricePill:IsA("GuiObject") then
						pricePill.Visible = not owned
					end
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

		local function setRobloxOwned(nextOwned: boolean)
			if robloxOwned == nextOwned then
				return
			end
			robloxOwned = nextOwned
			refresh()
		end

		local nameLabel = findValueLabel(button, SLOT_AMOUNT_NAME)
		if nameLabel then
			nameLabel.Text = pass.DisplayName
		end

		button.AutoButtonColor = false
		refresh()

		-- Aunque ya lo posea: el dueño de un pass puede seguir regalándolo.
		bindGiftButton(slot:FindFirstChild(GIFT_BUTTON_NAME), if pass.PassId > 0 then pass.GiftProductId else 0)

		if pass.PassId <= 0 then
			return
		end
		setRobloxOwnedByPassId[pass.PassId] = setRobloxOwned
		setGiftedByPassName[pass.Name] = function(nextGifted: boolean)
			if gifted == nextGifted then
				return
			end
			gifted = nextGifted
			refresh()
		end

		-- Una consulta por pass al arrancar la feature (llamada web): el estado solo cambia por
		-- una compra, que ya avisa por PromptGamePassPurchaseFinished. En Studio, el flag.
		task.spawn(function()
			if IS_STUDIO then
				-- Hasta Loaded la carpeta Debug puede no haber replicado y el flag daría false.
				if not game:IsLoaded() then
					game.Loaded:Wait()
				end
				setRobloxOwned(not noGamePasses())
				return
			end

			local ok, result = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.PassId)
			end)
			if not ok then
				warn(`[StoreFeature] UserOwnsGamePassAsync falló para {pass.Name}: {result}`)
				return
			end
			setRobloxOwned(result == true)
		end)

		InteractiveScaleTween.bindButton(button, janitor, {
			enableHover = canUseHoverAnimations,
			hoverScale = SLOT_HOVER_SCALE,
			clickScale = UITheme.ButtonClickScale,
		})

		janitor:Add(button.Activated:Connect(function()
			-- Re-chequeo del estado vivo (no el capturado al cablear): un pass comprado en otro
			-- sitio no debe acabar en un prompt de algo que ya se tiene.
			if robloxOwned or gifted then
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
			local slot, button = resolveSlot(passesRow, PASSES_ROW_NAME, pass.ButtonName, pass.Name)
			if not (slot and button) then
				continue
			end
			table.insert(passItems, slot)
			bindGamePassSlot(slot, button, pass)
		end
	else
		warn(`[StoreFeature] Fila {PASSES_ROW_NAME} no encontrada; gamepasses no cableados.`)
	end

	-- Refrescos de los bundles, para el observer de Inventory de abajo.
	local refreshBundleSlots: { () -> () } = {}

	local function bindBundleSlot(slot: GuiObject, button: GuiButton, bundle: StoreProducts.BundleDefinition)
		local priceLabel = findValueLabel(slot, SLOT_PRICE_NAME)
		local stockLabel = findValueLabel(button, SLOT_STOCK_NAME)
		local ownedNode = slot:FindFirstChild(OWNED_NODE_NAME)

		-- Mismo criterio que los passes para el precio y `Owned`. Lo que queda se cuenta
		-- hasta SellableUnits, donde de verdad se cierra la venta.
		local function refresh()
			local owned = LimitedBundles.ownsBundle({ Inventory = Fusion.peek(DataController.Inventory) }, bundle)
			local sold = LimitedBundles.getSold(bundle)
			local saleOpen = LimitedBundles.isSaleOpen(bundle, sold)

			if ownedNode and ownedNode:IsA("GuiObject") then
				ownedNode.Visible = owned
			end
			if priceLabel then
				if ownedNode then
					priceLabel.Text = bundle.PriceText
					local pricePill = priceLabel.Parent
					if pricePill and pricePill:IsA("GuiObject") then
						pricePill.Visible = not owned
					end
				else
					priceLabel.Text = if owned then OWNED_PRICE_TEXT else bundle.PriceText
				end
			end
			if stockLabel then
				stockLabel.Text = if sold == nil
					then ""
					elseif saleOpen then string.format(STOCK_TEXT_FORMAT, bundle.SellableUnits - (sold :: number))
					else SOLD_OUT_TEXT
			end

			local buyable = saleOpen and not owned
			button.Active = buyable
			button.Selectable = buyable
		end

		button.AutoButtonColor = false
		refresh()
		table.insert(refreshBundleSlots, refresh)
		janitor:Add(
			ReplicatedStorage:GetAttributeChangedSignal(LimitedBundles.soldAttributeName(bundle)):Connect(refresh),
			"Disconnect"
		)

		-- Se regala aunque ya lo tenga: el servidor rechaza si el receptor no puede recibirlo.
		bindGiftButton(slot:FindFirstChild(GIFT_BUTTON_NAME), bundle.ProductId)

		InteractiveScaleTween.bindButton(button, janitor, {
			enableHover = canUseHoverAnimations,
			hoverScale = SLOT_HOVER_SCALE,
			clickScale = UITheme.ButtonClickScale,
		})

		janitor:Add(button.Activated:Connect(function()
			if not button.Active then
				return
			end
			Network.Store.BuyBundle.Send({ bundleName = bundle.Name })
		end), "Disconnect")
	end

	local bundlesRow = resolveRow(BUNDLES_ROW_NAME)
	if bundlesRow then
		local bundleItems: { GuiObject } = {}
		table.insert(revealRows, bundleItems)

		for _, bundle in StoreProducts.Bundles.InOrder do
			local slot, button = resolveSlot(bundlesRow, BUNDLES_ROW_NAME, bundle.ButtonName, bundle.Name)
			if not (slot and button) then
				continue
			end
			table.insert(bundleItems, slot)
			bindBundleSlot(slot, button, bundle)
		end
	elseif #StoreProducts.Bundles.InOrder > 0 then
		warn(`[StoreFeature] Fila {BUNDLES_ROW_NAME} no encontrada; bundles no cableados.`)
	end

	janitor:Add(Network.Store.BundleRejected.Listen(function(data: any)
		Notify.warning(data.message)
	end), true)

	-- Una sola conexión para toda la fila: la compra se confirma con la tienda
	-- delante, así que el botón tiene que pasar a "comprado" sin reabrir el panel.
	janitor:Add(MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(purchasePlayer, passId, wasPurchased)
		if not wasPurchased or purchasePlayer ~= player then
			return
		end
		local setRobloxOwned = setRobloxOwnedByPassId[passId]
		if setRobloxOwned then
			setRobloxOwned(true)
		end
	end), "Disconnect")

	local fusionScope = Fusion.scoped(Fusion)
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)

	DataController:WhenReady():andThen(function()
		local observer = fusionScope:Observer(DataController.GiftedPasses)
		-- onBind dispara también inmediatamente.
		janitor:Add(observer:onBind(function()
			local giftedPasses = Fusion.peek(DataController.GiftedPasses)
			for passName, setGifted in setGiftedByPassName do
				setGifted(type(giftedPasses) == "table" and giftedPasses[passName] ~= nil)
			end
		end), true)

		janitor:Add(fusionScope:Observer(DataController.Inventory):onBind(function()
			for _, refresh in refreshBundleSlots do
				refresh()
			end
		end), true)
	end)

	-- La cascada escala el slot y el hover/click su MainButton: son UIScales de instancias
	-- distintas, así que se componen en vez de pelearse.
	local reveal = StaggerReveal.new({
		staggerDelay = ROW_REVEAL_STAGGER,
		tweenInfo = ROW_REVEAL_TWEEN,
		startScale = 0,
	})
	reveal:setGroups(toRevealColumns(revealRows))
	janitor:Add(reveal, "Destroy")

	local panel = PanelController.new(menuController, storeFrame, menuBtn, closeBtn, {
		animationMode = "none",
		openSound = GameSounds.OpenStore,
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			-- Después del acquire: el animator ya dejó el frame visible, así los packs arrancan a
			-- escala 0 en el mismo frame en que se ve el panel.
			reveal:play()
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)

			-- Cierre con el flujo de regalo delante (programático o hot reload): retirarlo en
			-- silencio. PanelController decidió ANTES de este callback no restaurar el menú (Gifting
			-- visible), así que hay que rehacer esa decisión aquí.
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
