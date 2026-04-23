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
local Workspace = game:GetService("Workspace")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local CameraLock = require(Client.core.camera.CameraLock)
local MenuHover = require(Client.core.ui.MenuHover)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local DataController = require(Client.core.data.DataController)
local WeaponSkinWrapPreviewer = require(Client.features.locker.Previewers.WeaponSkinWrapPreviewer)
local CasesConfig = require(Shared.constants.CasesConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local Network = require(Shared.networking.Network)
local ChestUnboxing = require(script.ChestUnboxing)

local CasesFeature = {}

-- ────────────────────────────────────────────────────────────
-- HELPERS
-- ────────────────────────────────────────────────────────────

local function findFooterButton(menuGui: ScreenGui, buttonName: string): GuiButton?
	local bottomContainer = menuGui:FindFirstChild("BottomContainer")
	if not bottomContainer then return nil end

	local footer = bottomContainer:FindFirstChild("Footer")
	if not footer then return nil end

	local targetButton = footer:FindFirstChild(buttonName)
	if targetButton and targetButton:IsA("GuiButton") then
		return targetButton
	end

	return nil
end

local function formatCashAmount(amount: number): string
	local formatted = tostring(math.max(0, math.floor(amount)))
	local withSeparators = string.reverse(formatted):gsub("(%d%d%d)", "%1,")
	withSeparators = string.reverse(withSeparators)
	if string.sub(withSeparators, 1, 1) == "," then
		withSeparators = string.sub(withSeparators, 2)
	end
	return withSeparators
end

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

	local gradientNode = cardTemplate:FindFirstChildWhichIsA("UIGradient", true)
	if gradientNode then
		gradientNode.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, style.StartColor),
			ColorSequenceKeypoint.new(1, style.EndColor),
		})
		gradientNode.Rotation = style.Rotation
	end

	local strokeNode = cardTemplate:FindFirstChildWhichIsA("UIStroke", true)
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
	local casesButton = findFooterButton(menuGui, "cases")
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
	local unboxingFrame = container:FindFirstChild("Unboxing")

	if not nav1 or not nav2 or not dropsFrame then
		warn("[CasesFeature] Nav1, Nav2 o DropsFrame no encontrados")
		return janitor
	end

	if not unboxingFrame or not unboxingFrame:IsA("GuiObject") then
		warn("[CasesFeature] Container.Unboxing no encontrado")
		return janitor
	end

	local acceptButton = unboxingFrame:FindFirstChild("Accept")
	local equipButton = unboxingFrame:FindFirstChild("Equip")
	if not acceptButton or not acceptButton:IsA("GuiButton") or not equipButton or not equipButton:IsA("GuiButton") then
		warn("[CasesFeature] Unboxing.Accept o Unboxing.Equip no encontrado")
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
	local isOpen = false
	local selectedCaseId: string? = nil
	local dropsJanitor = Janitor.new()
	janitor:Add(dropsJanitor, "Destroy")

	local canUseHoverAnimations = UserInputService.MouseEnabled
		and not UserInputService.TouchEnabled

	-- GUI empieza oculta
	casesGui.Enabled = false

	-- ── Unboxing: estado y UI ────────────────────────────────
	local UNBOXING_CAMERA_CFRAME = CFrame.new(-267.155, 25.312, -248.177)
		* CFrame.fromEulerAnglesYXZ(math.rad(-3.707), math.rad(178.78), math.rad(0))
	local FADE_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

	local unboxingQueue: { { caseId: string, skinId: string, weaponCategory: string, weaponId: string, isPity: boolean, newPity: number } } = {}
	local isUnboxing = false

	-- Overlay negro para fade
	local fadeOverlay = Instance.new("Frame")
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

	-- ── Nav1: Selección de cases ─────────────────────────────
	local SELECTED_COLOR = Color3.fromRGB(249, 217, 93)
	local UNSELECTED_COLOR = Color3.fromRGB(35, 54, 99)
	local HOVER_STROKE_COLOR = Color3.fromRGB(255, 255, 255)
	local NAV_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local caseNavButtons: { [string]: GuiButton } = {}
	local defaultStrokeColors: { [GuiButton]: Color3 } = {}
	local rarityRankByName = buildRarityRankLookup()

	local function updateCaseNavVisuals()
		for caseId, btn in caseNavButtons do
			local isSelected = (selectedCaseId == caseId)

			local targetScale = if isSelected then 1.15 else 1.0
			local targetColor = if isSelected then SELECTED_COLOR else UNSELECTED_COLOR

			local scaleNode = btn:FindFirstChildOfClass("UIScale")
			if not scaleNode then
				scaleNode = Instance.new("UIScale")
				scaleNode.Name = "NavScale"
				scaleNode.Parent = btn
			end

			TweenService:Create(scaleNode, NAV_TWEEN_INFO, { Scale = targetScale }):Play()

			if btn:IsA("ImageButton") or btn:IsA("ImageLabel") then
				TweenService:Create(btn, NAV_TWEEN_INFO, { ImageColor3 = targetColor }):Play()
			end
		end
	end

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
			local aCfg = if ItemsConfig.WeaponSkins then ItemsConfig.WeaponSkins[a.SkinId] else nil
			local bCfg = if ItemsConfig.WeaponSkins then ItemsConfig.WeaponSkins[b.SkinId] else nil

			local aRarity = if aCfg and type(aCfg.Rarity) == "string" then aCfg.Rarity else "Common"
			local bRarity = if bCfg and type(bCfg.Rarity) == "string" then bCfg.Rarity else "Common"

			local aRank = rarityRankByName[aRarity] or 999
			local bRank = rarityRankByName[bRarity] or 999

			if aRank == bRank then
				return a.SkinId < b.SkinId
			end

			return aRank < bRank
		end)

		for _, drop in orderedDrops do
			local skinConfig = if ItemsConfig.WeaponSkins then ItemsConfig.WeaponSkins[drop.SkinId] else nil
			if not skinConfig then continue end

			local clone = templateNode:Clone()
			clone.Name = "Drop_" .. drop.SkinId
			clone.Visible = true
			clone.Parent = itemGrid
			dropsJanitor:Add(clone, "Destroy")

			applyRarityGradient(clone, if type(skinConfig.Rarity) == "string" then skinConfig.Rarity else nil)

			-- Nombre
			local itemNameLabel = clone:FindFirstChild("ItemName", true)
			if itemNameLabel and itemNameLabel:IsA("TextLabel") then
				itemNameLabel.Text = skinConfig.Name or drop.SkinId
			end

			-- Chance normal
			local chanceLabel = clone:FindFirstChild("Chance", true)
			if chanceLabel and chanceLabel:IsA("TextLabel") then
				chanceLabel.Text = formatChance(drop.Weight, totalWeight)
			end

			-- Chance con lucky
			local luckyChanceLabel = clone:FindFirstChild("LuckyChance", true)
			if luckyChanceLabel and luckyChanceLabel:IsA("TextLabel") then
				luckyChanceLabel.Text = formatChance(drop.LuckyWeight, totalLuckyWeight)
			end

			-- ViewportFrame con preview de la skin (wrap)
			local viewportFrame = clone:FindFirstChild("ViewportFrame", true)
			if viewportFrame and viewportFrame:IsA("ViewportFrame") then
				local previewItem = {
					TextureID = skinConfig.TextureID,
					BaseColor = skinConfig.BaseColor,
					Animated = skinConfig.Animated,
					StudsPerTile = skinConfig.StudsPerTile,
				}
				local previewJanitor = Janitor.new()
				dropsJanitor:Add(previewJanitor, "Destroy")
				WeaponSkinWrapPreviewer.Render(viewportFrame, previewItem, previewJanitor)
			end
		end
	end

	-- ── Pity bar ──────────────────────────────────────────────
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

		local barNode = pityContainer:FindFirstChild("Bar", true)
		if barNode then
			local fill = barNode:FindFirstChild("Fill", true)
			if fill and fill:IsA("GuiObject") then
				local fillRatio = math.clamp(currentPity / math.max(1, threshold), 0, 1)
				TweenService:Create(fill, TweenInfo.new(0.3, Enum.EasingStyle.Quad), {
					Size = UDim2.new(fillRatio, 0, 1, 0),
				}):Play()
			end
		end

		local progressText = tostring(currentPity) .. "/" .. tostring(threshold)

		local leftLabel = pityContainer:FindFirstChild("Left", true)
		if leftLabel and leftLabel:IsA("TextLabel") then
			leftLabel.Text = progressText
		end

		-- Fallbacks por si el layout usa nombres previos.
		local counterLabel = pityContainer:FindFirstChild("Counter", true)
			or pityContainer:FindFirstChild("Label", true)
		if counterLabel and counterLabel:IsA("TextLabel") then
			counterLabel.Text = progressText
		end
	end

	-- ── Actualizar precios de summon ──────────────────────────
	local function refreshSummonPrices(caseId: string)
		local caseDef = CasesConfig.Cases[caseId]
		if not caseDef then return end

		if nav2:FindFirstChild("Summon1") then
			local node = nav2:FindFirstChild("Summon1")
			if node then
				local priceLabel = node:FindFirstChild("Price", true)
				if priceLabel and priceLabel:IsA("TextLabel") then
					priceLabel.Text = formatCashAmount(caseDef.Price)
				end
			end
		end

		local summon4Node = nav2:FindFirstChild("Summon4")
		if summon4Node then
			local priceLabel = summon4Node:FindFirstChild("Price", true)
			if priceLabel and priceLabel:IsA("TextLabel") then
				priceLabel.Text = formatCashAmount(caseDef.PriceMulti)
			end
		end
	end

	-- ── Seleccionar un case ───────────────────────────────────
	local function selectCase(caseId: string)
		if selectedCaseId == caseId then return end
		selectedCaseId = caseId
		updateCaseNavVisuals()
		populateDrops(caseId)
		updatePityBar(caseId)
		refreshSummonPrices(caseId)
	end

	-- ── Registrar botones de Nav1 como selectores de cases ────
	local closeButton: GuiButton? = nil
	for _, child in nav1:GetChildren() do
		if child:IsA("GuiButton") then
			if child.Name == "CloseBtn" or child.Name == "Close" then
				closeButton = child :: GuiButton
				continue
			end

			local caseId = child.Name
			local btn = child :: GuiButton
			caseNavButtons[caseId] = btn

			local stroke = btn:FindFirstChildOfClass("UIStroke")
			if stroke then
				defaultStrokeColors[btn] = stroke.Color

				janitor:Add(btn.MouseEnter:Connect(function()
					if canUseHoverAnimations then
						TweenService:Create(stroke, NAV_TWEEN_INFO, { Color = HOVER_STROKE_COLOR }):Play()
					end
				end), "Disconnect")

				janitor:Add(btn.MouseLeave:Connect(function()
					TweenService:Create(stroke, NAV_TWEEN_INFO, { Color = defaultStrokeColors[btn] }):Play()
				end), "Disconnect")
			end

			InteractiveScaleTween.bindButton(btn, janitor, {
				enableHover = canUseHoverAnimations,
				hoverScale = 1.04,
				clickScale = 0.96,
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
		for caseId in caseNavButtons do
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
			hoverScale = 1.04,
			clickScale = 0.96,
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
			hoverScale = 1.04,
			clickScale = 0.96,
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
			hoverScale = 1.04,
			clickScale = 0.96,
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

	-- ── Procesamiento de cola de unboxing ─────────────────────
	local function processUnboxingQueue()
		if isUnboxing or #unboxingQueue == 0 then return end
		isUnboxing = true
		CameraLock.acquire("cases_unboxing")
		local isScreenBlack = false

		local savedCameraCFrame = Workspace.CurrentCamera.CFrame

		-- Ocultar UI del menú de cajas
		nav1.Visible = false
		nav2.Visible = false
		dropsFrame.Visible = false

		-- Fade a negro y mover cámara
		fadeToBlack()
		isScreenBlack = true
		Workspace.CurrentCamera.CFrame = UNBOXING_CAMERA_CFRAME
		fadeFromBlack()
		isScreenBlack = false

		-- Procesar cada resultado en la cola
		while #unboxingQueue > 0 do
			local result = table.remove(unboxingQueue, 1)

			-- Animación de cofre (bloquea hasta completar)
			local cleanup = ChestUnboxing.play(result.skinId, result.weaponCategory, result.weaponId)

			-- Mostrar acciones de unboxing
			unboxingFrame.Visible = true

			local actionEvent = Instance.new("BindableEvent")
			local actionChosen: string? = nil
			local acceptConnection = acceptButton.Activated:Connect(function()
				if actionChosen ~= nil then return end
				actionChosen = "accept"
				actionEvent:Fire(actionChosen)
			end)
			local equipConnection = equipButton.Activated:Connect(function()
				if actionChosen ~= nil then return end
				actionChosen = "equip"
				actionEvent:Fire(actionChosen)
			end)

			local chosenAction = actionEvent.Event:Wait()
			acceptConnection:Disconnect()
			equipConnection:Disconnect()
			actionEvent:Destroy()

			if chosenAction == "equip" then
				Network.Shop.EquipItem.Send({
					category = "WeaponSkins",
					itemId = result.skinId,
					weaponCategory = result.weaponCategory,
					weaponId = result.weaponId,
				})
			end

			unboxingFrame.Visible = false

			-- Cerrar/limpiar cofre justo con pantalla negra
			fadeToBlack()
			isScreenBlack = true
			cleanup()

			-- Actualizar pity
			if selectedCaseId then
				updatePityBar(selectedCaseId)
			end

			-- Si hay más resultados, volvemos a mostrar para el siguiente unboxing.
			if #unboxingQueue > 0 then
				fadeFromBlack()
				isScreenBlack = false
			end
		end

		-- Restaurar vista de cajas
		if not isScreenBlack then
			fadeToBlack()
			isScreenBlack = true
		end
		Workspace.CurrentCamera.CFrame = savedCameraCFrame
		nav1.Visible = true
		nav2.Visible = true
		dropsFrame.Visible = true
		unboxingFrame.Visible = false
		fadeFromBlack()
		isScreenBlack = false

		CameraLock.release("cases_unboxing")
		isUnboxing = false
	end

	-- ── Escuchar resultado de summon ──────────────────────────
	janitor:Add(Network.Cases.SummonResult.Listen(function(data: any)
		table.insert(unboxingQueue, {
			caseId = data.caseId,
			skinId = data.skinId,
			weaponCategory = data.weaponCategory,
			weaponId = data.weaponId,
			isPity = data.isPity,
			newPity = data.newPity,
		})
		task.spawn(processUnboxingQueue)
	end), true)

	-- ── Abrir / cerrar GUI ───────────────────────────────────

	local function setMenuVisible(visible: boolean)
		menuGui.Enabled = visible
	end

	local function openCasesGui()
		if isOpen then return end
		isOpen = true
		cameraController:apply()
		casesGui.Enabled = true
		setMenuVisible(false)

		-- Refrescar pity al abrir
		if selectedCaseId then
			updatePityBar(selectedCaseId)
		end
	end

	local function closeCasesGui()
		if not isOpen then return end
		isOpen = false
		cameraController:restore()
		casesGui.Enabled = false
		setMenuVisible(true)
	end

	janitor:Add(casesButton.MouseButton1Click:Connect(openCasesGui), "Disconnect")

	-- Close button en Nav1
	if closeButton then
		local resetClose = MenuHover.bindButton(closeButton, janitor)
		janitor:Add(closeButton.MouseButton1Click:Connect(function()
			resetClose()
			closeCasesGui()
		end), "Disconnect")
	end

	-- Sync external close
	janitor:Add(casesGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if casesGui.Enabled == false and isOpen then
			isOpen = false
			cameraController:restore()
			setMenuVisible(true)
		end
	end), "Disconnect")

	-- Cleanup
	janitor:Add(function()
		if isOpen then
			cameraController:restore()
			setMenuVisible(true)
		end
	end, true)

	return janitor
end

return CasesFeature
