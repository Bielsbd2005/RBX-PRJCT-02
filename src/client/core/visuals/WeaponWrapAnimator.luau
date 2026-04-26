--!strict

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local WeaponWrapAnimator = {}

local ANIMATED_WRAP_TEXTURE_TAG = "AnimatedWeaponWrapTexture"
local DEFAULT_WRAP_SCROLL_SPEED_U = 1
local DEFAULT_WRAP_SCROLL_SPEED_V = 0

local _connection: RBXScriptConnection? = nil

local function _resolveTile(value: number): number
	local magnitude = math.abs(value)
	if magnitude > 0.001 then
		return magnitude
	end
	return 1
end

local function _toNumberAttribute(value: any, fallback: number): number
	local parsed = tonumber(value)
	if parsed == nil then
		return fallback
	end
	return parsed
end

local function _updateTexture(texture: Texture, dt: number)
	if texture.Parent == nil then
		return
	end

	local speedU = _toNumberAttribute(texture:GetAttribute("WrapScrollSpeedU"), DEFAULT_WRAP_SCROLL_SPEED_U)
	local speedV = _toNumberAttribute(texture:GetAttribute("WrapScrollSpeedV"), DEFAULT_WRAP_SCROLL_SPEED_V)
	local tileU = _resolveTile(texture.StudsPerTileU)
	local tileV = _resolveTile(texture.StudsPerTileV)

	texture.OffsetStudsU = (texture.OffsetStudsU + speedU * dt) % tileU
	texture.OffsetStudsV = (texture.OffsetStudsV + speedV * dt) % tileV
end

function WeaponWrapAnimator.start()
	if _connection then
		return
	end

	_connection = RunService.RenderStepped:Connect(function(dt)
		for _, instance in CollectionService:GetTagged(ANIMATED_WRAP_TEXTURE_TAG) do
			if instance:IsA("Texture") then
				_updateTexture(instance, dt)
			end
		end
	end)
end

function WeaponWrapAnimator.stop()
	if _connection then
		_connection:Disconnect()
		_connection = nil
	end
end

return WeaponWrapAnimator
