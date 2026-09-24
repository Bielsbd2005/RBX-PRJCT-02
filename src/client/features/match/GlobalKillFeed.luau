--!strict
--[[
	Feed de muertes global (jugadores y bots). Studio: GlobalKillFeedContainer.Template
	con hijos directos Killer (TextLabel), Weapon (ImageLabel) y Victim (TextLabel).

	Contenedor y Template usan UIListLayout, así que no se puede animar Position:
	la entrada expande el alto + fade-in y la salida hace fade-out + colapso.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local TeamUtils = require(Shared.utils.TeamUtils)
local VipTag = require(Shared.utils.VipTag)
local AssetIds = require(Shared.constants.AssetIds)

local GlobalKillFeed = {}
local GlobalKillFeed_mt = { __index = GlobalKillFeed }

type FadeTarget = {
	object: Instance,
	property: string,
	original: number,
}

type GlobalKillFeedItem = {
	frame: GuiObject,
	fadeTargets: { FadeTarget },
	targetHeight: number,
	animateHeight: boolean,
	isDestroying: boolean,
}

local MAX_ITEMS = 5
local DISPLAY_TIME = 6
local SKULL_ICON = AssetIds.Images.Skull

local TEAM_A_COLOR = Color3.fromRGB(0, 161, 251)
local TEAM_B_COLOR = Color3.fromRGB(246, 82, 71)
local NEUTRAL_COLOR = Color3.fromRGB(220, 220, 220)

local ENTER_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EXIT_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

function GlobalKillFeed.new(matchHudGui: ScreenGui, matchHudInstance: any): any
	local self = setmetatable({}, GlobalKillFeed_mt)
	self._matchHudInstance = matchHudInstance
	self._activeItems = {} :: { GlobalKillFeedItem }
	self._destroyed = false
	local container = matchHudGui:WaitForChild("Container"):WaitForChild("GlobalKillFeedContainer") :: GuiObject
	self._container = container

	local template = container:WaitForChild("Template") :: GuiObject
	self._template = template
	template.Visible = false

	local listLayout = container:FindFirstChildOfClass("UIListLayout")
	if listLayout then
		listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	end

	local Network = require(Shared.networking.Network)
	self._connection = Network.Combat.KillFeed.Listen(function(data)
		self:pushKill(data.killerName, data.victimName, data.weaponId)
	end)

	return self
end

function GlobalKillFeed:_getParticipantTeamColor(name: string): Color3
	if not name or name == "" then
		return NEUTRAL_COLOR
	end

	local player = Players:FindFirstChild(name)
	if player then
		local side = if player.Character then TeamUtils.getSide(player.Character) else nil
		if not side then
			local attr = player:GetAttribute("TeamName")
			side = if typeof(attr) == "string" then TeamUtils.normalize(attr) else nil
		end
		if side == "A" then
			return TEAM_A_COLOR
		elseif side == "B" then
			return TEAM_B_COLOR
		end
	end

	if self._matchHudInstance and self._matchHudInstance._botRoster then
		for _, bot in pairs(self._matchHudInstance._botRoster) do
			if bot.displayName == name then
				if bot.team == "A" then
					return TEAM_A_COLOR
				elseif bot.team == "B" then
					return TEAM_B_COLOR
				end
			end
		end
	end

	return NEUTRAL_COLOR
end

function GlobalKillFeed:_getWeaponImage(weaponId: string): string
	if not weaponId or weaponId == "" then
		return SKULL_ICON
	end

	local mainItem = ItemsConfig.Main[weaponId]
	if mainItem and mainItem.Image then
		return mainItem.Image
	end

	local specialItem = ItemsConfig.Special[weaponId]
	if specialItem and specialItem.Image then
		return specialItem.Image
	end

	return SKULL_ICON
end

-- Guarda la transparencia original de cada elemento para no asumir que en Studio está todo en 0.
function GlobalKillFeed:_collectFadeTargets(item: GuiObject): { FadeTarget }
	local targets = {} :: { FadeTarget }

	local function add(object: Instance, property: string)
		targets[#targets + 1] = {
			object = object,
			property = property,
			original = (object :: any)[property],
		}
	end

	-- CanvasGroup: una sola propiedad para todo el grupo.
	if item:IsA("CanvasGroup") then
		add(item, "GroupTransparency")
		return targets
	end

	add(item, "BackgroundTransparency")
	for _, child in ipairs(item:GetDescendants()) do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			add(child, "TextTransparency")
			add(child, "BackgroundTransparency")
		elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
			add(child, "ImageTransparency")
			add(child, "BackgroundTransparency")
		elseif child:IsA("UIStroke") then
			add(child, "Transparency")
		end
	end

	return targets
end

function GlobalKillFeed:pushKill(killerName: string, victimName: string, weaponId: string)
	if self._destroyed then
		return
	end

	local killerColor = self:_getParticipantTeamColor(killerName)
	local victimColor = self:_getParticipantTeamColor(victimName)

	local item = self._template:Clone()
	item.Name = "KillItem"

	local killerLabel = item:FindFirstChild("Killer") :: TextLabel?
	local weaponImage = item:FindFirstChild("Weapon") :: ImageLabel?
	local victimLabel = item:FindFirstChild("Victim") :: TextLabel?

	local hasKiller = killerName ~= nil and killerName ~= ""

	-- Eliminador (oculto en suicidios/caídas; el arma muestra la calavera)
	if killerLabel then
		VipTag.apply(killerLabel, if hasKiller then killerName else "", VipTag.isVIPName(killerName))
		killerLabel.TextColor3 = killerColor
		killerLabel.Visible = hasKiller
	end

	if weaponImage then
		weaponImage.Image = if hasKiller then self:_getWeaponImage(weaponId) else SKULL_ICON
		weaponImage.Visible = true
	end

	if victimLabel then
		VipTag.apply(victimLabel, victimName, VipTag.isVIPName(victimName))
		victimLabel.TextColor3 = victimColor
		victimLabel.Visible = true
	end

	local fadeTargets = self:_collectFadeTargets(item)
	for _, target in ipairs(fadeTargets) do
		(target.object :: any)[target.property] = 1
	end

	-- Con AutomaticSize en Y el motor sobrescribe Size.Y: solo fade.
	local animateHeight = item.AutomaticSize == Enum.AutomaticSize.None
		or item.AutomaticSize == Enum.AutomaticSize.X
	local targetHeight = item.Size.Y.Offset
	if targetHeight <= 0 then
		targetHeight = 28
		animateHeight = false
	end

	if animateHeight then
		item.ClipsDescendants = true
		item.Size = UDim2.new(item.Size.X.Scale, item.Size.X.Offset, item.Size.Y.Scale, 0)
	end

	item.Visible = true
	item.Parent = self._container

	local feedItem: GlobalKillFeedItem = {
		frame = item,
		fadeTargets = fadeTargets,
		targetHeight = targetHeight,
		animateHeight = animateHeight,
		isDestroying = false,
	}

	table.insert(self._activeItems, feedItem)

	if animateHeight then
		TweenService:Create(item, ENTER_TWEEN, {
			Size = UDim2.new(item.Size.X.Scale, item.Size.X.Offset, item.Size.Y.Scale, targetHeight),
		}):Play()
	end
	for _, target in ipairs(fadeTargets) do
		TweenService:Create(target.object, ENTER_TWEEN, { [target.property] = target.original }):Play()
	end

	if #self._activeItems > MAX_ITEMS then
		local oldest = table.remove(self._activeItems, 1)
		if oldest then
			self:_removeItem(oldest)
		end
	end

	task.delay(DISPLAY_TIME, function()
		if self._destroyed then
			return
		end
		local idx = table.find(self._activeItems, feedItem)
		if idx then
			table.remove(self._activeItems, idx)
			self:_removeItem(feedItem)
		end
	end)
end

function GlobalKillFeed:_removeItem(item: GlobalKillFeedItem)
	if item.isDestroying then
		return
	end
	item.isDestroying = true

	local lastTween: Tween? = nil
	for _, target in ipairs(item.fadeTargets) do
		local tween = TweenService:Create(target.object, EXIT_TWEEN, { [target.property] = 1 })
		tween:Play()
		lastTween = tween
	end

	local function collapseAndDestroy()
		if item.animateHeight and item.frame.Parent then
			local collapse = TweenService:Create(item.frame, EXIT_TWEEN, {
				Size = UDim2.new(item.frame.Size.X.Scale, item.frame.Size.X.Offset, item.frame.Size.Y.Scale, 0),
			})
			collapse:Play()
			collapse.Completed:Once(function()
				item.frame:Destroy()
			end)
		else
			item.frame:Destroy()
		end
	end

	if lastTween then
		lastTween.Completed:Once(collapseAndDestroy)
	else
		collapseAndDestroy()
	end
end

function GlobalKillFeed:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	if self._connection then
		self._connection() -- ByteNet Listen returns a disconnect function
		self._connection = nil
	end

	for _, item in ipairs(self._activeItems) do
		item.frame:Destroy()
	end
	table.clear(self._activeItems)
end

return GlobalKillFeed
