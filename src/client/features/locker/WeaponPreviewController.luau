--!strict
-- WeaponPreviewController: gestiona los previews de armas (Main/Special) en el locker.
-- Encapsula clonación de templates, aplicación de wraps (con animación de scroll),
-- preview de armas bloqueadas (Highlight de bloqueo), motion de selección (rise + bob), y
-- transición down/up al cambiar de arma.
--
-- Los dos previews (Main y Special) NO tienen un sitio fijo: hay dos anclas por
-- ROL — la mesa (arma en foco) y la pared (arma en segundo plano) — y al cambiar
-- de categoría ambos previews intercambian ancla con un tween en arco. Por
-- defecto la Main está en la mesa.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local LockerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerConfig"))
local WeaponCategoryMod = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("WeaponCategory"))
local ItemDefaults = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemDefaults"))
local LockerCategory = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerCategory"))
local LockerMainCategory = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerMainCategory"))

local SELECTED_WEAPON_RISE_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SELECTED_WEAPON_RISE_HEIGHT = 0.28
local SELECTED_WEAPON_BOB_AMPLITUDE = 0.2
local SELECTED_WEAPON_BOB_SPEED = 0.3
local SELECTED_WEAPON_SWITCH_DOWN_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SELECTED_WEAPON_SWITCH_DOWN_STUDS = 0.05
-- Bloqueo por nivel: mismo contorno que el preview del personaje del lobby
-- (LobbyCharacterPreview) — relleno negro casi opaco + contorno blanco.
local LOCKED_HIGHLIGHT_NAME = "LockHighlight"
local LOCKED_FILL_COLOR = Color3.fromRGB(0, 0, 0)
local LOCKED_FILL_TRANSPARENCY = 0.1
local LOCKED_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local LOCKED_OUTLINE_TRANSPARENCY = 0.1
-- Intercambio mesa↔pared. El arco (subir a mitad de vuelo) evita que el arma
-- atraviese la mesa en línea recta y da sensación de "la cojo y la cuelgo".
local WEAPON_SWAP_TWEEN_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)
local WEAPON_SWAP_ARC_HEIGHT = 1.1

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
export type WeaponCategory = WeaponCategoryMod.WeaponCategory

export type LockerCatalogItem = {
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
}

export type LoadoutData = {
	[string]: any,
}

export type WeaponPreviewControllerOptions = {
	-- Anclas por ROL, no por arma: el arma en foco va a `tableSpawn` y la otra a
	-- `wallSpawn`; al cambiar de categoría se intercambian.
	tableSpawn: LockerPreviewSpawnTarget,
	wallSpawn: LockerPreviewSpawnTarget,
	sharedWeaponAssets: Instance,
	itemsConfig: any,
	getCurrentLevel: () -> number,
	getCurrentLoadout: () -> LoadoutData,
	getEquippedItemByCategory: (category: string) -> string?,
	isOwned: (category: string, itemId: string) -> boolean,
	-- Ownership per-weapon de un wrap (Inventory.WeaponWrapsByWeapon[cat][weaponId][wrapId]).
	-- Necesario para que la preview espeje la resolución del servidor: un wrap
	-- equipado en una entrada del Loadout (incluida la clave "Default") no debe
	-- propagarse a previews de armas que no lo poseen.
	ownsWeaponWrap: (weaponCategory: string, weaponId: string, wrapId: string) -> boolean,
}

