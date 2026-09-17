--!strict

-- Solo togglea `Enabled` del DepthOfFieldEffect que ya existe en Lighting (puesto
-- en el place; no lo crea ni configura). Lo conduce MatchState vía setEnabled.

local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local DepthOfFieldController = {}

-- En móvil (táctil sin mouse) no se enciende: post-effect a pantalla completa que
-- se apila con el blur de paneles donde esos jugadores pasan idle en el lobby.
local _isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local _dof: DepthOfFieldEffect? = nil
local _baseEnabled = false

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
		dof.Enabled = _baseEnabled and not _isMobile
	end
end

-- ScenePresetController reemplaza todos los effects de Lighting al aplicar/restaurar
-- un preset: el DoF pasa a ser otra instancia con el Enabled autorado del preset, y el
-- orden preset/setEnabled no está garantizado, así que hay que re-aplicar la fase.
local function _adoptDof(dof: DepthOfFieldEffect)
	_dof = dof
	_apply()
end

-- Con SignalBehavior Deferred los handlers corren tras todo el swap de effects del
-- preset y el `child` del evento puede estar ya desparentado: el evento solo sirve de
-- disparador, el estado se resuelve siempre contra Lighting vivo.
local function _resyncDof()
	local current = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if current == nil then
		_dof = nil
		return
	end
	if current ~= _dof then
		_adoptDof(current)
	else
		-- Re-afirmar Enabled por si el swap lo dejó como lo trae autorado el preset.
		_apply()
	end
end

Lighting.ChildAdded:Connect(function(child)
	if child:IsA("DepthOfFieldEffect") then
		_resyncDof()
	end
end)

Lighting.ChildRemoved:Connect(function(child)
	if child:IsA("DepthOfFieldEffect") then
		_resyncDof()
	end
end)

function DepthOfFieldController.setEnabled(enabled: boolean)
	_baseEnabled = enabled
	_apply()
end

return DepthOfFieldController
