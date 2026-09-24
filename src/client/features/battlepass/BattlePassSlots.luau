--!strict
--[[
	Las ocho casillas de la página del pase (BattlePass.PathContainer."1".."8"): las
	encuentra, las pinta, anima la entrada de página y levanta la seleccionada. Contrato
	de nodos de Studio en la cabecera de battlepass/init.luau.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Client = script.Parent.Parent.Parent
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any
local InteractiveScaleTween = require(Client.core.ui.animators.InteractiveScaleTween)
local UITheme = require(Client.core.ui.UITheme)
local BattlePassConfig = require(Shared.constants.BattlePassConfig)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local WeaponWrapPreviewer = require(Client.features.locker.Previewers.WeaponWrapPreviewer)
local BattlePassRewards = require(script.Parent.BattlePassRewards)

local SLOTS_PER_PAGE = 8

local UI_DARK_TEXT = Color3.fromRGB(34, 34, 34)
local TYPE_PREMIUM_BG = Color3.fromRGB(255, 196, 0)
local TYPE_FREE_BG = Color3.fromRGB(255, 255, 255)
local TYPE_CLAIMED_BG = Color3.fromRGB(34, 34, 34)
local TYPE_CLAIMED_TEXT = Color3.fromRGB(255, 255, 255)
-- Misma paleta de rareza que las cards del locker, para que un item brille igual en ambos.
local GLOW_CLAIMED_COLOR = Color3.fromRGB(34, 34, 34)
local RARITY_GLOW = UITheme.LockerRarityGlow
local STATUS_LEVEL_FORMAT = "Lvl. %d"
local LEVEL_PASSED_BG = Color3.fromRGB(255, 196, 0)
local LEVEL_LOCKED_BG = Color3.fromRGB(255, 255, 255)
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

-- previewKey = wrap + arma: si cambia cualquiera hay que rehacer el viewport.
type WrapEntry = { previewKey: string, janitor: any }

-- Lo que la casilla necesita saber del jugador para pintar un nivel.
export type SlotState = {
	realLevel: number,
	isClaimed: boolean,
	claimable: boolean,
	-- Nivel actual del jugador (acotado a la season) y progreso 0..1 hacia el siguiente.
	currentTier: number,
	ratio: number,
}

export type Deps = {
	frame: GuiObject,
	pathFolder: Instance?,
	currentLevelTemplate: Instance?,
	janitor: any,
	canHover: boolean,
	onSlotClick: (index: number) -> (),
}

export type BattlePassSlots = {
	has: (self: BattlePassSlots, index: number) -> boolean,
	beginRender: (self: BattlePassSlots) -> (),
	paint: (self: BattlePassSlots, index: number, tierDef: BattlePassConfig.Tier, state: SlotState) -> (),
	hide: (self: BattlePassSlots, index: number) -> (),
	select: (self: BattlePassSlots, index: number) -> boolean,
	resetSelection: (self: BattlePassSlots) -> (),
	playStagger: (self: BattlePassSlots) -> (),
	clearWraps: (self: BattlePassSlots) -> (),
}

type Internal = BattlePassSlots & {
	_slots: { SlotRefs? },
	_wrapBySlot: { [GuiObject]: WrapEntry },
	_restPos: { [GuiObject]: UDim2 },
	_moveTween: { [GuiObject]: Tween },
	_selected: GuiObject?,
	_currentLevel: GuiObject?,
	_currentFill: GuiObject?,
	_currentLevelLabel: TextLabel?,
}

local BattlePassSlots = {}
BattlePassSlots.__index = BattlePassSlots
BattlePassSlots.SLOTS_PER_PAGE = SLOTS_PER_PAGE

local function resolveSlot(pathFolder: Instance, index: number): SlotRefs?
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

	-- El nivel puede ir en Container.Level o en Footer.Status.Value.
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

-- UIScale escala desde el AnchorPoint: se recentra a (0.5, 0.5) compensando Position con
-- Size (no AbsoluteSize, para no depender de la resolución). Si un layout manda la
-- Position o un constraint el tamaño, la compensación no sería exacta: devuelve false y
-- no lo toca.
local function centerScaleAnchor(node: GuiObject): boolean
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

function BattlePassSlots.new(deps: Deps): BattlePassSlots
	local self = setmetatable({
		_slots = {},
		_wrapBySlot = {},
		_restPos = {},
		_moveTween = {},
		_selected = nil,
		_currentLevel = nil,
		_currentFill = nil,
		_currentLevelLabel = nil,
	}, BattlePassSlots) :: any

	local pathFolder = deps.pathFolder
	if pathFolder then
		for i = 1, SLOTS_PER_PAGE do
			self._slots[i] = resolveSlot(pathFolder, i)
		end
	else
		warn("[BattlePassFeature] BattlePass.PathContainer no existe")
	end

	-- El hover escala el Container (Position ya la animan stagger y selección). El
	-- AnchorPoint se recentra aquí y no al abrir: el stagger cachea la Position de reposo
	-- la primera vez que anima y debe cachear ya la compensada.
	local anchorFixFailed = false
	for i = 1, SLOTS_PER_PAGE do
		local refs = self._slots[i]
		if refs and refs.frame:IsA("GuiButton") then
			if not centerScaleAnchor(refs.container) then
				anchorFixFailed = true
			end
			InteractiveScaleTween.bindButton(refs.frame :: GuiButton, deps.janitor, {
				scaleTarget = refs.container,
				enableHover = deps.canHover,
				hoverScale = SLOT_HOVER_SCALE,
				clickScale = SLOT_CLICK_SCALE,
			})
			deps.janitor:Add((refs.frame :: GuiButton).Activated:Connect(function()
				deps.onSlotClick(i)
			end), "Disconnect")
		end
	end
	if anchorFixFailed then
		warn(
			"[BattlePassFeature] Algún Container de PathContainer no se puede recentrar por código (lo posiciona un layout o su tamaño lo decide un constraint): el hover crecerá desde la esquina. Ponle AnchorPoint 0.5,0.5 en Studio."
		)
	end

	-- CurrentLevel: plantilla clonada UNA vez y reparentada al Container del nivel actual
	-- en cada render, para no crear CanvasGroups por tick.
	local template = deps.currentLevelTemplate
	if template and template:IsA("GuiObject") then
		template.Visible = false
		local clone = template:Clone()
		clone.Visible = false
		clone.Parent = deps.frame
		deps.janitor:Add(clone, "Destroy")
		self._currentLevel = clone
		local fillNode = clone:FindFirstChild("Fill")
		self._currentFill = if fillNode and fillNode:IsA("GuiObject") then fillNode else nil
		local levelNode = clone:FindFirstChild("Level")
		self._currentLevelLabel = if levelNode and levelNode:IsA("TextLabel") then levelNode else nil
	end

	deps.janitor:Add(function()
		self:resetSelection()
		self:clearWraps()
	end, true)
	return self
end

function BattlePassSlots.has(self: Internal, index: number): boolean
	return self._slots[index] ~= nil
end

local function clearWrap(self: Internal, slotFrame: GuiObject)
	local entry = self._wrapBySlot[slotFrame]
	if entry then
		entry.janitor:Destroy()
		self._wrapBySlot[slotFrame] = nil
	end
end

-- Los wraps animados actualizan textura cada frame: se sueltan al cerrar el panel.
function BattlePassSlots.clearWraps(self: Internal)
	for slotFrame in self._wrapBySlot do
		clearWrap(self, slotFrame)
	end
end

function BattlePassSlots.beginRender(self: Internal)
	if self._currentLevel then
		self._currentLevel.Visible = false
	end
end

function BattlePassSlots.hide(self: Internal, index: number)
	local refs = self._slots[index]
	if refs then
		refs.frame.Visible = false
		clearWrap(self, refs.frame)
	end
end

local function paintType(refs: SlotRefs, isPremium: boolean, isClaimed: boolean)
	local typeLabel = refs.typeLabel
	if not typeLabel then
		return
	end
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

local function paintWrapViewport(self: Internal, refs: SlotRefs, reward: BattlePassConfig.Reward)
	local viewport = refs.viewport :: ViewportFrame
	if refs.image then
		refs.image.Visible = false
	end
	viewport.Visible = true
	local wrapId = reward.ItemId :: string
	local weaponCategory, weaponId, weaponName = BattlePassRewards.wrapPreviewWeapon(reward)
	local previewKey = `{wrapId}|{weaponCategory}|{weaponId or ""}`
	local existing = self._wrapBySlot[refs.frame]
	if existing and existing.previewKey == previewKey then
		return
	end
	clearWrap(self, refs.frame)
	local wrapsCatalog = ItemsConfig.WeaponWraps
	if type(wrapsCatalog) ~= "table" or type(wrapsCatalog[wrapId]) ~= "table" then
		return
	end
	local previewJanitor = Janitor.new()
	local ok, usedWeapon = WeaponWrapPreviewer.Render(viewport, {
		WrapId = wrapId,
		PreviewWeaponCategory = weaponCategory,
		PreviewWeaponId = weaponId,
		PreviewWeaponDisplayName = weaponName,
	}, previewJanitor)
	if ok then
		-- Solo el bloque genérico (sin modelo de arma) necesita recentrarse.
		if not usedWeapon then
			WeaponWrapPreviewer.reframeCentered(viewport)
		end
		self._wrapBySlot[refs.frame] = { previewKey = previewKey, janitor = previewJanitor }
	else
		previewJanitor:Destroy()
	end
end

local function paintContent(self: Internal, refs: SlotRefs, reward: BattlePassConfig.Reward, isClaimed: boolean)
	if BattlePassRewards.isWrap(reward) and refs.viewport then
		paintWrapViewport(self, refs, reward)
	else
		clearWrap(self, refs.frame)
		if refs.viewport then
			refs.viewport.Visible = false
		end
		if refs.image then
			refs.image.Image = BattlePassRewards.image(reward)
			refs.image.Visible = true
		end
	end

	if refs.value then
		local text = BattlePassRewards.valueText(reward)
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
			else (RARITY_GLOW[BattlePassRewards.rarity(reward)] or RARITY_GLOW[BattlePassRewards.RARITY_FALLBACK])
		if color then
			if glow:IsA("ImageLabel") or glow:IsA("ImageButton") then
				glow.ImageColor3 = color
			else
				glow.BackgroundColor3 = color
			end
		end
	end
end

-- El clon de CurrentLevel lleva el LayoutOrder de la plantilla y cae en el hueco del Level.
local function paintLevel(self: Internal, refs: SlotRefs, state: SlotState)
	local realLevel = state.realLevel
	local isCurrent = realLevel == state.currentTier
	local currentLevel = self._currentLevel
	if refs.levelLabel then
		refs.levelLabel.Text = STATUS_LEVEL_FORMAT:format(realLevel)
		refs.levelLabel.Visible = not (isCurrent and currentLevel ~= nil)
		refs.levelLabel.TextColor3 = UI_DARK_TEXT
		refs.levelLabel.BackgroundColor3 = if realLevel < state.currentTier then LEVEL_PASSED_BG else LEVEL_LOCKED_BG
	end
	if not (isCurrent and currentLevel) then
		return
	end
	currentLevel.Parent = refs.container
	currentLevel.Visible = true
	if self._currentLevelLabel then
		self._currentLevelLabel.Text = STATUS_LEVEL_FORMAT:format(realLevel)
	end
	local fill = self._currentFill
	if fill then
		fill.Size = UDim2.new(state.ratio, 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
	end
end

function BattlePassSlots.paint(self: Internal, index: number, tierDef: BattlePassConfig.Tier, state: SlotState)
	local refs = self._slots[index]
	if not refs then
		return
	end
	refs.frame.Visible = true
	paintContent(self, refs, tierDef.Reward, state.isClaimed)
	paintType(refs, tierDef.Premium, state.isClaimed)
	if refs.locked then
		refs.locked.Visible = not state.isClaimed and not state.claimable
	end
	if refs.claim then
		refs.claim.Visible = state.claimable
	end
	paintLevel(self, refs, state)
	if refs.rewardGradient then
		refs.rewardGradient.Enabled = tierDef.Premium
	end
end

-- Un único tween de Position por Container, compartido por stagger y selección.
local function restPosOf(self: Internal, container: GuiObject): UDim2
	local cached = self._restPos[container]
	if cached == nil then
		cached = container.Position
		self._restPos[container] = cached
	end
	return cached
end

local function moveSlot(self: Internal, container: GuiObject, lifted: boolean)
	local rest = restPosOf(self, container)
	local target = if lifted
		then UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset - SELECTED_LIFT_PIXELS)
		else rest
	local existing = self._moveTween[container]
	if existing then
		existing:Cancel()
	end
	local tween = TweenService:Create(container, SELECT_MOVE_INFO, { Position = target })
	self._moveTween[container] = tween
	tween:Play()
end

-- Levanta la casilla; false si no existe o ya estaba seleccionada.
function BattlePassSlots.select(self: Internal, index: number): boolean
	local refs = self._slots[index]
	if not refs or self._selected == refs.container then
		return false
	end
	if self._selected then
		moveSlot(self, self._selected, false)
	end
	moveSlot(self, refs.container, true)
	self._selected = refs.container
	return true
end

function BattlePassSlots.resetSelection(self: Internal)
	for container, tween in self._moveTween do
		tween:Cancel()
		local rest = self._restPos[container]
		if rest and container.Parent then
			container.Position = rest
		end
	end
	table.clear(self._moveTween)
	self._selected = nil
end

function BattlePassSlots.playStagger(self: Internal)
	local order = 0
	for i = 1, SLOTS_PER_PAGE do
		local refs = self._slots[i]
		if not (refs and refs.frame.Visible) then
			continue
		end
		local container = refs.container
		local rest = restPosOf(self, container)
		local existing = self._moveTween[container]
		if existing then
			existing:Cancel()
		end
		container.Position = UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset + STAGGER_ENTER_OFFSET)
		local tween = TweenService:Create(container, SLOT_STAGGER_INFO, { Position = rest })
		self._moveTween[container] = tween
		task.delay(order * SLOT_STAGGER_DELAY, function()
			if self._moveTween[container] == tween then
				tween:Play()
			end
		end)
		order += 1
	end
end

return BattlePassSlots
