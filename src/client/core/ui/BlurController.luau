--!strict
--[[
	Toggle del BlurEffect bajo Lighting con refcount: varios paneles pueden estar
	abiertos a la vez y el blur debe seguir activo hasta que TODOS cierren.
	acquire/release son idempotentes por key (única por consumidor), para no
	filtrar si un panel emite open dos veces sin cerrar.
	Reutiliza el BlurEffect "Blur" de Lighting si existe; si no, lo crea.
]]

local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local BLUR_NAME = "Blur"
-- En móviles táctiles sin mouse, blur a la mitad para abaratar el post-effect.
local _isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local BLUR_SIZE = if _isMobile then 9 else 18

local BlurController = {}

local _holders: { [string]: boolean } = {}
local _activeCount = 0

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

local function _applyState()
	local blur = _ensureBlur()
	blur.Enabled = _activeCount > 0
end

function BlurController.acquire(owner: string)
	if type(owner) ~= "string" or owner == "" then
		warn("[BlurController] acquire: owner inválido")
		return
	end
	if _holders[owner] then
		return
	end
	_holders[owner] = true
	_activeCount += 1
	_applyState()
end

function BlurController.release(owner: string)
	if type(owner) ~= "string" or owner == "" then
		return
	end
	if not _holders[owner] then
		return
	end
	_holders[owner] = nil
	_activeCount -= 1
	_applyState()
end

return BlurController
