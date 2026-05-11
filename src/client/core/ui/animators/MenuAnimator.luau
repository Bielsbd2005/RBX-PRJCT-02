--!strict

local TweenService = game:GetService("TweenService")

local HIDE_TIME = 0.1
local SHOW_TIME = 0.25
local STAGGER_DELAY = 0.01

local HIDE_INFO = TweenInfo.new(HIDE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local SHOW_INFO = TweenInfo.new(SHOW_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local OFFSCREEN = {
	Top = UDim2.new(0, 0, -0.25, 0),
	Bottom = UDim2.new(0, 0, 1.25, 0),
}

type ContainerData = {
	instance: GuiObject,
	originPos: UDim2,
	targetPos: UDim2,
	hideTween: Tween,
	showTween: Tween,
}

local MenuAnimator = {}
MenuAnimator.__index = MenuAnimator

function MenuAnimator.new(menuGui: ScreenGui)
	local self = setmetatable({}, MenuAnimator)
	self._containers = {} :: { ContainerData }
	self._scheduledThreads = {} :: { thread }
	self._generation = 0

	local priority = { "Top", "Bottom" }

	for _, name in ipairs(priority) do
		local container = menuGui:FindFirstChild(name)
		if container and container:IsA("GuiObject") then
			local originPos = container.Position
			local targetPos = OFFSCREEN[name] or UDim2.new(0, 0, -1, 0)
			table.insert(self._containers, {
				instance = container,
				originPos = originPos,
				targetPos = targetPos,
				hideTween = TweenService:Create(container, HIDE_INFO, { Position = targetPos }),
				showTween = TweenService:Create(container, SHOW_INFO, { Position = originPos }),
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

	for _, data in self._containers do
		data.hideTween:Cancel()
		data.showTween:Cancel()
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
		self:_scheduleTween(data.hideTween, (i - 1) * STAGGER_DELAY, generation)
	end
end

function MenuAnimator:show(): ()
	self:_cancelPending()

	local generation = self._generation

	for i = #self._containers, 1, -1 do
		local data = self._containers[i]
		self:_scheduleTween(data.showTween, (#self._containers - i) * STAGGER_DELAY, generation)
	end
end

function MenuAnimator:Destroy(): ()
	self:_cancelPending()
end

return MenuAnimator
