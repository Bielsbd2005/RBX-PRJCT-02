--!strict

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any
local LockerCameraController = require(Client.core.camera.LockerCameraController)
local CameraLock = require(Client.core.camera.CameraLock)
local LightingPresetController = require(Client.core.lighting.LightingPresetController)
local LockerCatalog = require(script:WaitForChild("LockerCatalog"))
local LockerGrid = require(script:WaitForChild("LockerGrid"))
local WeaponPreviewController = require(script:WaitForChild("WeaponPreviewController"))
local FaceApplier = require(script.Appliers.FaceApplier)
local HatApplier = require(script.Appliers.HatApplier)
local MenuHover = require(Client.core.ui.MenuHover)
local NavStaggerController = require(Client.core.ui.NavStaggerController)
local UIUtils = require(Client.core.ui.UIUtils)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local LockerConfig = require(Shared.constants.LockerConfig)
local WeaponCategoryMod = require(Shared.constants.WeaponCategory)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local LockerCategory = require(Shared.constants.LockerCategory)
local LockerMainCategory = require(Shared.constants.LockerMainCategory)
local Network = require(Shared.networking.Network)
local DataController = require(Client.core.data.DataController)
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local StoreProducts = require(Shared.constants.StoreProducts)
local UITheme = require(Client.core.ui.UITheme)
local NavTabController = require(Client.core.ui.NavTabController)
local Confetti = require(Client.core.ui.Confetti)

local LockerFeature = {}

local STROKE_DEFAULT = UITheme.StrokeDefault
local STROKE_WHITE = UITheme.StrokeHover
local PURCHASE_BUTTON_HOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PURCHASE_BUTTON_CLICK_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PURCHASE_BUTTON_DEFAULT_SCALE = 1
local PURCHASE_BUTTON_HOVER_SCALE = 1.03
local PURCHASE_BUTTON_CLICK_SCALE = 0.96
local DEFAULT_NAV_THUMBNAIL = "rbxasset://textures/ui/GuiImagePlaceholder.png"
local ACTION_FRAME_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LOCKER_PREVIEW_IDLE_ANIMATION_ID = "rbxassetid://115197033304718"
local SHOP_REQUEST_TIMEOUT = 5

type LockerCategoryKey = LockerMainCategory.LockerMainCategory

type LockerNavItemDefinition = {
	key: string,
	title: string,
	thumbnail: string,
}

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

type StatsData = {
	Level: number,
	Cash: number,
}

type InventoryData = {
	[string]: { [string]: boolean },
	WeaponWrapsByWeapon: {
		Main: { [string]: { [string]: number | boolean } },
		Special: { [string]: { [string]: number | boolean } },
	}?,
}

type LoadoutData = {
	[string]: string?,
}

type WeaponCategory = WeaponCategoryMod.WeaponCategory

type LockerPreviewSpawnTarget = Folder | Model | BasePart

local LOCKER_NAV_ITEMS = LockerConfig.NavItems :: { [LockerCategoryKey]: { LockerNavItemDefinition } }
local ITEMS_CONFIG_BY_NAV = LockerConfig.ItemsConfigByNav :: { [LockerCategoryKey]: { [string]: string } }
local CATEGORY_TO_LOADOUT_SLOT = LockerConfig.CategoryToLoadoutSlot :: { [string]: string }
local RARITY_RANK = LockerConfig.RarityRank :: { [string]: number }

local CAMERA_TARGET_BY_MAIN_CATEGORY = {
	Style = "clothing",
	Arsenal = "weapons",
	Effects = "weapons",
} :: { [LockerCategoryKey]: string }
local KILL_EFFECTS_CAMERA_TARGET = "killEffects"
local KILL_EFFECTS_DUMMY_NAME = "LockerKillEffectsDummy"
local KILL_EFFECTS_DUMMY_RESTORE_DELAY = 1.25
local KILL_EFFECTS_PREVIEW_COOLDOWN = 1
local MAIN_CATEGORY_SWITCH_COOLDOWN = 0.2

