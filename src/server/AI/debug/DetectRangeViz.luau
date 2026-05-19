--!strict
--[[
	DetectRangeViz — visualización de la esfera de detección de cada bot.

	Toggle desde Command Bar de Studio:
	  workspace:SetAttribute("DebugBotDetectRange", true)   -- enable
	  workspace:SetAttribute("DebugBotDetectRange", false)  -- disable
	  workspace:SetAttribute("DebugBotDetectRange", nil)    -- equivalente a false

	Implementación: SphereHandleAdornment parentado al HumanoidRootPart del
	bot. Es render-only — sin física, sin queries, sin colisión. Sigue al
	bot automáticamente (es un handle adornment).

	Se respeta el toggle via GetAttributeChangedSignal: flipear el atributo
	enciende/apaga todas las esferas a la vez sin restart.

	Coste: 1 SphereHandleAdornment por bot. 16 bots = 16 adornments. Render
	únicamente para clientes que tengan al bot visible. Despreciable.
]]

local Workspace = game:GetService("Workspace")

local DetectRangeViz = {}

local ATTR = "DebugBotDetectRange"

local function _isEnabled(): boolean
	return Workspace:GetAttribute(ATTR) == true
end

-- Crea y attachea el adornment al rootPart. Devuelve (adornment, connection)
-- para que el caller los limpie en Stop. El adornment se parentea al
-- rootPart, así que si el char muere y se destruye, el adornment muere
-- automáticamente — pero la connection necesita Disconnect explícito.
function DetectRangeViz.attach(rootPart: BasePart, radius: number): (SphereHandleAdornment, RBXScriptConnection)
	local adornment = Instance.new("SphereHandleAdornment")
	adornment.Name = "BotDetectRangeDbg"
	adornment.Adornee = rootPart
	adornment.Radius = radius
	adornment.Color3 = Color3.fromRGB(120, 200, 255) -- azul cyan
	adornment.Transparency = 0.85                     -- apenas visible
	adornment.AlwaysOnTop = false                     -- respeta oclusión
	adornment.ZIndex = 1
	adornment.Visible = _isEnabled()
	adornment.Parent = rootPart

	local conn = Workspace:GetAttributeChangedSignal(ATTR):Connect(function()
		if adornment.Parent then
			adornment.Visible = _isEnabled()
		end
	end)

	return adornment, conn
end

return DetectRangeViz
