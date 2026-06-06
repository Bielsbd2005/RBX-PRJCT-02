--!strict
-- PurchaseFlowController.luau (Client Feature Library)
-- Coordina el flujo de compra de items, incluyendo comprobaciones de saldo y nivel,
-- compras con Cash (vía Network) y prompts de Robux (MarketplaceService) para paquetes de Cash.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StoreProducts = require(Shared.constants.StoreProducts)
local Network = require(Shared.networking.Network)

local LocalPlayer = Players.LocalPlayer

type LockerCatalogItem = {
	qualifiedId: string,
	Category: string,
	id: string,
	Name: string,
	Price: number,
	LevelRequired: number,
	Rarity: string,
	Image: string,
	CanPurchase: boolean,
	TextureID: string?,
	BaseColor: Color3?,
	isAnimated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponId: string?,
	PreviewWeaponDisplayName: string?,
	KillGoal: number?,
	KillProgress: number?,
}

type PendingShopAction = {
	kind: "buy" | "equip",
	item: LockerCatalogItem,
}

local PurchaseFlowController = {}
PurchaseFlowController.__index = PurchaseFlowController

function PurchaseFlowController.new()
	local self = setmetatable({}, PurchaseFlowController)
	return self
end

function PurchaseFlowController:promptBestFitPack(item: LockerCatalogItem, currentCash: number)
	local deficit = item.Price - currentCash
	local bestPack = nil

	for _, pack in ipairs(StoreProducts.ProductsInOrder) do
		if pack.CashAmount >= deficit and pack.ProductId > 0 then
			bestPack = pack
			break
		end
	end

	if not bestPack then
		local largest = StoreProducts.ProductsInOrder[#StoreProducts.ProductsInOrder]
		if largest and largest.ProductId > 0 then
			bestPack = largest
		end
	end

	if bestPack then
		MarketplaceService:PromptProductPurchase(LocalPlayer, bestPack.ProductId)
	end
end

function PurchaseFlowController:startPurchase(
	item: LockerCatalogItem,
	currentCash: number,
	currentLevel: number,
	isOwned: boolean,
	getWeaponWrapRequestContext: (category: string) -> (string, string),
	onBuyStarted: (buyAction: PendingShopAction) -> ()
)
	if currentLevel < item.LevelRequired then
		return
	end

	if isOwned then
		return
	end

	if item.KillGoal ~= nil and item.KillGoal > 0 then
		-- Los wraps de desafío de kills no se compran
		return
	end

	if currentCash < item.Price then
		self:promptBestFitPack(item, currentCash)
		return
	end

	local buyAction: PendingShopAction = {
		kind = "buy",
		item = item,
	}

	onBuyStarted(buyAction)

	local weaponCategory, weaponId = getWeaponWrapRequestContext(item.Category)

	Network.Shop.BuyItem.Send({
		itemId = item.id,
		category = item.Category,
		weaponCategory = weaponCategory,
		weaponId = weaponId,
	})
end

return PurchaseFlowController
