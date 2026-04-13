--!strict

local Players = game:GetService("Players")
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
local LockerCatalog = require(script:WaitForChild("LockerCatalog"))
local LockerGrid = require(script:WaitForChild("LockerGrid"))
local FaceApplier = require(script.Appliers.FaceApplier)
local HatApplier = require(script.Appliers.HatApplier)
local MenuHover = require(Client.core.ui.MenuHover)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local LockerConfig = require(Shared.constants.LockerConfig)
local Network = require(Shared.networking.Network)
local DataController = require(Client.core.data.DataController)
local KillEffectsRegistry = require(Shared.locker.killEffects.KillEffectsRegistry)

local LockerFeature = {}

local SELECTED_NAV_ITEM_SIZE = UDim2.new(1.257, 0, 0.107, 0)
local SIZE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STROKE_DEFAULT = Color3.fromRGB(38, 38, 38)
local STROKE_WHITE = Color3.fromRGB(255, 255, 255)
local PURCHASE_BUTTON_HOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PURCHASE_BUTTON_CLICK_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PURCHASE_BUTTON_DEFAULT_SCALE = 1
local PURCHASE_BUTTON_HOVER_SCALE = 1.03
local PURCHASE_BUTTON_CLICK_SCALE = 0.96
local DEFAULT_NAV_THUMBNAIL = "rbxasset://textures/ui/GuiImagePlaceholder.png"
local ACTION_FRAME_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LOCKER_PREVIEW_IDLE_ANIMATION_ID = "rbxassetid://115197033304718"
local DEFAULT_WRAP_STUDS_PER_TILE = 3
local WEAPON_WRAP_TEXTURE_SCROLL_SPEED_U = 1
local WEAPON_WRAP_TEXTURE_SCROLL_SPEED_V = 0
local SELECTED_WEAPON_RISE_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SELECTED_WEAPON_RISE_HEIGHT = 0.28
local SELECTED_WEAPON_BOB_AMPLITUDE = 0.2
local SELECTED_WEAPON_BOB_SPEED = 0.3
local SELECTED_WEAPON_SWITCH_DOWN_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SELECTED_WEAPON_SWITCH_DOWN_STUDS = 0.05
local LOCKED_WEAPON_PREVIEW_COLOR = Color3.fromRGB(0, 0, 0)

local WEAPON_WRAP_TEXTURE_FACE_BY_NAME = {
	ScrollTexture_Back = Enum.NormalId.Back,
	ScrollTexture_Bottom = Enum.NormalId.Bottom,
	ScrollTexture_Left = Enum.NormalId.Left,
	ScrollTexture_Right = Enum.NormalId.Right,
	ScrollTexture_Front = Enum.NormalId.Front,
	ScrollTexture_Top = Enum.NormalId.Top,
} :: { [string]: Enum.NormalId }

