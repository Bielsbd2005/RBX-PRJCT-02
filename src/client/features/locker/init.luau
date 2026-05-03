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
local LockerCatalog = require(script:WaitForChild("LockerCatalog"))
local LockerGrid = require(script:WaitForChild("LockerGrid"))
local WeaponPreviewController = require(script:WaitForChild("WeaponPreviewController"))
local FaceApplier = require(script.Appliers.FaceApplier)
local HatApplier = require(script.Appliers.HatApplier)
local MenuHover = require(Client.core.ui.MenuHover)
local UIUtils = require(Client.core.ui.UIUtils)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local LockerConfig = require(Shared.constants.LockerConfig)
local Network = require(Shared.networking.Network)
local DataController = require(Client.core.data.DataController)
local KillEffectsRegistry = require(Shared.locker.killEffects.KillEffectsRegistry)
local StoreProducts = require(Shared.constants.StoreProducts)
local UITheme = require(Client.core.ui.UITheme)
local NavTabController = require(Client.core.ui.NavTabController)
local Confetti = require(Client.core.ui.Confetti)

local LockerFeature = {}

local SELECTED_NAV_ITEM_SIZE = UDim2.new(1.257, 0, 0.107, 0)
local SIZE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
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

type LockerCategoryKey = "Style" | "Arsenal" | "Effects"

type LockerNavItemDefinition = {
	key: string,
	title: string,
	thumbnail: string,
}

type LockerCatalogItem = {
	Id: string,
	Category: string,
	ItemKey: string,
	Name: string,
	Price: number,
	LevelRequired: number,
	Rarity: string,
	Image: string,
	CanPurchase: boolean,
	TextureID: string?,
	BaseColor: Color3?,
	Animated: boolean?,
	StudsPerTile: number?,
	PreviewWeaponCategory: string?,
	PreviewWeaponKey: string?,
	PreviewWeaponName: string?,
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
	WeaponSkinsByWeapon: {
		Main: { [string]: { [string]: number | boolean } },
		Special: { [string]: { [string]: number | boolean } },
	}?,
}

type LoadoutData = {
	[string]: string?,
}