export type WeaponPreviewController = {
	applySelected: (self: WeaponPreviewController, item: LockerCatalogItem?) -> (),
	setFocusCategory: (self: WeaponPreviewController, category: string?) -> (),
	applyWrapPreview: (self: WeaponPreviewController, weaponCategory: string, wrapId: string?) -> (),
	restoreEquipped: (self: WeaponPreviewController) -> (),
	restoreEquippedFor: (self: WeaponPreviewController, category: string) -> (),
	destroyAll: (self: WeaponPreviewController) -> (),
	updateFocusCategory: (
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

local WRAP_ORIGINAL_MATERIAL_ATTR = "WrapOriginalMaterial"

local function getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function getOptionalMaterial(value: any): Enum.Material?
	if typeof(value) == "EnumItem" and value.EnumType == Enum.Material then
		return value :: Enum.Material
	end
	return nil
end

-- Aplica/restaura el Material de la parte del arma. Recuerda el material
-- original la primera vez para poder volver a él cuando una skin no define
-- Material (el preview reutiliza la misma instancia al cambiar de wrap).
local function applyMaterialToPart(part: BasePart, material: Enum.Material?)
	if part:GetAttribute(WRAP_ORIGINAL_MATERIAL_ATTR) == nil then
		part:SetAttribute(WRAP_ORIGINAL_MATERIAL_ATTR, part.Material.Name)
	end

	if material then
		part.Material = material
		return
	end

	local originalName = part:GetAttribute(WRAP_ORIGINAL_MATERIAL_ATTR)
	if type(originalName) == "string" then
		local restored = (Enum.Material :: any)[originalName]
		if restored then
			part.Material = restored
		end
	end
end

local function isWeaponCategory(category: string): boolean
	return WeaponCategoryMod.isValid(category)
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

-- Mirror exacto de LoadoutService._resolveWeaponWrapForLoadout: equip es
-- estrictamente per-weapon. `wrapsTable.Default` es la slot del arma con id
-- "Default", no un fallback que se propaga. Un wrap global del BP otorga
-- ownership a todas las armas, pero equiparlo sigue siendo manual per-arma.
-- El check de ownership es defense-in-depth contra Loadout stale.
local function resolveWeaponWrap(
	loadout: LoadoutData,
	weaponCategory: WeaponCategory,
	weaponId: string?,
	ownsWeaponWrap: (weaponCategory: string, weaponId: string, wrapId: string) -> boolean
): string
	local normalizedWeaponId = getOptionalString(weaponId) or ItemDefaults.ITEM_ID
	local wrapsTableKey = if weaponCategory == WeaponCategoryMod.MAIN then "MainWeaponWraps" else "SpecialWeaponWraps"
	local wrapsTableAny = loadout[wrapsTableKey]
	if type(wrapsTableAny) == "table" then
		local wrapsTable = wrapsTableAny :: { [string]: string }
		local resolvedByWeapon = getOptionalString(wrapsTable[normalizedWeaponId])
		if resolvedByWeapon and ownsWeaponWrap(weaponCategory, normalizedWeaponId, resolvedByWeapon) then
			return resolvedByWeapon
		end
	end

	return ItemDefaults.ITEM_ID
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

	-- Pool persistente de CFrameValue + listener por categoría. Antes cada
	-- selección del locker (tap-tap-tap) alocaba 2× Instance.new("CFrameValue")
	-- + 2× GetPropertyChangedSignal:Connect (1 down + 1 rise). En browsing
	-- intensivo era GC pressure visible. Con el pool, el alloc ocurre 1 vez
	-- por categoría y el listener lee el preview target via _motionTargetByCategory.
	self._motionCFrameByCategory = {} :: { [string]: CFrameValue }
	self._motionTargetByCategory = {} :: { [string]: Instance }
	self._motionConnByCategory = {} :: { [string]: RBXScriptConnection }

	-- Categoría en la mesa (foco). El resto va a la pared.
	self._focusCategory = WeaponCategoryMod.MAIN :: WeaponCategory
	-- Driver del intercambio mesa↔pared, uno por categoría (mismo patrón que el
	-- CFrameValue del bob: cero allocs por cambio de nav).
	self._swapAlphaByCategory = {} :: { [string]: NumberValue }
	self._swapConnByCategory = {} :: { [string]: RBXScriptConnection }
	self._swapStateByCategory = {} :: {
		[string]: { preview: Instance, startPivot: CFrame, targetPivot: CFrame }
	}

	self._sharedHeartbeat = nil :: RBXScriptConnection?
	return self
end

function WeaponPreviewController:_ensureHeartbeat()
	if self._sharedHeartbeat then return end
	self._sharedHeartbeat = RunService.Heartbeat:Connect(function(dt)
		for _, data in self._wrapAnimDataByCategory do
			local tU, tV = data.tileU, data.tileV
			for _, texture in data.textures do
				if texture.Parent then
					texture.OffsetStudsU = (texture.OffsetStudsU + WEAPON_WRAP_TEXTURE_SCROLL_SPEED_U * dt) % tU
					texture.OffsetStudsV = (texture.OffsetStudsV + WEAPON_WRAP_TEXTURE_SCROLL_SPEED_V * dt) % tV
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

		if next(self._wrapAnimDataByCategory) == nil and next(self._motionDataByCategory) == nil then
			if self._sharedHeartbeat then
				self._sharedHeartbeat:Disconnect()
				self._sharedHeartbeat = nil
			end
		end
	end)
end

-- ── Métodos privados ───────────────────────────────────────────

function WeaponPreviewController:_getSpawnFor(category: string): LockerPreviewSpawnTarget?
	if not isWeaponCategory(category) then
		return nil
	end
	return if category == self._focusCategory then self._options.tableSpawn else self._options.wallSpawn
end

function WeaponPreviewController:_isLocked(category: WeaponCategory, itemId: string?): boolean
	if type(itemId) ~= "string" or itemId == "" then
		return false
	end

	if self._options.isOwned(category, itemId) then
		return false
	end

	local categoryConfig = self._options.itemsConfig[category]
	local definition = if type(categoryConfig) == "table" then categoryConfig[itemId] else nil
	local levelRequired = if type(definition) == "table" then tonumber(definition.LevelRequired) else nil
	if levelRequired and self._options.getCurrentLevel() < levelRequired then
		return true
	end

	return false
end

function WeaponPreviewController:_resolveTemplate(category: string, itemId: string?, itemName: string?): Instance?
	if not isWeaponCategory(category) then
		return nil
	end

	local categoryFolder = self._options.sharedWeaponAssets:FindFirstChild(category)
	if not categoryFolder then
		return nil
	end

	return (if itemId then categoryFolder:FindFirstChild(itemId) else nil)
		or (if itemName then categoryFolder:FindFirstChild(itemName) else nil)
		-- "Default" aquí es el nombre del Tool fallback en Locker.weapons.*; por convención
		-- coincide con el item-id default del catálogo, así que reusamos ItemDefaults.ITEM_ID.
		or categoryFolder:FindFirstChild(ItemDefaults.ITEM_ID)
end

function WeaponPreviewController:_getStateId(
	category: WeaponCategory,
	itemId: string?,
	previewId: string,
	isLocked: boolean?
): string
	if isLocked then
		return previewId .. "::locked"
	end
	local resolvedWeaponId = getOptionalString(itemId) or ItemDefaults.ITEM_ID
	local loadout = self._options.getCurrentLoadout()
	local resolvedWrapId = resolveWeaponWrap(loadout, category, resolvedWeaponId, self._options.ownsWeaponWrap)
	return previewId .. "::" .. resolvedWrapId .. "::unlocked"
end

-- El arma bloqueada conserva su geometría y materiales: el bloqueo lo marca un
-- Highlight, igual que el body y los hats del preview del lobby. El clone vive en
-- _lockedTemplateCache y nunca se reutiliza para el estado desbloqueado (ver
-- _getStateId), así que no hace falta quitar el Highlight en ningún punto.
function WeaponPreviewController:_applyLockedAppearance(previewInstance: Instance, weaponCategory: WeaponCategory)
	self._wrapAnimDataByCategory[weaponCategory] = nil

	local existing = previewInstance:FindFirstChild(LOCKED_HIGHLIGHT_NAME)
	local highlight: Highlight
	if existing and existing:IsA("Highlight") then
		highlight = existing
	else
		highlight = Instance.new("Highlight")
		highlight.Name = LOCKED_HIGHLIGHT_NAME
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = previewInstance
	end

	-- Adornee explícito: el template puede ser Model o BasePart suelto.
	if previewInstance:IsA("Model") or previewInstance:IsA("BasePart") then
		highlight.Adornee = previewInstance :: any
	end

	highlight.FillColor = LOCKED_FILL_COLOR
	highlight.FillTransparency = LOCKED_FILL_TRANSPARENCY
	highlight.OutlineColor = LOCKED_OUTLINE_COLOR
	highlight.OutlineTransparency = LOCKED_OUTLINE_TRANSPARENCY
	highlight.Enabled = true
end

function WeaponPreviewController:_applyWrap(previewInstance: Instance, weaponCategory: WeaponCategory, wrapId: string)
	local primaryPart = getWeaponPreviewPrimaryPart(previewInstance)
	if not primaryPart then
		return
	end

	self._wrapAnimDataByCategory[weaponCategory] = nil

	local wrapsConfig = self._options.itemsConfig.WeaponWraps
	local wrapDefinition = if type(wrapsConfig) == "table" then wrapsConfig[wrapId] else nil
	local validDef = type(wrapDefinition) == "table"
	local textureId = if validDef then getOptionalString(wrapDefinition.TextureID) else nil
	local baseColor = if validDef and typeof(wrapDefinition.BaseColor) == "Color3"
		then wrapDefinition.BaseColor
		else nil
	local material = if validDef then getOptionalMaterial(wrapDefinition.Material) else nil
	local studsPerTile = if validDef
		then math.max(0.01, tonumber(wrapDefinition.StudsPerTile) or DEFAULT_WRAP_STUDS_PER_TILE)
		else DEFAULT_WRAP_STUDS_PER_TILE
	local animated = validDef and wrapDefinition.isAnimated == true
	local animatedTextures = {} :: { Texture }

	-- Audit mobile: GetChildren() solo necesario al QUITAR un wrap (para
	-- destruir scroll textures viejas). Cuando se aplica un wrap nuevo
	-- iteramos directamente WEAPON_WRAP_TEXTURE_ORDER vía FindFirstChild,
	-- evitando la alocación de la tabla de GetChildren() en cada tap del
	-- locker browsing.
	if not textureId then
		for _, child in primaryPart:GetChildren() do
			if child:IsA("Texture") and string.sub(child.Name, 1, 14) == "ScrollTexture_" then
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

	applyMaterialToPart(primaryPart, material)

	if textureId and animated and #animatedTextures > 0 then
		local tileU = if studsPerTile > 0.001 then studsPerTile else 1
		local tileV = tileU
		self._wrapAnimDataByCategory[weaponCategory] = { textures = animatedTextures, tileU = tileU, tileV = tileV }
		self:_ensureHeartbeat()
	end
end

function WeaponPreviewController:_getOrCreateLockedTemplate(category: string, itemId: string?, itemName: string?): Instance?
	local resolvedKey = getOptionalString(itemId) or ItemDefaults.ITEM_ID
	local cacheKey = category .. "::" .. resolvedKey
	local cached = self._lockedTemplateCache[cacheKey]
	if cached then
		return cached
	end

	local weaponTemplate = self:_resolveTemplate(category, itemId, itemName)
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

	-- Un viaje mesa↔pared en curso manda sobre el bob. Sin esto, la repoblación de
	-- la nav (populateMainContentForNavItem → restoreEquippedWeaponPreviews) caía
	-- aquí justo después de arrancar el viaje, lo cancelaba y encima recolocaba el
	-- arma en su ancla nueva: el arma aparecía de golpe en el destino y no se veía
	-- el recorrido. El propio _travelToAnchor limpia su estado al terminar.
	if self._swapStateByCategory[category] then
		return
	end

	cancelTweenFromMap(self._activeMotionTweenByCategory, category)

	if restoreToBase ~= false then
		local activePreview = self._activePreviewByCategory[category]
		local basePivot = self._previewBasePivotByCategory[category]
		if activePreview and activePreview.Parent and basePivot then
			setWeaponPreviewPivot(activePreview, basePivot)
		end
	end
end

-- Devuelve el CFrameValue cacheado para la categoría (creándolo + conectando
-- el listener una sola vez por categoría). El listener lee
-- `_motionTargetByCategory[category]` cada update, así que cambiar el preview
-- activo no requiere reconectar.
function WeaponPreviewController:_ensureMotionDriver(category: string): CFrameValue
	local existing = self._motionCFrameByCategory[category]
	if existing then
		return existing
	end

	local cv = Instance.new("CFrameValue")
	cv.Name = "MotionCFrame_" .. category
	self._motionCFrameByCategory[category] = cv
	self._motionConnByCategory[category] = cv:GetPropertyChangedSignal("Value"):Connect(function()
		local target = self._motionTargetByCategory[category]
		if target and target.Parent then
			setWeaponPreviewPivot(target, cv.Value)
		end
	end)
	return cv
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

	self._motionTargetByCategory[category] = activePreview
	local cframeValue = self:_ensureMotionDriver(category)
	cframeValue.Value = startPivot

	local riseTween = TweenService:Create(cframeValue, SELECTED_WEAPON_RISE_TWEEN_INFO, {
		Value = liftPivot,
	})
	self._activeMotionTweenByCategory[category] = riseTween

	-- `:Once` auto-desconecta tras el primer fire (Completed se llama una vez,
	-- tanto en finalización natural como en :Cancel). Antes este Connect
	-- quedaba "vivo" hasta GC del closure capturado.
	riseTween.Completed:Once(function(playbackState)
		if self._activeMotionTweenByCategory[category] == riseTween then
			self._activeMotionTweenByCategory[category] = nil
		end

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
		self:_ensureHeartbeat()
	end)

	riseTween:Play()
end

-- Driver del intercambio: NumberValue 0→1 por categoría. En cada update lerpea
-- entre el ancla de salida y la de llegada, y añade el arco (sube a mitad de
-- vuelo). Cacheado por categoría igual que el CFrameValue del bob.
function WeaponPreviewController:_ensureSwapDriver(category: string): NumberValue
	local existing = self._swapAlphaByCategory[category]
	if existing then
		return existing
	end

	local alpha = Instance.new("NumberValue")
	alpha.Name = "SwapAlpha_" .. category
	self._swapAlphaByCategory[category] = alpha
	self._swapConnByCategory[category] = alpha:GetPropertyChangedSignal("Value"):Connect(function()
		local state = self._swapStateByCategory[category]
		if not state or not state.preview.Parent then
			return
		end
		local t = alpha.Value
		local pivot = state.startPivot:Lerp(state.targetPivot, t)
		local arc = math.sin(t * math.pi) * WEAPON_SWAP_ARC_HEIGHT
		setWeaponPreviewPivot(state.preview, pivot * CFrame.new(0, arc, 0))
	end)
	return alpha
end

-- Manda una categoría a su ancla actual (según el foco) con el tween de arco.
-- `focused` decide qué pasa al llegar: la de la mesa retoma el bob; la de la
-- pared se queda quieta en su sitio.
function WeaponPreviewController:_travelToAnchor(category: WeaponCategory, focused: boolean)
	local preview = self._activePreviewByCategory[category]
	local spawnTarget = self:_getSpawnFor(category)
	if not preview or not preview.Parent or not spawnTarget then
		return
	end

	local targetPivot = getSpawnPivot(spawnTarget)
	local startPivot = getWeaponPreviewPivot(preview) or targetPivot

	-- El ancla nueva pasa a ser la base: el bob y los restores posteriores
	-- (_stopMotion con restoreToBase) tienen que referirse ya al destino.
	self._previewBasePivotByCategory[category] = targetPivot

	-- Corta bob y cualquier tween en curso sin recolocar: seguimos desde donde
	-- esté el arma ahora mismo, que es lo que hace que un cambio de nav a media
	-- animación no dé saltos.
	self:_stopMotion(category, false)

	-- Invalida la transición de selección en vuelo (el down/up de applySelected):
	-- su Completed recolocaría el arma en el ancla vieja.
	self._selectionTransitionTokenByCategory[category] = (self._selectionTransitionTokenByCategory[category] or 0) + 1

	self._swapStateByCategory[category] = {
		preview = preview,
		startPivot = startPivot,
		targetPivot = targetPivot,
	}

	local alpha = self:_ensureSwapDriver(category)
	alpha.Value = 0
	local swapTween = TweenService:Create(alpha, WEAPON_SWAP_TWEEN_INFO, { Value = 1 })
	self._activeMotionTweenByCategory[category] = swapTween

	swapTween.Completed:Once(function(playbackState)
		if self._activeMotionTweenByCategory[category] == swapTween then
			self._activeMotionTweenByCategory[category] = nil
		end
		self._swapStateByCategory[category] = nil

		-- El preview puede haberse reconstruido durante el viaje (cambio de arma o
		-- de wrap a media animación), así que se lee el vivo, no el capturado.
		local arrived = self._activePreviewByCategory[category]
		if playbackState ~= Enum.PlaybackState.Completed or not arrived or not arrived.Parent then
			return
		end

		if focused then
			self:_startMotion(category)
		else
			setWeaponPreviewPivot(arrived, self._previewBasePivotByCategory[category] or targetPivot)
		end
	end)

	swapTween:Play()
end

--- Pone `category` en la mesa y la otra en la pared. No-op si ya es la del foco.
--- `nil` (fuera de la vista de armas) mantiene el reparto actual.
function WeaponPreviewController:setFocusCategory(category: string?)
	if not category or not isWeaponCategory(category) then
		return
	end

	local nextFocus = category :: WeaponCategory
	if self._focusCategory == nextFocus then
		return
	end

	self._focusCategory = nextFocus
	local other = if nextFocus == WeaponCategoryMod.MAIN then WeaponCategoryMod.SPECIAL else WeaponCategoryMod.MAIN
	self:_travelToAnchor(nextFocus, true)
	self:_travelToAnchor(other, false)
end

function WeaponPreviewController:_applyForCategory(category: string, itemId: string?, itemName: string?, previewId: string)
	if not isWeaponCategory(category) then
		return
	end

	local previewCategory = category :: WeaponCategory
	local previewLocked = self:_isLocked(previewCategory, itemId)
	local previewStateId = self:_getStateId(previewCategory, itemId, previewId, previewLocked)

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
		local lockedTemplate = self:_getOrCreateLockedTemplate(category, itemId, itemName)
		if not lockedTemplate then
			return
		end
		clonedWeapon = lockedTemplate:Clone()
	else
		local weaponTemplate = self:_resolveTemplate(category, itemId, itemName)
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
		local resolvedWeaponId = getOptionalString(itemId) or ItemDefaults.ITEM_ID
		local loadout = self._options.getCurrentLoadout()
		local resolvedWrapId = resolveWeaponWrap(loadout, previewCategory, resolvedWeaponId, self._options.ownsWeaponWrap)
		self:_applyWrap(clonedWeapon, previewCategory, resolvedWrapId)
	end

	self._activePreviewByCategory[category] = clonedWeapon
	self._activePreviewItemIdByCategory[category] = previewStateId

	-- Si el arma está a mitad de viaje mesa↔pared, el clone nuevo hereda el viaje:
	-- si no, se quedaría clavado en el ancla mientras el driver sigue moviendo al
	-- que acaba de morir.
	local swapState = self._swapStateByCategory[category]
	if swapState then
		swapState.preview = clonedWeapon
	end
end

-- ── API pública ────────────────────────────────────────────────

function WeaponPreviewController:restoreEquippedFor(category: string)
	if not isWeaponCategory(category) then
		return
	end

	local equippedItemId = self._options.getEquippedItemByCategory(category) or ItemDefaults.ITEM_ID

	local categoryConfig = self._options.itemsConfig[category]
	local definition = if type(categoryConfig) == "table" then categoryConfig[equippedItemId] else nil
	local resolvedName = if type(definition) == "table" then tostring(definition.Name or equippedItemId) else equippedItemId
	local previewId = LockerConfig.makeQualifiedId(category, equippedItemId)
	self:_applyForCategory(category, equippedItemId, resolvedName, previewId)

	-- Restaurar el wrap del loadout sobre el preview activo (cancela cualquier
	-- preview de wrap no equipado que hubiera quedado por la última selección).
	local previewCategory = category :: WeaponCategory
	if not self:_isLocked(previewCategory, equippedItemId) then
		local activePreview = self._activePreviewByCategory[category]
		if activePreview and activePreview.Parent then
			local loadout = self._options.getCurrentLoadout()
			local equippedWrapId = resolveWeaponWrap(loadout, previewCategory, equippedItemId, self._options.ownsWeaponWrap)
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

	local resolvedWrapId = getOptionalString(wrapId) or ItemDefaults.ITEM_ID
	self:_applyWrap(activePreview, previewCategory, resolvedWrapId)
end

function WeaponPreviewController:restoreEquipped()
	self:_stopMotion(WeaponCategoryMod.MAIN, true)
	self:_stopMotion(WeaponCategoryMod.SPECIAL, true)
	self:restoreEquippedFor(WeaponCategoryMod.MAIN)
	self:restoreEquippedFor(WeaponCategoryMod.SPECIAL)
end

function WeaponPreviewController:applySelected(item: LockerCatalogItem?)
	if item and item.Category == LockerCategory.WEAPON_WRAPS then
		local previewCategory = item.PreviewWeaponCategory
		if previewCategory and isWeaponCategory(previewCategory) then
			self:applyWrapPreview(previewCategory, item.id)
		end
		return
	end

	if not item or not isWeaponCategory(item.Category) then
		self:restoreEquipped()
		return
	end

	local selectedCategory = item.Category :: WeaponCategory
	if selectedCategory == WeaponCategoryMod.MAIN then
		self:_stopMotion(WeaponCategoryMod.SPECIAL, true)
	else
		self:_stopMotion(WeaponCategoryMod.MAIN, true)
	end

	local selectedLocked = self:_isLocked(selectedCategory, item.id)
	local desiredPreviewStateId = self:_getStateId(selectedCategory, item.id, item.qualifiedId, selectedLocked)
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

	-- Con un viaje mesa↔pared en curso no se hace el down/up de selección: el arma
	-- ya se está moviendo y su clone nuevo hereda el viaje (_applyForCategory). Sin
	-- esto, el down tween pisaría la referencia del tween de viaje y quedarían dos
	-- drivers moviendo la misma arma.
	if self._swapStateByCategory[selectedCategory] then
		self:_applyForCategory(item.Category, item.id, item.Name, item.qualifiedId)
		return
	end

	local nextTransitionToken = (self._selectionTransitionTokenByCategory[selectedCategory] or 0) + 1
	self._selectionTransitionTokenByCategory[selectedCategory] = nextTransitionToken

	local currentBasePivot = self._previewBasePivotByCategory[selectedCategory]
	if not currentPreview or not currentPreview.Parent or not currentBasePivot then
		self:_applyForCategory(item.Category, item.id, item.Name, item.qualifiedId)
		self:_startMotion(selectedCategory, -SELECTED_WEAPON_SWITCH_DOWN_STUDS)
		return
	end

	self:_stopMotion(selectedCategory, false)

	local downPivot = currentBasePivot * CFrame.new(0, -SELECTED_WEAPON_SWITCH_DOWN_STUDS, 0)
	local startPivot = getWeaponPreviewPivot(currentPreview) or currentBasePivot

	-- Reusa el CFrameValue + listener cacheado por categoría. Antes 1 alloc
	-- + 1 conexión efímera por click; ahora cero allocs (el listener leerá
	-- _motionTargetByCategory[selectedCategory] = currentPreview).
	self._motionTargetByCategory[selectedCategory] = currentPreview
	local cframeValue = self:_ensureMotionDriver(selectedCategory)
	cframeValue.Value = startPivot

	local downTween = TweenService:Create(cframeValue, SELECTED_WEAPON_SWITCH_DOWN_TWEEN_INFO, {
		Value = downPivot,
	})
	self._activeMotionTweenByCategory[selectedCategory] = downTween

	downTween.Completed:Once(function(playbackState)
		if self._activeMotionTweenByCategory[selectedCategory] == downTween then
			self._activeMotionTweenByCategory[selectedCategory] = nil
		end

		if playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		if self._selectionTransitionTokenByCategory[selectedCategory] ~= nextTransitionToken then
			return
		end

		self:_applyForCategory(item.Category, item.id, item.Name, item.qualifiedId)

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
	self:_destroyForCategory(WeaponCategoryMod.MAIN)
	self:_destroyForCategory(WeaponCategoryMod.SPECIAL)
	-- Sin previews en el mundo el reparto vuelve al de arranque: Main en la mesa.
	self._focusCategory = WeaponCategoryMod.MAIN
	table.clear(self._swapStateByCategory)
end

--- Deriva de la navegación qué categoría de arma está en foco y la manda a la
--- mesa (la otra se va a la pared).
function WeaponPreviewController:updateFocusCategory(
	selectedMainCategory: string?,
	selectedNavKey: string?,
	wrapsTargetWeaponCategory: WeaponCategory
)
	local activeWeaponCategory: WeaponCategory? = nil
	if selectedMainCategory == LockerMainCategory.ARSENAL then
		if WeaponCategoryMod.isValid(selectedNavKey) then
			activeWeaponCategory = selectedNavKey :: WeaponCategory
		elseif selectedNavKey == LockerCategory.WEAPON_WRAPS then
			activeWeaponCategory = wrapsTargetWeaponCategory
		end
	end

	self:setFocusCategory(activeWeaponCategory)
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
	for _, conn in self._motionConnByCategory do
		conn:Disconnect()
	end
	for _, conn in self._swapConnByCategory do
		conn:Disconnect()
	end
	for _, cv in self._motionCFrameByCategory do
		cv:Destroy()
	end
	for _, alpha in self._swapAlphaByCategory do
		alpha:Destroy()
	end
	table.clear(self._swapConnByCategory)
	table.clear(self._swapAlphaByCategory)
	table.clear(self._swapStateByCategory)
	table.clear(self._motionConnByCategory)
	table.clear(self._motionCFrameByCategory)
	table.clear(self._motionTargetByCategory)
	table.clear(self._wrapAnimDataByCategory)
	table.clear(self._motionDataByCategory)
	table.clear(self._activeMotionTweenByCategory)
	-- Destruir los clones cacheados (parented a nil) antes de soltar la tabla, en
	-- vez de solo table.clear, para liberarlos de inmediato al teardown.
	for _, clone in self._lockedTemplateCache do
		clone:Destroy()
	end
	table.clear(self._lockedTemplateCache)
end

return WeaponPreviewController
