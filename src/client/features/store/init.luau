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
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local PanelController = require(Client.core.ui.PanelController)
local NavTabController = require(Client.core.ui.NavTabController)
local NavStaggerController = require(Client.core.ui.NavStaggerController)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local BlurController = require(Client.core.ui.BlurController)
local CameraFovEffect = require(Client.core.ui.CameraFovEffect)
local StoreProducts = require(Shared.constants.StoreProducts)
local GiftingController = require(script.GiftingController)

local BLUR_KEY = "Store"

local StoreFeature = {}

type StoreProductDefinition = StoreProducts.StoreProductDefinition

function StoreFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	-- Botón de apertura opcional en Menu.Nav.Store. Si no existe, el Store se
	-- configura igual, solo sin abrirse desde el menú.
	local navContainer = menuGui:FindFirstChild("Nav")
	local storeButtonInstance = navContainer and navContainer:FindFirstChild("Store")
	local storeButton: GuiButton? = if storeButtonInstance and storeButtonInstance:IsA("GuiButton")
		then storeButtonInstance
		else nil

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local storeFrame = uiGui:WaitForChild("Store") :: Frame

	local nav = storeFrame:WaitForChild("Nav")
	local closeButton = nav:WaitForChild("CloseBtn") :: GuiButton

	local cashContainer = storeFrame:WaitForChild("Cash") :: GuiObject

	local fovEffect = CameraFovEffect.new()
	janitor:Add(fovEffect, "Destroy")
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled

	local function applyProductToButton(button: GuiButton, product: StoreProductDefinition)
		local priceLabel = button:WaitForChild("Price") :: TextLabel
		local amountLabel = button:WaitForChild("Ammount") :: TextLabel
		priceLabel.Text = product.PriceText
		amountLabel.Text = UIUtils.formatCashAmount(product.CashAmount)

		button.Active = product.ProductId > 0
		button.Selectable = product.ProductId > 0
		button.AutoButtonColor = false
	end

	local function bindCashButtons()
		for _, product in StoreProducts.ProductsInOrder do
			local buttonNode = cashContainer:FindFirstChild(product.ButtonName)
			if buttonNode and buttonNode:IsA("GuiButton") then
				local button = buttonNode :: GuiButton
				applyProductToButton(button, product)
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
	end

	bindCashButtons()

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

	-- Forward decl: setActiveTab necesita llamar al tween de aparición del
	-- frame seleccionado, que se define más abajo con sus dependencias listas.
	-- `kind` controla la intensidad: "open" (entrada desde menú, pop grande)
	-- vs "switch" (cambio de tab, pop sutil).
	local playActiveNavFrameTween: (kind: "open" | "switch") -> ()

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
	end

	for _, child in nav:GetChildren() do
		if child:IsA("GuiButton") and child.Name ~= "CloseBtn" and child.Name ~= "Close" then
			local btn = child :: GuiButton
			local targetFrame = storeFrame:FindFirstChild(btn.Name)

			if targetFrame and targetFrame:IsA("GuiObject") then
				navFrames[btn.Name] = targetFrame
				navTabController:register(btn.Name, btn)

				local stroke = btn:FindFirstChildOfClass("UIStroke")
				if stroke then
					local defaultColor = stroke.Color

					janitor:Add(btn.MouseEnter:Connect(function()
						if canUseHoverAnimations then
							tweenStroke(btn, stroke, UITheme.StrokeHover)
						end
					end), "Disconnect")

					janitor:Add(btn.MouseLeave:Connect(function()
						tweenStroke(btn, stroke, defaultColor)
					end), "Disconnect")
				end

				janitor:Add(btn.Activated:Connect(function()
					setActiveTab(btn.Name)
				end), "Disconnect")
			end
		end
	end

	local hasSetDefault = false
	for name, frame in navFrames do
		if name == "Cash" or (not hasSetDefault and not navFrames["Cash"]) then
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

	-- ── Stagger de aparición de los items de Nav ─────────────
	local navStagger = NavStaggerController.new({
		{ container = nav, getSelectedKey = function() return activeNavTab end },
	})
	janitor:Add(navStagger, "Destroy")

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

	-- ── Gifting ──────────────────────────────────────────────
	-- Selección del destinatario de un regalo. La pestaña se auto-registra arriba
	-- (Store.Nav.Gifting + Store.Gifting); aquí cableamos su máquina de estados.
	-- Si la GUI aún no tiene los hijos esperados, la pestaña queda inerte.
	local giftingController: any = nil
	local giftingFrame = storeFrame:FindFirstChild("Gifting")
	if giftingFrame and giftingFrame:IsA("GuiObject") then
		local textBox = giftingFrame:FindFirstChild("TextBox")
		local actionBtn = giftingFrame:FindFirstChild("ActionBtn")
		local profile = giftingFrame:FindFirstChild("Profile")
		local title = giftingFrame:FindFirstChild("Title")
		if textBox and textBox:IsA("TextBox")
			and actionBtn and actionBtn:IsA("GuiButton")
			and profile and profile:IsA("GuiObject")
			and title and title:IsA("GuiObject")
		then
			giftingController = GiftingController.new({
				frame = giftingFrame,
				textBox = textBox,
				actionBtn = actionBtn,
				profile = profile,
				title = title,
			}, janitor)
		else
			warn("[StoreFeature] Gifting: faltan hijos (TextBox/ActionBtn/Profile/Title); pestaña inactiva.")
		end
	end

	-- ── Panel controller ──────────────────────────────────────
	local panel = PanelController.new(menuController, storeFrame, storeButton, closeButton, {
		animationMode = "none",
		onOpen = function()
			BlurController.acquire(BLUR_KEY)
			fovEffect:expand()
			navStagger:play()
			playActiveNavFrameTween("open")
		end,
		onClose = function()
			BlurController.release(BLUR_KEY)
			fovEffect:restore()
			-- Cerrar el panel (CloseBtn) cancela el regalo en curso.
			if giftingController then
				giftingController:reset()
			end
		end,
	})
	janitor:Add(panel, "Destroy")

	return janitor
end

return StoreFeature
