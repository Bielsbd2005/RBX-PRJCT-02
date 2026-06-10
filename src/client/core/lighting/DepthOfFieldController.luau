--!strict

-- DepthOfFieldController
-- Activa/desactiva el DepthOfFieldEffect que YA existe en Lighting (puesto en el
-- place). No lo crea ni lo configura: solo togglea su `Enabled` según la fase
-- (menú/locker → on, partida → off). Lo conduce MatchState vía setEnabled.

local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local DepthOfFieldController = {}

-- Audit P5: en móviles (táctil sin mouse) no encendemos DepthOfField; es un
-- post-effect a pantalla completa que se apila con el blur de paneles justo
-- donde los jugadores de móvil pasan idle en el lobby.
local _isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local _dof: DepthOfFieldEffect? = nil

local function _getDof(): DepthOfFieldEffect?
	if _dof and _dof.Parent then
		return _dof
	end
	_dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	return _dof
end

--- Enciende/apaga el DepthOfField del lobby. Lo conduce la fase de MatchState.
function DepthOfFieldController.setEnabled(enabled: boolean)
	local dof = _getDof()
	if dof then
		dof.Enabled = enabled and not _isMobile
	end
end

return DepthOfFieldController
