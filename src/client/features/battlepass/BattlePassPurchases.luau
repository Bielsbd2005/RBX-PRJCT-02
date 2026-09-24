--!strict
--[[
	Compras del pase: saltar 1 o 5 niveles (developer products con Robux, los concede el
	servidor en ProcessReceipt) y el Premium (con Gems, Network.BattlePass.BuyPremium).
	También avisa de lo que responde el servidor a reclamar o comprar.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Client = script.Parent.Parent.Parent
local Fusion = require(ReplicatedStorage:WaitForChild("Packages").fusion) :: any
local DataController = require(Client.core.data.DataController)
local Notify = require(Client.core.ui.NotificationController)
local Network = require(Shared.networking.Network)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)

-- El espacio inicial separa del icono de Robux, igual que en la tienda.
local SKIP_PRICE_FORMAT = " %d"

local SUCCESS_MESSAGES: { [string]: string } = {
	OK = "Reward claimed!",
	PremiumGranted = "Premium unlocked!",
	SkipGranted = "Level skipped!",
	Skip5Granted = "5 levels skipped!",
}

-- Fallos que el jugador puede resolver: notificación. El resto solo va al log.
local FAILURE_MESSAGES: { [string]: string } = {
	GemsInsufficient = "Not enough Gems. Get more in the store.",
	AlreadyOwned = "You already own the Premium pass.",
	SeasonCompleted = "You already completed the season.",
}

export type Deps = {
	janitor: any,
	skipButton: Instance?,
	skip5Button: Instance?,
	purchaseButton: Instance?,
	getSeason: () -> any,
	getMaxTier: () -> number,
}

local BattlePassPurchases = {}

-- Antes de cobrar se comprueba que queden niveles suficientes. ProductId = 0 (producto
-- sin crear) → botón inactivo.
local function bindSkipButton(deps: Deps, buttonNode: Instance?, buttonName: string, kind: BattlePassConfig.SkipKind)
	if not (buttonNode and buttonNode:IsA("GuiButton")) then
		warn(("[BattlePassFeature] BattlePass.%s no existe"):format(buttonName))
		return
	end
	local button = buttonNode :: GuiButton
	local productId, robuxPrice, tierCount = BattlePassConfig.GetSkipOffer(deps.getSeason(), kind)

	local priceNode = button:FindFirstChild("Price")
	if priceNode and priceNode:IsA("TextLabel") and robuxPrice > 0 then
		priceNode.Text = SKIP_PRICE_FORMAT:format(robuxPrice)
	end
	button.Active = productId > 0
	button.Selectable = productId > 0

	deps.janitor:Add(button.MouseButton1Click:Connect(function()
		if productId <= 0 then
			warn("[BattlePassFeature] ProductId no configurado para", buttonName)
			return
		end
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) == "table" then
			local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
			local remaining = deps.getMaxTier() - currentTier + 1
			if remaining <= 0 then
				Notify.warning("You already completed the season.")
				return
			end
			if remaining < tierCount then
				Notify.warning(("Only %d levels left in the season."):format(remaining))
				return
			end
		end
		MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
	end), "Disconnect")
end

function BattlePassPurchases.bind(deps: Deps)
	bindSkipButton(deps, deps.skipButton, "SkipLevel", "Skip")
	bindSkipButton(deps, deps.skip5Button, "SkipLevel5", "Skip5")

	local purchaseButton = deps.purchaseButton
	if purchaseButton and purchaseButton:IsA("GuiButton") then
		deps.janitor:Add(purchaseButton.MouseButton1Click:Connect(function()
			Network.BattlePass.BuyPremium.Send({})
		end), "Disconnect")
	end

	deps.janitor:Add(Network.BattlePass.Response.Listen(function(data: any)
		if type(data) ~= "table" then
			return
		end
		if data.success then
			local message = SUCCESS_MESSAGES[data.message]
			if message then
				Notify.success(message)
			end
			return
		end
		local message = FAILURE_MESSAGES[data.message]
		if message then
			Notify.warning(message)
		end
		warn(("[BattlePassFeature] Response: %s (tier=%s)"):format(tostring(data.message), tostring(data.tier)))
	end), true)
end

return BattlePassPurchases