function LockerFeature.start(menuController: any, options: { autoOpen: boolean? }?): any
	local janitor = Janitor.new()
	local fusionScope = Fusion.scoped(Fusion)
	local navItemsJanitor = Janitor.new()
	local autoOpenOnStart = options and options.autoOpen == true
	janitor:Add(function()
		Fusion.doCleanup(fusionScope)
	end, true)
	janitor:Add(navItemsJanitor, "Destroy")
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = menuController:getGui()
	local lockerBodiesFolder = Shared:WaitForChild("LockerBodies") :: Folder
	local defaultLockerBodyTemplate = lockerBodiesFolder:WaitForChild("Default") :: Instance

	local function resolveLockerBodyTemplate(outfitId: string?): Model?
		local byId = if outfitId and outfitId ~= "" then lockerBodiesFolder:FindFirstChild(outfitId) else nil
		if byId and byId:IsA("Model") then
			return byId :: Model
		end
		return if defaultLockerBodyTemplate:IsA("Model") then defaultLockerBodyTemplate :: Model else nil
	end

	local lockerFolder = Workspace:WaitForChild("Locker")
	local lockerWeaponsFolder = lockerFolder:WaitForChild("weapons")
	local characterSpawn = lockerFolder:WaitForChild("CharacterSpawn")
	local mainWeaponSpawn = lockerFolder:WaitForChild("MainSpawn")
	local specialWeaponSpawn = lockerFolder:WaitForChild("SpecialSpawn")
	local dummySpawn = lockerFolder:WaitForChild("DummySpawn") :: LockerPreviewSpawnTarget
	local killEffectsDummyTemplate = ReplicatedStorage:WaitForChild("Dummy")
	local mainIndicator = lockerWeaponsFolder:FindFirstChild("MainIndicator")
	local specialIndicator = lockerWeaponsFolder:FindFirstChild("SpecialIndicator")

	local lockerBtn = menuGui.Bottom:WaitForChild("Locker") :: GuiButton
	local uiGui = playerGui:WaitForChild("UserInterface") :: ScreenGui
	local lockerFrame = uiGui:WaitForChild("Locker") :: Frame

	-- Registrar el Locker como panel del MenuController para que hasOpenPanel()
	-- lo cuente — afecta a MapVote (auto-hide cuando hay panel encima) y al
	-- estado MUFFLED de la música del lobby. El Locker oculta el menú via
	-- :hide()/:show() pero antes no se registraba: la música caía en STOP
	-- creyendo que estábamos en match.
	menuController:registerPanel(lockerFrame)
	janitor:Add(function()
		menuController:unregisterPanel(lockerFrame)
	end, true)
	local nav = lockerFrame:WaitForChild("Nav2")
	local navTemplate = nav:WaitForChild("Template") :: GuiButton
	local defaultNavItemSize = navTemplate.Size
	local nav1 = lockerFrame:WaitForChild("Nav1")
	local closeBtn = nav1:WaitForChild("CloseBtn") :: GuiButton
	local styleBtn = nav1:WaitForChild("Style") :: GuiButton
	local arsenalBtn = nav1:WaitForChild("Arsenal") :: GuiButton
	local effectsBtn = nav1:WaitForChild("Effects") :: GuiButton
	local mainFrame = lockerFrame:WaitForChild("MainFrame")
	local wrapsTitle = lockerFrame:WaitForChild("WrapsTitle") :: TextLabel
	local itemGrid = mainFrame:WaitForChild("ItemGrid")
	local itemGridTemplate = itemGrid:WaitForChild("Template") :: GuiObject
	-- ⚠️ Requiere que el Frame en Studio se llame "WeaponWraps" (renombrado manual).
	local itemGridWrapsTemplate = itemGrid:WaitForChild("WeaponWraps") :: GuiObject
	local actionFrame = lockerFrame:WaitForChild("ActionFrame") :: GuiObject
	local purchaseButtonContainer = actionFrame:WaitForChild("PurchaseButton") :: GuiButton
	-- ⚠️ Requiere que el GuiButton en Studio se llame "WeaponWraps" (renombrado manual).
	local wrapsButtonContainer = actionFrame:WaitForChild("WeaponWraps") :: GuiButton
	local wrapsButton = wrapsButtonContainer
	local purchaseButton = purchaseButtonContainer
	local purchasePriceLabel = purchaseButtonContainer:WaitForChild("Price") :: TextLabel
	local purchaseIconLocked = purchaseButtonContainer:WaitForChild("IconLocked") :: GuiObject
	local purchaseLockedGradient = purchaseButtonContainer:WaitForChild("Locked") :: UIGradient
	local purchaseUnlockedGradient = purchaseButtonContainer:WaitForChild("Unlocked") :: UIGradient
	local cashFrame = lockerFrame:WaitForChild("CashFrame")
	local cashValueNode = cashFrame:WaitForChild("Value")
	local cashValueLabel = if cashValueNode:IsA("TextLabel") then cashValueNode else nil
	local levelContainer = lockerFrame:WaitForChild("LevelContainer")
	local levelValueNode = levelContainer:WaitForChild("Value")
	local levelValueLabel = if levelValueNode:IsA("TextLabel") then levelValueNode else nil
	local cameraController = LockerCameraController.new("weapons")
	janitor:Add(cameraController, "Destroy")
	lockerFrame.Visible = false

	MenuHover.bindButton(closeBtn, janitor)

	local mainCategoryButtons = {
		Style = styleBtn,
		Arsenal = arsenalBtn,
		Effects = effectsBtn,
	} :: { [LockerCategoryKey]: GuiButton }
	local navButtons = {} :: { GuiButton }
	local activeNavSizeTweens = {} :: { [GuiButton]: Tween }
	local selectedNavButton: GuiButton? = nil
	local selectedMainCategory: LockerCategoryKey? = nil
	local selectedCatalogItem: LockerCatalogItem? = nil
	local wrapsTargetWeaponCategory: WeaponCategory = WeaponCategoryMod.MAIN
	local wrapsTargetWeaponIdByCategory = {
		Main = "",
		Special = "",
	} :: { [WeaponCategory]: string }
	local pendingShopAction: PendingShopAction? = nil
	local activeActionFrameTween: Tween? = nil
	local activePurchaseButtonScaleTween: Tween? = nil
	local activePurchaseButtonStrokeTween: Tween? = nil
	local purchaseButtonIsHovered = false
	local canUseHoverAnimations = UserInputService.MouseEnabled and not UserInputService.TouchEnabled
	local ownedLookup = {} :: { [string]: { [string]: boolean } }
	local ownedWrapsByWeaponLookup = {
		Main = {},
		Special = {},
	} :: { [WeaponCategory]: { [string]: { [string]: number } } }
	local equippedLookup = {} :: { [string]: string }
	local selectedNavKey: string? = nil
	-- Forward decl: el controlador del stagger de Nav2 se construye más abajo
	-- (cuando `navTemplate`/janitor están listos) pero `populateNavButtons` lo
	-- llama para re-tweenear los items al cambiar de categoría.
	local nav2Stagger: NavStaggerController.NavStaggerController? = nil
	local isOpen = false
	local dirtyWhileClosed = false
	local activeKillEffectsDummy: Model? = nil
	local killEffectsRestoreToken = 0
	local nextAllowedKillEffectPreviewAt = 0
	local skipNextKillEffectSelectionPreview = false
	local nextAllowedMainCategorySwitchAt = 0
	local sharedLockerAssets = Shared:WaitForChild("Locker")
	local sharedWeaponAssets = sharedLockerAssets:WaitForChild("weapons")
	local actionFrameVisiblePosition = actionFrame.Position
	local actionFrameHiddenPosition = UDim2.new(actionFrameVisiblePosition.X.Scale, actionFrameVisiblePosition.X.Offset, 1.15, actionFrameVisiblePosition.Y.Offset)
	local catalog: any = nil
	local grid: any = nil

	local isWrapsMode = false

	local function setWrapsMode(enabled: boolean)
		isWrapsMode = enabled
		if levelContainer then levelContainer.Visible = not enabled end
		if cashFrame then cashFrame.Visible = not enabled end
		if nav then nav.Visible = not enabled end
		if wrapsTitle then wrapsTitle.Visible = enabled end

		for _, child in nav1:GetChildren() do
			if child.Name ~= "CloseBtn" and child:IsA("GuiObject") then
				child.Visible = not enabled
			end
		end
	end

	actionFrame.Visible = false
	if wrapsTitle then wrapsTitle.Visible = false end
	actionFrame.Position = actionFrameHiddenPosition

	local function getOptionalString(value: any): string?
		if type(value) == "string" and value ~= "" then
			return value
		end

		return nil
	end

	local function getCurrentLoadout(): LoadoutData
		return Fusion.peek(DataController.Loadout) :: LoadoutData
	end

	local function getCurrentStats(): StatsData
		return Fusion.peek(DataController.Stats) :: StatsData
	end

	local function getCurrentLevel(): number
		return math.max(0, math.floor(tonumber(getCurrentStats().Level) or 0))
	end

	local function setOptionalVisible(guiObject: GuiObject?, visible: boolean)
		if guiObject then
			guiObject.Visible = visible
		end
	end

	local function cancelTween(tween: Tween?): Tween?
		if tween then
			tween:Cancel()
		end

		return nil
	end

	local function cancelTweenMap(tweenMap: { [any]: Tween })
		for _, tween in tweenMap do
			tween:Cancel()
		end

		table.clear(tweenMap)
	end

	local function disconnectFromMap(map: { [any]: RBXScriptConnection }, key: any)
		local conn = map[key]
		if conn then
			conn:Disconnect()
			map[key] = nil
		end
	end

	local function cancelTweenFromMap(map: { [any]: Tween }, key: any)
		local tw = map[key]
		if tw then
			tw:Cancel()
			map[key] = nil
		end
	end

	local function getSpawnPivot(spawnTarget: LockerPreviewSpawnTarget): CFrame
		if spawnTarget:IsA("BasePart") then
			return spawnTarget.CFrame
		end

		return spawnTarget:GetPivot()
	end

	local function placePreviewCharacter(previewModel: Model, spawnTarget: LockerPreviewSpawnTarget)
		if not spawnTarget:IsA("BasePart") then
			previewModel:PivotTo(spawnTarget:GetPivot())
			return
		end

		local rootPart = previewModel:FindFirstChild("HumanoidRootPart", true)
		if rootPart and rootPart:IsA("BasePart") then
			local rootOffset = previewModel:GetPivot():ToObjectSpace(rootPart.CFrame)
			local targetPivot = spawnTarget.CFrame * rootOffset:Inverse()
			previewModel:PivotTo(targetPivot)
			return
		end

		previewModel:MoveTo(spawnTarget.Position)
	end

	local function playPreviewIdleAnimation(previewModel: Model)
		local animator = previewModel:FindFirstChildWhichIsA("Animator", true)
		if not animator then
			local humanoid = previewModel:FindFirstChildWhichIsA("Humanoid", true)
			if humanoid then
				animator = humanoid:FindFirstChildOfClass("Animator")
				if not animator then
					animator = Instance.new("Animator")
					animator.Parent = humanoid
				end
			else
				local animationController = previewModel:FindFirstChildWhichIsA("AnimationController", true)
				if not animationController then
					animationController = Instance.new("AnimationController")
					animationController.Name = "LockerPreviewAnimationController"
					animationController.Parent = previewModel
				end

				animator = animationController:FindFirstChildOfClass("Animator")
				if not animator then
					animator = Instance.new("Animator")
					animator.Parent = animationController
				end
			end
		end

		if not animator then
			return
		end

		local animation = Instance.new("Animation")
		animation.Name = "LockerPreviewIdle"
		animation.AnimationId = LOCKER_PREVIEW_IDLE_ANIMATION_ID

		local animationTrack = animator:LoadAnimation(animation)
		animationTrack.Name = "LockerPreviewIdle"
		animationTrack.Looped = true
		animationTrack.Priority = Enum.AnimationPriority.Idle
		animationTrack:Play(0.1)

		janitor:Add(function()
			animationTrack:Stop(0.1)
			animationTrack:Destroy()
			animation:Destroy()
		end, true)
	end

	local previewCharacter: Model? = nil
	local faceApplier: any = nil
	local hatApplier: any = nil
	local lastPreviewOutfitId: string? = nil

	local function rebuildPreviewCharacter(outfitId: string?)
		local spawnTarget = characterSpawn :: LockerPreviewSpawnTarget
		local targetParent = spawnTarget :: Instance

		-- Limpieza defensiva: cualquier preview previo (incluido el de un build
		-- anterior con nombre "CharacterTemplate") cae aquí.
		if previewCharacter and previewCharacter.Parent then
			previewCharacter:Destroy()
		end
		local stale = targetParent:FindFirstChild("PreviewCharacter")
		if stale then stale:Destroy() end
		local staleLegacy = targetParent:FindFirstChild("CharacterTemplate")
		if staleLegacy then staleLegacy:Destroy() end

		previewCharacter = nil
		faceApplier = nil
		hatApplier = nil

		local template = resolveLockerBodyTemplate(outfitId)
		if not template then
			return
		end

		local clone = template:Clone()
		clone.Name = "PreviewCharacter"
		clone.Parent = targetParent
		placePreviewCharacter(clone, spawnTarget)
		playPreviewIdleAnimation(clone)

		previewCharacter = clone
		faceApplier = FaceApplier.new(clone, ItemsConfig)
		hatApplier = HatApplier.new(clone, ItemsConfig)
		lastPreviewOutfitId = outfitId
	end

	local applyEquippedFacePreview: () -> ()
	local applyEquippedHatPreview: () -> ()

	local function applySelectedFacePreview(item: LockerCatalogItem?)
		if not faceApplier then
			return
		end

		if item and item.Category == LockerCategory.FACES then
			faceApplier:ApplyImage(item.Image)
			return
		end

		applyEquippedFacePreview()
	end

	local function applySelectedHatPreview(item: LockerCatalogItem?)
		if not hatApplier then
			return
		end

		if item and item.Category == LockerCategory.HATS then
			hatApplier:Apply(item)
			return
		end

		applyEquippedHatPreview()
	end

	applyEquippedFacePreview = function()
		if not faceApplier then
			return
		end

		faceApplier:ApplyItemId(getOptionalString(equippedLookup.Faces) or getCurrentLoadout().Face)
	end

	applyEquippedHatPreview = function()
		if not hatApplier then
			return
		end

		hatApplier:ApplyItemId(getOptionalString(equippedLookup.Hats) or getCurrentLoadout().Hat)
	end

	-- Body preview: a diferencia de face/hat, reconstruir el modelo entero. Por eso
	-- comparamos contra `lastPreviewOutfitId` para evitar clonar si el item
	-- seleccionado ya coincide con lo que está parenteado. Tras la reconstrucción,
	-- los appliers se reasignan dentro de rebuildPreviewCharacter — los siguientes
	-- applySelectedFace/HatPreview del onSelectionChanged ven los nuevos.
	local function applyEquippedBodyPreview()
		local outfitId = getOptionalString(equippedLookup.Outfits) or getCurrentLoadout().Outfit
		if outfitId ~= lastPreviewOutfitId then
			rebuildPreviewCharacter(outfitId)
		end
	end

	local function applySelectedBodyPreview(item: LockerCatalogItem?)
		local targetOutfitId: string?
		if item and item.Category == LockerCategory.OUTFITS then
			targetOutfitId = item.id
		else
			targetOutfitId = getOptionalString(equippedLookup.Outfits) or getCurrentLoadout().Outfit
		end
		if targetOutfitId ~= lastPreviewOutfitId then
			rebuildPreviewCharacter(targetOutfitId)
		end
	end

	janitor:Add(function()
		if previewCharacter and previewCharacter.Parent then
			previewCharacter:Destroy()
		end
	end, true)

	local function resolveKillEffectId(): string
		return getOptionalString(equippedLookup.KillEffects) or getOptionalString(getCurrentLoadout().KillEffect) or ItemDefaults.ITEM_ID
	end

	local killEffectsDummyTemplateModel = if killEffectsDummyTemplate:IsA("Model")
			and killEffectsDummyTemplate:FindFirstChildWhichIsA("Humanoid", true)
		then killEffectsDummyTemplate
		else if defaultLockerBodyTemplate:IsA("Model") and defaultLockerBodyTemplate:FindFirstChildWhichIsA("Humanoid", true)
			then defaultLockerBodyTemplate
			else nil

	local function replaceKillEffectsDummy(): Model?
		if activeKillEffectsDummy and activeKillEffectsDummy.Parent then
			activeKillEffectsDummy:Destroy()
		end

		activeKillEffectsDummy = nil

		if not killEffectsDummyTemplateModel then
			return nil
		end

		local clonedDummy = killEffectsDummyTemplateModel:Clone()
		clonedDummy.Name = KILL_EFFECTS_DUMMY_NAME
		clonedDummy.Parent = dummySpawn :: Instance
		placePreviewCharacter(clonedDummy, dummySpawn)
		playPreviewIdleAnimation(clonedDummy)
		activeKillEffectsDummy = clonedDummy
		return clonedDummy
	end

	local function destroyKillEffectsDummy()
		killEffectsRestoreToken += 1
		nextAllowedKillEffectPreviewAt = 0

		if activeKillEffectsDummy and activeKillEffectsDummy.Parent then
			activeKillEffectsDummy:Destroy()
		end

		activeKillEffectsDummy = nil
	end

	local function previewKillEffect(effectId: string?)
		if not isOpen or selectedMainCategory ~= LockerMainCategory.EFFECTS or selectedNavKey ~= LockerCategory.KILL_EFFECTS then
			return
		end

		local now = os.clock()
		if now < nextAllowedKillEffectPreviewAt then
			return
		end
		nextAllowedKillEffectPreviewAt = now + KILL_EFFECTS_PREVIEW_COOLDOWN

		local dummy = replaceKillEffectsDummy()
		if not dummy then
			return
		end

		local resolvedEffectId = if type(effectId) == "string" and effectId ~= "" then effectId else resolveKillEffectId()
		if not KillEffectsRegistry.apply(resolvedEffectId, dummy) then
			return
		end

		killEffectsRestoreToken += 1
		local restoreToken = killEffectsRestoreToken
		task.delay(KILL_EFFECTS_DUMMY_RESTORE_DELAY, function()
			if restoreToken ~= killEffectsRestoreToken then
				return
			end

			if not isOpen or selectedMainCategory ~= LockerMainCategory.EFFECTS or selectedNavKey ~= LockerCategory.KILL_EFFECTS then
				return
			end

			replaceKillEffectsDummy()
		end)
	end

	local function updateKillEffectsPreviewState(categoryKey: LockerCategoryKey, navKey: string)
		if categoryKey == LockerMainCategory.EFFECTS and navKey == LockerCategory.KILL_EFFECTS then
			cameraController:setTargetPartName(KILL_EFFECTS_CAMERA_TARGET)
			if isOpen then
				if selectedCatalogItem and selectedCatalogItem.Category == LockerCategory.KILL_EFFECTS then
					previewKillEffect(selectedCatalogItem.id)
				else
					replaceKillEffectsDummy()
				end
			else
				destroyKillEffectsDummy()
			end
			return
		end

		destroyKillEffectsDummy()
		cameraController:setTargetPartName(CAMERA_TARGET_BY_MAIN_CATEGORY[categoryKey])
	end

	janitor:Add(destroyKillEffectsDummy, true)

	-- WeaponPreviewController se inicializa después de las funciones que necesita como dependencia.
	local weaponPreviewController: any = nil

	janitor:Add(function()
		activeActionFrameTween = cancelTween(activeActionFrameTween)
		activePurchaseButtonScaleTween = cancelTween(activePurchaseButtonScaleTween)
		activePurchaseButtonStrokeTween = cancelTween(activePurchaseButtonStrokeTween)
		cancelTweenMap(activeNavSizeTweens)
	end, true)

	local function rebuildOwnedLookup()
		local inventory = Fusion.peek(DataController.Inventory) :: InventoryData
		local nextLookup = {} :: { [string]: { [string]: boolean } }
		local nextWrapsByWeapon = {
			Main = {},
			Special = {},
		} :: { [WeaponCategory]: { [string]: { [string]: number } } }

		for category, items in inventory do
			if category == "WeaponWrapsByWeapon" then
				local wrapsByWeapon = items :: any
				for weaponCategory, weaponEntriesAny in wrapsByWeapon do
					if WeaponCategoryMod.isValid(weaponCategory) then
						local weaponEntries = weaponEntriesAny :: { [string]: { [string]: number | boolean } }
						local categoryWrapLookup = nextWrapsByWeapon[weaponCategory :: WeaponCategory]
						for weaponId, ownedWrapsAny in weaponEntries do
							if type(ownedWrapsAny) == "table" then
								local wrapLookup = {} :: { [string]: number }
								for wrapId, wrapOwned in ownedWrapsAny do
									if wrapOwned == true then
										wrapLookup[wrapId] = 1
									elseif type(wrapOwned) == "number" and wrapOwned > 0 then
										wrapLookup[wrapId] = math.max(1, math.floor(wrapOwned))
									end
								end
								categoryWrapLookup[weaponId] = wrapLookup
							end
						end
					end
				end
			elseif category ~= LockerCategory.WEAPON_WRAPS then
				local categoryLookup = {} :: { [string]: boolean }
				for itemId, owned in items do
					if owned == true then
						categoryLookup[itemId] = true
					end
				end
				nextLookup[category] = categoryLookup
			end
		end

		ownedLookup = nextLookup
		ownedWrapsByWeaponLookup = nextWrapsByWeapon
		if catalog then
			catalog:InvalidateSorted()
		end
	end

	local function getStoredWrapsTargetWeaponId(weaponCategory: WeaponCategory): string?
		return getOptionalString(wrapsTargetWeaponIdByCategory[weaponCategory])
	end

	local function setStoredWrapsTargetWeaponId(weaponCategory: WeaponCategory, weaponId: string?)
		wrapsTargetWeaponIdByCategory[weaponCategory] = getOptionalString(weaponId) or ""
	end

	local function resolveWeaponIdForCategory(weaponCategory: WeaponCategory, loadout: LoadoutData?): string
		local storedWeaponId = getStoredWrapsTargetWeaponId(weaponCategory)
		if storedWeaponId then
			return storedWeaponId
		end

		if loadout then
			local weaponSlot = CATEGORY_TO_LOADOUT_SLOT[weaponCategory]
			local weaponId = if weaponSlot then getOptionalString(loadout[weaponSlot]) else nil
			if weaponId then
				return weaponId
			end
		end

		return ItemDefaults.ITEM_ID
	end

	local function resolveWrapsTargetWeaponId(loadout: LoadoutData?): string
		return resolveWeaponIdForCategory(wrapsTargetWeaponCategory, loadout)
	end

	local function getWeaponWrapRequestContext(category: string): (string, string)
		if category ~= LockerCategory.WEAPON_WRAPS then
			return "", ""
		end

		return wrapsTargetWeaponCategory, resolveWrapsTargetWeaponId(getCurrentLoadout())
	end

	local getWrapAmountForWeapon: (weaponCategory: WeaponCategory, weaponId: string, wrapId: string) -> number

	local function isWrapOwnedForWeapon(weaponCategory: WeaponCategory, weaponId: string, wrapId: string): boolean
		return getWrapAmountForWeapon(weaponCategory, weaponId, wrapId) > 0
	end

	function getWrapAmountForWeapon(weaponCategory: WeaponCategory, weaponId: string, wrapId: string): number
		local categoryLookup = ownedWrapsByWeaponLookup[weaponCategory]
		if not categoryLookup then
			return 0
		end

		local weaponLookup = categoryLookup[weaponId]
		if not weaponLookup then
			return 0
		end

		return weaponLookup[wrapId] or 0
	end

	local function rebuildEquippedLookup()
		local loadout = getCurrentLoadout()
		local nextLookup = {} :: { [string]: string }

		for category, slot in CATEGORY_TO_LOADOUT_SLOT do
			local equippedItem = getOptionalString(loadout[slot])
			if equippedItem then
				nextLookup[category] = equippedItem
			end
		end

		equippedLookup = nextLookup
	end

	local function getEquippedItemByCategory(category: string): string?
		local equippedItem = getOptionalString(equippedLookup[category])
		if equippedItem then
			return equippedItem
		end

		local slot = CATEGORY_TO_LOADOUT_SLOT[category]
		if not slot then
			return nil
		end

		return getOptionalString(getCurrentLoadout()[slot])
	end

	local function getEquippedWeaponByCategory(category: WeaponCategory): string
		return getEquippedItemByCategory(category) or ItemDefaults.ITEM_ID
	end

	-- Mirror del server (LoadoutService._resolveWeaponWrapForLoadout) y del
	-- preview controller. Equip es per-weapon: la slot `wrapsTable.Default`
	-- es la del arma con id "Default", no un fallback que se propaga al resto.
	-- Un wrap global del BP otorga ownership a todas las armas, pero equiparlo
	-- sigue siendo manual per-arma desde el locker.
	local function resolveWeaponWrap(loadout: LoadoutData, weaponCategory: WeaponCategory, weaponId: string?): string
		local normalizedWeaponId = getOptionalString(weaponId) or ItemDefaults.ITEM_ID
		local wrapsTableKey = if weaponCategory == WeaponCategoryMod.MAIN then "MainWeaponWraps" else "SpecialWeaponWraps"
		local wrapsTableAny = loadout[wrapsTableKey]
		if type(wrapsTableAny) == "table" then
			local wrapsTable = wrapsTableAny :: { [string]: string }
			local resolvedByWeapon = getOptionalString(wrapsTable[normalizedWeaponId])
			if resolvedByWeapon and isWrapOwnedForWeapon(weaponCategory, normalizedWeaponId, resolvedByWeapon) then
				return resolvedByWeapon
			end
		end

		return ItemDefaults.ITEM_ID
	end

	local function isWeaponCategory(category: string): boolean
		return WeaponCategoryMod.isValid(category)
	end

	weaponPreviewController = WeaponPreviewController.new({
		mainWeaponSpawn = mainWeaponSpawn,
		specialWeaponSpawn = specialWeaponSpawn,
		sharedWeaponAssets = sharedWeaponAssets,
		mainIndicator = mainIndicator,
		specialIndicator = specialIndicator,
		itemsConfig = ItemsConfig,
		getCurrentLevel = getCurrentLevel,
		getCurrentLoadout = getCurrentLoadout,
		getEquippedItemByCategory = getEquippedItemByCategory,
		isOwned = function(category: string, itemId: string): boolean
			local categoryLookup = ownedLookup[category]
			return categoryLookup ~= nil and categoryLookup[itemId] == true
		end,
		ownsWeaponWrap = isWrapOwnedForWeapon,
	})
	janitor:Add(weaponPreviewController, "Destroy")

	local function updateWeaponCategoryIndicators()
		weaponPreviewController:updateIndicators(selectedMainCategory, selectedNavKey, wrapsTargetWeaponCategory)
	end

	local function applySelectedWeaponPreview(item: any)
		weaponPreviewController:applySelected(item)
	end

	local function restoreEquippedWeaponPreviews()
		weaponPreviewController:restoreEquipped()
	end

	local function restoreEquippedWeaponPreviewForCategory(category: string)
		weaponPreviewController:restoreEquippedFor(category)
	end

	local mainCategoryNavController = NavTabController.new()
	local navItemController = NavTabController.new()
	janitor:Add(mainCategoryNavController, "Destroy")
	janitor:Add(navItemController, "Destroy")

	for key, button in mainCategoryButtons do
		mainCategoryNavController:register(key, button)
	end

	local function clearNavButtons()
		navItemsJanitor:Cleanup()
		table.clear(navButtons)
		selectedNavButton = nil
		navItemController:clear()

		for _, tween in activeNavSizeTweens do
			tween:Cancel()
		end
		table.clear(activeNavSizeTweens)

		for _, child in nav:GetChildren() do
			if child ~= navTemplate and child:IsA("GuiButton") then
				child:Destroy()
			end
		end
	end

	local function getButtonStroke(button: GuiButton): UIStroke?
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke and stroke:IsA("UIStroke") then
			return stroke
		end

		return nil
	end

	local function setSelectedNavButton(selectedButton: GuiButton)
		selectedNavButton = selectedButton
		navItemController:setActive(selectedButton.Name)
	end

	local function setSelectedMainCategory(categoryKey: LockerCategoryKey)
		selectedMainCategory = categoryKey
		updateWeaponCategoryIndicators()
		mainCategoryNavController:setActive(categoryKey)
	end

	local function bindStrokeHover(button: GuiButton, parentJanitor: any, isSelected: () -> boolean)
		if not canUseHoverAnimations then
			return
		end

		parentJanitor:Add(button.MouseEnter:Connect(function()
			local stroke = getButtonStroke(button)
			if stroke then
				stroke.Color = STROKE_WHITE
			end
		end), "Disconnect")

		parentJanitor:Add(button.MouseLeave:Connect(function()
			local stroke = getButtonStroke(button)
			if stroke then
				stroke.Color = STROKE_DEFAULT
			end
		end), "Disconnect")
	end

	local function setNavButtonContent(button: GuiButton, definition: LockerNavItemDefinition)
		local iconNode = button:FindFirstChild("Icon")
		if iconNode and (iconNode:IsA("ImageLabel") or iconNode:IsA("ImageButton")) then
			iconNode.Image = definition.thumbnail
		end

		local titleNode = button:FindFirstChild("Title") or button:FindFirstChild("Tiltle")
		if titleNode and titleNode:IsA("TextLabel") then
			titleNode.Text = definition.title
		end
	end

	local function tweenActionFrame(targetPosition: UDim2, visible: boolean)
		if activeActionFrameTween then
			activeActionFrameTween:Cancel()
			activeActionFrameTween = nil
		end

		if visible then
			actionFrame.Visible = true
		end

		local tween = TweenService:Create(actionFrame, ACTION_FRAME_TWEEN_INFO, {
			Position = targetPosition,
		})
		activeActionFrameTween = tween
		tween.Completed:Connect(function()
			if activeActionFrameTween == tween then
				activeActionFrameTween = nil
				if not visible then
					actionFrame.Visible = false
				end
			end
		end)
		tween:Play()
	end

	local function showActionFrameForItem(item: LockerCatalogItem)
		purchaseButtonContainer.Visible = true
		wrapsButtonContainer.Visible = false

		local isLevelLocked = getCurrentLevel() < item.LevelRequired

		purchasePriceLabel.Text = if isLevelLocked then "LOCKED" else UIUtils.formatCashAmount(item.Price)
		purchaseIconLocked.Visible = isLevelLocked
		purchaseLockedGradient.Enabled = isLevelLocked
		purchaseUnlockedGradient.Enabled = not isLevelLocked
		purchaseButton.Active = not isLevelLocked
		purchaseButton.Selectable = not isLevelLocked

		tweenActionFrame(actionFrameVisiblePosition, true)
	end

	local function showOwnedWeaponActionFrame()
		purchaseButtonContainer.Visible = false
		wrapsButtonContainer.Visible = true

		tweenActionFrame(actionFrameVisiblePosition, true)
	end

	local function hideActionFrame()
		tweenActionFrame(actionFrameHiddenPosition, false)
	end

	local function isItemOwned(item: LockerCatalogItem): boolean
		if item.Category == LockerCategory.WEAPON_WRAPS then
			local targetWeaponId = resolveWrapsTargetWeaponId(getCurrentLoadout())
			return isWrapOwnedForWeapon(wrapsTargetWeaponCategory, targetWeaponId, item.id)
		end

		local categoryLookup = ownedLookup[item.Category]
		return categoryLookup ~= nil and categoryLookup[item.id] == true
	end

	local function getRarityRank(rarity: string): number
		return RARITY_RANK[rarity] or 0
	end

	local function isItemEquipped(item: LockerCatalogItem): boolean
		if pendingShopAction and pendingShopAction.kind == "equip" then
			if pendingShopAction.item.Category == item.Category then
				return pendingShopAction.item.qualifiedId == item.qualifiedId
			end
		end

		if item.Category == LockerCategory.WEAPON_WRAPS then
			local loadout = getCurrentLoadout()
			local targetWeaponId = resolveWrapsTargetWeaponId(loadout)
			local equippedWrap = resolveWeaponWrap(loadout, wrapsTargetWeaponCategory, targetWeaponId)
			return equippedWrap == item.id
		end

		local slot = CATEGORY_TO_LOADOUT_SLOT[item.Category]
		if not slot then
			return false
		end

		local equippedItem = getEquippedItemByCategory(item.Category)
		return equippedItem == item.id
	end

	catalog = LockerCatalog.new(ItemsConfig, ITEMS_CONFIG_BY_NAV, DEFAULT_NAV_THUMBNAIL, getRarityRank, isItemOwned)
	local updateActionFrameForSelected: () -> ()
	local populateMainContentForNavItem: (LockerCategoryKey, string, string?, boolean?) -> ()
	local clearItemGrid: () -> ()
	local syncWeaponPreviewsFromLoadout: () -> ()

	grid = LockerGrid.new(itemGrid, { default = itemGridTemplate, wraps = itemGridWrapsTemplate }, canUseHoverAnimations, {
		canInteract = function(): boolean
			return pendingShopAction == nil
		end,
		isItemOwned = isItemOwned,
		getItemAmount = function(item: LockerCatalogItem): number
			if item.Category ~= LockerCategory.WEAPON_WRAPS then
				return if isItemOwned(item) then 1 else 0
			end

			local targetWeaponId = resolveWrapsTargetWeaponId(getCurrentLoadout())
			return getWrapAmountForWeapon(wrapsTargetWeaponCategory, targetWeaponId, item.id)
		end,
		isItemEquipped = isItemEquipped,
		getCurrentLevel = getCurrentLevel,
		onSelectionChanged = function(item: LockerCatalogItem?)
			selectedCatalogItem = item
			if item and isWeaponCategory(item.Category) then
				local selectedWeaponCategory = item.Category :: WeaponCategory
				wrapsTargetWeaponCategory = selectedWeaponCategory
				setStoredWrapsTargetWeaponId(selectedWeaponCategory, item.id)
				updateWeaponCategoryIndicators()
			end
			applySelectedBodyPreview(item)
			applySelectedFacePreview(item)
			applySelectedHatPreview(item)
			applySelectedWeaponPreview(item)
			if item and item.Category == LockerCategory.KILL_EFFECTS then
				if skipNextKillEffectSelectionPreview then
					skipNextKillEffectSelectionPreview = false
					replaceKillEffectsDummy()
				else
					previewKillEffect(item.id)
				end
			elseif selectedMainCategory == LockerMainCategory.EFFECTS and selectedNavKey == LockerCategory.KILL_EFFECTS then
					replaceKillEffectsDummy()
			end
			updateActionFrameForSelected()
		end,
		onOwnedItemActivated = function(item: LockerCatalogItem)
			local weaponCategoryForEquip, weaponIdForEquip = getWeaponWrapRequestContext(item.Category)

			local equipAction = {
				kind = "equip",
				item = item,
			}
			pendingShopAction = equipAction
			grid:RefreshVisibleState(false)
			task.delay(SHOP_REQUEST_TIMEOUT, function()
				if pendingShopAction == equipAction then
					pendingShopAction = nil
					grid:RefreshVisibleState(false)
				end
			end)
			Network.Shop.EquipItem.Send({
				category = item.Category,
				itemId = item.id,
				weaponCategory = weaponCategoryForEquip,
				weaponId = weaponIdForEquip,
			})
		end,
	})
	janitor:Add(grid, "Destroy")

	local function getPreferredSelectedQualifiedId(categoryKey: LockerCategoryKey, navKey: string, selectedQualifiedId: string?): string?
		if selectedQualifiedId ~= nil then
			return selectedQualifiedId
		end

		if categoryKey == LockerMainCategory.STYLE and navKey == LockerCategory.FACES then
			local equippedFace = getOptionalString(equippedLookup.Faces) or getOptionalString(getCurrentLoadout().Face)
			if equippedFace then
				return LockerConfig.makeQualifiedId(LockerCategory.FACES, equippedFace)
			end
		end

		if categoryKey == LockerMainCategory.ARSENAL and isWeaponCategory(navKey) then
			local weaponCategory = navKey :: WeaponCategory
			local equippedWeapon = getEquippedWeaponByCategory(weaponCategory)
			wrapsTargetWeaponCategory = weaponCategory
			setStoredWrapsTargetWeaponId(weaponCategory, equippedWeapon)
			updateWeaponCategoryIndicators()
			return LockerConfig.makeQualifiedId(weaponCategory, equippedWeapon)
		end

		if categoryKey == LockerMainCategory.ARSENAL and navKey == LockerCategory.WEAPON_WRAPS then
			local loadout = getCurrentLoadout()
			local weaponId = resolveWrapsTargetWeaponId(loadout)
			return LockerConfig.makeQualifiedId(LockerCategory.WEAPON_WRAPS, resolveWeaponWrap(loadout, wrapsTargetWeaponCategory, weaponId))
		end

		return nil
	end

	local function getKillProgressForWeaponWrap(weaponCategory: WeaponCategory, weaponId: string, _wrapKey: string): number
		local weaponKills = Fusion.peek(DataController.WeaponKills) :: any
		if type(weaponKills) ~= "table" then
			return 0
		end
		local categoryKills = weaponKills[weaponCategory]
		if type(categoryKills) ~= "table" then
			return 0
		end
		local value = tonumber(categoryKills[weaponId])
		return if value and value > 0 then math.floor(value) else 0
	end

	local function getWrapItemsForCurrentWeapon(items: { LockerCatalogItem }): { LockerCatalogItem }
		local loadout = getCurrentLoadout()
		local targetWeaponId = resolveWrapsTargetWeaponId(loadout)
		local targetWeaponCategory = wrapsTargetWeaponCategory
		local targetCategoryConfig = ItemsConfig[targetWeaponCategory]
		local targetWeaponDefinition = if type(targetCategoryConfig) == "table"
			then targetCategoryConfig[targetWeaponId]
			else nil
		local targetWeaponDisplayName = if type(targetWeaponDefinition) == "table"
			and type(targetWeaponDefinition.Name) == "string"
			and targetWeaponDefinition.Name ~= ""
			then targetWeaponDefinition.Name
			else targetWeaponId
		local wrapItems = {} :: { LockerCatalogItem }

		for _, item in items do
			local isOwned = isWrapOwnedForWeapon(targetWeaponCategory, targetWeaponId, item.id)
			local isChallenge = item.KillGoal ~= nil and item.KillGoal > 0
			if isOwned or isChallenge then
				local wrapItem = table.clone(item)
				wrapItem.PreviewWeaponCategory = targetWeaponCategory
				wrapItem.PreviewWeaponId = targetWeaponId
				wrapItem.PreviewWeaponDisplayName = targetWeaponDisplayName
				if isChallenge and not isOwned then
					wrapItem.KillProgress = getKillProgressForWeaponWrap(targetWeaponCategory, targetWeaponId, item.id)
				end
				table.insert(wrapItems, wrapItem)
			end
		end

		-- Orden dentro de la vista Wraps:
		--   1) Default (siempre primero)
		--   2) Challenges de kill no desbloqueados
		--   3) Resto (owned) por rareza descendente
		local function groupRank(it: LockerCatalogItem): number
			if it.id == ItemDefaults.ITEM_ID then
				return 1
			end
			local isOwned = isWrapOwnedForWeapon(targetWeaponCategory, targetWeaponId, it.id)
			local isChallenge = it.KillGoal ~= nil and it.KillGoal > 0
			if isChallenge and not isOwned then
				return 2
			end
			return 3
		end

		table.sort(wrapItems, function(a, b)
			local groupA = groupRank(a)
			local groupB = groupRank(b)
			if groupA ~= groupB then
				return groupA < groupB
			end

			if groupA == 3 then
				local rarityA = getRarityRank(a.Rarity)
				local rarityB = getRarityRank(b.Rarity)
				if rarityA ~= rarityB then
					return rarityA > rarityB
				end
			end

			if a.KillGoal ~= nil and b.KillGoal ~= nil and a.KillGoal ~= b.KillGoal then
				return a.KillGoal < b.KillGoal
			end

			return a.Name < b.Name
		end)

		return wrapItems
	end

	-- `stagger` indica que la repoblación viene de una interacción de usuario
	-- (cambio de categoría/nav, abrir locker) — los cards entran en orden con
	-- UIScale 0→1. Las llamadas pasivas (observers de inventario/loadout) no
	-- pasan stagger para evitar re-animar al comprar/equipar.
	populateMainContentForNavItem = function(categoryKey: LockerCategoryKey, navKey: string, selectedQualifiedId: string?, stagger: boolean?)
		local previousNavKey = selectedNavKey
		selectedNavKey = navKey
		updateWeaponCategoryIndicators()
		skipNextKillEffectSelectionPreview = categoryKey == LockerMainCategory.EFFECTS
			and navKey == LockerCategory.KILL_EFFECTS
			and previousNavKey ~= navKey
		updateKillEffectsPreviewState(categoryKey, navKey)
		if categoryKey ~= LockerMainCategory.ARSENAL or previousNavKey ~= navKey then
			restoreEquippedWeaponPreviews()
		end
		local preferredSelectedQualifiedId = getPreferredSelectedQualifiedId(categoryKey, navKey, selectedQualifiedId)

		local items = catalog:GetItems(categoryKey, navKey)
		local isWrapsView = categoryKey == LockerMainCategory.ARSENAL and navKey == LockerCategory.WEAPON_WRAPS
		if isWrapsView then
			items = getWrapItemsForCurrentWeapon(items)
		end

		grid:Populate(items, preferredSelectedQualifiedId, if isWrapsView then "wraps" else "default")
		if stagger then
			grid:PlayStagger()
		end
	end

	updateActionFrameForSelected = function()
		local selectedItem = selectedCatalogItem
		if not selectedItem then
			hideActionFrame()
			return
		end

		if isItemOwned(selectedItem) then
			if isWeaponCategory(selectedItem.Category) then
				showOwnedWeaponActionFrame()
			else
				hideActionFrame()
			end
		elseif selectedItem.KillGoal ~= nil and selectedItem.KillGoal > 0 then
			-- Wraps de desafío de kills: no se compran, solo se desbloquean por progreso.
			hideActionFrame()
		else
			showActionFrameForItem(selectedItem)
		end
	end

	local function refreshGridSelectionState()
		grid:RefreshVisibleState()
	end

	syncWeaponPreviewsFromLoadout = function()
		local selectedItem = selectedCatalogItem
		if not selectedItem or not isWeaponCategory(selectedItem.Category) then
			restoreEquippedWeaponPreviews()
			return
		end

		local selectedCategory = selectedItem.Category :: WeaponCategory
		local otherCategory = if selectedCategory == WeaponCategoryMod.MAIN then WeaponCategoryMod.SPECIAL else WeaponCategoryMod.MAIN
		restoreEquippedWeaponPreviewForCategory(otherCategory)

		if weaponPreviewController:isMotionActive(selectedCategory) then
			return
		end

		applySelectedWeaponPreview(selectedItem)
	end

	local function populateNavButtons(categoryKey: LockerCategoryKey)
		clearNavButtons()
		clearItemGrid()
		hideActionFrame()

		local itemDefinitions = LOCKER_NAV_ITEMS[categoryKey]
		for layoutOrder, definition in ipairs(itemDefinitions) do
			local navButton = navTemplate:Clone()
			navButton.Name = definition.key
			navButton.Visible = true
			navButton.LayoutOrder = layoutOrder
			navButton.Size = defaultNavItemSize
			setNavButtonContent(navButton, definition)
			navButton.Parent = nav
			table.insert(navButtons, navButton)
			navItemController:register(definition.key, navButton)

			local stroke = getButtonStroke(navButton)
			if stroke then
				stroke.Color = STROKE_DEFAULT
			end

			bindStrokeHover(navButton, navItemsJanitor, function()
				return navButton == selectedNavButton
			end)

			navItemsJanitor:Add(navButton.Activated:Connect(function()
				setSelectedNavButton(navButton)
				populateMainContentForNavItem(categoryKey, definition.key, nil, true)
			end), "Disconnect")
		end

		if #navButtons > 0 then
			setSelectedNavButton(navButtons[1])
			populateMainContentForNavItem(categoryKey, itemDefinitions[1].key, nil, true)
		end

		if nav2Stagger then
			nav2Stagger:play()
		end
	end

	clearItemGrid = function()
		grid:Clear()
		restoreEquippedWeaponPreviews()
	end

	local function selectItem(selectedKey: LockerCategoryKey)
		if selectedMainCategory == selectedKey and selectedNavKey ~= nil then
			return
		end

		setSelectedMainCategory(selectedKey)
		cameraController:setTargetPartName(CAMERA_TARGET_BY_MAIN_CATEGORY[selectedKey])
		if selectedKey ~= LockerMainCategory.ARSENAL then
			restoreEquippedWeaponPreviews()
		end
		populateNavButtons(selectedKey)
	end

	local function handleMainCategoryButtonClick(selectedKey: LockerCategoryKey)
		if selectedMainCategory == selectedKey and selectedNavKey ~= nil then
			return
		end

		local now = os.clock()
		if now < nextAllowedMainCategorySwitchAt then
			return
		end

		nextAllowedMainCategorySwitchAt = now + MAIN_CATEGORY_SWITCH_COOLDOWN
		clearItemGrid()
		hideActionFrame()
		selectItem(selectedKey)
	end

	local function updateStatsUiFromData()
		local stats = getCurrentStats()
		if cashValueLabel then
			cashValueLabel.Text = UIUtils.formatCashAmount(stats.Cash)
		end

		if levelValueLabel then
			levelValueLabel.Text = tostring(stats.Level)
		end

		updateActionFrameForSelected()
	end

	for categoryKey, button in mainCategoryButtons do
		bindStrokeHover(button, janitor, function()
			return selectedMainCategory == categoryKey
		end)
	end

	navTemplate.Visible = false
	itemGridTemplate.Visible = false
	itemGridWrapsTemplate.Visible = false
	do
		purchaseButton.Active = true
		purchaseButton.Selectable = true
		purchaseButton.AutoButtonColor = false

		local purchaseButtonScaleNode = purchaseButton:FindFirstChild("ButtonScale")
		if not (purchaseButtonScaleNode and purchaseButtonScaleNode:IsA("UIScale")) then
			purchaseButtonScaleNode = Instance.new("UIScale")
			purchaseButtonScaleNode.Name = "ButtonScale"
			purchaseButtonScaleNode.Parent = purchaseButton
		end
		purchaseButtonScaleNode.Scale = PURCHASE_BUTTON_DEFAULT_SCALE

		local purchaseButtonStroke = getButtonStroke(purchaseButton)
		if purchaseButtonStroke then
			purchaseButtonStroke.Color = STROKE_DEFAULT
		end

		local function tweenPurchaseButtonScale(targetScale: number, tweenInfo: TweenInfo)
			local scaleNode = purchaseButtonScaleNode :: UIScale
			if activePurchaseButtonScaleTween then
				activePurchaseButtonScaleTween:Cancel()
				activePurchaseButtonScaleTween = nil
			end

			activePurchaseButtonScaleTween = TweenService:Create(scaleNode, tweenInfo, { Scale = targetScale })
			activePurchaseButtonScaleTween:Play()
		end

		local function tweenPurchaseButtonStroke(targetColor: Color3, tweenInfo: TweenInfo)
			if not purchaseButtonStroke then
				return
			end

			if activePurchaseButtonStrokeTween then
				activePurchaseButtonStrokeTween:Cancel()
				activePurchaseButtonStrokeTween = nil
			end

			activePurchaseButtonStrokeTween = TweenService:Create(purchaseButtonStroke, tweenInfo, { Color = targetColor })
			activePurchaseButtonStrokeTween:Play()
		end

		if canUseHoverAnimations then
			janitor:Add(purchaseButton.MouseEnter:Connect(function()
				purchaseButtonIsHovered = true
				tweenPurchaseButtonScale(PURCHASE_BUTTON_HOVER_SCALE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
				tweenPurchaseButtonStroke(STROKE_WHITE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
			end), "Disconnect")

			janitor:Add(purchaseButton.MouseLeave:Connect(function()
				purchaseButtonIsHovered = false
				tweenPurchaseButtonScale(PURCHASE_BUTTON_DEFAULT_SCALE, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
				tweenPurchaseButtonStroke(STROKE_DEFAULT, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
			end), "Disconnect")
		end

		janitor:Add(purchaseButton.MouseButton1Down:Connect(function()
			tweenPurchaseButtonScale(PURCHASE_BUTTON_CLICK_SCALE, PURCHASE_BUTTON_CLICK_TWEEN_INFO)
			tweenPurchaseButtonStroke(STROKE_WHITE, PURCHASE_BUTTON_CLICK_TWEEN_INFO)
		end), "Disconnect")

		janitor:Add(purchaseButton.MouseButton1Up:Connect(function()
			local targetScale = if purchaseButtonIsHovered and canUseHoverAnimations
				then PURCHASE_BUTTON_HOVER_SCALE
				else PURCHASE_BUTTON_DEFAULT_SCALE
			tweenPurchaseButtonScale(targetScale, PURCHASE_BUTTON_HOVER_TWEEN_INFO)

			local targetStrokeColor = if purchaseButtonIsHovered and canUseHoverAnimations then STROKE_WHITE else STROKE_DEFAULT
			tweenPurchaseButtonStroke(targetStrokeColor, PURCHASE_BUTTON_HOVER_TWEEN_INFO)
		end), "Disconnect")

		local function promptBestFitPack(item: LockerCatalogItem)
			local cash = getCurrentStats().Cash
			local deficit = item.Price - cash
			local bestPack: StoreProducts.StoreProductDefinition? = nil

			for _, pack in StoreProducts.ProductsInOrder do
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
				MarketplaceService:PromptProductPurchase(player, bestPack.ProductId)
			end
		end

		janitor:Add(purchaseButton.Activated:Connect(function()
			local item = selectedCatalogItem
			if not item or pendingShopAction then
				return
			end

			if getCurrentLevel() < item.LevelRequired then
				return
			end

			if isItemOwned(item) then
				return
			end

			if item.KillGoal ~= nil and item.KillGoal > 0 then
				-- Los wraps de desafío de kills no se compran.
				return
			end

			if getCurrentStats().Cash < item.Price then
				promptBestFitPack(item)
				return
			end

			local buyAction = {
				kind = "buy",
				item = item,
			}
			pendingShopAction = buyAction
			task.delay(SHOP_REQUEST_TIMEOUT, function()
				if pendingShopAction == buyAction then
					pendingShopAction = nil
					if selectedMainCategory and selectedNavKey then
						populateMainContentForNavItem(selectedMainCategory, selectedNavKey, buyAction.item.qualifiedId)
					end
				end
			end)

			local weaponCategory, weaponId = getWeaponWrapRequestContext(item.Category)

			Network.Shop.BuyItem.Send({
				itemId = item.id,
				category = item.Category,
				weaponCategory = weaponCategory,
				weaponId = weaponId,
			})
		end), "Disconnect")
	end

	do
		janitor:Add(wrapsButton.Activated:Connect(function()
			local item = selectedCatalogItem
			if not item or pendingShopAction then
				return
			end

			if not isItemOwned(item) or not isWeaponCategory(item.Category) then
				return
			end

			local selectedWeaponCategory = item.Category :: WeaponCategory
			wrapsTargetWeaponCategory = selectedWeaponCategory
			setStoredWrapsTargetWeaponId(selectedWeaponCategory, item.id)
			updateWeaponCategoryIndicators()

			setWrapsMode(true)
			local spawnPart = if selectedWeaponCategory == WeaponCategoryMod.MAIN then mainWeaponSpawn else specialWeaponSpawn
			if spawnPart and spawnPart:IsA("BasePart") then
				cameraController:zoomOnPosition(spawnPart.Position)
			end

			populateMainContentForNavItem(LockerMainCategory.ARSENAL, LockerCategory.WEAPON_WRAPS, nil, true)
		end), "Disconnect")
	end

	janitor:Add(Network.Shop.Response.Listen(function(response: { success: boolean, message: string })
		local resolvedAction = pendingShopAction
		pendingShopAction = nil

		if response.success then
			if resolvedAction and resolvedAction.kind == "buy" then
				Confetti.Rain(lockerFrame)
			end
		else
			task.defer(function()
				if resolvedAction and resolvedAction.kind == "buy" and selectedMainCategory and selectedNavKey then
					populateMainContentForNavItem(selectedMainCategory, selectedNavKey, resolvedAction.item.qualifiedId)
				else
					refreshGridSelectionState()
				end
			end)
		end
	end), true)

	DataController:WhenReady():andThen(function()
		rebuildOwnedLookup()
		rebuildEquippedLookup()
		rebuildPreviewCharacter(getOptionalString(getCurrentLoadout().Outfit))
		applyEquippedFacePreview()
		applyEquippedHatPreview()
		restoreEquippedWeaponPreviews()

		local statsObserver = fusionScope:Observer(DataController.Stats)
		janitor:Add(statsObserver:onBind(updateStatsUiFromData), true)

		local weaponKillsObserver = fusionScope:Observer(DataController.WeaponKills)
		janitor:Add(weaponKillsObserver:onBind(function()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			if selectedMainCategory == LockerMainCategory.ARSENAL and selectedNavKey == LockerCategory.WEAPON_WRAPS then
				local selectedQualifiedId = if selectedCatalogItem then selectedCatalogItem.qualifiedId else nil
				populateMainContentForNavItem(selectedMainCategory, selectedNavKey, selectedQualifiedId)
			end
		end), true)

		local inventoryObserver = fusionScope:Observer(DataController.Inventory)
		janitor:Add(inventoryObserver:onBind(function()
			rebuildOwnedLookup()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			if selectedMainCategory and selectedNavKey then
				local selectedQualifiedId = if selectedCatalogItem then selectedCatalogItem.qualifiedId else nil
				populateMainContentForNavItem(selectedMainCategory, selectedNavKey, selectedQualifiedId)
			end
		end), true)

		local loadoutObserver = fusionScope:Observer(DataController.Loadout)
		janitor:Add(loadoutObserver:onBind(function()
			rebuildEquippedLookup()
			-- Solo revertir el body al equipado si NO hay un body en preview no-comprometido.
			-- En otro caso, un cambio de loadout (p.ej. equipar un hat) sobreescribiría
			-- el preview del body que el usuario está mirando.
			local previewingBody = selectedCatalogItem ~= nil
				and selectedCatalogItem.Category == LockerCategory.OUTFITS
			local currentOutfit = getOptionalString(getCurrentLoadout().Outfit)
			if not previewingBody and currentOutfit ~= lastPreviewOutfitId then
				rebuildPreviewCharacter(currentOutfit)
			end
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			applyEquippedFacePreview()
			applyEquippedHatPreview()
			syncWeaponPreviewsFromLoadout()
			if selectedMainCategory == LockerMainCategory.EFFECTS and selectedNavKey == LockerCategory.KILL_EFFECTS then
				if selectedCatalogItem and selectedCatalogItem.Category == LockerCategory.KILL_EFFECTS then
					previewKillEffect(selectedCatalogItem.id)
				else
					replaceKillEffectsDummy()
				end
			end
			refreshGridSelectionState()
		end), true)
	end)

	local function setMenuVisibleInstant(visible: boolean)
		if visible then
			menuController:show()
		else
			menuController:hide()
		end
	end

	local function restoreLockerSceneState()
		destroyKillEffectsDummy()
		restoreEquippedWeaponPreviews()
		applyEquippedBodyPreview()
		applyEquippedFacePreview()
		applyEquippedHatPreview()
		cameraController:restore()
		CameraLock.release("locker")
		setMenuVisibleInstant(true)
	end

	-- ── Stagger de aparición de los items de Nav ─────────────
	-- Dos controladores separados: nav1 solo se anima al abrir el locker;
	-- nav2 se re-anima además cada vez que se repuebla (cambio de categoría
	-- en nav1) para que los nuevos items aparezcan escalonados.
	local nav1Stagger = NavStaggerController.new({
		{ container = nav1, getSelectedKey = function() return selectedMainCategory end },
	})
	nav2Stagger = NavStaggerController.new({
		{ container = nav, getSelectedKey = function() return selectedNavKey end, exclude = { navTemplate } },
	})
	janitor:Add(nav1Stagger, "Destroy")
	janitor:Add(nav2Stagger, "Destroy")

	local function openLockerGui()
		if isOpen then
			return
		end

		isOpen = true
		CameraLock.acquire("locker")
		if dirtyWhileClosed then
			dirtyWhileClosed = false
			rebuildOwnedLookup()
			rebuildEquippedLookup()
		end
		applyEquippedFacePreview()
		applyEquippedHatPreview()
		hideActionFrame()
		selectItem(LockerMainCategory.ARSENAL)
		cameraController:apply()
		lockerFrame.Visible = true
		setMenuVisibleInstant(false)
		LightingPresetController.apply("Locker")
		nav1Stagger:play()
		if nav2Stagger then nav2Stagger:play() end
	end

	local function closeLockerGui()
		if not isOpen then
			return
		end

		isOpen = false
		selectedMainCategory = nil
		selectedNavKey = nil
		selectedCatalogItem = nil
		hideActionFrame()
		restoreLockerSceneState()
		setWrapsMode(false)
		lockerFrame.Visible = false
		LightingPresetController.apply("Lobby")
	end

	janitor:Add(lockerBtn.MouseButton1Click:Connect(openLockerGui), "Disconnect")
	janitor:Add(closeBtn.MouseButton1Click:Connect(function()
		if isWrapsMode then
			setWrapsMode(false)
			local previousNavKey = wrapsTargetWeaponCategory or WeaponCategoryMod.MAIN

			cameraController:unzoom()

			for _, button in navButtons do
				if button.Name == previousNavKey then
					setSelectedNavButton(button)
					break
				end
			end

			populateMainContentForNavItem(LockerMainCategory.ARSENAL, previousNavKey, nil, true)
		else
			closeLockerGui()
		end
	end), "Disconnect")
	for categoryKey, button in mainCategoryButtons do
		janitor:Add(button.MouseButton1Click:Connect(function()
			handleMainCategoryButtonClick(categoryKey)
		end), "Disconnect")
	end

	janitor:Add(lockerFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if lockerFrame.Visible == false and isOpen then
			isOpen = false
			restoreLockerSceneState()
			LightingPresetController.apply("Lobby")
		end
	end), "Disconnect")

	janitor:Add(function()
		destroyKillEffectsDummy()
		if isOpen then
			restoreLockerSceneState()
		end
	end, true)

	if autoOpenOnStart then
		task.defer(openLockerGui)
	end

	return janitor
end

return LockerFeature
