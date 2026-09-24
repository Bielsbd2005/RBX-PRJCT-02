--!strict
-- Preview del arma en el locker: clonado de templates, wraps (WeaponWrapPainter),
-- Highlight de bloqueo y animaciones de entrada/salida/idle.
--
-- Hay un solo ancla (Workspace.Locker.WeaponSpawn) y en ella solo se ve el arma de
-- la categoría en foco. Se recuerda qué toca mostrar en cada categoría, así que al
-- cambiar de foco o de arma la actual sale encogiendo y la nueva entra con un pop.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LockerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerConfig"))
local WeaponCategoryMod = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("WeaponCategory"))
local ItemDefaults = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemDefaults"))
local WeaponWrapPainter = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("WeaponWrapPainter"))
local LoadoutWraps = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("data"):WaitForChild("LoadoutWraps"))
local LockerCategory = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerCategory"))
local LockerMainCategory = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("LockerMainCategory"))
local Client = script.Parent.Parent.Parent

local LockerUtils = require(script.Parent.LockerUtils)
local PreviewHighlightPanels = require(Client.core.ui.PreviewHighlightPanels)

-- Entrada: pop de escala con overshoot + un giro completo que frena + sube desde abajo.
local ENTER_TIME = 0.55
local ENTER_DELAY_AFTER_EXIT = 0.07
local ENTER_OVERSHOOT = 2.4
local ENTER_SPIN = -math.pi * 2
local ENTER_DROP = 0.9
-- Salida: encoge hacia dentro girando y subiendo un poco.
local EXIT_TIME = 0.16
local EXIT_SPIN = math.pi * 0.6
local EXIT_RISE = 0.35
-- Re-clic / equipar el arma que ya se ve: rebote de escala amortiguado.
local PUNCH_TIME = 0.4
local PUNCH_AMPLITUDE = 0.14
-- Idle: flota, sube y baja, y se balancea a los lados.
local HOVER_HEIGHT = 0.28
local BOB_AMPLITUDE = 0.2
local BOB_HZ = 0.3
local SWAY_ANGLE = math.rad(14)
local SWAY_HZ = 0.12
-- Model:ScaleTo no admite 0.
local MIN_SCALE = 0.02

-- Bloqueo por nivel: mismo contorno que LobbyCharacterPreview.
local LOCKED_HIGHLIGHT_NAME = "LockHighlight"
local LOCKED_FILL_COLOR = Color3.fromRGB(0, 0, 0)
local LOCKED_FILL_TRANSPARENCY = 0.1
local LOCKED_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local LOCKED_OUTLINE_TRANSPARENCY = 0.1

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
	weaponSpawn: LockerPreviewSpawnTarget?,
	sharedWeaponAssets: Instance,
	itemsConfig: any,
	getCurrentLevel: () -> number,
	getCurrentLoadout: () -> LoadoutData,
	getEquippedItemByCategory: (category: string) -> string?,
	isOwned: (category: string, itemId: string) -> boolean,
	-- Ownership per-weapon de un wrap, para espejar la resolución del servidor: un
	-- wrap equipado en una entrada del Loadout (incluida "Default") no se propaga a
	-- armas que no lo poseen.
	ownsWeaponWrap: (weaponCategory: string, weaponId: string, wrapId: string) -> boolean,
	-- PlayerGui.UserInterface: sus paneles apagan los contornos de los previews
	-- (ver PreviewHighlightPanels).
	uiGui: Instance?,
}

