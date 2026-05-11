--!strict
--[[
	WeaponWrapAnimator
	Anima el OffsetStudsU/V de cada Texture taggeada como
	`AnimatedWeaponWrapTexture` para crear el efecto de wrap "scrolling".

	Sprint 3: en vez de `CollectionService:GetTagged()` cada RenderStepped
	(60Hz × N textures + GetAttribute × 2 por texture), mantenemos un set
	local actualizado por GetInstanceAddedSignal/GetInstanceRemovedSignal y
	cacheamos las velocidades por texture al sumar (con AttributeChanged
	para refrescar). El RenderStepped solo itera el set cacheado.
]]

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local WeaponWrapAnimator = {}

local ANIMATED_WRAP_TEXTURE_TAG = "AnimatedWeaponWrapTexture"
local DEFAULT_WRAP_SCROLL_SPEED_U = 1
local DEFAULT_WRAP_SCROLL_SPEED_V = 0

type TrackedTexture = {
	speedU: number,
	speedV: number,
	attrConn: RBXScriptConnection,
}

local _connection: RBXScriptConnection? = nil
local _addedConn: RBXScriptConnection? = nil
local _removedConn: RBXScriptConnection? = nil
local _tracked: { [Texture]: TrackedTexture } = {}

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

local function _refreshAttrs(texture: Texture, entry: TrackedTexture)
	entry.speedU = _toNumberAttribute(texture:GetAttribute("WrapScrollSpeedU"), DEFAULT_WRAP_SCROLL_SPEED_U)
	entry.speedV = _toNumberAttribute(texture:GetAttribute("WrapScrollSpeedV"), DEFAULT_WRAP_SCROLL_SPEED_V)
end

local function _track(instance: Instance)
	if not instance:IsA("Texture") then return end
	local texture = instance :: Texture
	if _tracked[texture] then return end

	local entry: TrackedTexture = {
		speedU = DEFAULT_WRAP_SCROLL_SPEED_U,
		speedV = DEFAULT_WRAP_SCROLL_SPEED_V,
		attrConn = texture.AttributeChanged:Connect(function(name)
			if name == "WrapScrollSpeedU" or name == "WrapScrollSpeedV" then
				local cached = _tracked[texture]
				if cached then
					_refreshAttrs(texture, cached)
				end
			end
		end),
	}
	_refreshAttrs(texture, entry)
	_tracked[texture] = entry
end

local function _untrack(instance: Instance)
	if not instance:IsA("Texture") then return end
	local texture = instance :: Texture
	local entry = _tracked[texture]
	if not entry then return end
	entry.attrConn:Disconnect()
	_tracked[texture] = nil
end

function WeaponWrapAnimator.start()
	if _connection then
		return
	end

	-- Snapshot inicial (textures ya en el mundo cuando arranca el feature).
	for _, instance in CollectionService:GetTagged(ANIMATED_WRAP_TEXTURE_TAG) do
		_track(instance)
	end

	_addedConn = CollectionService:GetInstanceAddedSignal(ANIMATED_WRAP_TEXTURE_TAG):Connect(_track)
	_removedConn = CollectionService:GetInstanceRemovedSignal(ANIMATED_WRAP_TEXTURE_TAG):Connect(_untrack)

	_connection = RunService.RenderStepped:Connect(function(dt)
		for texture, entry in _tracked do
			if texture.Parent == nil then
				_untrack(texture)
				continue
			end
			local tileU = _resolveTile(texture.StudsPerTileU)
			local tileV = _resolveTile(texture.StudsPerTileV)
			texture.OffsetStudsU = (texture.OffsetStudsU + entry.speedU * dt) % tileU
			texture.OffsetStudsV = (texture.OffsetStudsV + entry.speedV * dt) % tileV
		end
	end)
end

function WeaponWrapAnimator.stop()
	if _connection then
		_connection:Disconnect()
		_connection = nil
	end
	if _addedConn then
		_addedConn:Disconnect()
		_addedConn = nil
	end
	if _removedConn then
		_removedConn:Disconnect()
		_removedConn = nil
	end
	for texture, entry in _tracked do
		entry.attrConn:Disconnect()
		_tracked[texture] = nil
	end
end

return WeaponWrapAnimator
