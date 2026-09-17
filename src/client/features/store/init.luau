--!strict
--[[
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

	Cada pack puede traer su botón `Gift` (Cash1.Gift…) que abre GiftFlow con ESE pack.
	Es hijo del botón del pack: Roblox entrega el clic solo al botón más profundo, así
	que regalar no dispara la compra. Con la lista de jugadores en pantalla la tienda se
	oculta y vuelve al cerrarse el flujo.

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
local GameSounds = require(Client.core.ui.GameSounds)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local StaggerReveal = require(Client.core.ui.animators.StaggerReveal)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local GiftFlow = require(Client.features.gifting.GiftFlow)
local StoreProducts = require(Shared.constants.StoreProducts)

local BLUR_KEY = "Store"

local CASH_ROW_NAME = "CoinsRow"
local GEMS_ROW_NAME = "GemsRow"
local PASSES_ROW_NAME = "PassesRow"

local GIFT_BUTTON_NAME = "Gift"

-- La tienda NO hace el pop de panel (animationMode = "none"): solo se animan sus packs
-- en cascada. Las filas arrancan a la vez, así que el retardo separa columnas
-- (Cash1+Gems1+VIP, luego Cash2+Gems2+BackWeapon…).
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

	-- `giftable` es del catálogo entero (ver bindCatalogRow); un pack sin ProductId tampoco
	-- se regala. En ambos casos el botón sigue ahí pero no abre nada.
	local function bindGiftButton(button: GuiButton, product: StoreProducts.ProductBase, giftable: boolean)
		local giftNode = button:FindFirstChild(GIFT_BUTTON_NAME)
		if not (giftNode and giftNode:IsA("GuiButton")) then
			return
		end
		local giftBtn = giftNode :: GuiButton

		local enabled = giftable and product.ProductId > 0
		-- `Active` se queda en true aunque no sea regalable: un botón inactivo deja pasar el
		-- clic al botón del pack de debajo y saldría el prompt de compra. `Selectable` refleja
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
			ensureGiftFlow():openForProduct(product :: any)
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
			El pass es permanente: a quien ya lo tiene el botón deja de comprar y lo dice. Si la
			GUI trae nodo `Owned` se muestra y el precio se esconde; si no, lo dice el label del
			precio, para que un dueño no quede ante un botón muerto sin explicación.
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

		if pass.PassId <= 0 then
			return
		end
		refreshOwnedByPassId[pass.PassId] = setOwned

		-- Una consulta por pass al arrancar la feature (llamada web): el estado solo cambia por
		-- una compra, que ya avisa por PromptGamePassPurchaseFinished.
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
			-- Re-chequeo del estado vivo (no el capturado al cablear): un pass comprado en otro
			-- sitio no debe acabar en un prompt de algo que ya se tiene.
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
