--!strict
--[[
	store/init.luau (Client Feature)

	Panel de la tienda (UserInterface.Store).

		Store
		  CloseBtn
		  ScrollingFrame.Container.Content
		    CoinsRow    ← Cash1…Cash5   (packs de StoreProducts.Cash)
		    GemsRow     ← Gems1…Gems5   (packs de StoreProducts.Gems)
		    PassesRow, Bundles, y los títulos/subtítulos (sin cablear)

	Los botones ya existen en Studio con el nombre de su pack; aquí solo se les
	rellenan los labels (Amount/Price) y se les cuelga el PromptProductPurchase.
	Las filas se buscan por nombre en cualquier nivel bajo Store, así que re-anidar
	el ScrollingFrame/Container/Content en Studio no rompe el binder.

	TODO: PassesRow (gamepass VIP), Bundles, y el botón Gift por pack
	(GiftFlow en src/client/features/gifting/GiftFlow.luau).
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
local CameraFovEffect = require(Client.core.ui.CameraFovEffect)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local StoreProducts = require(Shared.constants.StoreProducts)

local BLUR_KEY = "Store"

-- Fila de la GUI donde vive cada catálogo de packs.
local CASH_ROW_NAME = "CoinsRow"
local GEMS_ROW_NAME = "GemsRow"

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

	local fovEffect = CameraFovEffect.new()
	janitor:Add(fovEffect, "Destroy")

	-- ── Packs de Robux (Cash y Gems) ─────────────────────────
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	local function resolveRow(rowName: string): GuiObject?
		local node = storeFrame:FindFirstChild(rowName, true)
		return if node and node:IsA("GuiObject") then node :: GuiObject else nil
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

	local function bindCatalogRow(rowName: string, catalog: StoreProducts.Catalog<any>, getAmount: (any) -> number)
		local row = resolveRow(rowName)
		if not row then
			warn(`[StoreFeature] Fila {rowName} no encontrada; packs no cableados.`)
			return
		end

		for _, product in catalog.InOrder do
			local buttonNode = row:FindFirstChild(product.ButtonName)
			if not (buttonNode and buttonNode:IsA("GuiButton")) then
				warn(`[StoreFeature] {rowName}.{product.ButtonName} no encontrado.`)
				continue
			end
			local button = buttonNode :: GuiButton

			applyProductToButton(button, product, getAmount(product))
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
	end)
	bindCatalogRow(GEMS_ROW_NAME, StoreProducts.Gems, function(product: StoreProducts.GemProductDefinition)
		return product.GemAmount
	end)

	local panel = PanelController.new(menuController, storeFrame, menuBtn, closeBtn, {
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			fovEffect:expand()
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
			fovEffect:restore()
		end,
	})
	janitor:Add(panel, "Destroy")

	return janitor
end

return StoreFeature
