--!strict
--[[
	Vista de banners del Locker (Effects → Banners). No usa la grid de ítems
	(Locker.Content.ScrollingFrame): mientras está activa esa grid se oculta y se
	muestra Locker.Content.Banners, un ScrollingFrame propio con una tarjeta por
	banner poseído clonada de Banners.Template.

	Template (ImageButton):
	  · Image     → el banner (Image de ItemsConfig.Banners).
	  · UIStroke  → solo encendido en el banner equipado.
	  · Equiped   → TextLabel, solo visible en el banner equipado.

	Pulsar una tarjeta equipa ese banner. Sin preview ni panel de compra: los
	banners solo se consiguen en el pase, así que aquí solo aparecen los poseídos.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any
local LockerGrid = require(script.Parent:WaitForChild("LockerGrid"))

type LockerCatalogItem = LockerGrid.LockerCatalogItem

export type Callbacks = {
	canInteract: () -> boolean,
	isItemEquipped: (item: LockerCatalogItem) -> boolean,
	onActivated: (item: LockerCatalogItem) -> (),
}

type BannerCard = {
	root: ImageButton,
	item: LockerCatalogItem,
	stroke: UIStroke?,
	equippedLabel: GuiObject?,
}

-- Mismo ritmo de entrada que las cards de la grid (LockerGrid.PlayStagger).
local STAGGER_DELAY = 0.025
local STAGGER_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local LockerBanners = {}
LockerBanners.__index = LockerBanners

-- El TextLabel de "equipado" se llama Equiped en la GUI; se acepta también la
-- grafía correcta por si se renombra.
local function findEquippedLabel(card: Instance): GuiObject?
	local node = card:FindFirstChild("Equiped") or card:FindFirstChild("Equipped")
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

function LockerBanners.new(frame: ScrollingFrame, template: ImageButton, referenceGrid: ScrollingFrame, callbacks: Callbacks)
	local self = setmetatable({}, LockerBanners)
	self._frame = frame
	self._template = template
	self._callbacks = callbacks
	self._cards = {} :: { BannerCard }
	self._cardsJanitor = Janitor.new()
	self._staggerTweens = {} :: { Tween }

	-- Mismo dimensionado del canvas que la grid de ítems; si esta no lo tiene
	-- automático, aquí se fuerza Y porque el nº de banners cambia con el inventario.
	frame.CanvasSize = referenceGrid.CanvasSize
	frame.AutomaticCanvasSize = if referenceGrid.AutomaticCanvasSize ~= Enum.AutomaticSize.None
		then referenceGrid.AutomaticCanvasSize
		else Enum.AutomaticSize.Y

	template.Visible = false
	frame.Visible = false
	return self
end

function LockerBanners:_cancelStagger()
	for _, tween in self._staggerTweens do
		tween:Cancel()
	end
	table.clear(self._staggerTweens)
end

function LockerBanners:_clearCards()
	self:_cancelStagger()
	self._cardsJanitor:Cleanup()
	for _, card in self._cards do
		card.root:Destroy()
	end
	table.clear(self._cards)
end

function LockerBanners:_updateCard(card: BannerCard)
	local equipped = self._callbacks.isItemEquipped(card.item)
	if card.stroke then
		card.stroke.Enabled = equipped
	end
	if card.equippedLabel then
		card.equippedLabel.Visible = equipped
	end
end

function LockerBanners:_createCard(item: LockerCatalogItem, layoutOrder: number): BannerCard
	local template: ImageButton = self._template
	local root = template:Clone()
	root.Name = item.id
	root.LayoutOrder = layoutOrder
	root.Visible = true
	root.Image = item.Image

	local card: BannerCard = {
		root = root,
		item = item,
		stroke = root:FindFirstChildOfClass("UIStroke"),
		equippedLabel = findEquippedLabel(root),
	}

	self._cardsJanitor:Add(root.Activated:Connect(function()
		if not self._callbacks.canInteract() or self._callbacks.isItemEquipped(item) then
			return
		end
		self._callbacks.onActivated(item)
	end), "Disconnect")

	self:_updateCard(card)
	root.Parent = self._frame
	return card
end

-- Muestra la vista con `items` (ya filtrados y ordenados). `stagger` = entrada
-- animada, solo en interacciones del jugador (no en refrescos por datos).
function LockerBanners:Show(items: { LockerCatalogItem }, stagger: boolean?)
	self:_clearCards()
	for index, item in items do
		table.insert(self._cards, self:_createCard(item, index))
	end
	self._frame.Visible = true

	if stagger then
		self._frame.CanvasPosition = Vector2.zero
		for index, card in self._cards do
			local scale = Instance.new("UIScale")
			scale.Scale = 0
			scale.Parent = card.root
			local info = TweenInfo.new(
				STAGGER_TWEEN_INFO.Time,
				STAGGER_TWEEN_INFO.EasingStyle,
				STAGGER_TWEEN_INFO.EasingDirection,
				0,
				false,
				(index - 1) * STAGGER_DELAY
			)
			local tween = TweenService:Create(scale, info, { Scale = 1 })
			table.insert(self._staggerTweens, tween)
			tween:Play()
		end
	end
end

function LockerBanners:Hide()
	self._frame.Visible = false
	self:_clearCards()
end

function LockerBanners:IsVisible(): boolean
	return self._frame.Visible
end

-- Repinta el estado de equipado sin reconstruir (cambio de Loadout, equip en vuelo).
function LockerBanners:Refresh()
	for _, card in self._cards do
		self:_updateCard(card)
	end
end

function LockerBanners:Destroy()
	self:_clearCards()
	self._cardsJanitor:Destroy()
end

return LockerBanners
