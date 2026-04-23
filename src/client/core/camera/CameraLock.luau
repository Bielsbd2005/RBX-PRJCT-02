--!strict
--[[
	CameraLock.luau
	Mecanismo simple para que una feature reclame control exclusivo
	de la cámara. Mientras haya un lock activo, otros sistemas
	deben abstenerse de modificar la cámara.
]]

local CameraLock = {}

local _owner: string? = nil

function CameraLock.acquire(owner: string): boolean
	if _owner ~= nil then
		return false
	end
	_owner = owner
	return true
end

function CameraLock.release(owner: string)
	if _owner == owner then
		_owner = nil
	end
end

function CameraLock.isLocked(): boolean
	return _owner ~= nil
end

function CameraLock.getOwner(): string?
	return _owner
end

return CameraLock
