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
local UserInputService = game:GetService("UserInputService")

local BLUR_NAME = "Blur"
-- Audit P5: en móviles (táctil sin mouse) reducimos el tamaño del blur a la
-- mitad para abaratar el post-effect a pantalla completa.
local _isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local BLUR_SIZE = if _isMobile then 9 else 18

local BlurController = {}

local _holders: { [string]: boolean } = {}
local _activeCount = 0
-- Supresores: fuerzan el blur OFF mientras al menos uno está activo, sin tocar
-- el refcount de holders (p. ej. el reveal del unboxing muestra una escena 3D a
-- pantalla completa que no debe ir borrosa aunque el Store siga "abierto").
local _suppressors: { [string]: boolean } = {}
local _suppressCount = 0

local function _ensureBlur(): BlurEffect
	local existing = Lighting:FindFirstChild(BLUR_NAME)
	if existing and existing:IsA("BlurEffect") then
		if _isMobile and existing.Size > BLUR_SIZE then
			existing.Size = BLUR_SIZE
		end
		return existing
	end
	local blur = Instance.new("BlurEffect")
	blur.Name = BLUR_NAME
	blur.Size = BLUR_SIZE
	blur.Enabled = false
	blur.Parent = Lighting
	return blur
end

-- El blur está activo solo si algún holder lo pide y ningún supresor lo veta.
local function _applyState()
	local blur = _ensureBlur()
	blur.Enabled = _activeCount > 0 and _suppressCount == 0
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
	_applyState()
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
	if _activeCount < 0 then
		_activeCount = 0
	end
	_applyState()
end

--[[
	Fuerza el blur OFF mientras `owner` lo suprima, sin alterar el refcount de
	holders. Idempotente por owner. Úsalo para escenas 3D a pantalla completa
	(reveal del unboxing) que no deben ir borrosas aunque el panel siga abierto.
]]
function BlurController.suppress(owner: string)
	if type(owner) ~= "string" or owner == "" then
		warn("[BlurController] suppress: owner inválido")
		return
	end
	if _suppressors[owner] then
		return
	end
	_suppressors[owner] = true
	_suppressCount += 1
	_applyState()
end

--[[
	Levanta la supresión de `owner`. El blur vuelve si algún holder lo pedía y no
	quedan más supresores. Idempotente: unsuppress sin suppress previo es no-op.
]]
function BlurController.unsuppress(owner: string)
	if type(owner) ~= "string" or owner == "" then
		return
	end
	if not _suppressors[owner] then
		return
	end
	_suppressors[owner] = nil
	_suppressCount -= 1
	if _suppressCount < 0 then
		_suppressCount = 0
	end
	_applyState()
end

--[[
	Estado actual del refcount. Útil para debugging / tests.
]]
function BlurController.isActive(): boolean
	return _activeCount > 0
end

return BlurController
