--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local StoreProducts = require(Shared.constants.StoreProducts)

local PRODUCTS_BY_PRODUCT_ID = StoreProducts.ProductsByProductId :: { [number]: { CashAmount: number } }

local StoreService = {}

local _dataService: any = nil
local _started = false

local function processReceipt(receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision
	local product = PRODUCTS_BY_PRODUCT_ID[receiptInfo.ProductId]
	if not product then
		warn("[StoreService] Developer product is not configured:", receiptInfo.ProductId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not _dataService then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local success = _dataService:Increment(player, { "Stats", "Cash" }, product.CashAmount)
	if not success then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function StoreService:Start(dataService: any): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	-- ProcessReceipt se registra en CasesService para manejar
	-- tanto los productos de la tienda como el lucky boost.
end

function StoreService:ProcessReceipt(receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision?
	return processReceipt(receiptInfo)
end

return StoreService
