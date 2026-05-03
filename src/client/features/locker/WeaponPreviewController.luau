--!strict
-- WeaponPreviewController: gestiona los previews de armas (Main/Special) en el locker.
-- Encapsula clonación de templates, aplicación de wraps (con animación de scroll),
-- preview de armas bloqueadas (negro neón), motion de selección (rise + bob), y
-- transición down/up al cambiar de arma.

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local SELECTED_WEAPON_RISE_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SELECTED_WEAPON_RISE_HEIGHT = 0.28
local SELECTED_WEAPON_BOB_AMPLITUDE = 0.2
local SELECTED_WEAPON_BOB_SPEED = 0.3
local SELECTED_WEAPON_SWITCH_DOWN_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SELECTED_WEAPON_SWITCH_DOWN_STUDS = 0.05
local LOCKED_WEAPON_PREVIEW_COLOR = Color3.fromRGB(0, 0, 0)
local DEFAULT_WRAP_STUDS_PER_TILE = 3
local WEAPON_WRAP_TEXTURE_SCROLL_SPEED_U = 1
local WEAPON_WRAP_TEXTURE_SCROLL_SPEED_V = 0

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

export type LockerPreviewSpawnTarget = Folder | Model | BasePart
export type WeaponCategory = "Main" | "Special"

