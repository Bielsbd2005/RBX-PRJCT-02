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

export type DepthOfFieldProperties = {
	FarIntensity: number?,
	FocusDistance: number?,
	InFocusRadius: number?,
	NearIntensity: number?,
}

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

-- Snapshot de las propiedades del DOF antes de sobreescribirlas. Se guarda al
-- llamar setProperties(props) y se repone con setProperties(nil). Se re-captura
-- cada vez porque ScenePresetController puede reemplazar el DepthOfFieldEffect
-- entero al cambiar de preset, invalidando cualquier snapshot anterior.
local _propertiesOverrideActive = false
local _savedFarIntensity: number? = nil
local _savedFocusDistance: number? = nil
local _savedInFocusRadius: number? = nil
local _savedNearIntensity: number? = nil

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

--- Ajusta propiedades del DepthOfField (FarIntensity, FocusDistance, InFocusRadius, etc.).
--- Guarda los valores actuales ANTES de sobreescribir, para restaurarlos al pasar nil.
--- Re-captura el snapshot cada vez (el DepthOfFieldEffect puede haber sido reemplazado
--- por ScenePresetController entre llamadas).
function DepthOfFieldController.setProperties(props: DepthOfFieldProperties?)
	local dof = _getDof()
	if not dof then
		return
	end

	if props then
		-- Snapshot de los valores actuales antes de sobreescribir.
		if not _propertiesOverrideActive then
			_savedFarIntensity = dof.FarIntensity
			_savedFocusDistance = dof.FocusDistance
			_savedInFocusRadius = dof.InFocusRadius
			_savedNearIntensity = dof.NearIntensity
			_propertiesOverrideActive = true
		end

		if props.FarIntensity ~= nil then
			dof.FarIntensity = props.FarIntensity
		end
		if props.FocusDistance ~= nil then
			dof.FocusDistance = props.FocusDistance
		end
		if props.InFocusRadius ~= nil then
			dof.InFocusRadius = props.InFocusRadius
		end
		if props.NearIntensity ~= nil then
			dof.NearIntensity = props.NearIntensity
		end
	elseif _propertiesOverrideActive then
		-- Restaurar valores guardados.
		if _savedFarIntensity ~= nil then
			dof.FarIntensity = _savedFarIntensity
		end
		if _savedFocusDistance ~= nil then
			dof.FocusDistance = _savedFocusDistance
		end
		if _savedInFocusRadius ~= nil then
			dof.InFocusRadius = _savedInFocusRadius
		end
		if _savedNearIntensity ~= nil then
			dof.NearIntensity = _savedNearIntensity
		end
		_propertiesOverrideActive = false
		_savedFarIntensity = nil
		_savedFocusDistance = nil
		_savedInFocusRadius = nil
		_savedNearIntensity = nil
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
