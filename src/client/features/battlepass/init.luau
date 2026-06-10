--!strict
--[[
	BattlePassFeature (Client)

	Panel del Battle Pass (una recompensa por nivel, FREE o PASS). Se abre como
	los demás paneles (PanelController + blur + FOV, sin cambio de cámara).

	GUI (PlayerGui.UserInterface.BattlePass.Main):
	  Header.CloseBtn / Header.Title  ("SEASON 0 (BETA)")
	  Timer                            ("Ends in X, X")
	  Progress.Bar.Fill / Progress.ActualLevel / Progress.XP
	  Nav.Back (.Indicator) / Nav.Next (.Indicator) / Nav.Info  ("1/8")
	  SkipLevelBtn                     (compra Robux: +1 nivel)
	  PurchaseBtn                      (compra Robux: premium / PASS)
	  Path."1".."8" (cada item):
	    Type                            -- FREE/PASS/CLAIM (+ UIGradient para PASS); oculto si claimed
	    Content.Image                   -- recompensa no-wrap (ImageLabel)
	    Content.Viewport.Viewport       -- recompensa wrap (ViewportFrame 3D)
	    Content.Viewport.Description    -- cantidad de cash o tipo de item ("Hat")
	    Content.UIGradient              -- habilitado si el nivel es PASS
	    Content.Footer.Container.Frame  -- estado claimed/no-claimed
	      .Status                       -- "CLAIMED" / "LVL X" / "XP/OBJ"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local PanelController = require(Client.core.ui.PanelController)
local BlurController = require(Client.core.ui.BlurController)
local CameraFovEffect = require(Client.core.ui.CameraFovEffect)
local DataController = require(Client.core.data.DataController)
local Notify = require(Client.core.ui.NotificationController)
local UIUtils = require(Client.core.ui.UIUtils)
local Network = require(Shared.networking.Network)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local WeaponWrapPreviewer = require(Client.features.locker.Previewers.WeaponWrapPreviewer)

local BLUR_KEY = "BattlePass"
local SLOTS_PER_PAGE = 8

-- Type (FREE/PASS/CLAIM). FREE y PASS comparten colores; PASS añade gradient.
local TYPE_BG_TRANSPARENCY = 0.6
local TYPE_DARK_BG = Color3.fromRGB(0, 0, 0)
local TYPE_WHITE_TEXT = Color3.fromRGB(255, 255, 255)
local TYPE_CLAIM_COLOR = Color3.fromRGB(195, 252, 165)

-- Footer.Frame por estado.
local FOOTER_CLAIMED_BG = Color3.fromRGB(179, 254, 155)
local FOOTER_UNCLAIMED_BG = Color3.fromRGB(34, 34, 35)
local STATUS_CLAIMED_COLOR = Color3.fromRGB(0, 0, 0)
local STATUS_UNCLAIMED_COLOR = Color3.fromRGB(255, 255, 255)

-- Imagen/viewport de la recompensa cuando ya está reclamada.
local CLAIMED_IMG_COLOR = Color3.fromRGB(89, 89, 89)
local CLAIMED_IMG_TRANSPARENCY = 0.3

-- Margen a la derecha del Progress.Bar.Fill en progreso parcial.
local FILL_RIGHT_MARGIN = 8

-- Repoblar páginas: cada slot (su Container) entra deslizándose desde abajo.
local SLOT_STAGGER_DELAY = 0.04
local SLOT_STAGGER_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local STAGGER_ENTER_OFFSET = 30

-- Selección: el slot elegido se queda subido SELECTED_LIFT_PIXELS px (marcado).
local SELECTED_LIFT_PIXELS = 12
local SELECT_MOVE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Preview grande del item seleccionado (entra deslizándose desde abajo).
local PREVIEW_LIFT_PIXELS = 24
local PREVIEW_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Poll del timer: lento lejos del deadline, rápido (cada minuto) en la última hora.
local TIMER_POLL_SLOW = 3600
local TIMER_POLL_FAST = 60

-- Etiqueta de tipo de item para la Description (categoría → singular).
local CATEGORY_LABEL: { [string]: string } = {
	Hats = "Hat",
	Faces = "Face",
	KillEffects = "Kill Effect",
	Outfits = "Outfit",
	WeaponWraps = "Wrap",
	Main = "Weapon",
	Special = "Weapon",
}

local BattlePassFeature = {}

-- Formatea segundos restantes como "Ends in 6 weeks, 2 days" (máx 2 unidades).
local function _formatTimeLeft(seconds: number): string
	if seconds <= 0 then return "" end

	local function unit(n: number, singular: string): string
		return tostring(n) .. " " .. (if n == 1 then singular else singular .. "s")
	end

	local minutes = math.floor(seconds / 60)
	local hours = math.floor(minutes / 60)
	local days = math.floor(hours / 24)
	local weeks = math.floor(days / 7)

	if weeks >= 1 then
		local remDays = days - weeks * 7
		if remDays > 0 then
			return ("Ends in %s, %s"):format(unit(weeks, "week"), unit(remDays, "day"))
		end
		return ("Ends in %s"):format(unit(weeks, "week"))
	end
	if days >= 1 then
		local remHours = hours - days * 24
		if remHours > 0 then
			return ("Ends in %s, %s"):format(unit(days, "day"), unit(remHours, "hour"))
		end
		return ("Ends in %s"):format(unit(days, "day"))
	end
	if hours >= 1 then
		local remMinutes = minutes - hours * 60
		if remMinutes > 0 then
			return ("Ends in %s, %s"):format(unit(hours, "hour"), unit(remMinutes, "minute"))
		end
		return ("Ends in %s"):format(unit(hours, "hour"))
	end
	if minutes >= 1 then
		return ("Ends in %s"):format(unit(minutes, "minute"))
	end
	return "Ending soon"
end

local function _isWrapReward(reward: BattlePassConfig.Reward): boolean
	return reward.Kind == "Item" and reward.Category == "WeaponWraps" and reward.ItemId ~= nil
end

-- Imagen para recompensas que NO son wraps (cash → icono cash; item → ItemsConfig).
local function _rewardImage(reward: BattlePassConfig.Reward): string
	if reward.Kind == "Cash" then
		return reward.Icon or BattlePassConfig.RewardIcons.Cash or ""
	end
	local catalog = ItemsConfig[reward.Category]
	local def = if type(catalog) == "table" then catalog[reward.ItemId] else nil
	return reward.Icon or (if def and type(def.Image) == "string" then def.Image else "")
end

-- Texto de Description: cantidad de cash, o el tipo de item (p. ej. "Hat").
local function _rewardDescription(reward: BattlePassConfig.Reward): string
	if reward.Kind == "Cash" then
		return UIUtils.formatCashAmount(reward.Amount or 0)
	end
	if reward.Label then
		return reward.Label
	end
	return CATEGORY_LABEL[reward.Category or ""] or (reward.Category or "")
end

-- ────────────────────────────────────────────────────────────

type SlotRefs = {
	frame: GuiObject,
	container: GuiObject,
	image: ImageLabel?,
	viewport: ViewportFrame?,
	description: TextLabel?,
	contentGradient: UIGradient?,
	footerFrame: GuiObject?,
	status: TextLabel?,
	typeLabel: TextLabel?,
	typeGradient: UIGradient?,
}

local function _resolveSlot(pathFolder: Instance, index: number): SlotRefs?
	local frame = pathFolder:FindFirstChild(tostring(index))
	if not (frame and frame:IsA("GuiObject")) then
		return nil
	end

	-- Container: hijo que se anima (raise/scale); el slot queda fijo en el layout.
	local containerNode = frame:FindFirstChild("Container")
	local container: GuiObject = if containerNode and containerNode:IsA("GuiObject") then containerNode else frame

	local content = container:FindFirstChild("Content")
	local imageNode = content and content:FindFirstChild("Image")
	local viewportNode = content and content:FindFirstChild("Viewport")
	local descriptionNode = content and content:FindFirstChild("Description")
	local contentGradientNode = if content then content:FindFirstChildOfClass("UIGradient") else nil

	local footer = content and content:FindFirstChild("Footer")
	local footerContainer = footer and footer:FindFirstChild("Container")
	local footerFrameNode = footerContainer and footerContainer:FindFirstChild("Frame")
	local statusNode = footerFrameNode and footerFrameNode:FindFirstChild("Status")

	local typeNode = container:FindFirstChild("Type")

	return {
		frame = frame,
		container = container,
		image = if imageNode and imageNode:IsA("ImageLabel") then imageNode else nil,
		viewport = if viewportNode and viewportNode:IsA("ViewportFrame") then viewportNode else nil,
		description = if descriptionNode and descriptionNode:IsA("TextLabel") then descriptionNode else nil,
		contentGradient = contentGradientNode,
		footerFrame = if footerFrameNode and footerFrameNode:IsA("GuiObject") then footerFrameNode else nil,
		status = if statusNode and statusNode:IsA("TextLabel") then statusNode else nil,
		typeLabel = if typeNode and typeNode:IsA("TextLabel") then typeNode else nil,
		typeGradient = if typeNode then typeNode:FindFirstChildOfClass("UIGradient") else nil,
	}
end

-- ────────────────────────────────────────────────────────────

function BattlePassFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()

	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local frameNode = uiGui:WaitForChild("BattlePass")
	if not frameNode:IsA("GuiObject") then
		warn("[BattlePassFeature] UserInterface.BattlePass no es un GuiObject")
		return janitor
	end
	local frame = frameNode :: GuiObject
	local main = frame:WaitForChild("Main")

	-- Botón de apertura opcional en Menu.Nav.BattlePass.
	local navMenu = menuGui:FindFirstChild("Nav")
	local btnInstance = navMenu and navMenu:FindFirstChild("BattlePass")
	local menuBtn: GuiButton? = if btnInstance and btnInstance:IsA("GuiButton") then btnInstance else nil

	-- Header.
	local header = main:FindFirstChild("Header")
	local closeNode = header and header:FindFirstChild("CloseBtn")
	local closeBtn: GuiButton? = if closeNode and closeNode:IsA("GuiButton") then closeNode else nil
	local titleNode = header and header:FindFirstChild("Title")
	local titleLabel: TextLabel? = if titleNode and titleNode:IsA("TextLabel") then titleNode else nil

	-- Timer.
	local timerNode = main:FindFirstChild("Timer")
	local timerLabel: TextLabel? = if timerNode and timerNode:IsA("TextLabel") then timerNode else nil

	-- Progress (Bar.Fill / ActualLevel / XP).
	local progress = main:FindFirstChild("Progress")
	local progressBar = progress and progress:FindFirstChild("Bar")
	local progressFillNode = progressBar and progressBar:FindFirstChild("Fill")
	local progressFill: GuiObject? = if progressFillNode and progressFillNode:IsA("GuiObject") then progressFillNode else nil
	local actualLevelNode = progress and progress:FindFirstChild("ActualLevel")
	local actualLevel: TextLabel? = if actualLevelNode and actualLevelNode:IsA("TextLabel") then actualLevelNode else nil
	local xpNode = progress and progress:FindFirstChild("XP")
	local xpLabel: TextLabel? = if xpNode and xpNode:IsA("TextLabel") then xpNode else nil

	-- Nav (Back / Next / Info).
	local navFolder = main:FindFirstChild("Nav")
	local backBtn = navFolder and navFolder:FindFirstChild("Back")
	local nextBtn = navFolder and navFolder:FindFirstChild("Next")
	local pageLabelNode = navFolder and navFolder:FindFirstChild("Info")
	local pageLabel: TextLabel? = if pageLabelNode and pageLabelNode:IsA("TextLabel") then pageLabelNode else nil
	local backIndicator = if backBtn then backBtn:FindFirstChild("Indicator") else nil
	local nextIndicator = if nextBtn then nextBtn:FindFirstChild("Indicator") else nil

	-- Skip + Purchase (Premium) opcional.
	local skipBtn = main:FindFirstChild("SkipLevelBtn")
	local purchaseBtn = main:FindFirstChild("PurchaseBtn")

	-- Path slots 1..8.
	local pathFolder = main:FindFirstChild("Path")
	local slots: { SlotRefs? } = {}
	if pathFolder then
		for i = 1, SLOTS_PER_PAGE do
			slots[i] = _resolveSlot(pathFolder, i)
		end
	else
		warn("[BattlePassFeature] BattlePass.Main.Path no existe")
	end

	-- Preview grande del item seleccionado: ImagePreview (no-wraps) / ViewportPreview (wraps).
	local imagePreviewNode = main:FindFirstChild("ImagePreview")
	local imagePreview: (ImageLabel | ImageButton)? = if imagePreviewNode
			and (imagePreviewNode:IsA("ImageLabel") or imagePreviewNode:IsA("ImageButton"))
		then imagePreviewNode :: any
		else nil
	local viewportPreviewNode = main:FindFirstChild("ViewportPreview")
	local viewportPreview: ViewportFrame? = if viewportPreviewNode and viewportPreviewNode:IsA("ViewportFrame")
		then viewportPreviewNode
		else nil

	-- ── Estado / season ──────────────────────────────────────
	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)
	local pageCount = math.max(1, math.ceil(maxTier / SLOTS_PER_PAGE))
	local currentPage = 0
	local isOpen = false

	if titleLabel then
		titleLabel.Text = season.Name
	end

	-- ── Blur + FOV (como los demás paneles) ──────────────────
	local fovEffect = CameraFovEffect.new()
	janitor:Add(fovEffect, "Destroy")

	-- ── Wrap previews por slot ───────────────────────────────
	type WrapEntry = { wrapId: string, janitor: any, viewport: ViewportFrame }
	local wrapBySlot: { [GuiObject]: WrapEntry } = {}
	local function clearWrap(slotFrame: GuiObject)
		local entry = wrapBySlot[slotFrame]
		if not entry then return end
		entry.janitor:Destroy()
		wrapBySlot[slotFrame] = nil
	end
	janitor:Add(function()
		for slotFrame in wrapBySlot do
			clearWrap(slotFrame)
		end
	end, true)

	-- ── Animación de slots (todo por Position del Container) ──
	-- Un único tween activo por Container (se cancela al reemplazarse), compartido
	-- por el stagger de entrada y el raise de selección.
	-- Selección persistente: el slot elegido se queda subido; el anterior baja.
	local slotRestPos: { [GuiObject]: UDim2 } = {}
	local selectMoveTween: { [GuiObject]: Tween } = {}
	local selectedFrame: GuiObject? = nil
	local function restPosOf(slotFrame: GuiObject): UDim2
		local cached = slotRestPos[slotFrame]
		if cached == nil then
			cached = slotFrame.Position
			slotRestPos[slotFrame] = cached
		end
		return cached
	end
	local function moveSlot(slotFrame: GuiObject, lifted: boolean)
		local rest = restPosOf(slotFrame)
		local target = if lifted
			then UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset - SELECTED_LIFT_PIXELS)
			else rest
		local existing = selectMoveTween[slotFrame]
		if existing then
			existing:Cancel()
		end
		local tween = TweenService:Create(slotFrame, SELECT_MOVE_INFO, { Position = target })
		selectMoveTween[slotFrame] = tween
		tween:Play()
	end
	-- Devuelve true si la selección cambió (false si ya estaba seleccionado).
	local function selectSlot(slotFrame: GuiObject): boolean
		if selectedFrame == slotFrame then
			return false
		end
		if selectedFrame then
			moveSlot(selectedFrame, false)
		end
		moveSlot(slotFrame, true)
		selectedFrame = slotFrame
		return true
	end
	-- Al cambiar de página los slots cambian de nivel: limpia la selección.
	local function resetSelection()
		for slotFrame, tween in selectMoveTween do
			tween:Cancel()
			local rest = slotRestPos[slotFrame]
			if rest and slotFrame.Parent then
				slotFrame.Position = rest
			end
		end
		table.clear(selectMoveTween)
		selectedFrame = nil
	end

	-- Aparición escalonada: cada Container entra deslizándose desde abajo.
	local function playPageStagger()
		local order = 0
		for i = 1, SLOTS_PER_PAGE do
			local refs = slots[i]
			if not (refs and refs.frame.Visible) then
				continue
			end
			local container = refs.container
			local rest = restPosOf(container)
			local existing = selectMoveTween[container]
			if existing then
				existing:Cancel()
			end
			container.Position = UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset + STAGGER_ENTER_OFFSET)
			local tween = TweenService:Create(container, SLOT_STAGGER_INFO, { Position = rest })
			selectMoveTween[container] = tween
			task.delay(order * SLOT_STAGGER_DELAY, function()
				if selectMoveTween[container] == tween then
					tween:Play()
				end
			end)
			order += 1
		end
	end

	janitor:Add(function()
		for slotFrame, tween in selectMoveTween do
			tween:Cancel()
			local rest = slotRestPos[slotFrame]
			if rest and slotFrame.Parent then
				slotFrame.Position = rest
			end
		end
		table.clear(selectMoveTween)
	end, true)

	-- ── Preview del item seleccionado ────────────────────────
	local imagePreviewRest: UDim2? = nil
	local viewportPreviewRest: UDim2? = nil
	local previewWrapEntry: { wrapId: string, janitor: any }? = nil
	local function clearPreviewWrap()
		if previewWrapEntry then
			previewWrapEntry.janitor:Destroy()
			previewWrapEntry = nil
		end
	end
	janitor:Add(clearPreviewWrap, true)

	-- No-wrap → ImagePreview (assetId). Entra deslizándose desde abajo.
	local function showImagePreview(image: string)
		if not imagePreview then return end
		if viewportPreview then
			viewportPreview.Visible = false
		end
		if imagePreviewRest == nil then
			imagePreviewRest = imagePreview.Position
		end
		local rest = imagePreviewRest :: UDim2
		imagePreview.Image = image
		imagePreview.Visible = true
		imagePreview.Position = UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset + PREVIEW_LIFT_PIXELS)
		TweenService:Create(imagePreview, PREVIEW_TWEEN_INFO, { Position = rest }):Play()
	end

	-- Wrap → ViewportPreview (3D). Reusa el render si es el mismo wrap.
	local function showViewportPreview(wrapId: string)
		if not viewportPreview then return end
		local wrapsCatalog = ItemsConfig.WeaponWraps
		local wrapDef = if type(wrapsCatalog) == "table" then wrapsCatalog[wrapId] else nil
		if type(wrapDef) ~= "table" then return end
		if imagePreview then
			imagePreview.Visible = false
		end
		if viewportPreviewRest == nil then
			viewportPreviewRest = viewportPreview.Position
		end
		local rest = viewportPreviewRest :: UDim2

		if not previewWrapEntry or previewWrapEntry.wrapId ~= wrapId then
			clearPreviewWrap()
			local previewJanitor = Janitor.new()
			local ok = WeaponWrapPreviewer.Render(viewportPreview, {
				TextureID = wrapDef.TextureID,
				BaseColor = wrapDef.BaseColor,
				isAnimated = wrapDef.isAnimated,
				StudsPerTile = wrapDef.StudsPerTile,
			}, previewJanitor)
			if ok then
				WeaponWrapPreviewer.reframeCentered(viewportPreview)
				previewWrapEntry = { wrapId = wrapId, janitor = previewJanitor }
			else
				previewJanitor:Destroy()
				return
			end
		end

		viewportPreview.Visible = true
		viewportPreview.Position = UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset + PREVIEW_LIFT_PIXELS)
		TweenService:Create(viewportPreview, PREVIEW_TWEEN_INFO, { Position = rest }):Play()
	end

	local function showRewardPreview(reward: BattlePassConfig.Reward)
		if _isWrapReward(reward) then
			showViewportPreview(reward.ItemId :: string)
		else
			showImagePreview(_rewardImage(reward))
		end
	end

	-- Sin selección: el preview muestra el item 8 (último) de la página actual.
	local function showPageDefaultPreview()
		local level = currentPage * SLOTS_PER_PAGE + SLOTS_PER_PAGE
		local tierDef = BattlePassConfig.GetTier(season, level)
		if tierDef then
			showRewardPreview(tierDef.Reward)
		end
	end

	-- Por defecto al (re)mostrar una página: si el tier en el que está el jugador
	-- cae en esta página, lo selecciona (levantado) y lo previsualiza; si no,
	-- previsualiza el item 8.
	local function applyDefaultSelection()
		local state = Fusion.peek(DataController.BattlePass)
		local currentTier = if type(state) == "table" then math.floor(state.CurrentTier or 1) else 1
		if currentTier >= 1 and currentTier <= maxTier then
			local pageStart = currentPage * SLOTS_PER_PAGE
			if currentTier > pageStart and currentTier <= pageStart + SLOTS_PER_PAGE then
				local refs = slots[currentTier - pageStart]
				local tierDef = BattlePassConfig.GetTier(season, currentTier)
				if refs and tierDef then
					selectSlot(refs.container)
					showRewardPreview(tierDef.Reward)
					return
				end
			end
		end
		showPageDefaultPreview()
	end

	-- ── Timer ────────────────────────────────────────────────
	local timerRunning = true
	local function updateTimer(): number
		if not timerLabel then return TIMER_POLL_SLOW end
		if season.EndsAt <= 0 then
			timerLabel.Visible = false
			return TIMER_POLL_SLOW
		end
		local remaining = season.EndsAt - os.time()
		local text = _formatTimeLeft(remaining)
		if text == "" then
			timerLabel.Visible = false
			return TIMER_POLL_SLOW
		end
		timerLabel.Visible = true
		timerLabel.Text = text
		return if remaining > TIMER_POLL_SLOW then TIMER_POLL_SLOW else TIMER_POLL_FAST
	end
	updateTimer()
	if timerLabel and season.EndsAt > 0 then
		task.spawn(function()
			while timerRunning do
				task.wait(updateTimer())
			end
		end)
	end
	janitor:Add(function()
		timerRunning = false
	end, true)

	-- ── Claim helpers ────────────────────────────────────────
	local function isClaimable(level: number, state: any): boolean
		local tierDef = BattlePassConfig.GetTier(season, level)
		if not tierDef then return false end
		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		if level >= currentTier then return false end -- no completado
		local claimed = if type(state.Claimed) == "table" then state.Claimed else {}
		if claimed[tostring(level)] == true then return false end
		if tierDef.Premium and state.PremiumOwned ~= true then return false end
		return true
	end

	local function anyClaimableInRange(fromLevel: number, toLevel: number, state: any): boolean
		for level = math.max(1, fromLevel), math.min(maxTier, toLevel) do
			if isClaimable(level, state) then
				return true
			end
		end
		return false
	end

	-- ── Render ───────────────────────────────────────────────
	local slotConnections: { RBXScriptConnection } = {}
	local function clearSlotConnections()
		for _, conn in slotConnections do
			conn:Disconnect()
		end
		table.clear(slotConnections)
	end
	janitor:Add(clearSlotConnections, true)

	local function paintType(refs: SlotRefs, isPremium: boolean, isClaimable_: boolean, isClaimed: boolean)
		local typeLabel = refs.typeLabel
		if not typeLabel then return end

		if isClaimed then
			typeLabel.Visible = false
			if refs.typeGradient then
				refs.typeGradient.Enabled = false
			end
			return
		end

		typeLabel.Visible = true
		typeLabel.BackgroundTransparency = TYPE_BG_TRANSPARENCY

		if isClaimable_ then
			typeLabel.Text = "CLAIM"
			typeLabel.TextColor3 = TYPE_CLAIM_COLOR
			typeLabel.BackgroundColor3 = TYPE_CLAIM_COLOR
			if refs.typeGradient then
				refs.typeGradient.Enabled = false
			end
		else
			typeLabel.Text = if isPremium then "PASS" else "FREE"
			typeLabel.TextColor3 = TYPE_WHITE_TEXT
			typeLabel.BackgroundColor3 = TYPE_DARK_BG
			if refs.typeGradient then
				refs.typeGradient.Enabled = isPremium
			end
		end
	end

	local function paintContent(refs: SlotRefs, reward: BattlePassConfig.Reward, isClaimed: boolean)
		-- Visual: wrap → viewport (3D), resto → image.
		if _isWrapReward(reward) and refs.viewport then
			if refs.image then
				refs.image.Visible = false
			end
			refs.viewport.Visible = true
			local wrapId = reward.ItemId :: string
			local existing = wrapBySlot[refs.frame]
			if not existing or existing.wrapId ~= wrapId or existing.viewport ~= refs.viewport then
				clearWrap(refs.frame)
				local wrapsCatalog = ItemsConfig.WeaponWraps
				local wrapDef = if type(wrapsCatalog) == "table" then wrapsCatalog[wrapId] else nil
				if type(wrapDef) == "table" then
					local previewJanitor = Janitor.new()
					local ok = WeaponWrapPreviewer.Render(refs.viewport, {
						TextureID = wrapDef.TextureID,
						BaseColor = wrapDef.BaseColor,
						isAnimated = wrapDef.isAnimated,
						StudsPerTile = wrapDef.StudsPerTile,
					}, previewJanitor)
					if ok then
						WeaponWrapPreviewer.reframeCentered(refs.viewport)
						wrapBySlot[refs.frame] = { wrapId = wrapId, janitor = previewJanitor, viewport = refs.viewport }
					else
						previewJanitor:Destroy()
					end
				end
			end
		else
			clearWrap(refs.frame)
			if refs.viewport then
				refs.viewport.Visible = false
			end
			if refs.image then
				refs.image.Image = _rewardImage(reward)
				refs.image.Visible = true
			end
		end

		-- Description (cash / tipo).
		if refs.description then
			refs.description.Text = _rewardDescription(reward)
		end

		-- Reclamada → imagen/viewport gris semitransparente.
		local tintColor = if isClaimed then CLAIMED_IMG_COLOR else Color3.fromRGB(255, 255, 255)
		local tintTransp = if isClaimed then CLAIMED_IMG_TRANSPARENCY else 0
		if refs.image then
			refs.image.ImageColor3 = tintColor
			refs.image.ImageTransparency = tintTransp
		end
		if refs.viewport then
			refs.viewport.ImageColor3 = tintColor
			refs.viewport.ImageTransparency = tintTransp
		end
	end

	local function paintFooter(refs: SlotRefs, realLevel: number, currentTier: number, currentXP: number, isClaimed: boolean, tierDef: BattlePassConfig.Tier)
		if refs.footerFrame then
			refs.footerFrame.BackgroundColor3 = if isClaimed then FOOTER_CLAIMED_BG else FOOTER_UNCLAIMED_BG
		end
		if not refs.status then return end

		if isClaimed then
			refs.status.Text = "CLAIMED"
			refs.status.TextColor3 = STATUS_CLAIMED_COLOR
		else
			refs.status.TextColor3 = STATUS_UNCLAIMED_COLOR
			if realLevel == currentTier then
				refs.status.Text = tostring(currentXP) .. "/" .. tostring(tierDef.XPRequired)
			else
				refs.status.Text = "LVL " .. tostring(realLevel)
			end
		end
	end

	local function render()
		if not isOpen then return end
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then return end

		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		local currentXP = math.max(0, math.floor(state.XP or 0))
		local complete = currentTier > maxTier

		-- Progreso global.
		local activeTier = BattlePassConfig.GetTier(season, math.min(currentTier, maxTier))
		local needed = if activeTier then activeTier.XPRequired else 100
		local ratio = if complete then 1 else math.clamp(currentXP / math.max(1, needed), 0, 1)
		if progressFill then
			local size = progressFill.Size
			local widthOffset = if ratio > 0 and ratio < 1 then -FILL_RIGHT_MARGIN else 0
			progressFill.Size = UDim2.new(ratio, widthOffset, size.Y.Scale, size.Y.Offset)
		end
		if actualLevel then
			actualLevel.Text = tostring(math.clamp(currentTier, 1, maxTier))
		end
		if xpLabel then
			xpLabel.Text = if complete then "MAX" else (tostring(currentXP) .. "/" .. tostring(needed))
		end

		if pageLabel then
			pageLabel.Text = tostring(currentPage + 1) .. "/" .. tostring(pageCount)
		end
		if purchaseBtn and purchaseBtn:IsA("GuiObject") then
			purchaseBtn.Visible = state.PremiumOwned ~= true
		end

		clearSlotConnections()

		for i = 1, SLOTS_PER_PAGE do
			local refs = slots[i]
			if not refs then continue end

			local realLevel = currentPage * SLOTS_PER_PAGE + i
			local tierDef = BattlePassConfig.GetTier(season, realLevel)
			if not tierDef then
				refs.frame.Visible = false
				clearWrap(refs.frame)
				continue
			end

			refs.frame.Visible = true
			local claimedMap = if type(state.Claimed) == "table" then state.Claimed else {}
			local isClaimed = claimedMap[tostring(realLevel)] == true
			local claimable = isClaimable(realLevel, state)

			paintContent(refs, tierDef.Reward, isClaimed)
			paintType(refs, tierDef.Premium, claimable, isClaimed)
			paintFooter(refs, realLevel, currentTier, currentXP, isClaimed, tierDef)

			-- Content.UIGradient: habilitado en niveles PASS.
			if refs.contentGradient then
				refs.contentGradient.Enabled = tierDef.Premium
			end

			-- Click → marca seleccionado (preview) + claim si reclamable.
			local slotReward = tierDef.Reward
			local function onSlotClick()
				-- Solo recarga el preview si la selección realmente cambió.
				if selectSlot(refs.container) then
					showRewardPreview(slotReward)
				end
				if isClaimable(realLevel, Fusion.peek(DataController.BattlePass)) then
					Network.BattlePass.ClaimTier.Send({ tier = realLevel })
				end
			end
			-- Los slots son GuiButton → Activated (ratón + táctil); fallback a InputBegan.
			local conn: RBXScriptConnection
			if refs.frame:IsA("GuiButton") then
				conn = (refs.frame :: GuiButton).Activated:Connect(onSlotClick)
			else
				conn = refs.frame.InputBegan:Connect(function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.MouseButton1
						or input.UserInputType == Enum.UserInputType.Touch then
						onSlotClick()
					end
				end)
			end
			table.insert(slotConnections, conn)
		end

		-- Indicadores de Back/Next: reclamables fuera de la página actual.
		if backIndicator and backIndicator:IsA("GuiObject") then
			backIndicator.Visible = anyClaimableInRange(1, currentPage * SLOTS_PER_PAGE, state)
		end
		if nextIndicator and nextIndicator:IsA("GuiObject") then
			nextIndicator.Visible = anyClaimableInRange((currentPage + 1) * SLOTS_PER_PAGE + 1, maxTier, state)
		end
	end

	local function pageForCurrentTier(): number
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then return 0 end
		local tier = math.clamp(math.floor(state.CurrentTier or 1), 1, maxTier)
		return math.clamp(math.floor((tier - 1) / SLOTS_PER_PAGE), 0, pageCount - 1)
	end

	-- ── Panel (como settings: blur + fov, sin cámara) ─────────
	local panel = PanelController.new(menuController, frame, menuBtn, closeBtn, {
		onOpen = function()
			isOpen = true
			BlurController.acquire(BLUR_KEY)
			fovEffect:expand()
			currentPage = pageForCurrentTier()
			resetSelection()
			render()
			playPageStagger()
			applyDefaultSelection()
		end,
		onClose = function()
			isOpen = false
			BlurController.release(BLUR_KEY)
			fovEffect:restore()
			-- Liberar los wraps animados para que sus texturas dejen de
			-- actualizarse cada Heartbeat mientras el panel está cerrado.
			for slotFrame in wrapBySlot do
				clearWrap(slotFrame)
			end
			clearPreviewWrap()
		end,
	})
	janitor:Add(panel, "Destroy")

	-- ── Navegación / Skip / Purchase ──────────────────────────
	if nextBtn and nextBtn:IsA("GuiButton") then
		janitor:Add((nextBtn :: GuiButton).MouseButton1Click:Connect(function()
			if currentPage < pageCount - 1 then
				currentPage += 1
				resetSelection()
				render()
				playPageStagger()
				applyDefaultSelection()
			end
		end), "Disconnect")
	end
	if backBtn and backBtn:IsA("GuiButton") then
		janitor:Add((backBtn :: GuiButton).MouseButton1Click:Connect(function()
			if currentPage > 0 then
				currentPage -= 1
				resetSelection()
				render()
				playPageStagger()
				applyDefaultSelection()
			end
		end), "Disconnect")
	end
	if skipBtn and skipBtn:IsA("GuiButton") then
		janitor:Add((skipBtn :: GuiButton).MouseButton1Click:Connect(function()
			Network.BattlePass.BuySkip.Send({})
		end), "Disconnect")
	end
	if purchaseBtn and purchaseBtn:IsA("GuiButton") then
		janitor:Add((purchaseBtn :: GuiButton).MouseButton1Click:Connect(function()
			Network.BattlePass.BuyPremium.Send({})
		end), "Disconnect")
	end

	-- ── Feedback del servidor ─────────────────────────────────
	janitor:Add(Network.BattlePass.Response.Listen(function(data: any)
		if type(data) ~= "table" then return end
		if data.success then
			if data.message == "OK" then
				Notify.success("Recompensa reclamada")
			elseif data.message == "PremiumGranted" then
				Notify.success("Premium desbloqueado")
			elseif data.message == "SkipGranted" then
				Notify.success("Nivel saltado")
			end
		else
			warn(("[BattlePassFeature] Response: %s (tier=%s)"):format(tostring(data.message), tostring(data.tier)))
		end
	end), true)

	-- ── Render reactivo ───────────────────────────────────────
	DataController:WhenReady():andThen(function()
		currentPage = pageForCurrentTier()
		render()
		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)
		local obs = scope:Observer(DataController.BattlePass :: any)
		janitor:Add(obs:onBind(render), true)
	end)

	return janitor
end

return BattlePassFeature
