--!strict

-- DepthOfFieldController
-- Activa/desactiva el DepthOfFieldEffect que YA existe en Lighting (puesto en el
-- place). No lo crea ni lo configura: solo togglea su `Enabled` según la fase
-- (menú/locker → on, partida → off). Lo conduce MatchState vía setEnabled.

local Lighting = game:GetService("Lighting")

local DepthOfFieldController = {}

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
		dof.Enabled = enabled
	end
end

return DepthOfFieldController
