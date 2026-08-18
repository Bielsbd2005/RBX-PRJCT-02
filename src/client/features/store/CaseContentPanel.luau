--!strict
--[[
	CaseContentPanel.luau
	Panel de detalle de una wrap case (UserInterface.CaseContent). Estructura:
	  CaseContent.Main               — vista de detalle de la case (compra + cards):
	    .Content.Template  — card por wrap del case:
	      .ViewportFrame — preview 3D del wrap (WeaponWrapPreviewer)
	      .Chance        — probabilidad ("60%")
	      .Name          — nombre del wrap
	    .Nav               — barra de botones:
	      .Purchase        — comprar (texto = precio)
	      .CloseBtn        — cerrar el panel
	  CaseContent.Reveal             — vista de resultado del unboxing:
	    .Frame   — tarjeta del wrap ganado (.Name y .Rarity, ambos opcionales)
	    .Equip   — equipar el wrap ganado
	    .Collect — solo cerrar

	Main y Reveal son estados EXCLUYENTES. Al comprar, Main se OCULTA (setMainHidden)
	mientras la cámara viaja a Workspace.Cameras.unboxing y rueda el cofre; al llegar
	el reveal, `showReveal` muestra Reveal SIN mover la cámara (el arma ganadora ya está
	plantada en el RevealSpawn, dentro de esa misma toma). Equip y Collect lo descartan.

	El panel solo PINTA y notifica (onPurchase, y en el reveal los callbacks
	onEquip/onCollect) — el flujo de compra/unboxing/red lo orquesta
	store/init.luau (envía los packets y decide el estado del botón vía
	setPurchaseState).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local WrapCasesConfig = require(Shared.constants.WrapCasesConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local UITheme = require(script.Parent.Parent.Parent.core.ui.UITheme)
local InteractiveScaleTween = require(script.Parent.Parent.Parent.core.ui.animators.InteractiveScaleTween)
local WeaponWrapPreviewer = require(script.Parent.Parent.locker.Previewers.WeaponWrapPreviewer)

-- ColorSequence por rareza para Template.UIGradient de la card (mismo set que la
-- card del locker); rarezas sin entrada caen al fallback Common.
local RARITY_GRADIENTS = UITheme.LockerRarityGradients
local RARITY_FALLBACK = "Common"

export type WrapCaseDefinition = WrapCasesConfig.WrapCaseDefinition

export type PurchaseState = "price" | "pending" | "completed"

-- Datos del reveal: qué se ganó (para la tarjeta Reveal.Frame) + callbacks de los
-- botones, que invoca el panel al pulsar Equip/Collect; la lógica (red, cierre) vive
-- en store/init.luau.
export type RevealInfo = {
	wrapName: string,
	rarity: string,
	onEquip: () -> (),
	onCollect: () -> (),
}

export type CaseContentPanel = {
	open: (self: CaseContentPanel, caseDefinition: WrapCaseDefinition) -> (),
	close: (self: CaseContentPanel) -> (),
	isOpen: (self: CaseContentPanel) -> boolean,
	getActiveCase: (self: CaseContentPanel) -> WrapCaseDefinition?,
	setPurchaseState: (self: CaseContentPanel, state: PurchaseState) -> (),
	setMainHidden: (self: CaseContentPanel, hidden: boolean) -> (),
	showReveal: (self: CaseContentPanel, info: RevealInfo) -> (),
}

type Callbacks = {
	onPurchase: (WrapCaseDefinition) -> (),
	-- Notifica cualquier cierre del panel (CloseBtn o programático) — el Store
	-- lo usa para restaurar su propia visibilidad.
	onClosed: (() -> ())?,
	canUseHoverAnimations: boolean,
}

local CaseContentPanel = {}
CaseContentPanel.__index = CaseContentPanel

-- El texto del botón Purchase puede vivir en el propio botón (TextButton) o en
-- un hijo (mismo patrón que los ActionBtn del Locker).
local function resolveButtonTextTarget(button: GuiButton): Instance?
	for _, name in { "Title", "Label", "Text", "Price", "Value" } do
		local child = button:FindFirstChild(name)
		if child and child:IsA("TextLabel") then
			return child
		end
	end
	if button:IsA("TextButton") then
		return button
	end
	return button:FindFirstChildWhichIsA("TextLabel", true)
end

local function formatChance(percent: number): string
	if percent >= 10 or percent == math.floor(percent) then
		return string.format("%d%%", math.floor(percent + 0.5))
	end
	return string.format("%.1f%%", percent)
end

function CaseContentPanel.new(uiGui: ScreenGui, parentJanitor: any, callbacks: Callbacks): CaseContentPanel?
	local frameNode = uiGui:FindFirstChild("CaseContent")
	if not (frameNode and frameNode:IsA("GuiObject")) then
		warn("[CaseContentPanel] Falta UserInterface.CaseContent; wrap cases deshabilitadas.")
		return nil
	end
	local frame = frameNode :: GuiObject

	-- Los controles de detalle viven bajo CaseContent.Main; si el place aún tiene
	-- la estructura plana (sin Main), caemos al propio frame — retrocompatible.
	local mainNode = frame:FindFirstChild("Main")
	local mainHost: GuiObject = if mainNode and mainNode:IsA("GuiObject") then mainNode :: GuiObject else frame

	-- Los botones viven bajo Main.Nav; si el place aún trae la estructura plana
	-- (botones sueltos en Main), caemos a mainHost — retrocompatible.
	local navNode = mainHost:FindFirstChild("Nav")
	local navHost: GuiObject = if navNode and navNode:IsA("GuiObject") then navNode :: GuiObject else mainHost

	local purchaseNode = navHost:FindFirstChild("Purchase")
	local closeNode = navHost:FindFirstChild("CloseBtn")
	local contentNode = mainHost:FindFirstChild("Content")
	local templateNode = if contentNode then contentNode:FindFirstChild("Template") else nil

	if not (purchaseNode and purchaseNode:IsA("GuiButton"))
		or not (closeNode and closeNode:IsA("GuiButton"))
		or not (contentNode and contentNode:IsA("GuiObject"))
		or not (templateNode and templateNode:IsA("GuiObject")) then
		warn("[CaseContentPanel] Estructura incompleta en CaseContent.Main (Nav.Purchase/Nav.CloseBtn/Content.Template).")
		return nil
	end

	-- Vista de reveal (opcional): frame propio con la tarjeta del resultado (.Frame,
	-- con .Name/.Rarity) y los botones Equip/Collect. Si falta, el unboxing degrada
	-- (showReveal ejecuta onCollect directo).
	local revealNode = frame:FindFirstChild("Reveal")
	local revealCardNode = if revealNode then revealNode:FindFirstChild("Frame") else nil
	local equipNode = if revealNode then revealNode:FindFirstChild("Equip") else nil
	local collectNode = if revealNode then revealNode:FindFirstChild("Collect") else nil

	local self = setmetatable({}, CaseContentPanel) :: any
	self._frame = frame
	self._mainNode = mainHost
	self._onClosed = callbacks.onClosed
	self._purchaseBtn = purchaseNode :: GuiButton
	self._purchaseTextTarget = resolveButtonTextTarget(purchaseNode :: GuiButton)
	self._purchaseDefaultColor = (purchaseNode :: GuiButton).BackgroundColor3
	self._closeBtn = closeNode :: GuiButton
	self._content = contentNode :: GuiObject
	self._template = templateNode :: GuiObject
	self._activeCase = nil :: WrapCaseDefinition?
	self._purchaseState = "price" :: PurchaseState
	self._canUseHoverAnimations = callbacks.canUseHoverAnimations

	-- Nodos del reveal (pueden faltar → showReveal degrada).
	self._revealNode = if revealNode and revealNode:IsA("GuiObject") then revealNode :: GuiObject else nil
	self._revealCardNode = if revealCardNode and revealCardNode:IsA("GuiObject") then revealCardNode :: GuiObject else nil
	self._equipBtn = if equipNode and equipNode:IsA("GuiButton") then equipNode :: GuiButton else nil
	self._collectBtn = if collectNode and collectNode:IsA("GuiButton") then collectNode :: GuiButton else nil
	self._revealShown = false
	-- Janitor por-reveal: conexiones de Equip/Collect.
	self._revealJanitor = Janitor.new()

	-- Janitor por-populate: viewports de las cards del case abierto.
	self._cardsJanitor = Janitor.new()
	self._janitor = Janitor.new()
	parentJanitor:Add(self._janitor, "Destroy")
	self._janitor:Add(self._cardsJanitor, "Destroy")
	self._janitor:Add(self._revealJanitor, "Destroy")

	self._template.Visible = false
	if self._revealNode then
		self._revealNode.Visible = false
	end
	frame.Visible = false

	InteractiveScaleTween.bindButton(self._purchaseBtn, self._janitor, {
		enableHover = callbacks.canUseHoverAnimations,
		hoverScale = UITheme.ButtonHoverScale,
		clickScale = UITheme.ButtonClickScale,
	})
	InteractiveScaleTween.bindButton(self._closeBtn, self._janitor, {
		enableHover = callbacks.canUseHoverAnimations,
		hoverScale = UITheme.ButtonHoverScale,
		clickScale = UITheme.ButtonClickScale,
	})

	self._janitor:Add(self._purchaseBtn.Activated:Connect(function()
		local activeCase = self._activeCase
		if activeCase and self._purchaseState == "price" then
			callbacks.onPurchase(activeCase)
		end
	end), "Disconnect")

	self._janitor:Add(self._closeBtn.Activated:Connect(function()
		self:close()
	end), "Disconnect")

	return self
end

function CaseContentPanel:_setPurchaseText(text: string)
	if self._purchaseTextTarget then
		(self._purchaseTextTarget :: any).Text = text
	end
end

function CaseContentPanel:_clearCards()
	self._cardsJanitor:Cleanup()
	for _, child in self._content:GetChildren() do
		if child ~= self._template and child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function CaseContentPanel:_populate(caseDefinition: WrapCaseDefinition)
	self:_clearCards()

	-- Cards en orden de probabilidad descendente (lo común primero).
	local orderedItems = table.clone(caseDefinition.Items)
	table.sort(orderedItems, function(a, b)
		if a.Weight ~= b.Weight then
			return a.Weight > b.Weight
		end
		return a.WrapId < b.WrapId
	end)

	for layoutOrder, caseItem in ipairs(orderedItems) do
		local wrapDefinition = ItemsConfig.WeaponWraps[caseItem.WrapId]
		if type(wrapDefinition) ~= "table" then
			warn("[CaseContentPanel] Wrap de case sin definición en ItemsConfig:", caseItem.WrapId)
			continue
		end

		local card = self._template:Clone()
		card.Name = caseItem.WrapId
		card.LayoutOrder = layoutOrder
		card.Visible = true

		local nameNode = card:FindFirstChild("Name")
		if nameNode and nameNode:IsA("TextLabel") then
			nameNode.Text = tostring(wrapDefinition.Name or caseItem.WrapId)
		end

		local chanceNode = card:FindFirstChild("Chance")
		if chanceNode and chanceNode:IsA("TextLabel") then
			chanceNode.Text = formatChance(WrapCasesConfig.GetChancePercent(caseDefinition, caseItem.WrapId))
		end

		local rarity = tostring(wrapDefinition.Rarity or RARITY_FALLBACK)

		-- Gradiente de rareza en Template.UIGradient (hijo directo de la card),
		-- mismo set y fallback Common que la card del locker
		-- (LockerGrid._applyRarityVisuals).
		local gradientNode = card:FindFirstChildOfClass("UIGradient")
		if gradientNode then
			local gradient = RARITY_GRADIENTS[rarity] or RARITY_GRADIENTS[RARITY_FALLBACK]
			if gradient then
				gradientNode.Color = gradient
			end
		end

		local viewportNode = card:FindFirstChild("ViewportFrame")
		if viewportNode and viewportNode:IsA("ViewportFrame") then
			local ok = WeaponWrapPreviewer.Render(viewportNode, {
				TextureID = wrapDefinition.TextureID,
				BaseColor = wrapDefinition.BaseColor,
				Material = wrapDefinition.Material,
				isAnimated = wrapDefinition.isAnimated,
				StudsPerTile = wrapDefinition.StudsPerTile,
			}, self._cardsJanitor)
			if ok then
				WeaponWrapPreviewer.reframeCentered(viewportNode)
			end
		end

		card.Parent = self._content
		self._cardsJanitor:Add(card, "Destroy")
	end
end

function CaseContentPanel:open(caseDefinition: WrapCaseDefinition)
	self._activeCase = caseDefinition
	self:_populate(caseDefinition)
	self:setPurchaseState("price")
	-- Estado inicial: Nav en modo compra (Purchase/CloseBtn visibles, Equip/Collect
	-- ocultos), por si se reabre justo tras un reveal.
	self:_hideReveal()
	self._mainNode.Visible = true
	self._frame.Visible = true
end

-- Cierra el reveal: suelta las conexiones de Equip/Collect, oculta su frame y vuelve
-- a mostrar Main. Idempotente.
function CaseContentPanel:_hideReveal()
	if self._revealShown then
		self._revealShown = false
		self._revealJanitor:Cleanup()
	end
	if self._revealNode then
		self._revealNode.Visible = false
	end
	self._mainNode.Visible = true
end

function CaseContentPanel:close()
	local wasOpen = self._activeCase ~= nil
	self._activeCase = nil
	self:_hideReveal()
	self._frame.Visible = false
	self:_clearCards()
	if wasOpen and self._onClosed then
		self._onClosed()
	end
end

function CaseContentPanel:isOpen(): boolean
	return self._activeCase ~= nil
end

function CaseContentPanel:getActiveCase(): WrapCaseDefinition?
	return self._activeCase
end

-- Estado del botón Purchase:
--   "price"     → comprable; texto = precio de la case.
--   "pending"   → request en vuelo / animación en curso.
--   "completed" → el jugador ya posee todas las combinaciones de la case.
function CaseContentPanel:setPurchaseState(state: PurchaseState)
	self._purchaseState = state
	local activeCase = self._activeCase
	local enabled = state == "price" and activeCase ~= nil

	if state == "price" and activeCase then
		self:_setPurchaseText(UIUtils.formatCashAmount(activeCase.Price))
	elseif state == "pending" then
		self:_setPurchaseText("OPENING...")
	elseif state == "completed" then
		self:_setPurchaseText("COMPLETED")
	end

	self._purchaseBtn.Active = enabled
	self._purchaseBtn.Selectable = enabled
	self._purchaseBtn.BackgroundColor3 = if enabled
		then self._purchaseDefaultColor
		else Color3.fromRGB(120, 120, 120)
end

-- Oculta/muestra la vista Main sin perder el case activo. Durante el unboxing el
-- panel estorba (la cámara viaja a Cameras.unboxing y la escena es 3D), así que se
-- oculta; showReveal lo devuelve a la vista al llegar el reveal.
function CaseContentPanel:setMainHidden(hidden: boolean)
	self._mainNode.Visible = not hidden and self._activeCase ~= nil
end

-- Pinta la tarjeta del resultado (Reveal.Frame): nombre y rareza del wrap ganado, con
-- el texto de la rareza coloreado por UITheme.RarityColors. Degrada silenciosamente si
-- falta la tarjeta o alguno de los labels.
function CaseContentPanel:_paintRevealCard(info: RevealInfo)
	local card = self._revealCardNode
	if not card then
		return
	end

	local nameNode = card:FindFirstChild("Name")
	if nameNode and nameNode:IsA("TextLabel") then
		nameNode.Text = info.wrapName
	end

	local rarityNode = card:FindFirstChild("Rarity")
	if rarityNode and rarityNode:IsA("TextLabel") then
		rarityNode.Text = info.rarity
		local rarityColor = UITheme.RarityColors[info.rarity]
		if rarityColor then
			rarityNode.TextColor3 = rarityColor
		end
	end
end

-- Entra en modo reveal: muestra el frame CaseContent.Reveal (con Equip/Collect) sobre
-- la toma del unboxing, que NO cambia. Main sigue oculto desde el unboxing: Reveal lo
-- sustituye. El panel NO se cierra solo: Equip/Collect invocan el callback
-- correspondiente de `info` (la red/cierre los orquesta store/init.luau). Sin nodos de
-- reveal en la GUI, degrada ejecutando onCollect directo para no bloquear el flujo.
function CaseContentPanel:showReveal(info: RevealInfo)
	if not (self._revealNode and (self._equipBtn or self._collectBtn)) then
		info.onCollect()
		return
	end
	if self._revealShown then
		return
	end
	self._revealShown = true

	self:_paintRevealCard(info)

	local equipBtn = self._equipBtn
	if equipBtn then
		InteractiveScaleTween.bindButton(equipBtn, self._revealJanitor, {
			enableHover = self._canUseHoverAnimations,
			hoverScale = UITheme.ButtonHoverScale,
			clickScale = UITheme.ButtonClickScale,
		})
		equipBtn.Active = true
		self._revealJanitor:Add(equipBtn.Activated:Connect(function()
			info.onEquip()
		end), "Disconnect")
	end

	local collectBtn = self._collectBtn
	if collectBtn then
		InteractiveScaleTween.bindButton(collectBtn, self._revealJanitor, {
			enableHover = self._canUseHoverAnimations,
			hoverScale = UITheme.ButtonHoverScale,
			clickScale = UITheme.ButtonClickScale,
		})
		collectBtn.Active = true
		self._revealJanitor:Add(collectBtn.Activated:Connect(function()
			info.onCollect()
		end), "Disconnect")
	end

	-- Intercambio Main → Reveal (Main ya venía oculto del unboxing).
	self._mainNode.Visible = false
	self._revealNode.Visible = true
	self._frame.Visible = self._activeCase ~= nil
end

return CaseContentPanel
