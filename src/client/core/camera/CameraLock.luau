--!strict
-- Control exclusivo de la cámara: mientras haya un lock activo, los demás
-- sistemas deben abstenerse de modificarla (no se impone, es por convención).

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

return CameraLock
