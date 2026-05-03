--!strict
--[[
	BlurController.luau (Client)

	Toggle del BlurEffect bajo Lighting con refcount. Refcount es importante
	porque varios paneles pueden abrirse a la vez (p. ej. el jugador abre
	Settings y luego Store antes de cerrar Settings); el blur debe seguir
	activo hasta que TODOS hayan cerrado.

	Uso:
	    local BlurController = require(.../BlurController)
	    BlurController.acquire("Settings")
	    -- ... cuando cierra:
	    BlurController.release("Settings")

	La key debe ser única por consumidor. acquire/release son idempotentes
	respecto a la misma key (un acquire seguido de otro acquire del mismo
	owner cuenta como uno solo). Esto evita leaks si un panel emite open
	dos veces sin cerrar.

	Defaults: usa el BlurEffect llamado "Blur" bajo Lighting si existe; si no,
	crea uno con `BLUR_SIZE` por defecto. La instance se reutiliza entre sesiones.
]]

local Lighting = game:GetService("Lighting")

local BLUR_NAME = "Blur"
local BLUR_SIZE = 18

local BlurController = {}

local _holders: { [string]: boolean } = {}
local _activeCount = 0

local function _ensureBlur(): BlurEffect
	local existing = Lighting:FindFirstChild(BLUR_NAME)
	if existing and existing:IsA("BlurEffect") then
		return existing
	end
	local blur = Instance.new("BlurEffect")
	blur.Name = BLUR_NAME
	blur.Size = BLUR_SIZE
	blur.Enabled = false
	blur.Parent = Lighting
	return blur
end

local function _setEnabled(enabled: boolean)
	local blur = _ensureBlur()
	blur.Enabled = enabled
end

--[[
	Marca a `owner` como solicitando blur. Activa el efecto si no estaba ya.
	Idempotente: llamar dos veces con el mismo owner no incrementa refcount.
]]
function BlurController.acquire(owner: string)
	if type(owner) ~= "string" or owner == "" then
		warn("[BlurController] acquire: owner inválido")
		return
	end
	if _holders[owner] then
		return -- ya cuenta.
	end
	_holders[owner] = true
	_activeCount += 1
	if _activeCount == 1 then
		_setEnabled(true)
	end
end

--[[
	Suelta la solicitud de `owner`. Desactiva el efecto si era el último.
	Idempotente: release sin acquire previo es no-op.
]]
function BlurController.release(owner: string)
	if type(owner) ~= "string" or owner == "" then
		return
	end
	if not _holders[owner] then
		return
	end
	_holders[owner] = nil
	_activeCount -= 1
	if _activeCount <= 0 then
		_activeCount = 0
		_setEnabled(false)
	end
end

--[[
	Estado actual del refcount. Útil para debugging / tests.
]]
function BlurController.isActive(): boolean
	return _activeCount > 0
end

return BlurController
