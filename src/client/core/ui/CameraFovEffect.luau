--!strict
--[[
	CameraFovEffect
	Pequeño helper reutilizable para el "POV zoom-out" cuando se abre un panel
	(Store, Settings, Rewards, etc.): guarda el FOV actual al abrir, lo aumenta
	un delta hasta un máximo, y lo restaura al cerrar.

	Uso:
		local fovEffect = CameraFovEffect.new()  -- delta=10, max=90 por defecto
		janitor:Add(fovEffect, "Destroy")
		-- onOpen:  fovEffect:expand()
		-- onClose: fovEffect:restore()

	Llamar `expand()` mientras ya hay un FOV guardado es no-op (idempotente).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Retween = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("Retween"))

local OPEN_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLOSE_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local DEFAULT_EXPAND_DELTA = 10
local DEFAULT_FOV_MAX = 90

export type CameraFovEffect = {
	_tweenSlot: Retween.Slot,
	_savedFov: number?,
	_expandDelta: number,
	_fovMax: number,
	expand: (self: CameraFovEffect) -> (),
	restore: (self: CameraFovEffect) -> (),
	Destroy: (self: CameraFovEffect) -> (),
}

local CameraFovEffect = {}
CameraFovEffect.__index = CameraFovEffect

function CameraFovEffect.new(options: { expandDelta: number?, fovMax: number? }?): CameraFovEffect
	local self = setmetatable({}, CameraFovEffect) :: any
	self._tweenSlot = { current = nil }
	self._savedFov = nil
	self._expandDelta = if options and options.expandDelta then options.expandDelta else DEFAULT_EXPAND_DELTA
	self._fovMax = if options and options.fovMax then options.fovMax else DEFAULT_FOV_MAX
	return self
end

function CameraFovEffect:_tweenTo(targetFov: number, tweenInfo: TweenInfo)
	local camera = Workspace.CurrentCamera
	if not camera then return end

	Retween.run(self._tweenSlot, camera, tweenInfo, { FieldOfView = targetFov })
end

function CameraFovEffect:expand()
	local camera = Workspace.CurrentCamera
	if not camera or self._savedFov ~= nil then return end

	local fov = camera.FieldOfView
	self._savedFov = fov
	self:_tweenTo(math.min(fov + self._expandDelta, self._fovMax), OPEN_TWEEN_INFO)
end

function CameraFovEffect:restore()
	local fov = self._savedFov
	if fov == nil then return end
	self:_tweenTo(fov, CLOSE_TWEEN_INFO)
	self._savedFov = nil
end

function CameraFovEffect:Destroy()
	Retween.cancel(self._tweenSlot)
end

return CameraFovEffect
