--!strict

-- DepthOfFieldController
-- Activa/desactiva el DepthOfFieldEffect que YA existe en Lighting (puesto en el
-- place). No lo crea ni lo configura: solo togglea su `Enabled` según la fase
-- (menú/locker → on, partida → off). Lo conduce MatchState vía setEnabled.
--
-- Además de la fase (base), acepta SUPRESORES: fuerzan el DoF OFF mientras al
-- menos uno esté activo, sin tocar el estado base (p. ej. el reveal del unboxing
-- muestra una escena 3D a pantalla completa que no debe llevar DoF aunque el
-- lobby lo tenga encendido). Simétrico con BlurController.

local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local DepthOfFieldController = {}

-- Audit P5: en móviles (táctil sin mouse) no encendemos DepthOfField; es un
-- post-effect a pantalla completa que se apila con el blur de paneles justo
-- donde los jugadores de móvil pasan idle en el lobby.
local _isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local _dof: DepthOfFieldEffect? = nil
-- Estado base (fase): lo fija setEnabled. El DoF está encendido solo si la base
-- lo pide y ningún supresor lo veta.
local _baseEnabled = false
local _suppressors: { [string]: boolean } = {}
local _suppressCount = 0

local function _getDof(): DepthOfFieldEffect?
	if _dof and _dof.Parent then
		return _dof
	end
	_dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	return _dof
end

local function _apply()
	local dof = _getDof()
	if dof then
		dof.Enabled = _baseEnabled and _suppressCount == 0 and not _isMobile
	end
end

--- Enciende/apaga el DepthOfField del lobby. Lo conduce la fase de MatchState.
function DepthOfFieldController.setEnabled(enabled: boolean)
	_baseEnabled = enabled
	_apply()
end

--- Fuerza el DoF OFF mientras `owner` lo suprima, sin alterar el estado base.
--- Idempotente por owner. Úsalo para escenas 3D a pantalla completa (reveal del
--- unboxing) que no deben llevar DoF aunque el lobby lo tenga encendido.
function DepthOfFieldController.suppress(owner: string)
	if type(owner) ~= "string" or owner == "" then
		warn("[DepthOfFieldController] suppress: owner inválido")
		return
	end
	if _suppressors[owner] then
		return
	end
	_suppressors[owner] = true
	_suppressCount += 1
	_apply()
end

--- Levanta la supresión de `owner`. El DoF vuelve si la base lo pide y no quedan
--- más supresores. Idempotente: unsuppress sin suppress previo es no-op.
function DepthOfFieldController.unsuppress(owner: string)
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
	_apply()
end

return DepthOfFieldController