export type WeaponPreviewController = {
	applySelected: (self: WeaponPreviewController, item: LockerCatalogItem?, animate: boolean?) -> (),
	setUserYaw: (self: WeaponPreviewController, yaw: number) -> (),
	setFocusCategory: (self: WeaponPreviewController, category: string?) -> (),
	applyWrapPreview: (self: WeaponPreviewController, weaponCategory: string, wrapId: string?, animate: boolean?) -> (),
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

type Desired = { itemId: string?, itemName: string?, previewId: string }

-- Un arma en el mundo. `t` cuenta desde la entrada (negativo = aún esperando a que
-- salga la anterior); `idleT` desde que acabó la entrada.
type LivePreview = {
	instance: Instance,
	category: string,
	previewId: string,
	stateId: string,
	locked: boolean,
	basePivot: CFrame,
	baseScale: number,
	t: number,
	idleT: number,
	punchT: number?,
	exitT: number?,
	exitFromY: number,
	exitFromYaw: number,
}

local WeaponPreviewController = {}
WeaponPreviewController.__index = WeaponPreviewController

local function getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
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

local function setWeaponPreviewPivot(previewInstance: Instance, pivot: CFrame)
	if previewInstance:IsA("Model") then
		previewInstance:PivotTo(pivot)
	elseif previewInstance:IsA("BasePart") then
		previewInstance.CFrame = pivot
	end
end

-- El preview se mueve sólo con PivotTo, así que tiene que estar anclado: los modelos
-- generados desde la Tool vienen desanclados y sin soldar. Se hace sobre el clone
-- para no depender de cómo venga el asset.
local function anchorWeaponPreview(previewInstance: Instance)
	if previewInstance:IsA("BasePart") then
		previewInstance.Anchored = true
		previewInstance.CanCollide = false
	end
	for _, descendant in previewInstance:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end
end

local function easeOutBack(x: number, s: number): number
	local u = x - 1
	return 1 + (s + 1) * u * u * u + s * u * u
end

local function easeInBack(x: number, s: number): number
	return (s + 1) * x * x * x - s * x * x
end

local function easeOutCubic(x: number): number
	return 1 - (1 - x) ^ 3
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Pose de un preview en este frame: (escala, altura sobre el ancla, giro en Y).
local function computePose(live: LivePreview): (number, number, number)
	local exitT = live.exitT
	if exitT then
		local a = math.clamp(exitT / EXIT_TIME, 0, 1)
		local scale = lerp(1, MIN_SCALE, math.clamp(easeInBack(a, 1.7), 0, 1))
		return scale, live.exitFromY + EXIT_RISE * a, live.exitFromYaw + EXIT_SPIN * a * a
	end

	if live.t < ENTER_TIME then
		local a = math.clamp(live.t / ENTER_TIME, 0, 1)
		local pop = easeOutBack(a, ENTER_OVERSHOOT)
		local scale = math.max(MIN_SCALE, lerp(MIN_SCALE, 1, pop))
		local y = HOVER_HEIGHT - ENTER_DROP * (1 - easeOutBack(a, 1.4))
		return scale, y, ENTER_SPIN * (1 - easeOutCubic(a))
	end

	local tau = live.idleT
	local y = HOVER_HEIGHT + math.sin(tau * BOB_HZ * math.pi * 2) * BOB_AMPLITUDE
	local yaw = math.sin(tau * SWAY_HZ * math.pi * 2) * SWAY_ANGLE
	local scale = 1
	local punchT = live.punchT
	if punchT then
		local p = punchT / PUNCH_TIME
		scale += PUNCH_AMPLITUDE * math.sin(p * math.pi * 3) * (1 - p)
	end
	return scale, y, yaw
end

local function applyPose(live: LivePreview, userYaw: number)
	local scale, y, yaw = computePose(live)
	yaw += userYaw
	local instance = live.instance
	if instance:IsA("Model") then
		local target = live.baseScale * scale
		if math.abs(instance:GetScale() - target) > 1e-4 then
			instance:ScaleTo(target)
		end
	end
	setWeaponPreviewPivot(instance, live.basePivot * CFrame.new(0, y, 0) * CFrame.Angles(0, yaw, 0))
end

-- El arma de muestra queda en idle toda la sesión (también en partida): fuera de cámara
-- solo avanza su reloj y se salta el PivotTo/ScaleTo del modelo entero.
local function isOnScreen(live: LivePreview): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end
	local _, onScreen = camera:WorldToViewportPoint(live.basePivot.Position)
	return onScreen
end

function WeaponPreviewController.new(options: WeaponPreviewControllerOptions): WeaponPreviewController
	local self = setmetatable({}, WeaponPreviewController) :: any
	self._options = options
	self._lockedTemplateCache = {} :: { [string]: Instance }

	self._focusCategory = WeaponCategoryMod.MAIN :: WeaponCategory
	self._desiredByCategory = {} :: { [string]: Desired }
	self._current = nil :: LivePreview?
	self._exiting = {} :: { LivePreview }
	-- Giro del arrastre del jugador (CharacterRotateController), sumado al del idle.
	self._userYaw = 0

	-- Contornos fuera mientras haya un panel abierto encima (como en el preview del
	-- lobby): si no, el contorno se pinta por delante de la GUI que tapa el arma.
	self._highlightsHidden = false
	self._stopPanelObserver = PreviewHighlightPanels.observe(options.uiGui, function(hidden: boolean)
		self._highlightsHidden = hidden
		local current = self._current
		if current and current.instance.Parent then
			LockerUtils.setPreviewHighlightsEnabled(current.instance, not hidden)
		end
	end)

	self._sharedHeartbeat = nil :: RBXScriptConnection?
	return self
end

function WeaponPreviewController:_ensureHeartbeat()
	if self._sharedHeartbeat then
		return
	end
	self._sharedHeartbeat = RunService.Heartbeat:Connect(function(dt)
		for i = #self._exiting, 1, -1 do
			local live = self._exiting[i]
			live.exitT = (live.exitT :: number) + dt
			if not live.instance.Parent or (live.exitT :: number) >= EXIT_TIME then
				live.instance:Destroy()
				table.remove(self._exiting, i)
			else
				applyPose(live, self._userYaw)
			end
		end

		local current: LivePreview? = self._current
		if current then
			if not current.instance.Parent then
				self._current = nil
			else
				current.t += dt
				if current.t >= ENTER_TIME then
					current.idleT += dt
				end
				local punchT = current.punchT
				if punchT then
					current.punchT = if punchT + dt >= PUNCH_TIME then nil else punchT + dt
				end
				if current.t < ENTER_TIME or current.punchT ~= nil or isOnScreen(current) then
					applyPose(current, self._userYaw)
				end
			end
		end

		if self._current == nil and #self._exiting == 0 then
			if self._sharedHeartbeat then
				self._sharedHeartbeat:Disconnect()
				self._sharedHeartbeat = nil
			end
		end
	end)
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
	local categoryFolder = self._options.sharedWeaponAssets:FindFirstChild(category)
	if not categoryFolder then
		return nil
	end

	return (if itemId then categoryFolder:FindFirstChild(itemId) else nil)
		or (if itemName then categoryFolder:FindFirstChild(itemName) else nil)
		-- "Default" es el nombre del Tool fallback en Locker.weapons.*; por convención
		-- coincide con ItemDefaults.ITEM_ID.
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
	local resolvedWrapId = LoadoutWraps.resolveEquipped(loadout, category, resolvedWeaponId, self._options.ownsWeaponWrap)
	return previewId .. "::" .. resolvedWrapId .. "::unlocked"
end

-- El arma bloqueada conserva geometría y materiales: el bloqueo lo marca un
-- Highlight. El clone vive en _lockedTemplateCache y nunca se reutiliza para el
-- estado desbloqueado (ver _getStateId), así que el Highlight nunca hay que quitarlo.
function WeaponPreviewController:_applyLockedAppearance(previewInstance: Instance)
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

	if previewInstance:IsA("Model") or previewInstance:IsA("BasePart") then
		highlight.Adornee = previewInstance :: any
	end

	highlight.FillColor = LOCKED_FILL_COLOR
	highlight.FillTransparency = LOCKED_FILL_TRANSPARENCY
	highlight.OutlineColor = LOCKED_OUTLINE_COLOR
	highlight.OutlineTransparency = LOCKED_OUTLINE_TRANSPARENCY
	highlight.Enabled = true
end

function WeaponPreviewController:_applyWrap(previewInstance: Instance, wrapId: string)
	WeaponWrapPainter.paint(previewInstance, WeaponWrapPainter.getDefinition(wrapId))
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
	self:_applyLockedAppearance(processedClone)
	self._lockedTemplateCache[cacheKey] = processedClone
	return processedClone
end

-- La salida arranca desde la pose actual para no dar saltos.
function WeaponPreviewController:_beginExit(live: LivePreview)
	local _, y, yaw = computePose(live)
	live.exitFromY = y
	live.exitFromYaw = yaw
	live.exitT = 0
	live.punchT = nil
	table.insert(self._exiting, live)
	self:_ensureHeartbeat()
end

function WeaponPreviewController:_clearCurrent(animate: boolean)
	local current = self._current
	self._current = nil
	if not current then
		return
	end
	if animate and current.instance.Parent then
		self:_beginExit(current)
	else
		current.instance:Destroy()
	end
end

function WeaponPreviewController:_createPreview(category: WeaponCategory, desired: Desired, locked: boolean): Instance?
	local clonedWeapon: Instance
	if locked then
		local lockedTemplate = self:_getOrCreateLockedTemplate(category, desired.itemId, desired.itemName)
		if not lockedTemplate then
			return nil
		end
		clonedWeapon = lockedTemplate:Clone()
	else
		local weaponTemplate = self:_resolveTemplate(category, desired.itemId, desired.itemName)
		if not weaponTemplate then
			return nil
		end
		clonedWeapon = weaponTemplate:Clone()
	end

	clonedWeapon.Name = category .. "WeaponPreview"
	anchorWeaponPreview(clonedWeapon)
	if not locked then
		local resolvedWeaponId = getOptionalString(desired.itemId) or ItemDefaults.ITEM_ID
		local loadout = self._options.getCurrentLoadout()
		local resolvedWrapId = LoadoutWraps.resolveEquipped(loadout, category, resolvedWeaponId, self._options.ownsWeaponWrap)
		self:_applyWrap(clonedWeapon, resolvedWrapId)
		-- Contorno solo si NO está bloqueada: un segundo Highlight no sustituye al de
		-- bloqueo, se suma.
		LockerUtils.applyPreviewOutline(clonedWeapon)
	end
	-- El clone nace con sus contornos encendidos: bajarlos si hay un panel abierto.
	if self._highlightsHidden then
		LockerUtils.setPreviewHighlightsEnabled(clonedWeapon, false)
	end
	return clonedWeapon
end

-- Lleva el mundo a lo que toca mostrar en la categoría en foco. Devuelve true si
-- ya se estaba viendo exactamente eso.
function WeaponPreviewController:_render(): boolean
	local spawnTarget = self._options.weaponSpawn
	local category = self._focusCategory
	local desired = self._desiredByCategory[category]
	if not spawnTarget or not desired then
		return false
	end

	local locked = self:_isLocked(category, desired.itemId)
	local stateId = self:_getStateId(category, desired.itemId, desired.previewId, locked)
	local current = self._current

	if current and current.instance.Parent and current.category == category then
		if current.stateId == stateId then
			return true
		end
		-- Solo cambia el wrap equipado: se repinta en sitio, sin salida/entrada.
		if current.previewId == desired.previewId and not locked and not current.locked then
			local resolvedWeaponId = getOptionalString(desired.itemId) or ItemDefaults.ITEM_ID
			local loadout = self._options.getCurrentLoadout()
			self:_applyWrap(current.instance, LoadoutWraps.resolveEquipped(loadout, category, resolvedWeaponId, self._options.ownsWeaponWrap))
			current.stateId = stateId
			return true
		end
	end

	local hadPrevious = current ~= nil and current.instance.Parent ~= nil
	self:_clearCurrent(true)

	local instance = self:_createPreview(category, desired, locked)
	if not instance then
		return false
	end

	local basePivot = getSpawnPivot(spawnTarget)
	local live: LivePreview = {
		instance = instance,
		category = category,
		previewId = desired.previewId,
		stateId = stateId,
		locked = locked,
		basePivot = basePivot,
		baseScale = if instance:IsA("Model") then instance:GetScale() else 1,
		t = if hadPrevious then -ENTER_DELAY_AFTER_EXIT else 0,
		idleT = 0,
		punchT = nil,
		exitT = nil,
		exitFromY = 0,
		exitFromYaw = 0,
	}
	-- Pose inicial antes de entrar al Workspace para que no asome a tamaño real.
	applyPose(live, self._userYaw)
	instance.Parent = spawnTarget :: Instance
	self._current = live
	self:_ensureHeartbeat()
	return false
end

function WeaponPreviewController:_setDesired(category: string, itemId: string?, itemName: string?, previewId: string): boolean
	self._desiredByCategory[category] = { itemId = itemId, itemName = itemName, previewId = previewId }
	if category ~= self._focusCategory then
		return false
	end
	return self:_render()
end

function WeaponPreviewController:_punch()
	local current = self._current
	if current and current.t >= ENTER_TIME and not current.exitT then
		current.punchT = 0
	end
end

function WeaponPreviewController:setUserYaw(yaw: number)
	self._userYaw = yaw
end

--- Muestra la categoría en foco en el ancla; la otra se guarda para cuando vuelva.
--- `nil` (fuera de la vista de armas) mantiene el foco actual.
function WeaponPreviewController:setFocusCategory(category: string?)
	if not category or not isWeaponCategory(category) then
		return
	end

	local nextFocus = category :: WeaponCategory
	if self._focusCategory == nextFocus then
		return
	end

	self._focusCategory = nextFocus
	if self._desiredByCategory[nextFocus] then
		self:_render()
	else
		self:restoreEquippedFor(nextFocus)
	end
end

function WeaponPreviewController:restoreEquippedFor(category: string)
	if not isWeaponCategory(category) then
		return
	end

	local equippedItemId = self._options.getEquippedItemByCategory(category) or ItemDefaults.ITEM_ID
	local categoryConfig = self._options.itemsConfig[category]
	local definition = if type(categoryConfig) == "table" then categoryConfig[equippedItemId] else nil
	local resolvedName = if type(definition) == "table" then tostring(definition.Name or equippedItemId) else equippedItemId
	local previewId = LockerConfig.makeQualifiedId(category, equippedItemId)
	self:_setDesired(category, equippedItemId, resolvedName, previewId)

	-- Reaplicar el wrap del loadout: cancela un preview de wrap no equipado que
	-- hubiera quedado de la última selección.
	local current = self._current
	if current and current.category == category and not current.locked and current.instance.Parent then
		local loadout = self._options.getCurrentLoadout()
		local equippedWrapId = LoadoutWraps.resolveEquipped(loadout, category :: WeaponCategory, equippedItemId, self._options.ownsWeaponWrap)
		self:_applyWrap(current.instance, equippedWrapId)
	end
end

function WeaponPreviewController:applyWrapPreview(weaponCategory: string, wrapId: string?, animate: boolean?)
	if not isWeaponCategory(weaponCategory) then
		return
	end

	local current = self._current
	if not current or current.category ~= weaponCategory or current.locked or not current.instance.Parent then
		return
	end

	self:_applyWrap(current.instance, getOptionalString(wrapId) or ItemDefaults.ITEM_ID)
	if animate then
		self:_punch()
	end
end

function WeaponPreviewController:restoreEquipped()
	self:restoreEquippedFor(WeaponCategoryMod.MAIN)
	self:restoreEquippedFor(WeaponCategoryMod.SPECIAL)
end

-- `animate`: la selección viene de un clic. Sin él (grid repoblado al entrar o salir de
-- wraps, cambio de pestaña, refresco tras equipar) no hay punch.
function WeaponPreviewController:applySelected(item: LockerCatalogItem?, animate: boolean?)
	if item and item.Category == LockerCategory.WEAPON_WRAPS then
		local previewCategory = item.PreviewWeaponCategory
		if previewCategory and isWeaponCategory(previewCategory) then
			self:applyWrapPreview(previewCategory, item.id, animate)
		end
		return
	end

	if not item or not isWeaponCategory(item.Category) then
		self:restoreEquipped()
		return
	end

	if self:_setDesired(item.Category, item.id, item.Name, item.qualifiedId) and animate and item.Category == self._focusCategory then
		self:_punch()
	end
end

function WeaponPreviewController:destroyAll()
	self:_clearCurrent(false)
	for _, live in self._exiting do
		live.instance:Destroy()
	end
	table.clear(self._exiting)
	table.clear(self._desiredByCategory)
	self._focusCategory = WeaponCategoryMod.MAIN
end

--- Deriva de la navegación qué categoría de arma está en foco.
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
	self._stopPanelObserver()
	if self._sharedHeartbeat then
		self._sharedHeartbeat:Disconnect()
		self._sharedHeartbeat = nil
	end
	-- Los clones cacheados están parented a nil: destruirlos para liberarlos ya.
	for _, clone in self._lockedTemplateCache do
		clone:Destroy()
	end
	table.clear(self._lockedTemplateCache)
end

return WeaponPreviewController
