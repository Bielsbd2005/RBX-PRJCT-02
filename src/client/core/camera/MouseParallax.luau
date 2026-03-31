--!strict

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local MAX_YAW_DEGREES = 1.6
local MAX_PITCH_DEGREES = 1.1
local SMOOTHING_SPEED = 10

export type MouseParallax = {
	_camera: Camera,
	_getBaseCFrame: () -> CFrame,
	_renderConnection: RBXScriptConnection?,
	_currentYaw: number,
	_currentPitch: number,
	isActive: (self: MouseParallax) -> boolean,
	start: (self: MouseParallax) -> (),
	stop: (self: MouseParallax, resetOffset: boolean?) -> (),
	Destroy: (self: MouseParallax) -> (),
}

local MouseParallax = {}
MouseParallax.__index = MouseParallax

function MouseParallax.new(camera: Camera, getBaseCFrame: () -> CFrame): MouseParallax
	local self = setmetatable({}, MouseParallax) :: any
	self._camera = camera
	self._getBaseCFrame = getBaseCFrame
	self._renderConnection = nil
	self._currentYaw = 0
	self._currentPitch = 0
	return self
end

function MouseParallax:isActive(): boolean
	return self._renderConnection ~= nil
end

function MouseParallax:start()
	if self._renderConnection then
		return
	end

	self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime: number)
		local viewportSize = self._camera.ViewportSize
		if viewportSize.X <= 0 or viewportSize.Y <= 0 then
			return
		end

		local mousePosition = UserInputService:GetMouseLocation()
		local normalizedX = math.clamp((mousePosition.X / viewportSize.X - 0.5) * 2, -1, 1)
		local normalizedY = math.clamp((mousePosition.Y / viewportSize.Y - 0.5) * 2, -1, 1)

		local targetYaw = math.rad(-normalizedX * MAX_YAW_DEGREES)
		local targetPitch = math.rad(-normalizedY * MAX_PITCH_DEGREES)
		local alpha = 1 - math.exp(-SMOOTHING_SPEED * deltaTime)

		self._currentYaw += (targetYaw - self._currentYaw) * alpha
		self._currentPitch += (targetPitch - self._currentPitch) * alpha

		local baseCFrame = self._getBaseCFrame()
		self._camera.CFrame = baseCFrame * CFrame.Angles(self._currentPitch, self._currentYaw, 0)
	end)
end

function MouseParallax:stop(resetOffset: boolean?)
	if self._renderConnection then
		self._renderConnection:Disconnect()
		self._renderConnection = nil
	end

	if resetOffset ~= false then
		self._currentYaw = 0
		self._currentPitch = 0
	end
end

function MouseParallax:Destroy()
	self:stop(true)
end

return MouseParallax
