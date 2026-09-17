--!strict
--[[
	Sin blur: salta a su propia cámara (Workspace.Cameras.<CAMERA_TARGET>) tras un
	fundido a negro y aplica el LightingPreset de esa parte (su DoF desenfoca el fondo).

	GUI (PlayerGui.UserInterface.BattlePass). Cada nodo se busca primero bajo el frame
	intermedio OPCIONAL `Content` (o `Main`, nombre antiguo) y luego en la raíz.
	Todo con FindFirstChild: un nodo que falte no rompe el feature.
	  CloseBtn (root; fallback Header.CloseBtn)
	  Nav.Back (.Indicator) / Nav.Next (.Indicator) / Nav.Info ("1/8")
	  SkipLevel / SkipLevel5 (Robux, .Price opcional) · PurchaseBtn (Gems, premium)
	  ImagePreview (preview grande; un wrap usa su `Image` de ItemsConfig)
	  PathContainer."1".."8" (GuiButton; también `Path`, o PathContainer.Path.1..8):
	    Container.Level                    ("Lvl. 5"; oculto en el slot del nivel actual)
	    Container.Type / Container.Claim   (OPCIONALES)
	    Container.LevelReward
	      .ViewportReward (wraps) / .ImageReward (resto) / .Value (tipo de recompensa)
	      .Glow / .Check                   (OPCIONALES)
	      .Footer.Status.Locked
	  CurrentLevel (OPCIONAL; .Fill, .Level): plantilla clonada UNA vez y reparentada
	    al Container del nivel actual en cada render, para no crear CanvasGroups por tick.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local PanelController = require(Client.core.ui.PanelController)
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local CameraLock = require(Client.core.camera.CameraLock)
local ScenePresetController = require(Client.core.lighting.ScenePresetController)
local ScreenFade = require(Client.core.ui.ScreenFade)
local DataController = require(Client.core.data.DataController)
local Notify = require(Client.core.ui.NotificationController)
local UITheme = require(Client.core.ui.UITheme)
local Network = require(Shared.networking.Network)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local LockerConfig = require(Shared.constants.LockerConfig)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local WeaponWrapPreviewer = require(Client.features.locker.Previewers.WeaponWrapPreviewer)
local ScenePreview = require(script.ScenePreview)

local SLOTS_PER_PAGE = 8

-- Nombre de la parte en Workspace.Cameras; el look sale de su atributo LightingPreset.
local CAMERA_TARGET = "battlepass"
local CAMERA_LOCK_OWNER = "battlepass"

local UI_DARK_TEXT = Color3.fromRGB(34, 34, 34)

local TYPE_PREMIUM_BG = Color3.fromRGB(255, 196, 0)
local TYPE_FREE_BG = Color3.fromRGB(255, 255, 255)
local TYPE_CLAIMED_BG = Color3.fromRGB(34, 34, 34)
local TYPE_CLAIMED_TEXT = Color3.fromRGB(255, 255, 255)

-- Misma paleta de rareza que las cards del locker, para que un item brille igual en ambos.
local GLOW_CLAIMED_COLOR = Color3.fromRGB(34, 34, 34)
local RARITY_GLOW = UITheme.LockerRarityGlow
local RARITY_FALLBACK = "Common"

-- El espacio inicial separa del icono de Robux, igual que en la tienda.
local SKIP_PRICE_FORMAT = " %d"

local STATUS_LEVEL_FORMAT = "Lvl. %d"

local LEVEL_PASSED_BG = Color3.fromRGB(255, 196, 0)
local LEVEL_LOCKED_BG = Color3.fromRGB(255, 255, 255)

-- Un wrap GLOBAL se previsualiza sobre el arma equipada en esta categoría.
local WRAP_PREVIEW_CATEGORY = WeaponCategoryMod.MAIN
local LOADOUT_SLOT_BY_WEAPON = LockerConfig.CategoryToLoadoutSlot :: { [string]: string }

local CLAIMED_IMG_COLOR = Color3.fromRGB(89, 89, 89)
local CLAIMED_IMG_TRANSPARENCY = 0.3

local SLOT_STAGGER_DELAY = 0.04
local SLOT_STAGGER_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local STAGGER_ENTER_OFFSET = 30

local SELECTED_LIFT_PIXELS = 12
local SELECT_MOVE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Mayor que en MapVote: con ocho cards pequeñas por página un 2% no se lee.
local SLOT_HOVER_SCALE = 1.05
local SLOT_CLICK_SCALE = 0.97

local PREVIEW_LIFT_PIXELS = 24
local PREVIEW_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- "Body" y no "Outfit": así llama el nav del locker a Outfits (LockerConfig.ITEMS_CONFIG_BY_NAV).
local CATEGORY_LABEL: { [string]: string } = {
	Outfits = "Body",
	Faces = "Face",
	Hats = "Hat",
	KillEffects = "Kill Effect",
	WeaponWraps = "Wrap",
	Banners = "Banner",
	Main = "Weapon",
	Special = "Weapon",
}

local BattlePassFeature = {}

local function _isWrapReward(reward: BattlePassConfig.Reward): boolean
	return reward.Kind == "Item" and reward.Category == "WeaponWraps" and reward.ItemId ~= nil
end

local function _rewardImage(reward: BattlePassConfig.Reward): string
	if reward.Kind == "Cash" then
		return reward.Icon or BattlePassConfig.RewardIcons.Cash or ""
	end
	if reward.Kind == "Gems" then
		-- Sin icono, "" y no el de Cash: mejor sin imagen que con la moneda equivocada.
		return reward.Icon or BattlePassConfig.RewardIcons.Gems or ""
	end
	local catalog = ItemsConfig[reward.Category]
	local def = if type(catalog) == "table" then catalog[reward.ItemId] else nil
	return reward.Icon or (if def and type(def.Image) == "string" then def.Image else "")
end

local function _rewardRarity(reward: BattlePassConfig.Reward): string
	if reward.Kind ~= "Item" then
		return RARITY_FALLBACK
	end
	local catalog = ItemsConfig[reward.Category]
	local def = if type(catalog) == "table" then catalog[reward.ItemId] else nil
	if type(def) == "table" and type(def.Rarity) == "string" then
		return def.Rarity
	end
	return RARITY_FALLBACK
end

-- El TIPO de recompensa, no su cantidad.
local function _rewardValueText(reward: BattlePassConfig.Reward): string
	if reward.Label then
		return reward.Label
	end
	if reward.Kind == "Cash" or reward.Kind == "Gems" then
		return reward.Kind
	end
	local category = reward.Category or ""
	return CATEGORY_LABEL[category] or category
end

-- Wrap global sin loadout → id nil y el previewer cae al modelo "Default".
-- Se devuelve también el nombre visible: los modelos de Shared.Locker.weapons.*
-- pueden estar nombrados por id o por nombre.
local function _wrapPreviewWeapon(reward: BattlePassConfig.Reward): (string, string?, string?)
	local category: string
	local weaponId: string?

	if WeaponCategoryMod.isValid(reward.WeaponCategory) then
		category = reward.WeaponCategory :: string
		weaponId = if type(reward.WeaponId) == "string" and reward.WeaponId ~= "" then reward.WeaponId else nil
	else
		category = WRAP_PREVIEW_CATEGORY
		local loadout = Fusion.peek(DataController.Loadout)
		local slot = LOADOUT_SLOT_BY_WEAPON[category]
		local equipped = if type(loadout) == "table" and slot then loadout[slot] else nil
		weaponId = if type(equipped) == "string" and equipped ~= "" then equipped else nil
	end

	local catalog = ItemsConfig[category]
	local def = if type(catalog) == "table" and weaponId then catalog[weaponId] else nil
	local displayName = if type(def) == "table" and type(def.Name) == "string" and def.Name ~= ""
		then def.Name
		else nil

	return category, weaponId, displayName
end

type SlotRefs = {
	frame: GuiObject,
	container: GuiObject,
	image: ImageLabel?,
	viewport: ViewportFrame?,
	value: TextLabel?,
	rewardGradient: UIGradient?,
	glow: GuiObject?,
	levelLabel: TextLabel?,
	locked: GuiObject?,
	claim: GuiObject?,
	typeLabel: TextLabel?,
	check: ImageLabel?,
}

local function _resolveSlot(pathFolder: Instance, index: number): SlotRefs?
	local frame = pathFolder:FindFirstChild(tostring(index))
	if not (frame and frame:IsA("GuiObject")) then
		return nil
	end

	-- Se anima el Container (raise/scale); el slot queda fijo en el layout.
	local containerNode = frame:FindFirstChild("Container")
	local container: GuiObject = if containerNode and containerNode:IsA("GuiObject") then containerNode else frame

	local reward = container:FindFirstChild("LevelReward")
	local imageNode = reward and reward:FindFirstChild("ImageReward")
	local viewportNode = reward and reward:FindFirstChild("ViewportReward")
	local valueNode = reward and reward:FindFirstChild("Value")
	local rewardGradientNode = if reward then reward:FindFirstChildOfClass("UIGradient") else nil
	local glowNode = reward and reward:FindFirstChild("Glow")
	local checkNode = reward and reward:FindFirstChild("Check")

	local footer = reward and reward:FindFirstChild("Footer")
	local status = footer and footer:FindFirstChild("Status")
	local lockedNode = status and status:FindFirstChild("Locked")

	-- Footer.Status.Value: ubicación antigua de Level.
	local levelNode = container:FindFirstChild("Level") or (status and status:FindFirstChild("Value"))

	local typeNode = container:FindFirstChild("Type") or (reward and reward:FindFirstChild("Type"))
	local claimNode = container:FindFirstChild("Claim") or (reward and reward:FindFirstChild("Claim"))

	return {
		frame = frame,
		container = container,
		image = if imageNode and imageNode:IsA("ImageLabel") then imageNode else nil,
		viewport = if viewportNode and viewportNode:IsA("ViewportFrame") then viewportNode else nil,
		value = if valueNode and valueNode:IsA("TextLabel") then valueNode else nil,
		rewardGradient = rewardGradientNode,
		glow = if glowNode and glowNode:IsA("GuiObject") then glowNode else nil,
		levelLabel = if levelNode and levelNode:IsA("TextLabel") then levelNode else nil,
		locked = if lockedNode and lockedNode:IsA("GuiObject") then lockedNode else nil,
		claim = if claimNode and claimNode:IsA("GuiObject") then claimNode else nil,
		typeLabel = if typeNode and typeNode:IsA("TextLabel") then typeNode else nil,
		check = if checkNode and checkNode:IsA("ImageLabel") then checkNode else nil,
	}
end

-- UIScale escala desde el AnchorPoint: se recentra a (0.5, 0.5) compensando Position
-- con Size (no AbsoluteSize, para no depender de la resolución). Si un layout manda la
-- Position o un constraint el tamaño, la compensación no sería exacta: devuelve false
-- y no lo toca.
local function _centerScaleAnchor(node: GuiObject): boolean
	local anchor = node.AnchorPoint
	if anchor.X == 0.5 and anchor.Y == 0.5 then
		return true
	end

	local parent = node.Parent
	if parent and parent:IsA("GuiObject") and parent:FindFirstChildWhichIsA("UILayout") then
		return false
	end
	if node:FindFirstChildWhichIsA("UIAspectRatioConstraint") or node:FindFirstChildWhichIsA("UISizeConstraint") then
		return false
	end

	local dx = 0.5 - anchor.X
	local dy = 0.5 - anchor.Y
	local size = node.Size
	local pos = node.Position
	node.Position = UDim2.new(
		pos.X.Scale + size.X.Scale * dx,
		pos.X.Offset + size.X.Offset * dx,
		pos.Y.Scale + size.Y.Scale * dy,
		pos.Y.Offset + size.Y.Offset * dy
	)
	node.AnchorPoint = Vector2.new(0.5, 0.5)
	return true
end

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
	-- Sin WaitForChild a propósito: el frame intermedio es opcional y esperarlo colgaría.
	local mainNode = frame:FindFirstChild("Content") or frame:FindFirstChild("Main")
	local main: Instance = if mainNode then mainNode else frame

	local function findPanelChild(name: string): Instance?
		local found = main:FindFirstChild(name)
		if found then
			return found
		end
		return if main ~= frame then frame:FindFirstChild(name) else nil
	end

	local container = menuGui:FindFirstChild("Container")
	local btnInstance = container and container:FindFirstChild("FamePass")
	local menuBtn: GuiButton? = if btnInstance and btnInstance:IsA("GuiButton")
		then btnInstance
		else (btnInstance and btnInstance:FindFirstChildWhichIsA("GuiButton"))

	local navIconValueNode = btnInstance and btnInstance:FindFirstChild("Icon")
	local navValueNode = navIconValueNode and navIconValueNode:FindFirstChild("Value")
	local navIconValue: TextLabel? = if navValueNode and navValueNode:IsA("TextLabel") then navValueNode else nil
	local navIndicatorNode = btnInstance and btnInstance:FindFirstChild("Indicator")
	local navIndicator: GuiObject? = if navIndicatorNode and navIndicatorNode:IsA("GuiObject") then navIndicatorNode else nil

	local header = findPanelChild("Header")
	local closeNode = frame:FindFirstChild("CloseBtn") or (header and header:FindFirstChild("CloseBtn"))
	local closeBtn: GuiButton? = if closeNode and closeNode:IsA("GuiButton") then closeNode else nil

	local navFolder = findPanelChild("Nav")
	local backBtn = navFolder and navFolder:FindFirstChild("Back")
	local nextBtn = navFolder and navFolder:FindFirstChild("Next")
	local pageLabelNode = navFolder and navFolder:FindFirstChild("Info")
	local pageLabel: TextLabel? = if pageLabelNode and pageLabelNode:IsA("TextLabel") then pageLabelNode else nil
	local backIndicator = if backBtn then backBtn:FindFirstChild("Indicator") else nil
	local nextIndicator = if nextBtn then nextBtn:FindFirstChild("Indicator") else nil

	local skipBtn = findPanelChild("SkipLevel")
	local skip5Btn = findPanelChild("SkipLevel5")
	local purchaseBtn = findPanelChild("PurchaseBtn")

	local pathFolder = findPanelChild("PathContainer") or findPanelChild("Path")
	if pathFolder and not pathFolder:FindFirstChild("1") then
		pathFolder = pathFolder:FindFirstChild("Path") or pathFolder
	end
	local slots: { SlotRefs? } = {}
	if pathFolder then
		for i = 1, SLOTS_PER_PAGE do
			slots[i] = _resolveSlot(pathFolder, i)
		end
	else
		warn("[BattlePassFeature] BattlePass.PathContainer no existe")
	end

	-- El hover escala el Container (Position ya la animan stagger y selección).
	-- El AnchorPoint se recentra aquí y no al abrir: el stagger cachea la Position de
	-- reposo la primera vez que anima y debe cachear ya la compensada.
	local canHover = UserInputService.MouseEnabled and not UserInputService.TouchEnabled
	local anchorFixFailed = false
	for i = 1, SLOTS_PER_PAGE do
		local refs = slots[i]
		if refs and refs.frame:IsA("GuiButton") then
			if not _centerScaleAnchor(refs.container) then
				anchorFixFailed = true
			end
			InteractiveScaleTween.bindButton(refs.frame :: GuiButton, janitor, {
				scaleTarget = refs.container,
				enableHover = canHover,
				hoverScale = SLOT_HOVER_SCALE,
				clickScale = SLOT_CLICK_SCALE,
			})
		end
	end
	if anchorFixFailed then
		warn(
			"[BattlePassFeature] Algún Container de PathContainer no se puede recentrar por código (lo posiciona un layout o su tamaño lo decide un constraint): el hover crecerá desde la esquina. Ponle AnchorPoint 0.5,0.5 en Studio."
		)
	end

	local currentLevelTemplate = findPanelChild("CurrentLevel")
	local currentLevel: GuiObject? = nil
	local currentFill: GuiObject? = nil
	local currentLevelLabel: TextLabel? = nil
	if currentLevelTemplate and currentLevelTemplate:IsA("GuiObject") then
		(currentLevelTemplate :: GuiObject).Visible = false
		local clone = (currentLevelTemplate :: GuiObject):Clone()
		clone.Visible = false
		clone.Parent = frame
		janitor:Add(clone, "Destroy")
		currentLevel = clone
		local fillNode = clone:FindFirstChild("Fill")
		currentFill = if fillNode and fillNode:IsA("GuiObject") then fillNode else nil
		local levelNode = clone:FindFirstChild("Level")
		currentLevelLabel = if levelNode and levelNode:IsA("TextLabel") then levelNode else nil
	end

	local imagePreviewNode = findPanelChild("ImagePreview")
	local imagePreview: (ImageLabel | ImageButton)? = if imagePreviewNode
			and (imagePreviewNode:IsA("ImageLabel") or imagePreviewNode:IsA("ImageButton"))
		then imagePreviewNode :: any
		else nil

	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)
	local pageCount = math.max(1, math.ceil(maxTier / SLOTS_PER_PAGE))
	local currentPage = 0
	local isOpen = false
	-- Lo fija `onOpen` y lo lee `onClose` para deshacer exactamente lo que se hizo.
	local cameraActive = false

	-- La cámara se resuelve en cada apertura (en el bootstrap Workspace.Cameras puede
	-- no haber replicado) y con FindFirstChild antes de LockerCameraController.new,
	-- que hace WaitForChild sin timeout y colgaría si la parte no existe.
	local cameraController: any = nil
	local fade: any = nil
	local warnedMissingCamera = false

	local function findCameraPart(): BasePart?
		local camerasFolder = Workspace:FindFirstChild("Cameras")
		local part = if camerasFolder then camerasFolder:FindFirstChild(CAMERA_TARGET) else nil
		return if part and part:IsA("BasePart") then part :: BasePart else nil
	end

	-- nil → el panel se abre sin cámara.
	local function ensureCameraController(): any
		if cameraController then
			return cameraController
		end
		if not findCameraPart() then
			if not warnedMissingCamera then
				warnedMissingCamera = true
				warn(`[BattlePassFeature] Falta Workspace.Cameras.{CAMERA_TARGET} (o no es un BasePart); el panel se abre sin cámara`)
			end
			return nil
		end
		cameraController = LockerCameraController.new(CAMERA_TARGET)
		janitor:Add(cameraController, "Destroy")
		-- Singleton compartido vía playerGui: no va al janitor.
		fade = ScreenFade.new(playerGui)
		return cameraController
	end

	-- Atributo LightingPreset de la parte de cámara; si no lo lleva, el de Workspace.Locker.
	local function applyPassPreset()
		local cameraPart = findCameraPart()
		if cameraPart and ScenePresetController.applyFrom(cameraPart) then
			return
		end
		local lockerNode = Workspace:FindFirstChild("Locker")
		if lockerNode and ScenePresetController.applyFrom(lockerNode) then
			return
		end
		warn(`[BattlePassFeature] Sin preset de iluminación: ni Workspace.Cameras.{CAMERA_TARGET} ni Workspace.Locker llevan atributo LightingPreset`)
	end

	-- Peanas de Workspace.BattlePass; si faltan las anclas no hace nada.
	local scenePreview = ScenePreview.new()
	janitor:Add(scenePreview, "Destroy")

	-- previewKey = wrap + arma: si cambia cualquiera hay que rehacer el viewport.
	type WrapEntry = { previewKey: string, janitor: any }
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

	-- Un único tween de Position por Container, compartido por stagger y selección.
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

	-- El perfil puede traer el SeasonId de la season anterior hasta que el servidor
	-- lo resetee: se relee al abrir y cuando `state.SeasonId` no coincide.
	local function refreshSeason()
		season = BattlePassConfig.GetActiveSeason()
		maxTier = BattlePassConfig.GetMaxTier(season)
		pageCount = math.max(1, math.ceil(maxTier / SLOTS_PER_PAGE))
		currentPage = 0
		resetSelection()
	end

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

	janitor:Add(resetSelection, true)

	local imagePreviewRest: UDim2? = nil

	-- El observer de Loadout la reenvía para recolocar un wrap global sobre el arma nueva.
	local lastSceneReward: BattlePassConfig.Reward? = nil

	local function pushScenePreview(reward: BattlePassConfig.Reward)
		lastSceneReward = reward
		local weaponCategory, weaponId, weaponName = _wrapPreviewWeapon(reward)
		scenePreview:setReward(reward, {
			weaponCategory = weaponCategory,
			weaponId = weaponId,
			weaponName = weaponName,
			wrapId = if _isWrapReward(reward) then reward.ItemId else nil,
		})
	end

	local function showRewardPreview(reward: BattlePassConfig.Reward)
		pushScenePreview(reward)
		if not imagePreview then return end
		local image = _rewardImage(reward)
		if image == "" then
			imagePreview.Visible = false
			return
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

	local function showPageDefaultPreview()
		local level = currentPage * SLOTS_PER_PAGE + SLOTS_PER_PAGE
		local tierDef = BattlePassConfig.GetTier(season, level)
		if tierDef then
			showRewardPreview(tierDef.Reward)
		end
	end

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

	local function isClaimable(level: number, state: any): boolean
		local tierDef = BattlePassConfig.GetTier(season, level)
		if not tierDef then return false end
		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		if level >= currentTier then return false end
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

	-- Menu.Container.FamePass se actualiza aunque el panel esté cerrado (render no).
	local function updateNavButton()
		if not (navIconValue or navIndicator) then
			return
		end
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then
			return
		end
		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		if navIconValue then
			navIconValue.Text = tostring(math.clamp(currentTier, 1, maxTier))
		end
		if navIndicator then
			navIndicator.Visible = anyClaimableInRange(1, maxTier, state)
		end
	end

	local slotConnections: { RBXScriptConnection } = {}
	local function clearSlotConnections()
		for _, conn in slotConnections do
			conn:Disconnect()
		end
		table.clear(slotConnections)
	end
	janitor:Add(clearSlotConnections, true)

	local function paintType(refs: SlotRefs, isPremium: boolean, isClaimed: boolean)
		local typeLabel = refs.typeLabel
		if not typeLabel then return end

		typeLabel.Visible = true

		if isClaimed then
			typeLabel.Text = "CLAIMED"
			typeLabel.TextColor3 = TYPE_CLAIMED_TEXT
			typeLabel.BackgroundColor3 = TYPE_CLAIMED_BG
		else
			typeLabel.Text = if isPremium then "PASS" else "FREE"
			typeLabel.TextColor3 = UI_DARK_TEXT
			typeLabel.BackgroundColor3 = if isPremium then TYPE_PREMIUM_BG else TYPE_FREE_BG
		end
	end

	local function paintContent(refs: SlotRefs, reward: BattlePassConfig.Reward, isClaimed: boolean)
		if _isWrapReward(reward) and refs.viewport then
			if refs.image then
				refs.image.Visible = false
			end
			refs.viewport.Visible = true
			local wrapId = reward.ItemId :: string
			local weaponCategory, weaponId, weaponName = _wrapPreviewWeapon(reward)
			local previewKey = `{wrapId}|{weaponCategory}|{weaponId or ""}`
			local existing = wrapBySlot[refs.frame]
			if not existing or existing.previewKey ~= previewKey then
				clearWrap(refs.frame)
				local wrapsCatalog = ItemsConfig.WeaponWraps
				local wrapDef = if type(wrapsCatalog) == "table" then wrapsCatalog[wrapId] else nil
				if type(wrapDef) == "table" then
					local previewJanitor = Janitor.new()
					local ok, usedWeapon = WeaponWrapPreviewer.Render(refs.viewport, {
						TextureID = wrapDef.TextureID,
						BaseColor = wrapDef.BaseColor,
						Material = wrapDef.Material,
						isAnimated = wrapDef.isAnimated,
						StudsPerTile = wrapDef.StudsPerTile,
						PreviewWeaponCategory = weaponCategory,
						PreviewWeaponId = weaponId,
						PreviewWeaponDisplayName = weaponName,
					}, previewJanitor)
					if ok then
						-- Solo el bloque genérico (sin modelo de arma) necesita recentrarse.
						if not usedWeapon then
							WeaponWrapPreviewer.reframeCentered(refs.viewport)
						end
						wrapBySlot[refs.frame] = { previewKey = previewKey, janitor = previewJanitor }
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

		if refs.value then
			local text = _rewardValueText(reward)
			refs.value.Text = text
			refs.value.Visible = text ~= ""
		end

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
		if refs.check then
			refs.check.Visible = isClaimed
		end

		local glow = refs.glow
		if glow then
			local color = if isClaimed
				then GLOW_CLAIMED_COLOR
				else (RARITY_GLOW[_rewardRarity(reward)] or RARITY_GLOW[RARITY_FALLBACK])
			if color then
				if glow:IsA("ImageLabel") or glow:IsA("ImageButton") then
					glow.ImageColor3 = color
				else
					glow.BackgroundColor3 = color
				end
			end
		end
	end

	local function paintFooter(refs: SlotRefs, isClaimed: boolean, isClaimable_: boolean)
		if refs.locked then
			refs.locked.Visible = not isClaimed and not isClaimable_
		end
		if refs.claim then
			refs.claim.Visible = isClaimable_
		end
	end

	-- El clon de CurrentLevel lleva el LayoutOrder de la plantilla y cae en el hueco del Level.
	local function paintLevel(refs: SlotRefs, realLevel: number, currentLevelTier: number, ratio: number)
		local isCurrent = realLevel == currentLevelTier
		local replacedByCurrent = isCurrent and currentLevel ~= nil
		if refs.levelLabel then
			refs.levelLabel.Text = STATUS_LEVEL_FORMAT:format(realLevel)
			refs.levelLabel.Visible = not replacedByCurrent
			refs.levelLabel.TextColor3 = UI_DARK_TEXT
			refs.levelLabel.BackgroundColor3 = if realLevel < currentLevelTier
				then LEVEL_PASSED_BG
				else LEVEL_LOCKED_BG
		end
		if not (isCurrent and currentLevel) then return end
		local node = currentLevel :: GuiObject
		node.Parent = refs.container
		node.Visible = true
		if currentLevelLabel then
			currentLevelLabel.Text = STATUS_LEVEL_FORMAT:format(realLevel)
		end
		if currentFill then
			local size = currentFill.Size
			currentFill.Size = UDim2.new(ratio, 0, size.Y.Scale, size.Y.Offset)
		end
	end

	local function render()
		if not isOpen then return end
		local state = Fusion.peek(DataController.BattlePass)
		if type(state) ~= "table" then return end

		local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
		local currentXP = math.max(0, math.floor(state.XP or 0))
		local complete = currentTier > maxTier

		local activeTier = BattlePassConfig.GetTier(season, math.min(currentTier, maxTier))
		local needed = if activeTier then activeTier.XPRequired else 100
		local ratio = if complete then 1 else math.clamp(currentXP / math.max(1, needed), 0, 1)

		if pageLabel then
			pageLabel.Text = tostring(currentPage + 1) .. "/" .. tostring(pageCount)
		end
		if purchaseBtn and purchaseBtn:IsA("GuiObject") then
			purchaseBtn.Visible = state.PremiumOwned ~= true
		end

		clearSlotConnections()

		if currentLevel then
			(currentLevel :: GuiObject).Visible = false
		end
		local displayTier = math.clamp(currentTier, 1, maxTier)

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
			paintType(refs, tierDef.Premium, isClaimed)
			paintFooter(refs, isClaimed, claimable)
			paintLevel(refs, realLevel, displayTier, ratio)

			if refs.rewardGradient then
				refs.rewardGradient.Enabled = tierDef.Premium
			end

			local slotReward = tierDef.Reward
			local function onSlotClick()
				if selectSlot(refs.container) then
					showRewardPreview(slotReward)
				end
				if isClaimable(realLevel, Fusion.peek(DataController.BattlePass)) then
					Network.BattlePass.ClaimTier.Send({ tier = realLevel })
				end
			end
			if refs.frame:IsA("GuiButton") then
				table.insert(slotConnections, (refs.frame :: GuiButton).Activated:Connect(onSlotClick))
			end
		end

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

	local panel = PanelController.new(menuController, frame, menuBtn, closeBtn, {
		onOpen = function()
			isOpen = true

			local function presentPanel()
				refreshSeason()
				currentPage = pageForCurrentTier()
				resetSelection()
				render()
				playPageStagger()
				scenePreview:show()
				applyDefaultSelection()
			end

			-- onClose mira este flag y no el controller: un panel abierto sin cámara se
			-- cierra sin fundido aunque la parte replique mientras está abierto.
			cameraActive = ensureCameraController() ~= nil
			if cameraActive then
				CameraLock.acquire(CAMERA_LOCK_OWNER)
				-- El animator ya hizo Visible=true: se oculta hasta que la pantalla esté negra
				-- para no ver el panel con la cámara vieja detrás.
				frame.Visible = false
				fade:cover(function()
					cameraController:apply(true)
					applyPassPreset()
					frame.Visible = true
					presentPanel()
					fade:reveal()
				end)
			else
				presentPanel()
			end
		end,
		onClose = function()
			isOpen = false
			-- El decorado se retira detrás del negro, no antes.
			if cameraActive then
				-- PanelController ya remostró el menú; se re-oculta en el mismo frame (sin
				-- parpadeo) para que no se vea sobre la cámara del pase durante el fundido.
				menuController:hide()
				fade:cover(function()
					ScenePresetController.applyLobbyOrRestore("[BattlePassFeature]")
					cameraController:restore()
					CameraLock.release(CAMERA_LOCK_OWNER)
					scenePreview:hide()
					-- Mismo guard que PanelController: otro panel pudo abrirse durante el fundido.
					if not menuController:hasOpenPanel() then
						menuController:show()
					end
					fade:reveal()
				end)
			else
				scenePreview:hide()
			end
			-- Los wraps animados actualizan textura cada Heartbeat.
			for slotFrame in wrapBySlot do
				clearWrap(slotFrame)
			end
		end,
	})
	janitor:Add(panel, "Destroy")

	if btnInstance and not menuBtn and btnInstance:IsA("GuiObject") then
		janitor:Add(btnInstance.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				panel:open()
			end
		end), "Disconnect")
	end

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
	-- El servidor concede en ProcessReceipt. Antes de cobrar se comprueba que queden
	-- niveles suficientes. ProductId = 0 (producto sin crear) → botón inactivo.
	local function bindSkipButton(buttonNode: Instance?, buttonName: string, kind: BattlePassConfig.SkipKind)
		if not (buttonNode and buttonNode:IsA("GuiButton")) then
			warn(("[BattlePassFeature] BattlePass.%s no existe"):format(buttonName))
			return
		end
		local button = buttonNode :: GuiButton
		local productId, robuxPrice, tierCount = BattlePassConfig.GetSkipOffer(season, kind)

		local priceNode = button:FindFirstChild("Price")
		if priceNode and priceNode:IsA("TextLabel") and robuxPrice > 0 then
			priceNode.Text = SKIP_PRICE_FORMAT:format(robuxPrice)
		end
		button.Active = productId > 0
		button.Selectable = productId > 0

		janitor:Add(button.MouseButton1Click:Connect(function()
			if productId <= 0 then
				warn("[BattlePassFeature] ProductId no configurado para", buttonName)
				return
			end
			local state = Fusion.peek(DataController.BattlePass)
			if type(state) == "table" then
				local currentTier = math.max(1, math.floor(state.CurrentTier or 1))
				local remaining = maxTier - currentTier + 1
				if remaining <= 0 then
					Notify.warning("You already completed the season.")
					return
				end
				if remaining < tierCount then
					Notify.warning(("Only %d levels left in the season."):format(remaining))
					return
				end
			end
			MarketplaceService:PromptProductPurchase(player, productId)
		end), "Disconnect")
	end
	bindSkipButton(skipBtn, "SkipLevel", "Skip")
	bindSkipButton(skip5Btn, "SkipLevel5", "Skip5")
	if purchaseBtn and purchaseBtn:IsA("GuiButton") then
		janitor:Add((purchaseBtn :: GuiButton).MouseButton1Click:Connect(function()
			Network.BattlePass.BuyPremium.Send({})
		end), "Disconnect")
	end

	janitor:Add(Network.BattlePass.Response.Listen(function(data: any)
		if type(data) ~= "table" then return end
		if data.success then
			if data.message == "OK" then
				Notify.success("Reward claimed!")
			elseif data.message == "PremiumGranted" then
				Notify.success("Premium unlocked!")
			elseif data.message == "SkipGranted" then
				Notify.success("Level skipped!")
			elseif data.message == "Skip5Granted" then
				Notify.success("5 levels skipped!")
			end
		else
			-- Fallos accionables por el jugador → notificación; el resto, solo log.
			if data.message == "GemsInsufficient" then
				Notify.warning("Not enough Gems. Get more in the store.")
			elseif data.message == "AlreadyOwned" then
				Notify.warning("You already own the Premium pass.")
			elseif data.message == "SeasonCompleted" then
				Notify.warning("You already completed the season.")
			end
			warn(("[BattlePassFeature] Response: %s (tier=%s)"):format(tostring(data.message), tostring(data.tier)))
		end
	end), true)

	DataController:WhenReady():andThen(function()
		currentPage = pageForCurrentTier()
		render()
		updateNavButton()
		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)
		local obs = scope:Observer(DataController.BattlePass :: any)
		janitor:Add(obs:onBind(function()
			local state = Fusion.peek(DataController.BattlePass)
			if type(state) == "table" and type(state.SeasonId) == "string" and state.SeasonId ~= season.Id then
				refreshSeason()
			end
			render()
			updateNavButton()
		end), true)
		-- Los wraps globales van sobre el arma equipada: la previewKey detecta el cambio
		-- pero hace falta repintar para que se relea.
		local loadoutObs = scope:Observer(DataController.Loadout :: any)
		janitor:Add(loadoutObs:onBind(function()
			if not isOpen then
				return
			end
			render()
			if lastSceneReward then
				pushScenePreview(lastSceneReward)
			end
		end), true)
	end)

	return janitor
end

return BattlePassFeature