type WeaponCategory = "Main" | "Special"

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
local KILL_EFFECTS_NAV_KEY = "KillEffects"
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
	local sharedTemplates = Shared:WaitForChild("templates")
	local characterTemplate = sharedTemplates:WaitForChild("CharacterTemplate")
	local lockerFolder = Workspace:WaitForChild("Locker")
	local lockerWeaponsFolder = lockerFolder:WaitForChild("weapons")
	local characterSpawn = lockerFolder:WaitForChild("CharacterSpawn")
	local mainWeaponSpawn = lockerFolder:WaitForChild("MainSpawn")
	local specialWeaponSpawn = lockerFolder:WaitForChild("SpecialSpawn")
	local dummySpawn = lockerFolder:WaitForChild("DummySpawn") :: LockerPreviewSpawnTarget
	local killEffectsDummyTemplate = ReplicatedStorage:WaitForChild("Dummy")
	local mainIndicator = lockerWeaponsFolder:FindFirstChild("MainIndicator")
	local specialIndicator = lockerWeaponsFolder:FindFirstChild("SpecialIndicator")

	local lockerBtn = menuGui.BottomContainer.Footer:WaitForChild("locker") :: GuiButton
	local lockerGui = playerGui:WaitForChild("LockerGui") :: ScreenGui
	local root = lockerGui:WaitForChild("Root")
	local nav = root:WaitForChild("Nav2")
	local navTemplate = nav:WaitForChild("Template") :: GuiButton
	local defaultNavItemSize = navTemplate.Size
	local nav1 = root:WaitForChild("Nav1")
	local closeBtn = nav1:WaitForChild("CloseBtn") :: GuiButton
	local styleBtn = nav1:WaitForChild("Style") :: GuiButton
	local arsenalBtn = nav1:WaitForChild("Arsenal") :: GuiButton
	local effectsBtn = nav1:WaitForChild("Effects") :: GuiButton
	local mainFrame = root:WaitForChild("MainFrame")
	local wrapsTitle = root:WaitForChild("WrapsTitle") :: TextLabel
	local itemGrid = mainFrame:WaitForChild("ItemGrid")
	local itemGridTemplate = itemGrid:WaitForChild("Template") :: GuiObject
	local itemGridWrapsTemplate = itemGrid:WaitForChild("Wraps") :: GuiObject
	local actionFrame = root:WaitForChild("ActionFrame") :: GuiObject
	local purchaseButtonContainer = actionFrame:WaitForChild("PurchaseButton") :: GuiButton
	local wrapsButtonContainer = actionFrame:WaitForChild("Wraps") :: GuiButton
	local wrapsButton = wrapsButtonContainer
	local purchaseButton = purchaseButtonContainer
	local purchasePriceLabel = purchaseButtonContainer:WaitForChild("Price") :: TextLabel
	local purchaseIconLocked = purchaseButtonContainer:WaitForChild("IconLocked") :: GuiObject
	local purchaseLockedGradient = purchaseButtonContainer:WaitForChild("Locked") :: UIGradient
	local purchaseUnlockedGradient = purchaseButtonContainer:WaitForChild("Unlocked") :: UIGradient
	local cashFrame = lockerGui:WaitForChild("CashFrame")
	local cashValueNode = cashFrame:WaitForChild("Value")
	local cashValueLabel = if cashValueNode:IsA("TextLabel") then cashValueNode else nil
	local levelContainer = lockerGui:WaitForChild("LevelContainer")
	local levelValueNode = levelContainer:WaitForChild("Value")
	local levelValueLabel = if levelValueNode:IsA("TextLabel") then levelValueNode else nil
	local cameraController = LockerCameraController.new("weapons")
	janitor:Add(cameraController, "Destroy")
	lockerGui.Enabled = false

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
	local wrapsTargetWeaponCategory: WeaponCategory = "Main"
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
	local isOpen = false
	local dirtyWhileClosed = false
	local activeKillEffectsDummy: Model? = nil
	local killEffectsRestoreToken = 0
	local nextAllowedKillEffectPreviewAt = 0
	local skipNextKillEffectSelectionPreview = false
	local nextAllowedMainCategorySwitchAt = 0
	local sharedLockerAssets = Shared:WaitForChild("locker")
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

	local function ensurePreviewCharacter(): Model?
		local spawnTarget = characterSpawn :: LockerPreviewSpawnTarget
		local targetParent = spawnTarget :: Instance
		local existingPreview = targetParent:FindFirstChild("CharacterTemplate")
		if existingPreview and existingPreview:IsA("Model") then
			placePreviewCharacter(existingPreview, spawnTarget)
			playPreviewIdleAnimation(existingPreview)
			return existingPreview
		end

		local previewTemplate = characterTemplate
		if not previewTemplate:IsA("Model") then
			return nil
		end

		local previewClone = previewTemplate:Clone()
		previewClone.Name = "CharacterTemplate"
		previewClone.Parent = targetParent
		placePreviewCharacter(previewClone, spawnTarget)
		playPreviewIdleAnimation(previewClone)
		return previewClone
	end

	local previewCharacter = ensurePreviewCharacter()
	local faceApplier = if previewCharacter then FaceApplier.new(previewCharacter, ItemsConfig) else nil
	local hatApplier = if previewCharacter then HatApplier.new(previewCharacter, ItemsConfig) else nil
	local applyEquippedFacePreview: () -> ()
	local applyEquippedHatPreview: () -> ()

	local function applySelectedFacePreview(item: LockerCatalogItem?)
		if not faceApplier then
			return
		end

		if item and item.Category == "Faces" then
			faceApplier:ApplyImage(item.Image)
			return
		end

		applyEquippedFacePreview()
	end

	local function applySelectedHatPreview(item: LockerCatalogItem?)
		if not hatApplier then
			return
		end

		if item and item.Category == "Hats" then
			hatApplier:Apply(item)
			return
		end

		applyEquippedHatPreview()
	end

	applyEquippedFacePreview = function()
		if not faceApplier then
			return
		end

		faceApplier:ApplyFromLoadoutFace(getOptionalString(equippedLookup.Faces) or getCurrentLoadout().Face)
	end

	applyEquippedHatPreview = function()
		if not hatApplier then
			return
		end

		hatApplier:ApplyFromLoadoutHat(getOptionalString(equippedLookup.Hats) or getCurrentLoadout().Hat)
	end

	if previewCharacter then
		janitor:Add(function()
			if previewCharacter.Parent then
				previewCharacter:Destroy()
			end
		end, true)
	end

	local function getResolvedKillEffectId(): string
		return getOptionalString(equippedLookup.KillEffects) or getOptionalString(getCurrentLoadout().KillEffect) or "Default"
	end

	local killEffectsDummyTemplateModel = if killEffectsDummyTemplate:IsA("Model")
			and killEffectsDummyTemplate:FindFirstChildWhichIsA("Humanoid", true)
		then killEffectsDummyTemplate
		else if characterTemplate:IsA("Model") and characterTemplate:FindFirstChildWhichIsA("Humanoid", true)
			then characterTemplate
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
		if not isOpen or selectedMainCategory ~= "Effects" or selectedNavKey ~= KILL_EFFECTS_NAV_KEY then
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

		local resolvedEffectId = if type(effectId) == "string" and effectId ~= "" then effectId else getResolvedKillEffectId()
		if not KillEffectsRegistry.apply(resolvedEffectId, dummy) then
			return
		end

		killEffectsRestoreToken += 1
		local restoreToken = killEffectsRestoreToken
		task.delay(KILL_EFFECTS_DUMMY_RESTORE_DELAY, function()
			if restoreToken ~= killEffectsRestoreToken then
				return
			end

			if not isOpen or selectedMainCategory ~= "Effects" or selectedNavKey ~= KILL_EFFECTS_NAV_KEY then
				return
			end

			replaceKillEffectsDummy()
		end)
	end

	local function updateKillEffectsPreviewState(categoryKey: LockerCategoryKey, navKey: string)
		if categoryKey == "Effects" and navKey == KILL_EFFECTS_NAV_KEY then
			cameraController:setTargetPartName(KILL_EFFECTS_CAMERA_TARGET)
			if isOpen then
				if selectedCatalogItem and selectedCatalogItem.Category == "KillEffects" then
					previewKillEffect(selectedCatalogItem.ItemKey)
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
			if category == "WeaponSkinsByWeapon" then
				local wrapsByWeapon = items :: any
				for weaponCategory, weaponEntriesAny in wrapsByWeapon do
					if weaponCategory == "Main" or weaponCategory == "Special" then
						local weaponEntries = weaponEntriesAny :: { [string]: { [string]: number | boolean } }
						local categoryWrapLookup = nextWrapsByWeapon[weaponCategory :: WeaponCategory]
						for weaponId, ownedSkinsAny in weaponEntries do
							if type(ownedSkinsAny) == "table" then
								local skinLookup = {} :: { [string]: number }
								for skinId, skinOwned in ownedSkinsAny do
									if skinOwned == true then
										skinLookup[skinId] = 1
									elseif type(skinOwned) == "number" and skinOwned > 0 then
										skinLookup[skinId] = math.max(1, math.floor(skinOwned))
									end
								end
								categoryWrapLookup[weaponId] = skinLookup
							end
						end
					end
				end
			elseif category ~= "WeaponSkins" then
				local categoryLookup = {} :: { [string]: boolean }
				for itemKey, owned in items do
					if owned == true then
						categoryLookup[itemKey] = true
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

	local function getResolvedWeaponIdForCategory(weaponCategory: WeaponCategory, loadout: LoadoutData?): string
		local storedWeaponId = getStoredWrapsTargetWeaponId(weaponCategory)
		if storedWeaponId then
			return storedWeaponId
		end

		if loadout then
			local weaponSlot = CATEGORY_TO_LOADOUT_SLOT[weaponCategory]
			local weaponKey = if weaponSlot then getOptionalString(loadout[weaponSlot]) else nil
			if weaponKey then
				return weaponKey
			end
		end

		return "Default"
	end

	local function getResolvedWrapsTargetWeaponId(loadout: LoadoutData?): string
		return getResolvedWeaponIdForCategory(wrapsTargetWeaponCategory, loadout)
	end

	local function getWeaponSkinRequestContext(category: string): (string, string)
		if category ~= "WeaponSkins" then
			return "", ""
		end

		return wrapsTargetWeaponCategory, getResolvedWrapsTargetWeaponId(getCurrentLoadout())
	end

	local getWrapAmountForWeapon: (weaponCategory: WeaponCategory, weaponId: string, skinId: string) -> number

	local function isWrapOwnedForWeapon(weaponCategory: WeaponCategory, weaponId: string, skinId: string): boolean
		return getWrapAmountForWeapon(weaponCategory, weaponId, skinId) > 0
	end

	function getWrapAmountForWeapon(weaponCategory: WeaponCategory, weaponId: string, skinId: string): number
		local categoryLookup = ownedWrapsByWeaponLookup[weaponCategory]
		if not categoryLookup then
			return 0
		end

		local weaponLookup = categoryLookup[weaponId]
		if not weaponLookup then
			return 0
		end

		return weaponLookup[skinId] or 0
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
		return getEquippedItemByCategory(category) or "Default"
	end

	local function resolveWeaponWrap(loadout: LoadoutData, weaponCategory: WeaponCategory, weaponKey: string?): string
		local normalizedWeaponKey = getOptionalString(weaponKey) or "Default"
		local wrapsTableKey = if weaponCategory == "Main" then "MainWeaponWraps" else "SpecialWeaponWraps"
		local wrapsTableAny = loadout[wrapsTableKey]
		if type(wrapsTableAny) == "table" then
			local wrapsTable = wrapsTableAny :: { [string]: string }
			local resolvedByWeapon = getOptionalString(wrapsTable[normalizedWeaponKey])
			if resolvedByWeapon then
				return resolvedByWeapon
			end

			local resolvedDefault = getOptionalString(wrapsTable.Default)
			if resolvedDefault then
				return resolvedDefault
			end
		end

		return "Default"
	end

	local function isWeaponCategory(category: string): boolean
		return category == "Main" or category == "Special"
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
		isOwned = function(category: string, itemKey: string): boolean
			local categoryLookup = ownedLookup[category]
			return categoryLookup ~= nil and categoryLookup[itemKey] == true
		end,
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
		if item.Category == "WeaponSkins" then
			local targetWeaponId = getResolvedWrapsTargetWeaponId(getCurrentLoadout())
			return isWrapOwnedForWeapon(wrapsTargetWeaponCategory, targetWeaponId, item.ItemKey)
		end

		local categoryLookup = ownedLookup[item.Category]
		return categoryLookup ~= nil and categoryLookup[item.ItemKey] == true
	end

	local function getRarityRank(rarity: string): number
		return RARITY_RANK[rarity] or 0
	end

	local function isItemEquipped(item: LockerCatalogItem): boolean
		if pendingShopAction and pendingShopAction.kind == "equip" then
			if pendingShopAction.item.Category == item.Category then
				return pendingShopAction.item.Id == item.Id
			end
		end

		if item.Category == "WeaponSkins" then
			local loadout = getCurrentLoadout()
			local targetWeaponId = getResolvedWrapsTargetWeaponId(loadout)
			local equippedWrap = resolveWeaponWrap(loadout, wrapsTargetWeaponCategory, targetWeaponId)
			return equippedWrap == item.ItemKey
		end

		local slot = CATEGORY_TO_LOADOUT_SLOT[item.Category]
		if not slot then
			return false
		end

		local equippedItem = getEquippedItemByCategory(item.Category)
		return equippedItem == item.ItemKey
	end

	catalog = LockerCatalog.new(ItemsConfig, ITEMS_CONFIG_BY_NAV, DEFAULT_NAV_THUMBNAIL, getRarityRank, isItemOwned)
	local updateActionFrameForSelected: () -> ()
	local populateMainContentForNavItem: (LockerCategoryKey, string, string?) -> ()
	local clearItemGrid: () -> ()
	local syncWeaponPreviewsFromLoadout: () -> ()

	grid = LockerGrid.new(itemGrid, { default = itemGridTemplate, wraps = itemGridWrapsTemplate }, canUseHoverAnimations, {
		canInteract = function(): boolean
			return pendingShopAction == nil
		end,
		isItemOwned = isItemOwned,
		getItemAmount = function(item: LockerCatalogItem): number
			if item.Category ~= "WeaponSkins" then
				return if isItemOwned(item) then 1 else 0
			end

			local targetWeaponId = getResolvedWrapsTargetWeaponId(getCurrentLoadout())
			return getWrapAmountForWeapon(wrapsTargetWeaponCategory, targetWeaponId, item.ItemKey)
		end,
		isItemEquipped = isItemEquipped,
		getCurrentLevel = getCurrentLevel,
		onSelectionChanged = function(item: LockerCatalogItem?)
			selectedCatalogItem = item
			if item and isWeaponCategory(item.Category) then
				local selectedWeaponCategory = item.Category :: WeaponCategory
				wrapsTargetWeaponCategory = selectedWeaponCategory
				setStoredWrapsTargetWeaponId(selectedWeaponCategory, item.ItemKey)
				updateWeaponCategoryIndicators()
			end
			applySelectedFacePreview(item)
			applySelectedHatPreview(item)
			applySelectedWeaponPreview(item)
			if item and item.Category == "KillEffects" then
				if skipNextKillEffectSelectionPreview then
					skipNextKillEffectSelectionPreview = false
					replaceKillEffectsDummy()
				else
					previewKillEffect(item.ItemKey)
				end
			elseif selectedMainCategory == "Effects" and selectedNavKey == KILL_EFFECTS_NAV_KEY then
					replaceKillEffectsDummy()
			end
			updateActionFrameForSelected()
		end,
		onOwnedItemActivated = function(item: LockerCatalogItem)
			local weaponCategoryForEquip, weaponIdForEquip = getWeaponSkinRequestContext(item.Category)

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
				itemId = item.ItemKey,
				weaponCategory = weaponCategoryForEquip,
				weaponId = weaponIdForEquip,
			})
		end,
	})
	janitor:Add(grid, "Destroy")

	local function getPreferredSelectedItemId(categoryKey: LockerCategoryKey, navKey: string, selectedItemId: string?): string?
		if selectedItemId ~= nil then
			return selectedItemId
		end

		if categoryKey == "Style" and navKey == "Faces" then
			local equippedFace = getOptionalString(equippedLookup.Faces) or getOptionalString(getCurrentLoadout().Face)
			if equippedFace then
				return "Faces." .. equippedFace
			end
		end

		if categoryKey == "Arsenal" and isWeaponCategory(navKey) then
			local weaponCategory = navKey :: WeaponCategory
			local equippedWeapon = getEquippedWeaponByCategory(weaponCategory)
			wrapsTargetWeaponCategory = weaponCategory
			setStoredWrapsTargetWeaponId(weaponCategory, equippedWeapon)
			updateWeaponCategoryIndicators()
			return navKey .. "." .. equippedWeapon
		end

		if categoryKey == "Arsenal" and navKey == "Wraps" then
			local loadout = getCurrentLoadout()
			local weaponKey = getResolvedWrapsTargetWeaponId(loadout)
			return "WeaponSkins." .. resolveWeaponWrap(loadout, wrapsTargetWeaponCategory, weaponKey)
		end

		return nil
	end

	local function getKillProgressForWeaponSkin(weaponCategory: WeaponCategory, weaponId: string, _skinKey: string): number
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
		local targetWeaponId = getResolvedWrapsTargetWeaponId(loadout)
		local targetWeaponCategory = wrapsTargetWeaponCategory
		local targetCategoryConfig = ItemsConfig[targetWeaponCategory]
		local targetWeaponDefinition = if type(targetCategoryConfig) == "table"
			then targetCategoryConfig[targetWeaponId]
			else nil
		local targetWeaponName = if type(targetWeaponDefinition) == "table"
			and type(targetWeaponDefinition.Name) == "string"
			and targetWeaponDefinition.Name ~= ""
			then targetWeaponDefinition.Name
			else targetWeaponId
		local wrapItems = {} :: { LockerCatalogItem }

		for _, item in items do
			local owned = isWrapOwnedForWeapon(targetWeaponCategory, targetWeaponId, item.ItemKey)
			local isChallenge = item.KillGoal ~= nil and item.KillGoal > 0
			if owned or isChallenge then
				local wrapItem = table.clone(item)
				wrapItem.PreviewWeaponCategory = targetWeaponCategory
				wrapItem.PreviewWeaponKey = targetWeaponId
				wrapItem.PreviewWeaponName = targetWeaponName
				if isChallenge and not owned then
					wrapItem.KillProgress = getKillProgressForWeaponSkin(targetWeaponCategory, targetWeaponId, item.ItemKey)
				end
				table.insert(wrapItems, wrapItem)
			end
		end

		-- Orden dentro de la vista Wraps:
		--   1) Challenges de kill no desbloqueados
		--   2) Default
		--   3) Resto (owned) por rareza descendente
		local function groupRank(it: LockerCatalogItem): number
			local owned = isWrapOwnedForWeapon(targetWeaponCategory, targetWeaponId, it.ItemKey)
			local isChallenge = it.KillGoal ~= nil and it.KillGoal > 0
			if isChallenge and not owned then
				return 1
			end
			if it.ItemKey == "Default" then
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

	populateMainContentForNavItem = function(categoryKey: LockerCategoryKey, navKey: string, selectedItemId: string?)
		local previousNavKey = selectedNavKey
		selectedNavKey = navKey
		updateWeaponCategoryIndicators()
		skipNextKillEffectSelectionPreview = categoryKey == "Effects"
			and navKey == KILL_EFFECTS_NAV_KEY
			and previousNavKey ~= navKey
		updateKillEffectsPreviewState(categoryKey, navKey)
		if categoryKey ~= "Arsenal" or previousNavKey ~= navKey then
			restoreEquippedWeaponPreviews()
		end
		local preferredSelectedItemId = getPreferredSelectedItemId(categoryKey, navKey, selectedItemId)

		local items = catalog:GetItems(categoryKey, navKey)
		local isWrapsView = categoryKey == "Arsenal" and navKey == "Wraps"
		if isWrapsView then
			items = getWrapItemsForCurrentWeapon(items)
		end

		grid:Populate(items, preferredSelectedItemId, if isWrapsView then "wraps" else "default")
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
		local otherCategory = if selectedCategory == "Main" then "Special" else "Main"
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
				populateMainContentForNavItem(categoryKey, definition.key, nil)
			end), "Disconnect")
		end

		if #navButtons > 0 then
			setSelectedNavButton(navButtons[1])
			populateMainContentForNavItem(categoryKey, itemDefinitions[1].key, nil)
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
		if selectedKey ~= "Arsenal" then
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
						populateMainContentForNavItem(selectedMainCategory, selectedNavKey, buyAction.item.Id)
					end
				end
			end)

			local weaponCategory, weaponId = getWeaponSkinRequestContext(item.Category)

			Network.Shop.BuyItem.Send({
				itemId = item.ItemKey,
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
			setStoredWrapsTargetWeaponId(selectedWeaponCategory, item.ItemKey)
			updateWeaponCategoryIndicators()

			setWrapsMode(true)
			local spawnPart = if selectedWeaponCategory == "Main" then mainWeaponSpawn else specialWeaponSpawn
			if spawnPart and spawnPart:IsA("BasePart") then
				cameraController:zoomOnPosition(spawnPart.Position)
			end

			populateMainContentForNavItem("Arsenal", "Wraps", nil)
		end), "Disconnect")
	end

	janitor:Add(Network.Shop.Response.Listen(function(response: { success: boolean, message: string })
		local resolvedAction = pendingShopAction
		pendingShopAction = nil

		if response.success then
			if resolvedAction and resolvedAction.kind == "buy" then
				Confetti.Rain(lockerGui)
			end
		else
			task.defer(function()
				if resolvedAction and resolvedAction.kind == "buy" and selectedMainCategory and selectedNavKey then
					populateMainContentForNavItem(selectedMainCategory, selectedNavKey, resolvedAction.item.Id)
				else
					refreshGridSelectionState()
				end
			end)
		end
	end), true)

	DataController:WhenReady():andThen(function()
		rebuildOwnedLookup()
		rebuildEquippedLookup()
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
			if selectedMainCategory == "Arsenal" and selectedNavKey == "Wraps" then
				local selectedItemId = if selectedCatalogItem then selectedCatalogItem.Id else nil
				populateMainContentForNavItem(selectedMainCategory, selectedNavKey, selectedItemId)
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
				local selectedItemId = if selectedCatalogItem then selectedCatalogItem.Id else nil
				populateMainContentForNavItem(selectedMainCategory, selectedNavKey, selectedItemId)
			end
		end), true)

		local loadoutObserver = fusionScope:Observer(DataController.Loadout)
		janitor:Add(loadoutObserver:onBind(function()
			rebuildEquippedLookup()
			if not isOpen then
				dirtyWhileClosed = true
				return
			end
			applyEquippedFacePreview()
			applyEquippedHatPreview()
			syncWeaponPreviewsFromLoadout()
			if selectedMainCategory == "Effects" and selectedNavKey == KILL_EFFECTS_NAV_KEY then
				if selectedCatalogItem and selectedCatalogItem.Category == "KillEffects" then
					previewKillEffect(selectedCatalogItem.ItemKey)
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
		cameraController:restore()
		CameraLock.release("locker")
		setMenuVisibleInstant(true)
	end

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
		selectItem("Arsenal")
		cameraController:apply()
		lockerGui.Enabled = true
		setMenuVisibleInstant(false)
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
		lockerGui.Enabled = false
	end

	janitor:Add(lockerBtn.MouseButton1Click:Connect(openLockerGui), "Disconnect")
	janitor:Add(closeBtn.MouseButton1Click:Connect(function()
		if isWrapsMode then
			setWrapsMode(false)
			local previousNavKey = wrapsTargetWeaponCategory or "Main"

			cameraController:unzoom()

			for _, button in navButtons do
				if button.Name == previousNavKey then
					setSelectedNavButton(button)
					break
				end
			end

			populateMainContentForNavItem("Arsenal", previousNavKey, nil)
		else
			closeLockerGui()
		end
	end), "Disconnect")
	for categoryKey, button in mainCategoryButtons do
		janitor:Add(button.MouseButton1Click:Connect(function()
			handleMainCategoryButtonClick(categoryKey)
		end), "Disconnect")
	end

	janitor:Add(lockerGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if lockerGui.Enabled == false and isOpen then
			isOpen = false
			restoreLockerSceneState()
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
