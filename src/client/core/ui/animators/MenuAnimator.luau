--!strict

local TweenService = game:GetService("TweenService")

local HIDE_TIME = 0.1
local SHOW_TIME = 0.25
local STAGGER_DELAY = 0.01

local HIDE_INFO = TweenInfo.new(HIDE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local SHOW_INFO = TweenInfo.new(SHOW_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local OFFSCREEN = {
	UpperContainer = UDim2.new(0, 0, -0.25, 0),
	LeftContainer = UDim2.new(-0.25, 0, 0, 0),
	BottomContainer = UDim2.new(0, 0, 1.25, 0),
	RightContainer = UDim2.new(1.25, 0, 0, 0),
}

local MenuAnimator = {}
MenuAnimator.__index = MenuAnimator

function MenuAnimator.new(menuGui: ScreenGui)
	local self = setmetatable({}, MenuAnimator)
	self._containers = {}
	self._tweens = {}
	self._scheduledThreads = {}
	self._generation = 0

	local priority = { "UpperContainer", "LeftContainer", "RightContainer", "BottomContainer" }

	for _, name in ipairs(priority) do
		local container = menuGui:FindFirstChild(name)
		if container and container:IsA("GuiObject") then
			table.insert(self._containers, {
				instance = container,
				originPos = container.Position,
				targetPos = OFFSCREEN[name] or UDim2.new(0, 0, -1, 0),
			})
		end
	end

	return self
end

function MenuAnimator:_cancelPending(): ()
	self._generation += 1

	for _, delayedThread in ipairs(self._scheduledThreads) do
		pcall(task.cancel, delayedThread)
	end
	table.clear(self._scheduledThreads)

	for instance, tween in self._tweens do
		tween:Cancel()
		self._tweens[instance] = nil
	end
end

function MenuAnimator:_scheduleTween(tween: Tween, delayTime: number, generation: number): ()
	if delayTime <= 0 then
		if self._generation == generation then
			tween:Play()
		end
		return
	end

	local delayedThread = task.delay(delayTime, function()
		if self._generation ~= generation then
			return
		end

		tween:Play()
	end)

	table.insert(self._scheduledThreads, delayedThread)
end

function MenuAnimator:hide(): ()
	self:_cancelPending()

	local generation = self._generation

	for i, data in ipairs(self._containers) do
		local tween = TweenService:Create(data.instance, HIDE_INFO, { Position = data.targetPos })
		self._tweens[data.instance] = tween
		self:_scheduleTween(tween, (i - 1) * STAGGER_DELAY, generation)
	end
end

function MenuAnimator:show(): ()
	self:_cancelPending()

	local generation = self._generation

	for i = #self._containers, 1, -1 do
		local data = self._containers[i]
		local tween = TweenService:Create(data.instance, SHOW_INFO, { Position = data.originPos })
		self._tweens[data.instance] = tween
		self:_scheduleTween(tween, (#self._containers - i) * STAGGER_DELAY, generation)
	end
end

function MenuAnimator:Destroy(): ()
	self:_cancelPending()
end

return MenuAnimator
