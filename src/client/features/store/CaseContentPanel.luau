--!strict
--[[
	CaseContentPanel.luau
	Panel de detalle de una wrap case (UserInterface.CaseContent). Estructura:
	  CaseContent.Purchase           — botón de compra (texto = precio)
	  CaseContent.CloseBtn           — cerrar el panel
	  CaseContent.Title              — nombre de la case
	  CaseContent.Content.Template   — card por wrap del case:
	    .ViewportFrame — preview 3D del wrap (WeaponWrapPreviewer)
	    .Chance        — probabilidad ("60%")
	    .Name          — nombre del wrap
	    .Rarity        — rareza (coloreada con UITheme.RarityColors)

	El panel solo PINTA y notifica onPurchase — el flujo de compra/unboxing
	lo orquesta store/init.luau (envía el packet y decide el estado del botón
	vía setPurchaseState).
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

export type WrapCaseDefinition = WrapCasesConfig.WrapCaseDefinition

export type PurchaseState = "price" | "pending" | "completed"

export type CaseContentPanel = {
	open: (self: CaseContentPanel, caseDefinition: WrapCaseDefinition) -> (),
	close: (self: CaseContentPanel) -> (),
	isOpen: (self: CaseContentPanel) -> boolean,
	getActiveCase: (self: CaseContentPanel) -> WrapCaseDefinition?,
	setPurchaseState: (self: CaseContentPanel, state: PurchaseState) -> (),
	setTemporarilyHidden: (self: CaseContentPanel, hidden: boolean) -> (),
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

	local purchaseNode = frame:FindFirstChild("Purchase")
	local closeNode = frame:FindFirstChild("CloseBtn")
	local contentNode = frame:FindFirstChild("Content")
	local titleNode = frame:FindFirstChild("Title")
	local templateNode = if contentNode then contentNode:FindFirstChild("Template") else nil

	if not (purchaseNode and purchaseNode:IsA("GuiButton"))
		or not (closeNode and closeNode:IsA("GuiButton"))
		or not (contentNode and contentNode:IsA("GuiObject"))
		or not (templateNode and templateNode:IsA("GuiObject")) then
		warn("[CaseContentPanel] Estructura incompleta en CaseContent (Purchase/CloseBtn/Content.Template).")
		return nil
	end

	local self = setmetatable({}, CaseContentPanel) :: any
	self._frame = frame
	self._onClosed = callbacks.onClosed
	self._purchaseBtn = purchaseNode :: GuiButton
	self._purchaseTextTarget = resolveButtonTextTarget(purchaseNode :: GuiButton)
	self._purchaseDefaultColor = (purchaseNode :: GuiButton).BackgroundColor3
	self._closeBtn = closeNode :: GuiButton
	self._content = contentNode :: GuiObject
	self._template = templateNode :: GuiObject
	self._titleLabel = if titleNode and titleNode:IsA("TextLabel") then titleNode else nil
	self._activeCase = nil :: WrapCaseDefinition?
	self._purchaseState = "price" :: PurchaseState
	-- Janitor por-populate: viewports de las cards del case abierto.
	self._cardsJanitor = Janitor.new()
	self._janitor = Janitor.new()
	parentJanitor:Add(self._janitor, "Destroy")
	self._janitor:Add(self._cardsJanitor, "Destroy")

	self._template.Visible = false
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

		local rarityNode = card:FindFirstChild("Rarity")
		if rarityNode and rarityNode:IsA("TextLabel") then
			local rarity = tostring(wrapDefinition.Rarity or "Common")
			rarityNode.Text = rarity
			local rarityColor = UITheme.RarityColors[rarity]
			if rarityColor then
				rarityNode.TextColor3 = rarityColor
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
	if self._titleLabel then
		self._titleLabel.Text = caseDefinition.Name
	end
	self:_populate(caseDefinition)
	self:setPurchaseState("price")
	self._frame.Visible = true
end

function CaseContentPanel:close()
	local wasOpen = self._activeCase ~= nil
	self._activeCase = nil
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

-- Oculta el panel sin perder el case activo (durante la animación de unboxing).
function CaseContentPanel:setTemporarilyHidden(hidden: boolean)
	self._frame.Visible = not hidden and self._activeCase ~= nil
end

return CaseContentPanel
