--!strict
--[[
	MatchNotificationsQueue.luau
	Queue + animaciones de notificaciones in-match: level up, BattlePass level up,
	challenge completed. Extraído de MatchHud para que ese módulo no orqueste
	tanto. Los frames y sus posiciones originales se cachean por instancia.

	API:
		MatchNotificationsQueue.new(matchHudGui: ScreenGui?)
		:playLevelUpAnimation(newLevel: number, unlock: LevelUpUnlock?)
		:playBattlePassLevelUpAnimation(newLevel: number)
		:playChallengeCompletedAnimation(reward: ChallengeCompletedReward)
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
	animated: boolean?,
	studsPerTile: number?,
	cashAmount: number?,
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

-- ── Módulo ───────────────────────────────────────────────────

local MatchNotificationsQueue = {}
MatchNotificationsQueue.__index = MatchNotificationsQueue

function MatchNotificationsQueue.new(matchHudGui: ScreenGui?): any
	local self = setmetatable({}, MatchNotificationsQueue)
	self._gui = matchHudGui
	self._destroyed = false
	self._queue = {} :: { (onDone: () -> ()) -> () }
	self._active = false
	-- Cache de posiciones originales de cada frame (se setean en el primer play).
	self._levelUpOriginalPosition = nil :: UDim2?
	self._battlePassLevelUpOriginalPosition = nil :: UDim2?
	self._completedOriginalPosition = nil :: UDim2?
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

function MatchNotificationsQueue:_processQueue()
	if self._active or self._destroyed then
		return
	end
	local nextRun = table.remove(self._queue, 1)
	if not nextRun then
		return
	end

	self._active = true
	task.spawn(function()
		nextRun(function()
			self._active = false
			if not self._destroyed then
				self:_processQueue()
			end
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

function MatchNotificationsQueue:playBattlePassLevelUpAnimation(newLevel: number)
	self:_enqueue(function(onDone)
		local matchHudGui = self._gui
		if not matchHudGui then onDone() return end

		local container = self:_resolveContainer()
		if not container then onDone() return end

		local frame = _findChildGuiObject(container, "BattlePassLevelUp")
		if not frame then onDone() return end

		local originalPosition = self._battlePassLevelUpOriginalPosition
		if not originalPosition then
			originalPosition = frame.Position
			self._battlePassLevelUpOriginalPosition = originalPosition
		end

		local aboveScreenPosition = UDim2.new(
			originalPosition.X.Scale,
			originalPosition.X.Offset,
			-1,
			originalPosition.Y.Offset
		)

		local resolvedLevel = math.max(0, math.floor(newLevel))

		local levelLabel = _findDescendantTextLabel(frame, { "Level" })
		if levelLabel then
			levelLabel.Text = tostring(resolvedLevel)
		end

		frame.Position = aboveScreenPosition
		frame.Visible = true

		Confetti.Rain(matchHudGui, {
			colors = BATTLEPASS_LEVEL_UP_CONFETTI_COLORS,
			count = 60,
			minLifetime = 0.9,
			maxLifetime = 1.5,
			spawnDuration = 1.2,
		})

		local tweenIn = TweenService:Create(frame, LEVEL_UP_TWEEN_IN_INFO, { Position = originalPosition })
		tweenIn:Play()
		tweenIn.Completed:Wait()

		task.wait(LEVEL_UP_HOLD_SECONDS)

		local tweenOut = TweenService:Create(frame, LEVEL_UP_TWEEN_OUT_INFO, { Position = aboveScreenPosition })
		tweenOut:Play()
		tweenOut.Completed:Wait()

		frame.Visible = false
		frame.Position = originalPosition

		onDone()
	end)
end

function MatchNotificationsQueue:playChallengeCompletedAnimation(reward: ChallengeCompletedReward)
	self:_enqueue(function(onDone)
		local matchHudGui = self._gui
		if not matchHudGui then onDone() return end

		local container = self:_resolveContainer()
		if not container then onDone() return end

		local completedFrame = _findChildGuiObject(container, "Completed")
		if not completedFrame then onDone() return end

		local rewardNode = _findChildGuiObject(completedFrame, "Reward")
			or _findChildGuiObject(container, "Reward")
		local itemImage = if rewardNode then rewardNode:FindFirstChild("ItemImage") else nil
		local itemViewport = if rewardNode then rewardNode:FindFirstChild("ItemViewport") else nil
		local rewardValueLabel = if rewardNode then rewardNode:FindFirstChild("Value") else nil
		local descriptionLabel = _findDescendantTextLabel(completedFrame, { "Description" })

		-- Reward.Value está oculto por defecto (no lo usan los challenges de
		-- wrap). Si llega cashAmount, lo mostramos con la cantidad y lo
		-- restauramos a oculto al cerrar el frame.
		local showedRewardValue = false
		if rewardValueLabel and rewardValueLabel:IsA("TextLabel") and type(reward.cashAmount) == "number" then
			rewardValueLabel.Text = UIUtils.formatCashAmount(reward.cashAmount)
			rewardValueLabel.Visible = true
			showedRewardValue = true
		end

		local originalPosition = self._completedOriginalPosition
		if not originalPosition then
			originalPosition = completedFrame.Position
			self._completedOriginalPosition = originalPosition
		end

		local aboveScreenPosition = UDim2.new(
			originalPosition.X.Scale,
			originalPosition.X.Offset,
			-1,
			originalPosition.Y.Offset
		)

		if descriptionLabel then
			descriptionLabel.Text = "You earned " .. tostring(reward.name)
		end

		local previewJanitor: any = nil

		local hasImage = type(reward.image) == "string" and reward.image ~= ""
		if itemImage and (itemImage:IsA("ImageLabel") or itemImage:IsA("ImageButton")) then
			if hasImage then
				itemImage.Image = reward.image :: string
				itemImage.Visible = true
			else
				itemImage.Visible = false
			end
		end

		if itemViewport and itemViewport:IsA("ViewportFrame") then
			if hasImage then
				itemViewport.Visible = false
				for _, child in itemViewport:GetChildren() do
					if not child:IsA("GuiObject") then
						child:Destroy()
					end
				end
				itemViewport.CurrentCamera = nil
			else
				itemViewport.Visible = true
				for _, child in itemViewport:GetChildren() do
					if not child:IsA("GuiObject") then
						child:Destroy()
					end
				end
				previewJanitor = Janitor.new()
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
					isAnimated = reward.animated,
					StudsPerTile = reward.studsPerTile,
					PreviewWeaponCategory = reward.previewWeaponCategory,
					PreviewWeaponId = reward.previewWeaponId,
				}
				WeaponWrapPreviewer.Render(itemViewport, previewItem :: any, previewJanitor)
			end
		end

		completedFrame.Position = aboveScreenPosition
		completedFrame.Visible = true

		Confetti.Rain(matchHudGui, {
			colors = CHALLENGE_CONFETTI_COLORS,
			count = 60,
			minLifetime = 0.9,
			maxLifetime = 1.5,
			spawnDuration = 0.4,
		})

		local tweenIn = TweenService:Create(completedFrame, LEVEL_UP_TWEEN_IN_INFO, { Position = originalPosition })
		tweenIn:Play()
		tweenIn.Completed:Wait()

		task.wait(LEVEL_UP_HOLD_SECONDS)

		local tweenOut = TweenService:Create(completedFrame, LEVEL_UP_TWEEN_OUT_INFO, { Position = aboveScreenPosition })
		tweenOut:Play()
		tweenOut.Completed:Wait()

		completedFrame.Visible = false
		completedFrame.Position = originalPosition

		if previewJanitor then
			previewJanitor:Cleanup()
		end
		if itemViewport and itemViewport:IsA("ViewportFrame") then
			itemViewport.CurrentCamera = nil
		end

		-- Restaurar Reward.Value a oculto si lo habíamos mostrado, para no
		-- contaminar la próxima notificación que use este mismo frame.
		if showedRewardValue and rewardValueLabel and rewardValueLabel:IsA("TextLabel") then
			rewardValueLabel.Visible = false
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
end

return MatchNotificationsQueue