export type LockerCatalogItem = {
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

export type LoadoutData = {
	[string]: any,
}

export type WeaponPreviewControllerOptions = {
	mainWeaponSpawn: LockerPreviewSpawnTarget,
	specialWeaponSpawn: LockerPreviewSpawnTarget,
	sharedWeaponAssets: Instance,
	mainIndicator: Instance?,
	specialIndicator: Instance?,
	itemsConfig: any,
	getCurrentLevel: () -> number,
	getCurrentLoadout: () -> LoadoutData,
	getEquippedItemByCategory: (category: string) -> string?,
	isOwned: (category: string, itemKey: string) -> boolean,
}

export type WeaponPreviewController = {
	applySelected: (self: WeaponPreviewController, item: LockerCatalogItem?) -> (),
	applyWrapPreview: (self: WeaponPreviewController, weaponCategory: string, wrapId: string?) -> (),
	restoreEquipped: (self: WeaponPreviewController) -> (),
	restoreEquippedFor: (self: WeaponPreviewController, category: string) -> (),
	destroyAll: (self: WeaponPreviewController) -> (),
	updateIndicators: (
		self: WeaponPreviewController,
		selectedMainCategory: string?,
		selectedNavKey: string?,
		wrapsTargetWeaponCategory: WeaponCategory
	) -> (),
	Destroy: (self: WeaponPreviewController) -> (),
}

local WeaponPreviewController = {}
WeaponPreviewController.__index = WeaponPreviewController

-- ── Helpers internos ──────────────────────────────────────────

local function getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function isWeaponCategory(category: string): boolean
	return category == "Main" or category == "Special"
end

local function getSpawnPivot(spawnTarget: LockerPreviewSpawnTarget): CFrame
	if spawnTarget:IsA("BasePart") then
		return spawnTarget.CFrame
	end
	return spawnTarget:GetPivot()
end

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

local function cancelTweenFromMap(map: { [any]: Tween }, key: any)
	local tw = map[key]
	if tw then
		tw:Cancel()
		map[key] = nil
	end
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

-- ── Constructor ────────────────────────────────────────────────

function WeaponPreviewController.new(options: WeaponPreviewControllerOptions): WeaponPreviewController
	local self = setmetatable({}, WeaponPreviewController) :: any
	self._options = options
	self._activePreviewByCategory = {} :: { [string]: Instance }
	self._activePreviewItemIdByCategory = {} :: { [string]: string }
	self._activeMotionTweenByCategory = {} :: { [string]: Tween }
	self._selectionTransitionTokenByCategory = {} :: { [string]: number }
	self._previewBasePivotByCategory = {} :: { [string]: CFrame }
	self._lockedTemplateCache = {} :: { [string]: Instance }

	-- Datos por categoría para el Heartbeat compartido (en vez de un Connect por
	-- categoría × tipo de animación).
	self._wrapAnimDataByCategory = {} :: { [string]: { textures: { Texture } } }
	self._motionDataByCategory = {} :: {
		[string]: { activePreview: Instance, basePivot: CFrame, elapsed: number }
	}

	-- Un único Heartbeat compartido para todas las animaciones del preview.
	self._sharedHeartbeat = RunService.Heartbeat:Connect(function(dt)
		for _, data in self._wrapAnimDataByCategory do
			for _, texture in data.textures do
				if texture.Parent then
					local tileU = if texture.StudsPerTileU ~= 0 then texture.StudsPerTileU else 1
					local tileV = if texture.StudsPerTileV ~= 0 then texture.StudsPerTileV else 1
					texture.OffsetStudsU = (texture.OffsetStudsU + WEAPON_WRAP_TEXTURE_SCROLL_SPEED_U * dt) % tileU
					texture.OffsetStudsV = (texture.OffsetStudsV + WEAPON_WRAP_TEXTURE_SCROLL_SPEED_V * dt) % tileV
				end
			end
		end
		for category, data in self._motionDataByCategory do
			if not data.activePreview.Parent then
				self._motionDataByCategory[category] = nil
				continue
			end
			data.elapsed += dt
			local bobY = SELECTED_WEAPON_RISE_HEIGHT
				+ math.sin(data.elapsed * SELECTED_WEAPON_BOB_SPEED * math.pi * 2) * SELECTED_WEAPON_BOB_AMPLITUDE
			setWeaponPreviewPivot(data.activePreview, data.basePivot * CFrame.new(0, bobY, 0))
		end
	end)
	return self
end

-- ── Métodos privados ───────────────────────────────────────────

function WeaponPreviewController:_getSpawnFor(category: string): LockerPreviewSpawnTarget?
	if category == "Main" then
		return self._options.mainWeaponSpawn
	elseif category == "Special" then
		return self._options.specialWeaponSpawn
	end
	return nil
end

function WeaponPreviewController:_isLocked(category: WeaponCategory, itemKey: string?): boolean
	if type(itemKey) ~= "string" or itemKey == "" then
		return false
	end

	if self._options.isOwned(category, itemKey) then
		return false
	end

	local categoryConfig = self._options.itemsConfig[category]
	local definition = if type(categoryConfig) == "table" then categoryConfig[itemKey] else nil
	local levelRequired = if type(definition) == "table" then tonumber(definition.LevelRequired) else nil
	if levelRequired and self._options.getCurrentLevel() < levelRequired then
		return true
	end

	return false
end

function WeaponPreviewController:_resolveTemplate(category: string, itemKey: string?, itemName: string?): Instance?
	if not isWeaponCategory(category) then
		return nil
	end

	local categoryFolder = self._options.sharedWeaponAssets:FindFirstChild(category)
	if not categoryFolder then
		return nil
	end

	return (if itemKey then categoryFolder:FindFirstChild(itemKey) else nil)
		or (if itemName then categoryFolder:FindFirstChild(itemName) else nil)
		or categoryFolder:FindFirstChild("Default")
end

function WeaponPreviewController:_getStateId(
	category: WeaponCategory,
	itemKey: string?,
	previewId: string,
	locked: boolean?
): string
	if locked then
		return previewId .. "::locked"
	end
	local resolvedWeaponKey = getOptionalString(itemKey) or "Default"
	local loadout = self._options.getCurrentLoadout()
	local resolvedWrapId = resolveWeaponWrap(loadout, category, resolvedWeaponKey)
	return previewId .. "::" .. resolvedWrapId .. "::unlocked"
end

function WeaponPreviewController:_applyLockedAppearance(previewInstance: Instance, weaponCategory: WeaponCategory)
	self._wrapAnimDataByCategory[weaponCategory] = nil

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

function WeaponPreviewController:_applyWrap(previewInstance: Instance, weaponCategory: WeaponCategory, wrapId: string)
	local primaryPart = getWeaponPreviewPrimaryPart(previewInstance)
	if not primaryPart then
		return
	end

	self._wrapAnimDataByCategory[weaponCategory] = nil

	local wrapsConfig = self._options.itemsConfig.WeaponSkins
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
		self._wrapAnimDataByCategory[weaponCategory] = { textures = animatedTextures }
	end
end

function WeaponPreviewController:_getOrCreateLockedTemplate(category: string, itemKey: string?, itemName: string?): Instance?
	local resolvedKey = getOptionalString(itemKey) or "Default"
	local cacheKey = category .. "::" .. resolvedKey
	local cached = self._lockedTemplateCache[cacheKey]
	if cached then
		return cached
	end

	local weaponTemplate = self:_resolveTemplate(category, itemKey, itemName)
	if not weaponTemplate then
		return nil
	end

	local processedClone = weaponTemplate:Clone()
	self:_applyLockedAppearance(processedClone, category :: WeaponCategory)
	self._lockedTemplateCache[cacheKey] = processedClone
	return processedClone
end

function WeaponPreviewController:_destroyForCategory(category: string)
	self:_stopMotion(category, false)
	self._wrapAnimDataByCategory[category] = nil

	local activePreview = self._activePreviewByCategory[category]
	if activePreview and activePreview.Parent then
		activePreview:Destroy()
	end

	self._activePreviewByCategory[category] = nil
	self._activePreviewItemIdByCategory[category] = nil
	self._previewBasePivotByCategory[category] = nil
end

function WeaponPreviewController:_stopMotion(category: string, restoreToBase: boolean?)
	self._motionDataByCategory[category] = nil
	cancelTweenFromMap(self._activeMotionTweenByCategory, category)

	if restoreToBase ~= false then
		local activePreview = self._activePreviewByCategory[category]
		local basePivot = self._previewBasePivotByCategory[category]
		if activePreview and activePreview.Parent and basePivot then
			setWeaponPreviewPivot(activePreview, basePivot)
		end
	end
end

function WeaponPreviewController:_startMotion(category: WeaponCategory, startOffsetY: number?)
	local hasExplicitStartOffset = type(startOffsetY) == "number"
	self:_stopMotion(category, not hasExplicitStartOffset)

	local activePreview = self._activePreviewByCategory[category]
	local basePivot = self._previewBasePivotByCategory[category]
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
	self._activeMotionTweenByCategory[category] = riseTween

	riseTween.Completed:Connect(function(playbackState)
		if self._activeMotionTweenByCategory[category] == riseTween then
			self._activeMotionTweenByCategory[category] = nil
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

		self._motionDataByCategory[category] = {
			activePreview = activePreview,
			basePivot = basePivot,
			elapsed = 0,
		}
	end)

	riseTween:Play()
end

function WeaponPreviewController:_applyForCategory(category: string, itemKey: string?, itemName: string?, previewId: string)
	if not isWeaponCategory(category) then
		return
	end

	local previewCategory = category :: WeaponCategory
	local previewLocked = self:_isLocked(previewCategory, itemKey)
	local previewStateId = self:_getStateId(previewCategory, itemKey, previewId, previewLocked)

	local spawnTarget = self:_getSpawnFor(category)
	if not spawnTarget then
		return
	end

	if self._activePreviewByCategory[category]
		and self._activePreviewByCategory[category].Parent
		and self._activePreviewItemIdByCategory[category] == previewStateId
	then
		return
	end

	self:_destroyForCategory(category)

	local clonedWeapon: Instance
	if previewLocked then
		local lockedTemplate = self:_getOrCreateLockedTemplate(category, itemKey, itemName)
		if not lockedTemplate then
			return
		end
		clonedWeapon = lockedTemplate:Clone()
	else
		local weaponTemplate = self:_resolveTemplate(category, itemKey, itemName)
		if not weaponTemplate then
			return
		end
		clonedWeapon = weaponTemplate:Clone()
	end

	clonedWeapon.Name = category .. "WeaponPreview"
	clonedWeapon.Parent = spawnTarget :: Instance
	setWeaponPreviewPivot(clonedWeapon, getSpawnPivot(spawnTarget))
	local basePivot = getWeaponPreviewPivot(clonedWeapon)
	if basePivot then
		self._previewBasePivotByCategory[category] = basePivot
	end
	if not previewLocked then
		local resolvedWeaponKey = getOptionalString(itemKey) or "Default"
		local loadout = self._options.getCurrentLoadout()
		local resolvedWrapId = resolveWeaponWrap(loadout, previewCategory, resolvedWeaponKey)
		self:_applyWrap(clonedWeapon, previewCategory, resolvedWrapId)
	end

	self._activePreviewByCategory[category] = clonedWeapon
	self._activePreviewItemIdByCategory[category] = previewStateId
end

-- ── API pública ────────────────────────────────────────────────

function WeaponPreviewController:restoreEquippedFor(category: string)
	if not isWeaponCategory(category) then
		return
	end

	local equippedItemKey = self._options.getEquippedItemByCategory(category) or "Default"

	local categoryConfig = self._options.itemsConfig[category]
	local definition = if type(categoryConfig) == "table" then categoryConfig[equippedItemKey] else nil
	local resolvedName = if type(definition) == "table" then tostring(definition.Name or equippedItemKey) else equippedItemKey
	local previewId = category .. "." .. equippedItemKey
	self:_applyForCategory(category, equippedItemKey, resolvedName, previewId)

	-- Restaurar el wrap del loadout sobre el preview activo (cancela cualquier
	-- preview de wrap no equipado que hubiera quedado por la última selección).
	local previewCategory = category :: WeaponCategory
	if not self:_isLocked(previewCategory, equippedItemKey) then
		local activePreview = self._activePreviewByCategory[category]
		if activePreview and activePreview.Parent then
			local loadout = self._options.getCurrentLoadout()
			local equippedWrapId = resolveWeaponWrap(loadout, previewCategory, equippedItemKey)
			self:_applyWrap(activePreview, previewCategory, equippedWrapId)
		end
	end
end

function WeaponPreviewController:applyWrapPreview(weaponCategory: string, wrapId: string?)
	if not isWeaponCategory(weaponCategory) then
		return
	end

	local previewCategory = weaponCategory :: WeaponCategory
	local activePreview = self._activePreviewByCategory[weaponCategory]
	if not activePreview or not activePreview.Parent then
		return
	end

	local resolvedWrapId = getOptionalString(wrapId) or "Default"
	self:_applyWrap(activePreview, previewCategory, resolvedWrapId)
end

function WeaponPreviewController:restoreEquipped()
	self:_stopMotion("Main", true)
	self:_stopMotion("Special", true)
	self:restoreEquippedFor("Main")
	self:restoreEquippedFor("Special")
end

function WeaponPreviewController:applySelected(item: LockerCatalogItem?)
	if item and item.Category == "WeaponSkins" then
		local previewCategory = item.PreviewWeaponCategory
		if previewCategory and isWeaponCategory(previewCategory) then
			self:applyWrapPreview(previewCategory, item.ItemKey)
		end
		return
	end

	if not item or not isWeaponCategory(item.Category) then
		self:restoreEquipped()
		return
	end

	local selectedCategory = item.Category :: WeaponCategory
	if selectedCategory == "Main" then
		self:_stopMotion("Special", true)
	else
		self:_stopMotion("Main", true)
	end

	local selectedLocked = self:_isLocked(selectedCategory, item.ItemKey)
	local desiredPreviewStateId = self:_getStateId(selectedCategory, item.ItemKey, item.Id, selectedLocked)
	local activePreviewStateId = self._activePreviewItemIdByCategory[selectedCategory]
	local currentPreview = self._activePreviewByCategory[selectedCategory]
	if currentPreview
		and currentPreview.Parent
		and activePreviewStateId == desiredPreviewStateId
	then
		if not self._motionDataByCategory[selectedCategory]
			and not self._activeMotionTweenByCategory[selectedCategory]
		then
			self:_startMotion(selectedCategory, -SELECTED_WEAPON_SWITCH_DOWN_STUDS)
		end
		return
	end

	local nextTransitionToken = (self._selectionTransitionTokenByCategory[selectedCategory] or 0) + 1
	self._selectionTransitionTokenByCategory[selectedCategory] = nextTransitionToken

	local currentBasePivot = self._previewBasePivotByCategory[selectedCategory]
	if not currentPreview or not currentPreview.Parent or not currentBasePivot then
		self:_applyForCategory(item.Category, item.ItemKey, item.Name, item.Id)
		self:_startMotion(selectedCategory, -SELECTED_WEAPON_SWITCH_DOWN_STUDS)
		return
	end

	self:_stopMotion(selectedCategory, false)

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
	self._activeMotionTweenByCategory[selectedCategory] = downTween

	downTween.Completed:Connect(function(playbackState)
		if self._activeMotionTweenByCategory[selectedCategory] == downTween then
			self._activeMotionTweenByCategory[selectedCategory] = nil
		end

		if valueChangedConnection then
			valueChangedConnection:Disconnect()
			valueChangedConnection = nil
		end

		cframeValue:Destroy()

		if playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		if self._selectionTransitionTokenByCategory[selectedCategory] ~= nextTransitionToken then
			return
		end

		self:_applyForCategory(item.Category, item.ItemKey, item.Name, item.Id)

		local nextPreview = self._activePreviewByCategory[selectedCategory]
		local nextBasePivot = self._previewBasePivotByCategory[selectedCategory]
		if nextPreview and nextPreview.Parent and nextBasePivot then
			setWeaponPreviewPivot(nextPreview, nextBasePivot * CFrame.new(0, -SELECTED_WEAPON_SWITCH_DOWN_STUDS, 0))
			self:_startMotion(selectedCategory, -SELECTED_WEAPON_SWITCH_DOWN_STUDS)
		else
			self:_startMotion(selectedCategory)
		end
	end)

	downTween:Play()
end

function WeaponPreviewController:isMotionActive(category: string): boolean
	return self._activeMotionTweenByCategory[category] ~= nil
		or self._motionDataByCategory[category] ~= nil
end

function WeaponPreviewController:destroyAll()
	self:_destroyForCategory("Main")
	self:_destroyForCategory("Special")
end

function WeaponPreviewController:updateIndicators(
	selectedMainCategory: string?,
	selectedNavKey: string?,
	wrapsTargetWeaponCategory: WeaponCategory
)
	local mainIndicator = self._options.mainIndicator
	local specialIndicator = self._options.specialIndicator
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

	(mainIndicator :: BasePart).LocalTransparencyModifier = if activeWeaponCategory == "Main" then 0 else 1
	(specialIndicator :: BasePart).LocalTransparencyModifier = if activeWeaponCategory == "Special" then 0 else 1
end

function WeaponPreviewController:Destroy()
	self:destroyAll()
	if self._sharedHeartbeat then
		self._sharedHeartbeat:Disconnect()
		self._sharedHeartbeat = nil
	end
	for _, tween in self._activeMotionTweenByCategory do
		tween:Cancel()
	end
	table.clear(self._wrapAnimDataByCategory)
	table.clear(self._motionDataByCategory)
	table.clear(self._activeMotionTweenByCategory)
	table.clear(self._lockedTemplateCache)
end

return WeaponPreviewController
