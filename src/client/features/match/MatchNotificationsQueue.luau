--!strict
--[[
	MatchNotificationsQueue.luau
	Queue + animaciones de notificaciones in-match: level up, BattlePass level up,
	daily task completed, y maestría de armas (hitos + completar). Extraído de
	MatchHud para que ese módulo no orqueste tanto. Los frames y sus posiciones
	originales se cachean por instancia.

	Frames esperados bajo MatchHud.Container:
		LevelUp.Value · BattlePassLevelUp.{Value, Reward} · TaskCompleted.Reward ·
		Maestry.{Bar.Fill, Reward.ItemViewport, Value}

	API:
		MatchNotificationsQueue.new(matchHudGui: ScreenGui?)
		:playLevelUpAnimation(newLevel: number, unlock: LevelUpUnlock?)
		:playBattlePassLevelUpAnimation(newLevel: number, reward: ChallengeCompletedReward?)
		:playTaskCompletedAnimation(reward: ChallengeCompletedReward)
		:playMasteryAnimation(progress: MasteryProgress)
		:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LockerConfig = require(Shared.constants.LockerConfig)
local LockerCategory = require(Shared.constants.LockerCategory)
local Confetti = require(script.Parent.Parent.Parent.core.ui.Confetti)
local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local WeaponWrapPreviewer = require(script.Parent.Parent.locker.Previewers.WeaponWrapPreviewer)
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any

-- ── Tipos públicos ───────────────────────────────────────────

export type LevelUpUnlock = {
	name: string,
	category: string,
	image: string?,
}

export type ChallengeCompletedReward = {
	name: string,
	image: string?,
	previewWeaponCategory: string?,
	previewWeaponId: string?,
	itemId: string?,
	category: string?,
	textureID: string?,
	baseColor: Color3?,
	material: Enum.Material?,
	animated: boolean?,
	studsPerTile: number?,
	cashAmount: number?,
}

-- Progreso de maestría de un arma hacia el siguiente tier (o el recién completado).
-- `current`/`target` se muestran como "current/target" y rellenan la barra.
-- `isComplete` = true cuando se acaba de ganar el wrap (100%, con confeti).
export type MasteryProgress = {
	current: number,
	target: number,
	name: string,
	isComplete: boolean?,
	-- Preview 3D del wrap de maestría (siguiente tier o el recién ganado).
	previewWeaponCategory: string?,
	previewWeaponId: string?,
	itemId: string?,
	category: string?,
	textureID: string?,
	baseColor: Color3?,
	material: Enum.Material?,
	animated: boolean?,
	studsPerTile: number?,
}

-- ── Constantes ───────────────────────────────────────────────

local LEVEL_UP_TWEEN_IN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local LEVEL_UP_TWEEN_OUT_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local LEVEL_UP_HOLD_SECONDS = 5.0
-- Cap defensivo: si se enchufan muchas notificaciones (drops, level-ups en
-- cadena), tirar las más antiguas todavía sin reproducir antes que dejar
-- crecer la cola indefinidamente.
local NOTIFICATION_QUEUE_CAP = 20

local LEVEL_UP_CONFETTI_COLORS = {
	Color3.fromRGB(40, 130, 255),
	Color3.fromRGB(80, 170, 255),
	Color3.fromRGB(120, 200, 255),
	Color3.fromRGB(20, 90, 200),
	Color3.fromRGB(170, 220, 255),
}

-- BattlePass usa paleta verde para diferenciar visualmente del level up de
-- character (azul). Mismo timing y animación, distinto frame y color.
local BATTLEPASS_LEVEL_UP_CONFETTI_COLORS = {
	Color3.fromRGB(60, 200, 100),
	Color3.fromRGB(40, 220, 80),
	Color3.fromRGB(100, 230, 130),
	Color3.fromRGB(20, 160, 60),
	Color3.fromRGB(140, 240, 160),
}

local CHALLENGE_CONFETTI_COLORS = {
	Color3.fromRGB(80, 220, 110),
	Color3.fromRGB(130, 240, 150),
	Color3.fromRGB(50, 180, 80),
	Color3.fromRGB(200, 255, 210),
	Color3.fromRGB(30, 140, 60),
}

-- Maestría de armas usa paleta dorada (logro/achievement). Solo se lanza confeti
-- al completar un tier (100%), no en los hitos intermedios.
local MASTERY_CONFETTI_COLORS = {
	Color3.fromRGB(255, 205, 70),
	Color3.fromRGB(255, 175, 30),
	Color3.fromRGB(255, 230, 140),
	Color3.fromRGB(230, 150, 20),
	Color3.fromRGB(255, 245, 200),
}
-- Tween de la barra de progreso de maestría (se rellena tras entrar el frame).
local MASTERY_BAR_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local LEVEL_UP_FILLER_PHRASES = {
	"Science says you're cool now",
	"You're doing great (for a human)",
	"Touch grass?",
	"Your cat is impressed",
	"The admin is very proud of you",
}

-- ── Helpers de resolución de GUI ─────────────────────────────

local function _findChildGuiObject(parent: Instance?, childName: string): GuiObject?
	if not parent then
		return nil
	end
	local node = parent:FindFirstChild(childName)
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

local function _findDescendant(parent: Instance?, path: { string }): Instance?
	local current = parent
	for _, childName in path do
		if not current then
			return nil
		end
		current = current:FindFirstChild(childName)
	end
	return current
end

local function _findDescendantGuiObject(parent: Instance?, path: { string }): GuiObject?
	local node = _findDescendant(parent, path)
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

local function _findDescendantTextLabel(parent: Instance?, path: { string }): TextLabel?
	local node = _findDescendant(parent, path)
	if node and node:IsA("TextLabel") then
		return node
	end
	return nil
end

-- Calcula el tamaño objetivo de un Fill horizontal para un ratio [0,1], cacheando
-- la escala/offset base del asset (igual criterio que MatchHud._setHorizontalFill).
local function _targetFillSize(fillNode: GuiObject, ratio: number): UDim2
	local clampedRatio = math.min(1, math.max(0, ratio))
	local baseScale = fillNode:GetAttribute("BaseFillScale")
	local baseOffset = fillNode:GetAttribute("BaseFillOffset")
	local currentSize = fillNode.Size
	if type(baseScale) ~= "number" then
		baseScale = currentSize.X.Scale
		fillNode:SetAttribute("BaseFillScale", baseScale)
	end
	if type(baseOffset) ~= "number" then
		baseOffset = currentSize.X.Offset
		fillNode:SetAttribute("BaseFillOffset", baseOffset)
	end
	local nextScale = baseScale + ((1 - baseScale) * clampedRatio)
	return UDim2.new(nextScale, baseOffset, currentSize.Y.Scale, currentSize.Y.Offset)
end

-- Renderiza el preview 3D de un wrap (maestría / item) dentro de un ViewportFrame.
-- Limpia hijos no-GUI previos y devuelve un Janitor con el preview para cleanup.
local function _renderWrapPreview(itemViewport: ViewportFrame, reward: any): any
	for _, child in itemViewport:GetChildren() do
		if not child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local previewJanitor = Janitor.new()
	local previewItem = {
		qualifiedId = LockerConfig.makeQualifiedId(reward.category or LockerCategory.WEAPON_WRAPS, tostring(reward.itemId or reward.name)),
		Category = reward.category or LockerCategory.WEAPON_WRAPS,
		id = reward.itemId or reward.name,
		Name = reward.name,
		Price = 0,
		LevelRequired = 0,
		Rarity = "Common",
		Image = "",
		CanPurchase = false,
		TextureID = reward.textureID,
		BaseColor = reward.baseColor,
		Material = reward.material,
		isAnimated = reward.animated,
		StudsPerTile = reward.studsPerTile,
		PreviewWeaponCategory = reward.previewWeaponCategory,
		PreviewWeaponId = reward.previewWeaponId,
	}
	WeaponWrapPreviewer.Render(itemViewport, previewItem :: any, previewJanitor)
	return previewJanitor
end

-- Rellena un nodo `Reward` con hijos { ItemImage, ItemViewport, Amount }. Si
-- `reward` es nil, oculta el nodo. Si trae `image`, usa ItemImage; si no y trae
-- datos de wrap (textureID/baseColor/previewWeaponId/itemId), renderiza el preview
-- 3D en ItemViewport. `cashAmount` se muestra en Amount. Devuelve el Janitor del
-- preview (o nil) para limpiarlo al cerrar la notificación.
local function _populateItemReward(rewardNode: Instance, reward: any): any
	local itemImage = rewardNode:FindFirstChild("ItemImage")
	local itemViewport = rewardNode:FindFirstChild("ItemViewport")
	local amountLabel = rewardNode:FindFirstChild("Amount")

	if not reward then
		if rewardNode:IsA("GuiObject") then
			rewardNode.Visible = false
		end
		return nil
	end
	if rewardNode:IsA("GuiObject") then
		rewardNode.Visible = true
	end

	local hasImage = type(reward.image) == "string" and reward.image ~= ""
	local hasPreview = type(reward.textureID) == "string"
		or typeof(reward.baseColor) == "Color3"
		or type(reward.previewWeaponId) == "string"
		or type(reward.itemId) == "string"

	if itemImage and (itemImage:IsA("ImageLabel") or itemImage:IsA("ImageButton")) then
		if hasImage then
			itemImage.Image = reward.image :: string
			itemImage.Visible = true
		else
			itemImage.Visible = false
		end
	end

	local previewJanitor: any = nil
	if itemViewport and itemViewport:IsA("ViewportFrame") then
		if not hasImage and hasPreview then
			itemViewport.Visible = true
			previewJanitor = _renderWrapPreview(itemViewport, reward)
		else
			itemViewport.Visible = false
			for _, child in itemViewport:GetChildren() do
				if not child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			itemViewport.CurrentCamera = nil
		end
	end

	if amountLabel and amountLabel:IsA("TextLabel") then
		if type(reward.cashAmount) == "number" then
			amountLabel.Text = UIUtils.formatCashAmount(reward.cashAmount)
			amountLabel.Visible = true
		else
			amountLabel.Visible = false
		end
	end

	return previewJanitor
end

-- ── Módulo ───────────────────────────────────────────────────

local MatchNotificationsQueue = {}
MatchNotificationsQueue.__index = MatchNotificationsQueue

function MatchNotificationsQueue.new(matchHudGui: ScreenGui?): any
	local self = setmetatable({}, MatchNotificationsQueue)
	self._gui = matchHudGui
	self._destroyed = false
	self._queue = {} :: { (onDone: () -> ()) -> () }
	self._active = false
	-- "Notifying" = hay una notificación en pantalla o en cola. Avisamos en cada
	-- transición (con detección de cambio para no parpadear entre notificaciones
	-- consecutivas). Lo usa MatchHud para ocultar las filas de jugadores.
	self._notifying = false
	self._onNotifyingChanged = nil :: ((notifying: boolean) -> ())?
	-- Cache de posiciones originales de cada frame (se setean en el primer play).
	self._levelUpOriginalPosition = nil :: UDim2?
	self._battlePassLevelUpOriginalPosition = nil :: UDim2?
	self._taskCompletedOriginalPosition = nil :: UDim2?
	self._maestryOriginalPosition = nil :: UDim2?
	return self
end

-- Los popups in-match (level up, BattlePass level up, challenge completado) se
-- muestran encima del HUD sin ocultar nada de Match: solo necesitan el Container.
function MatchNotificationsQueue:_resolveContainer(): GuiObject?
	local matchHudGui = self._gui
	if not matchHudGui then
		return nil
	end
	return _findChildGuiObject(matchHudGui, "Container")
end

-- Registra un callback que recibe `true` cuando empieza a haber notificaciones y
-- `false` cuando se vacía la cola (sin parpadeo entre notificaciones encadenadas).
function MatchNotificationsQueue:setOnNotifyingChanged(callback: ((notifying: boolean) -> ())?)
	self._onNotifyingChanged = callback
end

function MatchNotificationsQueue:_refreshNotifying()
	local notifying = self._active or #self._queue > 0
	if notifying == self._notifying then
		return
	end
	self._notifying = notifying
	if self._onNotifyingChanged then
		self._onNotifyingChanged(notifying)
	end
end

function MatchNotificationsQueue:_processQueue()
	if self._active or self._destroyed then
		return
	end
	local nextRun = table.remove(self._queue, 1)
	if not nextRun then
		return
	end

	self._active = true
	self:_refreshNotifying()
	task.spawn(function()
		nextRun(function()
			self._active = false
			if not self._destroyed then
				self:_processQueue()
			end
			self:_refreshNotifying()
		end)
	end)
end

function MatchNotificationsQueue:_enqueue(runFn: (onDone: () -> ()) -> ())
	if self._destroyed then
		return
	end
	while #self._queue >= NOTIFICATION_QUEUE_CAP do
		table.remove(self._queue, 1)
	end
	table.insert(self._queue, runFn)
	self:_processQueue()
end

-- Patrón común de notificación: cachea la posición original del frame, lo mete
-- fuera de pantalla (arriba), lo muestra, desliza dentro, opcionalmente lanza
-- confeti y corre `afterShown`, mantiene `LEVEL_UP_HOLD_SECONDS`, y sale. `cacheKey`
-- es el campo de self donde se cachea la Position original. Bloquea hasta terminar
-- (se llama dentro del runFn de la cola).
function MatchNotificationsQueue:_playFrameSlide(frame: GuiObject, cacheKey: string, confettiColors: { Color3 }?, spawnDuration: number?, afterShown: (() -> ())?)
	local matchHudGui = self._gui
	local originalPosition = (self :: any)[cacheKey]
	if not originalPosition then
		originalPosition = frame.Position
		;(self :: any)[cacheKey] = originalPosition
	end

	local aboveScreenPosition = UDim2.new(
		originalPosition.X.Scale,
		originalPosition.X.Offset,
		-1,
		originalPosition.Y.Offset
	)

	frame.Position = aboveScreenPosition
	frame.Visible = true

	if confettiColors and matchHudGui then
		Confetti.Rain(matchHudGui, {
			colors = confettiColors,
			count = 60,
			minLifetime = 0.9,
			maxLifetime = 1.5,
			spawnDuration = spawnDuration or 1.2,
		})
	end

	local tweenIn = TweenService:Create(frame, LEVEL_UP_TWEEN_IN_INFO, { Position = originalPosition })
	tweenIn:Play()
	tweenIn.Completed:Wait()

	if afterShown then
		afterShown()
	end

	task.wait(LEVEL_UP_HOLD_SECONDS)

	local tweenOut = TweenService:Create(frame, LEVEL_UP_TWEEN_OUT_INFO, { Position = aboveScreenPosition })
	tweenOut:Play()
	tweenOut.Completed:Wait()

	frame.Visible = false
	frame.Position = originalPosition
end

function MatchNotificationsQueue:playLevelUpAnimation(newLevel: number, unlock: LevelUpUnlock?)
	self:_enqueue(function(onDone)
		local matchHudGui = self._gui
		if not matchHudGui then onDone() return end

		local container = self:_resolveContainer()
		if not container then onDone() return end

		local levelUpFrame = _findChildGuiObject(container, "LevelUp")
		if not levelUpFrame then onDone() return end

		local originalPosition = self._levelUpOriginalPosition
		if not originalPosition then
			originalPosition = levelUpFrame.Position
			self._levelUpOriginalPosition = originalPosition
		end

		local aboveScreenPosition = UDim2.new(
			originalPosition.X.Scale,
			originalPosition.X.Offset,
			-1,
			originalPosition.Y.Offset
		)

		local resolvedLevel = math.max(0, math.floor(newLevel))

		local levelLabel = _findDescendantTextLabel(levelUpFrame, { "Level" })
			or _findDescendantTextLabel(levelUpFrame, { "Value" })
		if levelLabel then
			levelLabel.Text = tostring(resolvedLevel)
		end

		local descriptionLabel = _findDescendantTextLabel(levelUpFrame, { "Description" })
		local rewardNode = _findChildGuiObject(levelUpFrame, "Reward")
		local rewardItem = _findDescendantGuiObject(rewardNode, { "Item" })
		local rewardName = _findDescendantTextLabel(rewardNode, { "Name" })

		if unlock then
			if descriptionLabel then
				descriptionLabel.Text = unlock.name .. " Is now available in locker!!"
			end
			if rewardNode then
				rewardNode.Visible = true
			end
			if rewardItem and (rewardItem:IsA("ImageLabel") or rewardItem:IsA("ImageButton")) then
				rewardItem.Image = unlock.image or ""
			end
			if rewardName then
				rewardName.Text = unlock.category
			end
		else
			if descriptionLabel then
				local phrase = LEVEL_UP_FILLER_PHRASES[math.random(1, #LEVEL_UP_FILLER_PHRASES)]
				descriptionLabel.Text = phrase
			end
			if rewardNode then
				rewardNode.Visible = false
			end
		end

		levelUpFrame.Position = aboveScreenPosition
		levelUpFrame.Visible = true

		Confetti.Rain(matchHudGui, {
			colors = LEVEL_UP_CONFETTI_COLORS,
			count = 60,
			minLifetime = 0.9,
			maxLifetime = 1.5,
			spawnDuration = 1.2,
		})

		local tweenIn = TweenService:Create(levelUpFrame, LEVEL_UP_TWEEN_IN_INFO, { Position = originalPosition })
		tweenIn:Play()
		tweenIn.Completed:Wait()

		task.wait(LEVEL_UP_HOLD_SECONDS)

		local tweenOut = TweenService:Create(levelUpFrame, LEVEL_UP_TWEEN_OUT_INFO, { Position = aboveScreenPosition })
		tweenOut:Play()
		tweenOut.Completed:Wait()

		levelUpFrame.Visible = false
		levelUpFrame.Position = originalPosition

		onDone()
	end)
end

-- `reward` opcional: BattlePassLevelUp.Reward.{ItemImage, ItemViewport}. Si no se
-- pasa, el nodo Reward se oculta. (El call site actual no envía reward todavía.)
function MatchNotificationsQueue:playBattlePassLevelUpAnimation(newLevel: number, reward: ChallengeCompletedReward?)
	self:_enqueue(function(onDone)
		local matchHudGui = self._gui
		if not matchHudGui then onDone() return end

		local container = self:_resolveContainer()
		if not container then onDone() return end

		local frame = _findChildGuiObject(container, "BattlePassLevelUp")
		if not frame then onDone() return end

		local resolvedLevel = math.max(0, math.floor(newLevel))
		local levelLabel = _findDescendantTextLabel(frame, { "Value" })
			or _findDescendantTextLabel(frame, { "Level" })
		if levelLabel then
			levelLabel.Text = tostring(resolvedLevel)
		end

		local rewardNode = _findChildGuiObject(frame, "Reward")
		local previewJanitor: any = if rewardNode then _populateItemReward(rewardNode, reward) else nil

		self:_playFrameSlide(frame, "_battlePassLevelUpOriginalPosition", BATTLEPASS_LEVEL_UP_CONFETTI_COLORS, 1.2)

		if previewJanitor then
			previewJanitor:Cleanup()
		end

		onDone()
	end)
end

-- Daily task completada → frame Container.TaskCompleted. Reward.Amount muestra el
-- cash; Reward.ItemImage/ItemViewport el premio (imagen o preview de item).
function MatchNotificationsQueue:playTaskCompletedAnimation(reward: ChallengeCompletedReward)
	self:_enqueue(function(onDone)
		local matchHudGui = self._gui
		if not matchHudGui then onDone() return end

		local container = self:_resolveContainer()
		if not container then onDone() return end

		local frame = _findChildGuiObject(container, "TaskCompleted")
		if not frame then onDone() return end

		local descriptionLabel = _findDescendantTextLabel(frame, { "Description" })
		if descriptionLabel then
			descriptionLabel.Text = "You earned " .. tostring(reward.name)
		end

		local rewardNode = _findChildGuiObject(frame, "Reward")
		local previewJanitor: any = if rewardNode then _populateItemReward(rewardNode, reward) else nil

		self:_playFrameSlide(frame, "_taskCompletedOriginalPosition", CHALLENGE_CONFETTI_COLORS, 0.4)

		if previewJanitor then
			previewJanitor:Cleanup()
		end

		onDone()
	end)
end

-- Maestría de arma → frame Container.Maestry. Value muestra "current/target",
-- Bar.Fill se rellena con tween hasta el ratio, y Reward.ItemViewport muestra el
-- preview del wrap (siguiente tier o el recién ganado). Solo lanza confeti al
-- completar un tier (progress.isComplete).
function MatchNotificationsQueue:playMasteryAnimation(progress: MasteryProgress)
	self:_enqueue(function(onDone)
		local matchHudGui = self._gui
		if not matchHudGui then onDone() return end

		local container = self:_resolveContainer()
		if not container then onDone() return end

		local frame = _findChildGuiObject(container, "Maestry")
		if not frame then onDone() return end

		local current = math.max(0, math.floor(progress.current))
		local target = math.max(1, math.floor(progress.target))
		local ratio = math.min(1, current / target)
		local isComplete = progress.isComplete == true

		local valueLabel = _findDescendantTextLabel(frame, { "Value" })
		if valueLabel then
			valueLabel.Text = string.format("%d/%d", current, target)
		end

		-- Reward.ItemViewport: preview 3D del wrap de maestría.
		local rewardNode = _findChildGuiObject(frame, "Reward")
		local itemViewport = if rewardNode then rewardNode:FindFirstChild("ItemViewport") else nil
		local previewJanitor: any = nil
		if itemViewport and itemViewport:IsA("ViewportFrame") then
			itemViewport.Visible = true
			previewJanitor = _renderWrapPreview(itemViewport, progress)
		end

		-- Barra: arranca vacía y se rellena con tween tras entrar el frame.
		local barFill = _findDescendantGuiObject(frame, { "Bar", "Fill" })
		if barFill then
			barFill.Size = _targetFillSize(barFill, 0)
		end

		local confettiColors = if isComplete then MASTERY_CONFETTI_COLORS else nil
		self:_playFrameSlide(frame, "_maestryOriginalPosition", confettiColors, 0.4, function()
			if barFill then
				local tween = TweenService:Create(barFill, MASTERY_BAR_TWEEN_INFO, {
					Size = _targetFillSize(barFill, ratio),
				})
				tween:Play()
			end
		end)

		if previewJanitor then
			previewJanitor:Cleanup()
		end
		if itemViewport and itemViewport:IsA("ViewportFrame") then
			itemViewport.CurrentCamera = nil
		end

		onDone()
	end)
end

function MatchNotificationsQueue:destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	table.clear(self._queue)
	self._active = false
	self:_refreshNotifying()
end

return MatchNotificationsQueue