local WEAPON_WRAP_TEXTURE_ORDER = {
	"ScrollTexture_Back",
	"ScrollTexture_Bottom",
	"ScrollTexture_Left",
	"ScrollTexture_Right",
	"ScrollTexture_Front",
	"ScrollTexture_Top",
} :: { string }

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
		Main: { [string]: { [string]: boolean } },
		Special: { [string]: { [string]: boolean } },
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
	local actionFrame = root:WaitForChild("ActionFrame") :: GuiObject
	local purchaseButtonContainer = actionFrame:WaitForChild("PurchaseButton")
	local wrapsNode = actionFrame:FindFirstChild("Wraps", true)
	local wrapsButtonContainer = if wrapsNode and wrapsNode:IsA("GuiObject") then wrapsNode else nil
	local wrapsButton = if wrapsNode and wrapsNode:IsA("GuiButton")
		then wrapsNode
		else if wrapsNode then wrapsNode:FindFirstChildWhichIsA("GuiButton", true) else nil
	local purchaseButton = if purchaseButtonContainer:IsA("GuiButton")
		then purchaseButtonContainer
		else purchaseButtonContainer:FindFirstChildWhichIsA("GuiButton", true)
	local purchasePriceNode = purchaseButtonContainer:FindFirstChild("Price", true)
	local purchasePriceLabel = if purchasePriceNode and purchasePriceNode:IsA("TextLabel") then purchasePriceNode else nil
	local purchaseIconLockedNode = purchaseButtonContainer:FindFirstChild("IconLocked", true)
	local purchaseIconLocked = if purchaseIconLockedNode and purchaseIconLockedNode:IsA("GuiObject")
		then purchaseIconLockedNode
		else nil
	local purchaseLockedGradientNode = purchaseButtonContainer:FindFirstChild("Locked", true)
	local purchaseLockedGradient = if purchaseLockedGradientNode and purchaseLockedGradientNode:IsA("UIGradient")
		then purchaseLockedGradientNode
		else nil
	local purchaseUnlockedGradientNode = purchaseButtonContainer:FindFirstChild("Unlocked", true)
	local purchaseUnlockedGradient = if purchaseUnlockedGradientNode and purchaseUnlockedGradientNode:IsA("UIGradient")
		then purchaseUnlockedGradientNode
		else nil
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
	} :: { [WeaponCategory]: { [string]: { [string]: boolean } } }
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
	local updateWeaponCategoryIndicators: () -> ()

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

	local activeWeaponPreviewByCategory = {} :: { [string]: Instance }
	local activeWeaponPreviewItemIdByCategory = {} :: { [string]: string }
	local activeWeaponWrapAnimationByCategory = {} :: { [string]: RBXScriptConnection }
	local activeWeaponMotionTweenByCategory = {} :: { [string]: Tween }
	local activeWeaponMotionConnectionByCategory = {} :: { [string]: RBXScriptConnection }
	local activeWeaponSelectionTransitionTokenByCategory = {} :: { [string]: number }
	local weaponPreviewBasePivotByCategory = {} :: { [string]: CFrame }
	local lockedWeaponTemplateCache = {} :: { [string]: Instance }
	local applySelectedWeaponPreview: (LockerCatalogItem?) -> ()
	local restoreEquippedWeaponPreviewForCategory: (string) -> ()
	local restoreEquippedWeaponPreviews: () -> ()
	local stopWeaponSelectionMotion: (string, boolean?) -> ()
	local startWeaponSelectionMotion: (WeaponCategory, number?) -> ()

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
		} :: { [WeaponCategory]: { [string]: { [string]: boolean } } }

		for category, items in inventory do
			if category == "WeaponSkinsByWeapon" then
				local wrapsByWeapon = items :: any
				for weaponCategory, weaponEntriesAny in wrapsByWeapon do
					if weaponCategory == "Main" or weaponCategory == "Special" then
						local weaponEntries = weaponEntriesAny :: { [string]: { [string]: boolean } }
						local categoryWrapLookup = nextWrapsByWeapon[weaponCategory :: WeaponCategory]
						for weaponId, ownedSkinsAny in weaponEntries do
							if type(ownedSkinsAny) == "table" then
								local skinLookup = {} :: { [string]: boolean }
								for skinId, skinOwned in ownedSkinsAny do
									if skinOwned == true then
										skinLookup[skinId] = true
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

	local function isWrapOwnedForWeapon(weaponCategory: WeaponCategory, weaponId: string, skinId: string): boolean
		local categoryLookup = ownedWrapsByWeaponLookup[weaponCategory]
		if not categoryLookup then
			return false
		end

		local weaponLookup = categoryLookup[weaponId]
		if not weaponLookup then
			return false
		end

		return weaponLookup[skinId] == true
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

		return getOptionalString(loadout.ActiveSkin) or "Default"
	end

	local function isWeaponCategory(category: string): boolean
		return category == "Main" or category == "Special"
	end

	updateWeaponCategoryIndicators = function()
		if not (mainIndicator and mainIndicator:IsA("BasePart") and specialIndicator and specialIndicator:IsA("BasePart")) then
			return
		end

		local activeWeaponCategory: WeaponCategory? = nil
		if selectedMainCategory == "Arsenal" then
			if selectedNavKey == "Main" or selectedNavKey == "Special" then
				activeWeaponCategory = selectedNavKey :: WeaponCategory
			elseif selectedNavKey == "Wraps" then
				activeWeaponCategory = wrapsTargetWeaponCategory
			end
		end

		mainIndicator.LocalTransparencyModifier = if activeWeaponCategory == "Main" then 0 else 1
		specialIndicator.LocalTransparencyModifier = if activeWeaponCategory == "Special" then 0 else 1
	end

	local function getWeaponSpawnForCategory(category: string): LockerPreviewSpawnTarget?
		if category == "Main" then
			return mainWeaponSpawn
		elseif category == "Special" then
			return specialWeaponSpawn
		end

		return nil
	end

	local function destroyWeaponPreviewForCategory(category: string)
		stopWeaponSelectionMotion(category, false)
		disconnectFromMap(activeWeaponWrapAnimationByCategory, category)

		local activePreview = activeWeaponPreviewByCategory[category]
		if activePreview and activePreview.Parent then
			activePreview:Destroy()
		end

		activeWeaponPreviewByCategory[category] = nil
		activeWeaponPreviewItemIdByCategory[category] = nil
		weaponPreviewBasePivotByCategory[category] = nil
	end

	local function destroyAllWeaponPreviews()
		destroyWeaponPreviewForCategory("Main")
		destroyWeaponPreviewForCategory("Special")
	end
	janitor:Add(destroyAllWeaponPreviews, true)

	local function getWeaponPreviewPivot(previewInstance: Instance): CFrame?
		if previewInstance:IsA("Model") then
			return previewInstance:GetPivot()
		end

		if previewInstance:IsA("BasePart") then
			return previewInstance.CFrame
		end

		return nil
	end

	local function setWeaponPreviewPivot(previewInstance: Instance, pivot: CFrame)
		if previewInstance:IsA("Model") then
			previewInstance:PivotTo(pivot)
		elseif previewInstance:IsA("BasePart") then
			previewInstance.CFrame = pivot
		end
	end

	stopWeaponSelectionMotion = function(category: string, restoreToBase: boolean?)
		disconnectFromMap(activeWeaponMotionConnectionByCategory, category)
		cancelTweenFromMap(activeWeaponMotionTweenByCategory, category)

		if restoreToBase ~= false then
			local activePreview = activeWeaponPreviewByCategory[category]
			local basePivot = weaponPreviewBasePivotByCategory[category]
			if activePreview and activePreview.Parent and basePivot then
				setWeaponPreviewPivot(activePreview, basePivot)
			end
		end
	end

	startWeaponSelectionMotion = function(category: WeaponCategory, startOffsetY: number?)
		local hasExplicitStartOffset = type(startOffsetY) == "number"
		stopWeaponSelectionMotion(category, not hasExplicitStartOffset)

		local activePreview = activeWeaponPreviewByCategory[category]
		local basePivot = weaponPreviewBasePivotByCategory[category]
		if not activePreview or not activePreview.Parent or not basePivot then
			return
		end

		local initialOffsetY = if hasExplicitStartOffset then startOffsetY :: number else 0
		local startPivot = basePivot * CFrame.new(0, initialOffsetY, 0)
		local liftPivot = basePivot * CFrame.new(0, SELECTED_WEAPON_RISE_HEIGHT, 0)
		setWeaponPreviewPivot(activePreview, startPivot)
		local cframeValue = Instance.new("CFrameValue")
		cframeValue.Value = startPivot
		local valueChangedConnection: RBXScriptConnection? = nil

		valueChangedConnection = cframeValue:GetPropertyChangedSignal("Value"):Connect(function()
			if not activePreview.Parent then
				if valueChangedConnection then
					valueChangedConnection:Disconnect()
					valueChangedConnection = nil
				end
				return
			end

			setWeaponPreviewPivot(activePreview, cframeValue.Value)
		end)

		local riseTween = TweenService:Create(cframeValue, SELECTED_WEAPON_RISE_TWEEN_INFO, {
			Value = liftPivot,
		})
		activeWeaponMotionTweenByCategory[category] = riseTween

		riseTween.Completed:Connect(function(playbackState)
			if activeWeaponMotionTweenByCategory[category] == riseTween then
				activeWeaponMotionTweenByCategory[category] = nil
			end

			if valueChangedConnection then
				valueChangedConnection:Disconnect()
				valueChangedConnection = nil
			end

			cframeValue:Destroy()

			if playbackState ~= Enum.PlaybackState.Completed then
				return
			end

			if not activePreview.Parent then
				return
			end

			local elapsed = 0
			activeWeaponMotionConnectionByCategory[category] = RunService.Heartbeat:Connect(function(dt)
				if not activePreview.Parent then
					stopWeaponSelectionMotion(category, false)
					return
				end

				elapsed += dt
				local bobY = SELECTED_WEAPON_RISE_HEIGHT + math.sin(elapsed * SELECTED_WEAPON_BOB_SPEED * math.pi * 2) * SELECTED_WEAPON_BOB_AMPLITUDE
				setWeaponPreviewPivot(activePreview, basePivot * CFrame.new(0, bobY, 0))
			end)
		end)

		riseTween:Play()
	end

	local function positionWeaponPreview(previewInstance: Instance, spawnTarget: LockerPreviewSpawnTarget)
		setWeaponPreviewPivot(previewInstance, getSpawnPivot(spawnTarget))
	end

	local function getWeaponPreviewPrimaryPart(previewInstance: Instance): BasePart?
		if previewInstance:IsA("Model") then
			local primaryPart = previewInstance.PrimaryPart
			if primaryPart then
				return primaryPart
			end

			local namedPrimary = previewInstance:FindFirstChild("primaryPart", true)
			if namedPrimary and namedPrimary:IsA("BasePart") then
				return namedPrimary
			end

			return previewInstance:FindFirstChildWhichIsA("BasePart", true)
		end

		if previewInstance:IsA("BasePart") then
			return previewInstance
		end

		return nil
	end

	local function isWeaponPreviewLocked(category: WeaponCategory, itemKey: string?): boolean
		if type(itemKey) ~= "string" or itemKey == "" then
			return false
		end

		local categoryLookup = ownedLookup[category]
		if categoryLookup and categoryLookup[itemKey] == true then
			return false
		end

		local categoryConfig = ItemsConfig[category]
		local definition = if type(categoryConfig) == "table" then categoryConfig[itemKey] else nil
		local levelRequired = if type(definition) == "table" then tonumber(definition.LevelRequired) else nil
		if levelRequired and getCurrentLevel() < levelRequired then
			return true
		end

		return false
	end

	local function applyLockedWeaponPreviewAppearance(previewInstance: Instance, weaponCategory: WeaponCategory)
		disconnectFromMap(activeWeaponWrapAnimationByCategory, weaponCategory)

		for _, descendant in previewInstance:GetDescendants() do
			if descendant:IsA("MeshPart") then
				descendant.TextureID = ""
				descendant.Color = LOCKED_WEAPON_PREVIEW_COLOR
				descendant.Material = Enum.Material.Neon
			elseif descendant:IsA("Texture") or descendant:IsA("Decal") or descendant:IsA("SurfaceAppearance") then
				descendant:Destroy()
			end
		end
	end

	local function applyWrapToWeaponPreview(previewInstance: Instance, weaponCategory: WeaponCategory, wrapId: string)
		local primaryPart = getWeaponPreviewPrimaryPart(previewInstance)
		if not primaryPart then
			return
		end

		disconnectFromMap(activeWeaponWrapAnimationByCategory, weaponCategory)

		local wrapsConfig = ItemsConfig.WeaponSkins
		local wrapDefinition = if type(wrapsConfig) == "table" then wrapsConfig[wrapId] else nil
		local validDef = type(wrapDefinition) == "table"
		local textureId = if validDef then getOptionalString(wrapDefinition.TextureID) else nil
		local baseColor = if validDef and typeof(wrapDefinition.BaseColor) == "Color3"
			then wrapDefinition.BaseColor
			else nil
		local studsPerTile = if validDef
			then math.max(0.01, tonumber(wrapDefinition.StudsPerTile) or DEFAULT_WRAP_STUDS_PER_TILE)
			else DEFAULT_WRAP_STUDS_PER_TILE
		local animated = validDef and wrapDefinition.Animated == true
		local animatedTextures = {} :: { Texture }

		for _, child in primaryPart:GetChildren() do
			if child:IsA("Texture") and string.sub(child.Name, 1, 14) == "ScrollTexture_" then
				if not textureId then
					child:Destroy()
				end
			end
		end

		if textureId then
			for _, textureName in WEAPON_WRAP_TEXTURE_ORDER do
				local existingTexture = primaryPart:FindFirstChild(textureName)
				local texture: Texture
				if existingTexture and existingTexture:IsA("Texture") then
					texture = existingTexture
				else
					texture = Instance.new("Texture")
					texture.Name = textureName
					texture.Face = WEAPON_WRAP_TEXTURE_FACE_BY_NAME[textureName]
					texture.Parent = primaryPart
				end

				texture.Texture = textureId
				texture.Transparency = 0
				texture.StudsPerTileU = studsPerTile
				texture.StudsPerTileV = studsPerTile
				texture.OffsetStudsU = 0
				texture.OffsetStudsV = 0
				table.insert(animatedTextures, texture)
			end
		elseif baseColor then
			primaryPart.Color = baseColor
		end

		if textureId and animated and #animatedTextures > 0 then
			activeWeaponWrapAnimationByCategory[weaponCategory] = RunService.Heartbeat:Connect(function(dt)
				for _, texture in animatedTextures do
					if texture.Parent then
						local tileU = if texture.StudsPerTileU ~= 0 then texture.StudsPerTileU else 1
						local tileV = if texture.StudsPerTileV ~= 0 then texture.StudsPerTileV else 1
						texture.OffsetStudsU = (texture.OffsetStudsU + WEAPON_WRAP_TEXTURE_SCROLL_SPEED_U * dt) % tileU
						texture.OffsetStudsV = (texture.OffsetStudsV + WEAPON_WRAP_TEXTURE_SCROLL_SPEED_V * dt) % tileV
					end
				end
			end)
		end
	end

	local function resolveWeaponTemplate(category: string, itemKey: string?, itemName: string?): Instance?
		if not isWeaponCategory(category) then
			return nil
		end

		local categoryFolder = sharedWeaponAssets:FindFirstChild(category)
		if not categoryFolder then
			return nil
		end

		return (if itemKey then categoryFolder:FindFirstChild(itemKey) else nil)
			or (if itemName then categoryFolder:FindFirstChild(itemName) else nil)
			or categoryFolder:FindFirstChild("Default")
	end

	local function getWeaponPreviewStateId(category: WeaponCategory, itemKey: string?, previewId: string, locked: boolean?): string
		if locked then
			return previewId .. "::locked"
		end
		local resolvedWeaponKey = getOptionalString(itemKey) or "Default"
		local loadout = getCurrentLoadout()
		local resolvedWrapId = resolveWeaponWrap(loadout, category, resolvedWeaponKey)
		return previewId .. "::" .. resolvedWrapId .. "::unlocked"
	end

	local function getOrCreateLockedWeaponTemplate(category: string, itemKey: string?, itemName: string?): Instance?
		local resolvedKey = getOptionalString(itemKey) or "Default"
		local cacheKey = category .. "::" .. resolvedKey
		local cached = lockedWeaponTemplateCache[cacheKey]
		if cached then
			return cached
		end

		local weaponTemplate = resolveWeaponTemplate(category, itemKey, itemName)
		if not weaponTemplate then
			return nil
		end

		local processedClone = weaponTemplate:Clone()
		applyLockedWeaponPreviewAppearance(processedClone, category :: WeaponCategory)
		lockedWeaponTemplateCache[cacheKey] = processedClone
		return processedClone
	end

	local function applyWeaponPreviewForCategory(category: string, itemKey: string?, itemName: string?, previewId: string)
		if not isWeaponCategory(category) then
			return
		end

		local previewCategory = category :: WeaponCategory
		local previewLocked = isWeaponPreviewLocked(previewCategory, itemKey)
		local previewStateId = getWeaponPreviewStateId(previewCategory, itemKey, previewId, previewLocked)

		local spawnTarget = getWeaponSpawnForCategory(category)
		if not spawnTarget then
			return
		end

		if activeWeaponPreviewByCategory[category]
			and activeWeaponPreviewByCategory[category].Parent
			and activeWeaponPreviewItemIdByCategory[category] == previewStateId
		then
			return
		end

		destroyWeaponPreviewForCategory(category)

		local clonedWeapon: Instance
		if previewLocked then
			local lockedTemplate = getOrCreateLockedWeaponTemplate(category, itemKey, itemName)
			if not lockedTemplate then
				return
			end
			clonedWeapon = lockedTemplate:Clone()
		else
			local weaponTemplate = resolveWeaponTemplate(category, itemKey, itemName)
			if not weaponTemplate then
				return
			end
			clonedWeapon = weaponTemplate:Clone()
		end

		clonedWeapon.Name = category .. "WeaponPreview"
		clonedWeapon.Parent = spawnTarget :: Instance
		positionWeaponPreview(clonedWeapon, spawnTarget)
		local basePivot = getWeaponPreviewPivot(clonedWeapon)
		if basePivot then
			weaponPreviewBasePivotByCategory[category] = basePivot
		end
		if not previewLocked then
			local resolvedWeaponKey = getOptionalString(itemKey) or "Default"
			local loadout = getCurrentLoadout()
			local resolvedWrapId = resolveWeaponWrap(loadout, previewCategory, resolvedWeaponKey)
			applyWrapToWeaponPreview(clonedWeapon, previewCategory, resolvedWrapId)
		end

		activeWeaponPreviewByCategory[category] = clonedWeapon
		activeWeaponPreviewItemIdByCategory[category] = previewStateId
	end

	restoreEquippedWeaponPreviewForCategory = function(category: string)
		if not isWeaponCategory(category) then
			return
		end

		local equippedItemKey = getEquippedItemByCategory(category) or "Default"

		local categoryConfig = ItemsConfig[category]
		local definition = if type(categoryConfig) == "table" then categoryConfig[equippedItemKey] else nil
		local resolvedName = if type(definition) == "table" then tostring(definition.Name or equippedItemKey) else equippedItemKey
		local previewId = category .. "." .. equippedItemKey
		applyWeaponPreviewForCategory(category, equippedItemKey, resolvedName, previewId)
	end

	restoreEquippedWeaponPreviews = function()
		stopWeaponSelectionMotion("Main", true)
		stopWeaponSelectionMotion("Special", true)
		restoreEquippedWeaponPreviewForCategory("Main")
		restoreEquippedWeaponPreviewForCategory("Special")
	end

	applySelectedWeaponPreview = function(item: LockerCatalogItem?)
		if not item or not isWeaponCategory(item.Category) then
			restoreEquippedWeaponPreviews()
			return
		end

		local selectedCategory = item.Category :: WeaponCategory
		if selectedCategory == "Main" then
			stopWeaponSelectionMotion("Special", true)
		else
			stopWeaponSelectionMotion("Main", true)
		end

		local selectedLocked = isWeaponPreviewLocked(selectedCategory, item.ItemKey)
		local desiredPreviewStateId = getWeaponPreviewStateId(selectedCategory, item.ItemKey, item.Id, selectedLocked)
		local activePreviewStateId = activeWeaponPreviewItemIdByCategory[selectedCategory]
		local currentPreview = activeWeaponPreviewByCategory[selectedCategory]
		if currentPreview
			and currentPreview.Parent
			and activePreviewStateId == desiredPreviewStateId
		then
			if not activeWeaponMotionConnectionByCategory[selectedCategory]
				and not activeWeaponMotionTweenByCategory[selectedCategory]
			then
				startWeaponSelectionMotion(selectedCategory, -SELECTED_WEAPON_SWITCH_DOWN_STUDS)
			end
			return
		end

		local nextTransitionToken = (activeWeaponSelectionTransitionTokenByCategory[selectedCategory] or 0) + 1
		activeWeaponSelectionTransitionTokenByCategory[selectedCategory] = nextTransitionToken

		local currentBasePivot = weaponPreviewBasePivotByCategory[selectedCategory]
		if not currentPreview or not currentPreview.Parent or not currentBasePivot then
			applyWeaponPreviewForCategory(item.Category, item.ItemKey, item.Name, item.Id)
			startWeaponSelectionMotion(selectedCategory, -SELECTED_WEAPON_SWITCH_DOWN_STUDS)
			return
		end

		stopWeaponSelectionMotion(selectedCategory, false)

		local downPivot = currentBasePivot * CFrame.new(0, -SELECTED_WEAPON_SWITCH_DOWN_STUDS, 0)
		local startPivot = getWeaponPreviewPivot(currentPreview) or currentBasePivot
		local cframeValue = Instance.new("CFrameValue")
		cframeValue.Value = startPivot
		local valueChangedConnection: RBXScriptConnection? = nil

		valueChangedConnection = cframeValue:GetPropertyChangedSignal("Value"):Connect(function()
			if not currentPreview.Parent then
				if valueChangedConnection then
					valueChangedConnection:Disconnect()
					valueChangedConnection = nil
				end
				return
			end

			setWeaponPreviewPivot(currentPreview, cframeValue.Value)
		end)

		local downTween = TweenService:Create(cframeValue, SELECTED_WEAPON_SWITCH_DOWN_TWEEN_INFO, {
			Value = downPivot,
		})
		activeWeaponMotionTweenByCategory[selectedCategory] = downTween

		downTween.Completed:Connect(function(playbackState)
			if activeWeaponMotionTweenByCategory[selectedCategory] == downTween then
				activeWeaponMotionTweenByCategory[selectedCategory] = nil
			end

			if valueChangedConnection then
				valueChangedConnection:Disconnect()
				valueChangedConnection = nil
			end

			cframeValue:Destroy()

			if playbackState ~= Enum.PlaybackState.Completed then
				return
			end

			if activeWeaponSelectionTransitionTokenByCategory[selectedCategory] ~= nextTransitionToken then
				return
			end

			applyWeaponPreviewForCategory(item.Category, item.ItemKey, item.Name, item.Id)

			local nextPreview = activeWeaponPreviewByCategory[selectedCategory]
			local nextBasePivot = weaponPreviewBasePivotByCategory[selectedCategory]
			if nextPreview and nextPreview.Parent and nextBasePivot then
				setWeaponPreviewPivot(nextPreview, nextBasePivot * CFrame.new(0, -SELECTED_WEAPON_SWITCH_DOWN_STUDS, 0))
				startWeaponSelectionMotion(selectedCategory, -SELECTED_WEAPON_SWITCH_DOWN_STUDS)
			else
				startWeaponSelectionMotion(selectedCategory)
			end
		end)

		downTween:Play()
	end
	local function clearNavButtons()
		navItemsJanitor:Cleanup()
		table.clear(navButtons)
		selectedNavButton = nil

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

	local function tweenNavButtonVisuals(button: GuiButton, isSelected: boolean)
		local targetScale = if isSelected then 1.15 else 1.0
		local targetColor = if isSelected then Color3.fromRGB(249, 217, 93) else Color3.fromRGB(35, 54, 99)

		if button:IsA("ImageButton") or button:IsA("ImageLabel") then
			TweenService:Create(button, SIZE_TWEEN_INFO, { ImageColor3 = targetColor }):Play()
		end

		local scaleNode = button:FindFirstChildOfClass("UIScale")
		if not scaleNode then
			scaleNode = Instance.new("UIScale")
			scaleNode.Name = "NavScale"
			scaleNode.Parent = button
		end

		TweenService:Create(scaleNode, SIZE_TWEEN_INFO, { Scale = targetScale }):Play()
	end

	local function setSelectedNavButton(selectedButton: GuiButton)
		selectedNavButton = selectedButton

		for _, button in navButtons do
			local isSelected = (button == selectedButton)
			tweenNavButtonVisuals(button, isSelected)
		end
	end

	local function setSelectedMainCategory(categoryKey: LockerCategoryKey)
		selectedMainCategory = categoryKey
		updateWeaponCategoryIndicators()

		for key, button in mainCategoryButtons do
			local isSelected = (key == categoryKey)
			local targetScale = if isSelected then 1.15 else 1.0
			local targetColor = if isSelected then Color3.fromRGB(249, 217, 93) else Color3.fromRGB(35, 54, 99)

			local scaleNode = button:FindFirstChildOfClass("UIScale")
			if not scaleNode then
				scaleNode = Instance.new("UIScale")
				scaleNode.Name = "NavScale"
				scaleNode.Parent = button
			end

			if button:IsA("ImageButton") or button:IsA("ImageLabel") then
				TweenService:Create(button, SIZE_TWEEN_INFO, { ImageColor3 = targetColor }):Play()
			end

			TweenService:Create(scaleNode, SIZE_TWEEN_INFO, { Scale = targetScale }):Play()
		end
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
		setOptionalVisible(wrapsButtonContainer, false)

		local isLevelLocked = getCurrentLevel() < item.LevelRequired

		if purchasePriceLabel then
			purchasePriceLabel.Text = if isLevelLocked then "LOCKED" else tostring(item.Price)
		end

		setOptionalVisible(purchaseIconLocked, isLevelLocked)

		if purchaseLockedGradient then
			purchaseLockedGradient.Enabled = isLevelLocked
		end

		if purchaseUnlockedGradient then
			purchaseUnlockedGradient.Enabled = not isLevelLocked
		end

		if purchaseButton and purchaseButton:IsA("GuiButton") then
			purchaseButton.Active = not isLevelLocked
			purchaseButton.Selectable = not isLevelLocked
		end

		tweenActionFrame(actionFrameVisiblePosition, true)
	end

	local function showOwnedWeaponActionFrame()
		purchaseButtonContainer.Visible = false
		setOptionalVisible(wrapsButtonContainer, true)

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

	grid = LockerGrid.new(itemGrid, itemGridTemplate, canUseHoverAnimations, {
		canInteract = function(): boolean
			return pendingShopAction == nil
		end,
		isItemOwned = isItemOwned,
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

			pendingShopAction = {
				kind = "equip",
				item = item,
			}
			grid:RefreshVisibleState(false)
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

	local function getOwnedWrapItems(items: { LockerCatalogItem }): { LockerCatalogItem }
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
		local ownedWrapItems = {} :: { LockerCatalogItem }

		for _, item in items do
			if isWrapOwnedForWeapon(targetWeaponCategory, targetWeaponId, item.ItemKey) then
				local wrapItem = table.clone(item)
				wrapItem.PreviewWeaponCategory = targetWeaponCategory
				wrapItem.PreviewWeaponKey = targetWeaponId
				wrapItem.PreviewWeaponName = targetWeaponName
				table.insert(ownedWrapItems, wrapItem)
			end
		end

		return ownedWrapItems
	end

	populateMainContentForNavItem = function(categoryKey: LockerCategoryKey, navKey: string, selectedItemId: string?)
		local previousNavKey = selectedNavKeyœ
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
		if categoryKey == "Arsenal" and navKey == "Wraps" then
			items = getOwnedWrapItems(items)
		end

		grid:Populate(items, preferredSelectedItemId)
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

		if activeWeaponMotionTweenByCategory[selectedCategory]
			or activeWeaponMotionConnectionByCategory[selectedCategory]
		then
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
			cashValueLabel.Text = tostring(stats.Cash)
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
	if purchaseButton and purchaseButton:IsA("GuiButton") then
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

			pendingShopAction = {
				kind = "buy",
				item = item,
			}

			local weaponCategory, weaponId = getWeaponSkinRequestContext(item.Category)

			Network.Shop.BuyItem.Send({
				itemId = item.ItemKey,
				category = item.Category,
				weaponCategory = weaponCategory,
				weaponId = weaponId,
			})
		end), "Disconnect")
	end

	if wrapsButton and wrapsButton:IsA("GuiButton") then
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

		if not response.success then
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
		menuGui.Enabled = visible
	end

	local function restoreLockerSceneState()
		destroyKillEffectsDummy()
		restoreEquippedWeaponPreviews()
		table.clear(lockedWeaponTemplateCache)
		cameraController:restore()
		setMenuVisibleInstant(true)
	end

	local function openLockerGui()
		if isOpen then
			return
		end

		isOpen = true
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
