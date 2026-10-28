--!strict
--[[
	Apagado temporal de las ScreenGuis de PlayerGui (features/options, mientras el menú
	de Roblox está abierto) sin perder el Enabled que piden sus dueños.

	Contrato: quien encienda o apague por código una ScreenGui de PlayerGui lo hace con
	`setEnabled`, y quien decida algo según su estado lee `getEnabled`. Un `Enabled = false`
	a pelo durante el apagado se pierde (ya estaba apagada) y la GUI reaparece al
	restaurar; un `true` a pelo sí se detecta.
]]

local GuiSuppression = {}

-- Enabled que piden los dueños de cada ScreenGui apagada. Vacío = sin apagado.
local _wanted: { [LayerCollector]: boolean } = {}
local _connections: { RBXScriptConnection } = {}
local _active = false

function GuiSuppression.setEnabled(gui: LayerCollector, enabled: boolean)
	if _wanted[gui] ~= nil then
		_wanted[gui] = enabled
		return
	end
	gui.Enabled = enabled
end

function GuiSuppression.getEnabled(gui: LayerCollector): boolean
	local wanted = _wanted[gui]
	if wanted ~= nil then
		return wanted
	end
	return gui.Enabled
end

local function suppressOne(gui: LayerCollector)
	if _wanted[gui] ~= nil then
		return
	end
	_wanted[gui] = gui.Enabled
	gui.Enabled = false
	table.insert(_connections, gui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if gui.Enabled and _wanted[gui] ~= nil then
			_wanted[gui] = true
			gui.Enabled = false
		end
	end))
end

--- Apaga las ScreenGuis de `container` (y las que lleguen después) salvo `except`.
function GuiSuppression.suppress(container: Instance, except: Instance?)
	if _active then
		return
	end
	_active = true

	local function consider(child: Instance)
		if child ~= except and child:IsA("ScreenGui") then
			suppressOne(child)
		end
	end
	for _, child in container:GetChildren() do
		consider(child)
	end
	table.insert(_connections, container.ChildAdded:Connect(consider))
end

function GuiSuppression.restore()
	if not _active then
		return
	end
	_active = false
	for _, connection in _connections do
		connection:Disconnect()
	end
	table.clear(_connections)

	local wanted = _wanted
	_wanted = {}
	for gui, enabled in wanted do
		if gui.Parent then
			gui.Enabled = enabled
		end
	end
end

return GuiSuppression
