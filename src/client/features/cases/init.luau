--!strict
--[[
	CasesFeature  (Client)
	Sistema completo de cajas:
	  - Navegación entre cases (Nav1) con efecto de selección tipo Store
	  - Visualización de drops con previews de wraps en ViewportFrame
	  - Compra de summon single / multi (Cash)
	  - Compra de Lucky boost (Robux via MarketplaceService)
	  - Barra de pity y contador
	  - NO incluye la animación de unboxing (se implementará después)
]]

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
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local CameraLock = require(Client.core.camera.CameraLock)
local BlurController = require(Client.core.ui.BlurController)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local FeaturePanelController = require(Client.core.ui.FeaturePanelController)
local NavTabController = require(Client.core.ui.NavTabController)
local UIUtils = require(Client.core.ui.UIUtils)
local UITheme = require(Client.core.ui.UITheme)
local DataController = require(Client.core.data.DataController)
local WeaponWrapPreviewer = require(Client.features.locker.Previewers.WeaponWrapPreviewer)
local CasesConfig = require(Shared.constants.CasesConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local LockerCategory = require(Shared.constants.LockerCategory)
local Retween = require(Shared.utils.Retween)
local Network = require(Shared.networking.Network)
local SlotUnboxing = require(script.SlotUnboxing)

local CasesFeature = {}

-- ────────────────────────────────────────────────────────────
-- HELPERS
-- ────────────────────────────────────────────────────────────

local function formatChance(weight: number, totalWeight: number): string
	if totalWeight <= 0 then return "0%" end
	local pct = (weight / totalWeight) * 100
	if pct >= 1 then
		return string.format("%.1f%%", pct)
	else
		return string.format("%.2f%%", pct)
	end
end

local function buildRarityRankLookup(): { [string]: number }
	local rarityRankByName = {} :: { [string]: number }
	for idx, rarityName in CasesConfig.RarityOrder do
		rarityRankByName[rarityName] = idx
	end
	return rarityRankByName
end

local function applyRarityGradient(cardTemplate: GuiObject, rarity: string?)
	local gradients = CasesConfig.RarityGradients
	local style = gradients[rarity or ""] or gradients.Default
	if not style then
		return
	end

	local gradientNode = cardTemplate:FindFirstChildOfClass("UIGradient")
	if gradientNode then
		gradientNode.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, style.StartColor),
			ColorSequenceKeypoint.new(1, style.EndColor),
		})
		gradientNode.Rotation = style.Rotation
	end

	local strokeNode = cardTemplate:FindFirstChildOfClass("UIStroke")
	if strokeNode then
		strokeNode.Color = style.StrokeColor or style.EndColor
	end
end

-- ────────────────────────────────────────────────────────────
-- FEATURE START
-- ────────────────────────────────────────────────────────────

function CasesFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()
	local casesButton = UIUtils.findBottomButton(menuGui, "Cases")
	local casesGui = playerGui:FindFirstChild("Cases")

	if not casesButton or not casesGui or not casesGui:IsA("ScreenGui") then
		return janitor
	end

	local container = casesGui:FindFirstChild("Container")
	if not container then
		warn("[CasesFeature] Container no encontrado en Cases GUI")
		return janitor
	end

	local nav1 = container:FindFirstChild("Nav1")
	local nav2 = container:FindFirstChild("Nav2")
	local dropsFrame = container:FindFirstChild("DropsFrame")
	local unboxingFrame = casesGui:FindFirstChild("Unboxing")

	if not nav1 or not nav2 or not dropsFrame then
		warn("[CasesFeature] Nav1, Nav2 o DropsFrame no encontrados")
		return janitor
	end

	if not unboxingFrame or not unboxingFrame:IsA("GuiObject") then
		warn("[CasesFeature] Cases.Unboxing no encontrado")
		return janitor
	end

	local collectButton = unboxingFrame:FindFirstChild("Collect")
	local equipButton = unboxingFrame:FindFirstChild("Equip")
	if not collectButton or not collectButton:IsA("GuiButton") or not equipButton or not equipButton:IsA("GuiButton") then
		warn("[CasesFeature] Unboxing.Collect o Unboxing.Equip no encontrado")
		return janitor
	end

	unboxingFrame.Visible = false

	local itemGrid = dropsFrame:FindFirstChild("ItemGrid")
	local pityContainer = dropsFrame:FindFirstChild("Pity")

	local templateNode = if itemGrid then itemGrid:FindFirstChild("Template") else nil
	if templateNode then
		templateNode.Visible = false
	end

	-- Cámara
	local cameraController = LockerCameraController.new("cases", false)
	janitor:Add(cameraController, "Destroy")

	-- Estado
	local selectedCaseId: string? = nil
	local dropsJanitor = Janitor.new()
	janitor:Add(dropsJanitor, "Destroy")

	local canUseHoverAnimations = UserInputService.MouseEnabled
		and not UserInputService.TouchEnabled

	-- ── Unboxing: estado y UI ────────────────────────────────
	local FADE_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

	local unboxingQueue: { { caseId: string, wrapId: string, weaponCategory: string, weaponId: string, isPity: boolean, newPity: number } } = {}
	local isUnboxing = false
	local unboxingGeneration = 0
	-- D3: BindableEvent en vuelo del unboxing actual. Si el panel se cierra
	-- mid-unbox, onClose lo Fire con sentinel "cancel" para desbloquear el
	-- :Wait() — sin esto, la task quedaba colgada para siempre y las
	-- conexiones Collect/Equip nunca se desconectaban (leak por unbox cancelado).
	local pendingUnboxActionEvent: BindableEvent? = nil
	local function isGenerationCancelled(gen: number): boolean
		return unboxingGeneration ~= gen
	end

	-- Overlay negro para fade — usa el del editor si existe, si no crea uno
	local fadeOverlay: Frame
	local existingOverlay = casesGui:FindFirstChild("FadeOverlay")
	if existingOverlay and existingOverlay:IsA("Frame") then
		fadeOverlay = existingOverlay
		fadeOverlay.BackgroundTransparency = 1
		fadeOverlay.Visible = false
	else
		fadeOverlay = Instance.new("Frame")
		fadeOverlay.Name = "FadeOverlay"
		fadeOverlay.Size = UDim2.new(1, 0, 1, 0)
		fadeOverlay.Position = UDim2.new(0, 0, 0, 0)
		fadeOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
		fadeOverlay.BackgroundTransparency = 1
		fadeOverlay.BorderSizePixel = 0
		fadeOverlay.ZIndex = 100
		fadeOverlay.Visible = false
		fadeOverlay.Parent = casesGui
		janitor:Add(fadeOverlay, "Destroy")
	end

	local function fadeToBlack()
		fadeOverlay.BackgroundTransparency = 1
		fadeOverlay.Visible = true
		local tween = TweenService:Create(fadeOverlay, FADE_TWEEN_INFO, { BackgroundTransparency = 0 })
		tween:Play()
		tween.Completed:Wait()
	end

	local function fadeFromBlack()
		local tween = TweenService:Create(fadeOverlay, FADE_TWEEN_INFO, { BackgroundTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		fadeOverlay.Visible = false
	end

	-- ── Fusion scope para reactividad de datos ───────────────
	local scope = Fusion.scoped(Fusion)
	janitor:Add(function()
		Fusion.doCleanup(scope)
	end, true)

	-- ── Nav1: Selección de cases (delegado a NavTabController) ─
	local navTabController = NavTabController.new()
	janitor:Add(navTabController, "Destroy")
	local rarityRankByName = buildRarityRankLookup()

	-- ── Poblar drops del case seleccionado ────────────────────
	local function populateDrops(caseId: string)
		dropsJanitor:Cleanup()

		if not itemGrid or not templateNode then return end

		local caseDef = CasesConfig.Cases[caseId]
		if not caseDef then return end

		-- Calcular pesos totales
		local totalWeight = 0
		local totalLuckyWeight = 0
		for _, drop in caseDef.Drops do
			totalWeight += drop.Weight
			totalLuckyWeight += drop.LuckyWeight
		end

		local orderedDrops = table.clone(caseDef.Drops)
		table.sort(orderedDrops, function(a, b)
			local aCfg = if ItemsConfig.WeaponWraps then ItemsConfig.WeaponWraps[a.WrapId] else nil
			local bCfg = if ItemsConfig.WeaponWraps then ItemsConfig.WeaponWraps[b.WrapId] else nil

			local aRarity = if aCfg and type(aCfg.Rarity) == "string" then aCfg.Rarity else "Common"
			local bRarity = if bCfg and type(bCfg.Rarity) == "string" then bCfg.Rarity else "Common"

			local aRank = rarityRankByName[aRarity] or 999
			local bRank = rarityRankByName[bRarity] or 999

			if aRank == bRank then
				return a.WrapId < b.WrapId
			end

			return aRank < bRank
		end)

		for _, drop in orderedDrops do
			local wrapConfig = if ItemsConfig.WeaponWraps then ItemsConfig.WeaponWraps[drop.WrapId] else nil
			if not wrapConfig then continue end

			local clone = templateNode:Clone()
			clone.Name = "Drop_" .. drop.WrapId
			clone.Visible = true
			clone.Parent = itemGrid
			dropsJanitor:Add(clone, "Destroy")

			applyRarityGradient(clone, if type(wrapConfig.Rarity) == "string" then wrapConfig.Rarity else nil)

			local itemNameLabel = clone:WaitForChild("ItemName") :: TextLabel
			itemNameLabel.Text = wrapConfig.Name or drop.WrapId

			local chanceLabel = clone:WaitForChild("Chance") :: TextLabel
			chanceLabel.Text = formatChance(drop.Weight, totalWeight)

			local luckyChanceLabel = clone:WaitForChild("LuckyChance") :: TextLabel
			luckyChanceLabel.Text = formatChance(drop.LuckyWeight, totalLuckyWeight)

			local viewportFrame = clone:WaitForChild("ViewportFrame") :: ViewportFrame
			do
				local previewItem = {
					TextureID = wrapConfig.TextureID,
					BaseColor = wrapConfig.BaseColor,
					isAnimated = wrapConfig.isAnimated,
					StudsPerTile = wrapConfig.StudsPerTile,
				}
				local previewJanitor = Janitor.new()
				dropsJanitor:Add(previewJanitor, "Destroy")
				WeaponWrapPreviewer.Render(viewportFrame, previewItem, previewJanitor)
				SlotUnboxing.reframeWrap(viewportFrame)
			end
		end
	end

	-- ── Pity bar ──────────────────────────────────────────────
	local pityBarSlot: Retween.Slot = { current = nil }
	janitor:Add(function()
		Retween.cancel(pityBarSlot)
	end, true)

	local function updatePityBar(caseId: string)
		if not pityContainer then return end

		local caseDef = CasesConfig.Cases[caseId]
		if not caseDef then return end

		local casesData = Fusion.peek(DataController.Cases)
		local pityCounters = if casesData and type(casesData.PityCounters) == "table"
			then casesData.PityCounters
			else {}

		local rawPity = if type(pityCounters[caseId]) == "number" then pityCounters[caseId] else 0
		local threshold = caseDef.PityThreshold
		local currentPity = math.clamp(rawPity, 0, math.max(1, threshold))

		local fill = pityContainer.Bar.Fill :: GuiObject
		local fillRatio = math.clamp(currentPity / math.max(1, threshold), 0, 1)
		Retween.run(pityBarSlot, fill, TweenInfo.new(0.3, Enum.EasingStyle.Quad), {
			Size = UDim2.new(fillRatio, 0, 1, 0),
		})

		local progressText = tostring(currentPity) .. "/" .. tostring(threshold)
		local leftLabel = pityContainer.Left :: TextLabel
		leftLabel.Text = progressText
	end

	-- ── Actualizar precios de summon ──────────────────────────
	local function refreshSummonPrices(caseId: string)
		local caseDef = CasesConfig.Cases[caseId]
		if not caseDef then return end

		local summon1Price = nav2.Summon1.Price :: TextLabel
		local summon4Price = nav2.Summon4.Price :: TextLabel
		summon1Price.Text = UIUtils.formatCashAmount(caseDef.Price)
		summon4Price.Text = UIUtils.formatCashAmount(caseDef.PriceMulti)
	end

	-- ── Seleccionar un case ───────────────────────────────────
	local function selectCase(caseId: string)
		if selectedCaseId == caseId then return end
		selectedCaseId = caseId
		navTabController:setActive(caseId)
		populateDrops(caseId)
		updatePityBar(caseId)
		refreshSummonPrices(caseId)
	end

	-- ── Registrar botones de Nav1 como selectores de cases ────
	local closeButton: GuiButton? = nil
	local strokeTweens = {} :: { [GuiButton]: Tween }
	local function tweenStroke(button: GuiButton, stroke: UIStroke, color: Color3)
		local existing = strokeTweens[button]
		if existing then existing:Cancel() end
		local tween = TweenService:Create(stroke, UITheme.NavTweenInfo, { Color = color })
		strokeTweens[button] = tween
		tween:Play()
	end
	janitor:Add(function()
		for _, tween in strokeTweens do tween:Cancel() end
		table.clear(strokeTweens)
	end, true)

	local registeredCaseIds = {} :: { [string]: boolean }
	for _, child in nav1:GetChildren() do
		if child:IsA("GuiButton") then
			if child.Name == "CloseBtn" or child.Name == "Close" then
				closeButton = child :: GuiButton
				continue
			end

			local caseId = child.Name
			local btn = child :: GuiButton
			navTabController:register(caseId, btn)
			registeredCaseIds[caseId] = true

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

			InteractiveScaleTween.bindButton(btn, janitor, {
				enableHover = canUseHoverAnimations,
				hoverScale = UITheme.ButtonHoverScale,
				clickScale = UITheme.ButtonClickScale,
			})

			janitor:Add(btn.Activated:Connect(function()
				selectCase(caseId)
			end), "Disconnect")
		end
	end

	-- Seleccionar por defecto el primer case del config (o el primer hijo)
	local defaultCaseId: string? = if #CasesConfig.CasesInOrder > 0
		then CasesConfig.CasesInOrder[1]
		else nil

	if not defaultCaseId then
		for caseId in registeredCaseIds do
			defaultCaseId = caseId
			break
		end
	end

	if defaultCaseId then
		selectCase(defaultCaseId)
	end

	-- ── Nav2: Botones de acción ──────────────────────────────

	-- Summon1 (abrir 1 caja)
	local summon1Node = nav2:FindFirstChild("Summon1")
	if summon1Node and summon1Node:IsA("GuiButton") then
		InteractiveScaleTween.bindButton(summon1Node, janitor, {
			enableHover = canUseHoverAnimations,
			hoverScale = UITheme.ButtonHoverScale,
			clickScale = UITheme.ButtonClickScale,
		})

		janitor:Add(summon1Node.Activated:Connect(function()
			if not selectedCaseId then return end
			Network.Cases.Summon.Send({ caseId = selectedCaseId, multi = false })
		end), "Disconnect")
	end

	-- Summon4 (abrir 4 cajas)
	local summon4Node = nav2:FindFirstChild("Summon4")
	if summon4Node and summon4Node:IsA("GuiButton") then
		InteractiveScaleTween.bindButton(summon4Node, janitor, {
			enableHover = canUseHoverAnimations,
			hoverScale = UITheme.ButtonHoverScale,
			clickScale = UITheme.ButtonClickScale,
		})

		janitor:Add(summon4Node.Activated:Connect(function()
			if not selectedCaseId then return end
			Network.Cases.Summon.Send({ caseId = selectedCaseId, multi = true })
		end), "Disconnect")
	end

	-- Luck1 (comprar lucky boost con Robux)
	local luck1Node = nav2:FindFirstChild("Luck1")
	if luck1Node and luck1Node:IsA("GuiButton") then
		InteractiveScaleTween.bindButton(luck1Node, janitor, {
			enableHover = canUseHoverAnimations,
			hoverScale = UITheme.ButtonHoverScale,
			clickScale = UITheme.ButtonClickScale,
		})

		janitor:Add(luck1Node.Activated:Connect(function()
			local productId = CasesConfig.LuckyBoost.ProductId
			if productId <= 0 then
				warn("[CasesFeature] Lucky boost ProductId no configurado")
				return
			end
			MarketplaceService:PromptProductPurchase(player, productId)
		end), "Disconnect")
	end

	-- ── Reactividad: actualizar pity cuando cambian los datos ─
	local casesComputed = scope:Computed(function(use: any)
		return use(DataController.Cases)
	end)

	local observerCleanup = scope:Observer(casesComputed):onChange(function()
		if selectedCaseId then
			updatePityBar(selectedCaseId)
		end
	end)
	janitor:Add(observerCleanup, true)

	-- ── Escuchar respuesta del servidor ──────────────────────
	janitor:Add(Network.Cases.Response.Listen(function(data: { success: boolean, message: string })
		if not data.success then
			warn("[CasesFeature] Server:", data.message)
		end
	end), true)

	-- ── Recolectar armas poseídas (para Lane1 del slot machine) ─
	local function collectOwnedWeapons(): { { category: string, weaponId: string } }
		local owned = {}
		local inventory = Fusion.peek(DataController.Inventory)
		if type(inventory) == "table" then
			for _, categoryName in WeaponCategoryMod.ALL do
				local cat = inventory[categoryName]
				if type(cat) == "table" then
					for weaponId, isOwned in cat do
						if isOwned == true and type(weaponId) == "string" and weaponId ~= "" then
							table.insert(owned, { category = categoryName, weaponId = weaponId })
						end
					end
				end
			end
		end
		if #owned == 0 then
			table.insert(owned, { category = WeaponCategoryMod.MAIN, weaponId = ItemDefaults.ITEM_ID })
		end
		return owned
	end

	-- ── Procesamiento de cola de unboxing ─────────────────────
	local function processUnboxingQueue()
		if isUnboxing or #unboxingQueue == 0 then return end
		isUnboxing = true
		unboxingGeneration += 1
		local gen = unboxingGeneration
		CameraLock.acquire("cases_unboxing")
		BlurController.acquire("cases_unboxing")

		local ok, err = pcall(function()
			-- Ocultar UI del menú de cajas
			nav1.Visible = false
			nav2.Visible = false
			dropsFrame.Visible = false

			-- Fade a negro para tapar el cambio de UI (la cámara se mantiene en la de "cases")
			fadeToBlack()
			if isGenerationCancelled(gen) then return end
			fadeFromBlack()
			if isGenerationCancelled(gen) then return end

			-- Procesar cada resultado en la cola
			while #unboxingQueue > 0 do
				if isGenerationCancelled(gen) then return end
				local result = table.remove(unboxingQueue, 1)

				local cleanup
				unboxingFrame.Visible = true
				local ownedWeapons = collectOwnedWeapons()
				local playOk, playErr = pcall(function()
					cleanup = SlotUnboxing.play(result, ownedWeapons, unboxingFrame)
				end)
				if not playOk then
					warn("[CasesFeature] SlotUnboxing.play error:", playErr)
					if cleanup then pcall(cleanup) end
					continue
				end

				local actionEvent = Instance.new("BindableEvent")
				pendingUnboxActionEvent = actionEvent
				local actionChosen: string? = nil
				local collectConnection = collectButton.Activated:Connect(function()
					if actionChosen ~= nil then return end
					actionChosen = "collect"
					actionEvent:Fire(actionChosen)
				end)
				local equipConnection = equipButton.Activated:Connect(function()
					if actionChosen ~= nil then return end
					actionChosen = "equip"
					actionEvent:Fire(actionChosen)
				end)

				local chosenAction = actionEvent.Event:Wait()
				collectConnection:Disconnect()
				equipConnection:Disconnect()
				actionEvent:Destroy()
				pendingUnboxActionEvent = nil

				-- onClose dispara "cancel" para desbloquear el :Wait sin que
				-- el usuario haya elegido. El generation check abajo cierra
				-- el flujo limpiamente.
				if chosenAction == "cancel" or isGenerationCancelled(gen) then
					if cleanup then pcall(cleanup) end
					return
				end

				if chosenAction == "equip" then
					Network.Shop.EquipItem.Send({
						category = LockerCategory.WEAPON_WRAPS,
						itemId = result.wrapId,
						weaponCategory = result.weaponCategory,
						weaponId = result.weaponId,
					})
				end

				unboxingFrame.Visible = false

				fadeToBlack()
				if cleanup then pcall(cleanup) end

				if selectedCaseId then
					updatePityBar(selectedCaseId)
				end

				if #unboxingQueue > 0 then
					fadeFromBlack()
				end
			end
		end)

		if not ok then
			warn("[CasesFeature] processUnboxingQueue error:", err)
		end

		-- Restaurar vista de cajas (siempre, incluso tras error)
		pcall(function()
			nav1.Visible = true
			nav2.Visible = true
			dropsFrame.Visible = true
			unboxingFrame.Visible = false
			fadeOverlay.BackgroundTransparency = 1
			fadeOverlay.Visible = false
		end)

		BlurController.release("cases_unboxing")
		CameraLock.release("cases_unboxing")
		isUnboxing = false

		-- Si llegaron más eventos durante el error, intenta procesarlos
		if #unboxingQueue > 0 then
			task.spawn(processUnboxingQueue)
		end
	end

	-- ── Escuchar resultado de summon ──────────────────────────
	janitor:Add(Network.Cases.SummonResult.Listen(function(data: any)
		table.insert(unboxingQueue, {
			caseId = data.caseId,
			wrapId = data.wrapId,
			weaponCategory = data.weaponCategory,
			weaponId = data.weaponId,
			isPity = data.isPity,
			newPity = data.newPity,
		})
		task.spawn(processUnboxingQueue)
	end), true)

	-- ── Abrir / cerrar GUI (vía FeaturePanelController) ───────
	local panel = FeaturePanelController.new({
		menuController = menuController,
		screenGui = casesGui,
		openButton = casesButton,
		closeButton = closeButton,
		cameraController = cameraController,
		onOpen = function()
			if selectedCaseId then
				updatePityBar(selectedCaseId)
			end
		end,
		onClose = function()
			-- Cancela cualquier unboxing en curso al cerrar la GUI
			unboxingGeneration += 1
			table.clear(unboxingQueue)
			-- D3: si la task de unboxing está bloqueada en :Wait(), liberarla
			-- con un sentinel — sin esto la task queda zombie con conexiones
			-- Collect/Equip vivas hasta el unload del feature.
			local pending = pendingUnboxActionEvent
			if pending then
				pendingUnboxActionEvent = nil
				pcall(function() pending:Fire("cancel") end)
			end
		end,
	})
	janitor:Add(panel, "Destroy")

	return janitor
end

return CasesFeature
