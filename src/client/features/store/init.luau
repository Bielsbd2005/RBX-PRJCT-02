--!strict

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local DataController = require(Client.core.data.DataController)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local StaggerReveal = require(Client.core.ui.animators.StaggerReveal)
local PanelController = require(Client.core.ui.PanelController)
local NavTabController = require(Client.core.ui.NavTabController)
local NavStaggerController = require(Client.core.ui.NavStaggerController)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local BlurController = require(Client.core.ui.BlurController)
local CameraFovEffect = require(Client.core.ui.CameraFovEffect)
local StoreProducts = require(Shared.constants.StoreProducts)
local Notify = require(Client.core.ui.NotificationController)
local GiftFlow = require(script.GiftFlow)

local BLUR_KEY = "Store"

local StoreFeature = {}

type StoreProductDefinition = StoreProducts.StoreProductDefinition
type GemProductDefinition = StoreProducts.GemProductDefinition

function StoreFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	-- Botón de apertura en Menu.Container.Store
	local container = menuGui:FindFirstChild("Container")
	local storeButtonInstance = container and container:FindFirstChild("Store")
	local storeButton: GuiButton? = if storeButtonInstance and storeButtonInstance:IsA("GuiButton")
		then storeButtonInstance
		else nil

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local storeFrame = uiGui:WaitForChild("Store") :: Frame

	-- Nav y CloseBtn son opcionales: durante la migración de la GUI el Store puede
	-- no tener barra de tabs todavía. Sin Nav, el panel se configura igual (solo se
	-- omite el sistema de pestañas) y se cierra vía CloseBtn si existe.
	local nav = storeFrame:FindFirstChild("Nav")
	local closeButton: GuiButton? = nil
	if nav then
		local closeNode = nav:FindFirstChild("CloseBtn")
		if closeNode and closeNode:IsA("GuiButton") then
			closeButton = closeNode
		end
	end

	-- Página de packs de Cash, estructurada en filas: Store.CashPage.Row1/Row2/…,
	-- cada fila con sus botones (Cash1…). Resolvemos el frame CashPage; si la GUI
	-- aún no migró, caemos al contenedor plano "Cash" (con Cash1… directo dentro),
	-- que tratamos como una fila implícita. Lo identificamos por contener Cash1
	-- para no confundir un tab de Nav ni el label de saldo "Cash".
	local function resolveCashPage(): GuiObject?
		local page = storeFrame:FindFirstChild(StoreProducts.Cash.PageName)
		if page and page:IsA("GuiObject") then
			return page
		end
		local direct = storeFrame:FindFirstChild("Cash")
		if direct and direct:IsA("GuiObject") and direct:FindFirstChild("Cash1") then
			return direct
		end
		for _, descendant in storeFrame:GetDescendants() do
			if descendant.Name == "Cash" and descendant:IsA("GuiObject") and descendant:FindFirstChild("Cash1") then
				return descendant :: GuiObject
			end
		end
		return nil
	end
	local cashPage = resolveCashPage()

	-- Página de packs de Gems (Store.GemsPage.<Row>.<ButtonName>). Es opcional:
	-- si la GUI todavía no la tiene, los packs simplemente no se cablean y el
	-- resto de la tienda funciona igual.
	local gemsPage: GuiObject? = nil
	do
		local page = storeFrame:FindFirstChild(StoreProducts.Gems.PageName)
		if page and page:IsA("GuiObject") then
			gemsPage = page
		end
	end

	-- Localiza un botón de producto dentro de su página: primero en su fila
	-- (<Page>.<Row>.<ButtonName>), luego suelto en la página (fallback para la
	-- estructura plana previa a las filas).
	-- Sirve para packs de Cash y de Gems: solo mira los campos de ProductBase,
	-- que ambas monedas comparten.
	local function findProductButton(page: GuiObject, product: StoreProducts.ProductBase): GuiButton?
		local rowContainer = page:FindFirstChild(product.Row)
		if rowContainer and rowContainer:IsA("GuiObject") then
			local inRow = rowContainer:FindFirstChild(product.ButtonName)
			if inRow and inRow:IsA("GuiButton") then
				return inRow
			end
		end
		local flat = page:FindFirstChild(product.ButtonName)
		if flat and flat:IsA("GuiButton") then
			return flat
		end
		return nil
	end

	-- ── Regalo (estado; el wiring vive más abajo) ────────────
	-- Cada pack de Robux regalable tiene un botón hijo "Gift" (Store.CashPage.
	-- <Row>.<Pack>.Gift) que abre el flujo de regalo (UserInterface.Gifting) para
	-- ESE pack. Declarado antes de bindCashButtons para que el click handler lo
	-- capture como upvalue (se instancia más abajo).
	local giftFlow: any = nil

	-- Reveal escalonado (pop stagger) de los items de cada página del Store:
	-- Store.<Page>.Row1/Row2/…, mismo criterio que antes solo aplicaba a
	-- CashPage.Row1. Una instancia de StaggerReveal por página (se rellenan
	-- tras registrar la Nav, tabla de tab-name → GuiObject).
	local pageReveals = {} :: { [string]: any }
	-- Tab que contiene la CashPage (se resuelve tras registrar la Nav): es la
	-- página por defecto al abrir el Store si existe.
	local cashTabName: string? = nil

	-- Items a revelar de una página: todos los GuiObject hijos directos de sus
	-- Row1, Row2, … (en ese orden, y por LayoutOrder dentro de cada fila).
	local function collectRowItems(pageFrame: GuiObject): { GuiObject }
		local items = {} :: { GuiObject }
		local rowIndex = 1
		while true do
			local row = pageFrame:FindFirstChild("Row" .. rowIndex)
			if not (row and row:IsA("GuiObject")) then
				break
			end
			local rowItems = {} :: { GuiObject }
			for _, child in row:GetChildren() do
				if child:IsA("GuiObject") then
					table.insert(rowItems, child)
				end
			end
			table.sort(rowItems, function(a, b)
				return a.LayoutOrder < b.LayoutOrder
			end)
			for _, item in rowItems do
				table.insert(items, item)
			end
			rowIndex += 1
		end
		return items
	end

	local function ensurePageReveal(name: string, pageFrame: GuiObject): any
		local existing = pageReveals[name]
		if existing then
			return existing
		end
		local reveal = StaggerReveal.new()
		janitor:Add(reveal, "Destroy")
		reveal:setItems(collectRowItems(pageFrame))
		pageReveals[name] = reveal
		return reveal
	end

	local fovEffect = CameraFovEffect.new()
	janitor:Add(fovEffect, "Destroy")
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	local function bindButtonScale(button: GuiButton)
		InteractiveScaleTween.bindButton(button, janitor, {
			enableHover = canUseHoverAnimations,
			hoverScale = UITheme.ButtonHoverScale,
			clickScale = UITheme.ButtonClickScale,
		})
	end

	local function applyProductToButton(button: GuiButton, product: StoreProducts.ProductBase, amount: number)
		local priceLabel = button:WaitForChild("Price") :: TextLabel
		local amountLabel = button:WaitForChild("Amount") :: TextLabel
		priceLabel.Text = product.PriceText
		amountLabel.Text = UIUtils.formatCashAmount(amount)

		button.Active = product.ProductId > 0
		button.Selectable = product.ProductId > 0
		button.AutoButtonColor = false
	end

	--[[
		Cablea todos los packs de un catálogo (Cash o Gems) sobre su página.
		Recorre el layout por filas (Row1, Row2, … en orden) y dentro de cada fila
		los productos en orden, así que reordenar StoreProducts reordena la UI sin
		tocar código.

		`giftable` es la única diferencia real entre ambas monedas: los packs de
		Gems NO llevan botón "Gift" a propósito. El flujo de regalo (GiftIntent en
		el servidor) está atado a los developer products de Cash, así que un regalo
		de Gems se entregaría como Cash. Hasta que el servidor lo soporte, mejor
		que la opción no exista a que entregue la moneda equivocada.
	]]
	local function bindCatalogButtons(
		page: GuiObject,
		catalog: StoreProducts.Catalog<any>,
		getAmount: (any) -> number,
		giftable: boolean
	)
		for _, row in catalog.Rows do
			for _, product in row.Products do
				local button = findProductButton(page, product)
				if not button then
					continue
				end

				applyProductToButton(button, product, getAmount(product))
				bindButtonScale(button)
				janitor:Add(button.Activated:Connect(function()
					if product.ProductId <= 0 then
						-- Sin developer product no hay compra posible.
						warn("[StoreFeature] ProductId no configurado para", product.ButtonName)
						return
					end
					MarketplaceService:PromptProductPurchase(player, product.ProductId)
				end), "Disconnect")

				-- Botón "Gift" del pack (opcional): abre el flujo de regalo para
				-- ESTE producto. Solo los packs regalables lo llevan en la GUI.
				local giftNode = if giftable then button:FindFirstChild("Gift") else nil
				if giftNode and giftNode:IsA("GuiButton") then
					local giftBtn = giftNode :: GuiButton
					bindButtonScale(giftBtn)
					janitor:Add(giftBtn.Activated:Connect(function()
						if product.ProductId <= 0 then
							Notify.warning("That item can't be gifted.")
							return
						end
						if giftFlow then
							giftFlow:openForProduct(product)
						end
					end), "Disconnect")
				end
			end
		end
	end

	if cashPage then
		bindCatalogButtons(cashPage, StoreProducts.Cash, function(product: StoreProductDefinition)
			return product.CashAmount
		end, true)
	else
		warn("[StoreFeature] No se encontró la CashPage (ni el contenedor plano 'Cash'); packs no cableados.")
	end

	-- Que falte la GemsPage es un estado válido mientras se termina de montar la
	-- GUI en Studio: los packs no se cablean y el resto de la tienda funciona.
	if gemsPage then
		bindCatalogButtons(gemsPage, StoreProducts.Gems, function(product: GemProductDefinition)
			return product.GemAmount
		end, false)
	end

	-- ── Nav tabs ─────────────────────────────────────────────
	local navFrames = {} :: { [string]: GuiObject }
	local activeNavTab: string? = nil
	local navTabController = NavTabController.new()
	janitor:Add(navTabController, "Destroy")

	local strokeTweens = {} :: { [GuiButton]: Tween }
	local function tweenStroke(button: GuiButton, stroke: UIStroke, color: Color3)
		local existing = strokeTweens[button]
		if existing then
			existing:Cancel()
		end
		local tween = TweenService:Create(stroke, UITheme.NavTweenInfo, { Color = color })
		strokeTweens[button] = tween
		tween:Play()
	end
	janitor:Add(function()
		for _, tween in strokeTweens do
			tween:Cancel()
		end
		table.clear(strokeTweens)
	end, true)

	-- Escala de los tabs consciente de la selección: el tab activo se mantiene en
	-- NavSelectedScale (más grande que el resto) y NO se encoge ni cambia con el
	-- hover/click; los inactivos hacen un pop sutil al pasar/clicar. Opera sobre la
	-- misma UIScale que usa NavTabController (un único nodo por botón), por eso no
	-- usamos InteractiveScaleTween aquí (metería una segunda UIScale en conflicto).
	local navScaleTweens = {} :: { [GuiButton]: Tween }
	local function getNavScaleNode(button: GuiButton): UIScale
		local existing = button:FindFirstChildOfClass("UIScale")
		if existing then
			return existing
		end
		local created = Instance.new("UIScale")
		created.Name = "NavScale"
		created.Parent = button
		return created
	end
	local function tweenNavScale(button: GuiButton, target: number)
		local node = getNavScaleNode(button)
		local existing = navScaleTweens[button]
		if existing then
			existing:Cancel()
		end
		local tween = TweenService:Create(node, UITheme.HoverTweenInfo, { Scale = target })
		navScaleTweens[button] = tween
		tween:Play()
	end
	janitor:Add(function()
		for _, tween in navScaleTweens do
			tween:Cancel()
		end
		table.clear(navScaleTweens)
	end, true)

	-- Forward decl: setActiveTab necesita llamar al tween de aparición del
	-- frame seleccionado, que se define más abajo con sus dependencias listas.
	-- `kind` controla la intensidad: "open" (entrada desde menú, pop grande)
	-- vs "switch" (cambio de tab, pop sutil).
	local playActiveNavFrameTween: (kind: "open" | "switch") -> ()
	-- Reveal escalonado de los items de la página activa; se asigna más abajo
	-- cuando la Nav ya está registrada (los pageReveals se construyen por tab).
	local playPageRevealIfActive: () -> ()

	local function setActiveTab(name: string)
		if activeNavTab == name then return end
		activeNavTab = name
		for tabName, frame in navFrames do
			frame.Visible = (tabName == name)
		end
		navTabController:setActive(name)
		if playActiveNavFrameTween then
			playActiveNavFrameTween("switch")
		end
		if playPageRevealIfActive then
			playPageRevealIfActive()
		end
	end

	for _, child in (if nav then nav:GetChildren() else {}) do
		if child:IsA("GuiButton") and child.Name ~= "CloseBtn" and child.Name ~= "Close" then
			local btn = child :: GuiButton
			local targetFrame = storeFrame:FindFirstChild(btn.Name)

			if targetFrame and targetFrame:IsA("GuiObject") then
				navFrames[btn.Name] = targetFrame
				navTabController:register(btn.Name, btn)

				local function isActiveTab()
					return activeNavTab == btn.Name
				end
				local hovered = false

				local stroke = btn:FindFirstChildOfClass("UIStroke")
				local defaultStrokeColor = if stroke then stroke.Color else nil

				janitor:Add(btn.MouseEnter:Connect(function()
					hovered = true
					if not canUseHoverAnimations then
						return
					end
					if stroke then
						tweenStroke(btn, stroke, UITheme.StrokeHover)
					end
					if not isActiveTab() then
						tweenNavScale(btn, UITheme.ButtonHoverScale)
					end
				end), "Disconnect")

				janitor:Add(btn.MouseLeave:Connect(function()
					hovered = false
					if stroke and defaultStrokeColor then
						tweenStroke(btn, stroke, defaultStrokeColor)
					end
					if not isActiveTab() then
						tweenNavScale(btn, UITheme.NavUnselectedScale)
					end
				end), "Disconnect")

				-- El tab activo no reacciona al click (se queda en NavSelectedScale);
				-- los inactivos sí hacen el pop de presión.
				janitor:Add(btn.MouseButton1Down:Connect(function()
					if not isActiveTab() then
						tweenNavScale(btn, UITheme.ButtonClickScale)
					end
				end), "Disconnect")

				janitor:Add(btn.MouseButton1Up:Connect(function()
					if isActiveTab() then
						return
					end
					local target = if hovered and canUseHoverAnimations
						then UITheme.ButtonHoverScale
						else UITheme.NavUnselectedScale
					tweenNavScale(btn, target)
				end), "Disconnect")

				janitor:Add(btn.Activated:Connect(function()
					setActiveTab(btn.Name)
				end), "Disconnect")
			end
		end
	end

	-- Tab por defecto: preferimos la página de packs (CashPage, o "Cash" legacy);
	-- si no existe, el primer tab registrado.
	cashTabName = if navFrames["CashPage"] then "CashPage"
		elseif navFrames["Cash"] then "Cash"
		else nil
	local hasSetDefault = false
	for name, frame in navFrames do
		if name == cashTabName or (not hasSetDefault and not cashTabName) then
			frame.Visible = true
			activeNavTab = name
			hasSetDefault = true
		else
			frame.Visible = false
		end
	end
	if activeNavTab then
		navTabController:setActive(activeNavTab)
	end

	-- Reveal por página: cada tab registrado en Nav consigue su propio
	-- StaggerReveal (Row1/Row2 de ese tab); sin barra de tabs (estructura plana),
	-- el propio Store hace de única página implícita.
	for name, frame in navFrames do
		ensurePageReveal(name, frame)
	end
	local flatPageReveal = if next(navFrames) == nil then ensurePageReveal("__store__", storeFrame) else nil

	playPageRevealIfActive = function()
		if flatPageReveal then
			flatPageReveal:play()
			return
		end
		local reveal = if activeNavTab then pageReveals[activeNavTab] else nil
		if reveal then
			reveal:play()
		end
	end

	-- ── Stagger de aparición de los items de Nav ─────────────
	-- Solo si hay Nav; sin barra de tabs no hay items que escalonar.
	local navStagger: any = nil
	if nav then
		navStagger = NavStaggerController.new({
			{ container = nav, getSelectedKey = function() return activeNavTab end },
		})
		janitor:Add(navStagger, "Destroy")
	end

	-- ── Tween de aparición del frame activo ──────────────────
	-- Dos perfiles:
	--   "open"   → entrada desde el menú (pop grande, Back.Out con overshoot).
	--   "switch" → cambio de tab dentro del store (pop sutil, Quad.Out).
	local NAV_FRAME_OPEN_START_SCALE = 0
	local NAV_FRAME_OPEN_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local NAV_FRAME_SWITCH_START_SCALE = 0.94
	local NAV_FRAME_SWITCH_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local navFrameScales: { [GuiObject]: UIScale } = {}
	local activeNavFrameTween: Tween? = nil

	local function ensureNavFrameScale(frame: GuiObject): UIScale
		local cached = navFrameScales[frame]
		if cached then return cached end
		local existing = frame:FindFirstChild("NavFrameScale")
		local scale: UIScale
		if existing and existing:IsA("UIScale") then
			scale = existing
		else
			scale = Instance.new("UIScale")
			scale.Name = "NavFrameScale"
			scale.Parent = frame
		end
		navFrameScales[frame] = scale
		return scale
	end

	playActiveNavFrameTween = function(kind: "open" | "switch")
		if activeNavFrameTween then
			activeNavFrameTween:Cancel()
			activeNavFrameTween = nil
		end
		local name = activeNavTab
		if not name then return end
		local frame = navFrames[name]
		if not frame then return end
		local startScale = if kind == "open" then NAV_FRAME_OPEN_START_SCALE else NAV_FRAME_SWITCH_START_SCALE
		local tweenInfo = if kind == "open" then NAV_FRAME_OPEN_TWEEN_INFO else NAV_FRAME_SWITCH_TWEEN_INFO
		local scale = ensureNavFrameScale(frame)
		scale.Scale = startScale
		local tween = TweenService:Create(scale, tweenInfo, { Scale = 1 })
		activeNavFrameTween = tween
		tween:Play()
	end

	janitor:Add(function()
		if activeNavFrameTween then
			activeNavFrameTween:Cancel()
			activeNavFrameTween = nil
		end
		for _, scale in navFrameScales do
			if scale.Parent ~= nil then
				scale.Scale = 1
			end
		end
		table.clear(navFrameScales)
	end, true)

	-- ── Saldo de Cash en vivo ─────────────────────────────────
	-- Store.Cash.Value muestra el efectivo actual del jugador, observando el estado
	-- reactivo de DataController.Stats (mismo patrón que el HUD del menú). Si el
	-- label no existe, se omite sin afectar al resto del panel.
	local cashBalanceNode = storeFrame:FindFirstChild("Cash")
	local cashValueNode = cashBalanceNode and cashBalanceNode:FindFirstChild("Value")
	if cashValueNode and cashValueNode:IsA("TextLabel") then
		local cashValueLabel = cashValueNode :: TextLabel
		local fusionScope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(fusionScope)
		end, true)

		DataController:WhenReady():andThen(function()
			local function updateCashBalance()
				local stats = Fusion.peek(DataController.Stats)
				if stats then
					cashValueLabel.Text = UIUtils.formatCashAmount(stats.Cash)
				end
			end
			local statsObserver = fusionScope:Observer(DataController.Stats)
			janitor:Add(statsObserver:onBind(updateCashBalance), true)
		end)
	end

	-- ── Gifting ──────────────────────────────────────────────
	-- El flujo de regalo (UserInterface.Gifting) lo abre el botón "Gift" de cada
	-- pack regalable (cableado en bindCashButtons). No hay ya un modo regalo
	-- global ni botón toggle en el Store.
	giftFlow = GiftFlow.new({
		menuController = menuController,
		storeFrame = storeFrame,
	}, janitor)

	-- ── Panel controller ──────────────────────────────────────
	local panel = PanelController.new(menuController, storeFrame, storeButton, closeButton, {
		animationMode = "none",
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			fovEffect:expand()
			if navStagger then
				navStagger:play()
			end
			playActiveNavFrameTween("open")
			playPageRevealIfActive()
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
			fovEffect:restore()
			-- Cerrar el panel (CloseBtn) descarta cualquier flujo de regalo colgado.
			if giftFlow then
				giftFlow:reset()
			end
		end,
	})
	janitor:Add(panel, "Destroy")

	return janitor
end

return StoreFeature
