--!strict
--[[
	Esfera de detección de cada bot (solo Studio). Toggle en caliente desde la
	Command Bar: workspace:SetAttribute("DebugBotDetectRange", true/false).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DetectRangeViz = {}

local ATTR = "DebugBotDetectRange"
local _IS_STUDIO = RunService:IsStudio()

function DetectRangeViz.isEnabled(): boolean
	return _IS_STUDIO and Workspace:GetAttribute(ATTR) == true
end

-- El adornment muere con el rootPart, pero la conexión devuelta necesita
-- Disconnect explícito del caller.
function DetectRangeViz.attach(rootPart: BasePart, radius: number): (SphereHandleAdornment?, RBXScriptConnection?)
	if not _IS_STUDIO then
		return nil, nil
	end

	local adornment = Instance.new("SphereHandleAdornment")
	adornment.Name = "BotDetectRangeDbg"
	adornment.Adornee = rootPart
	adornment.Radius = radius
	adornment.Color3 = Color3.fromRGB(120, 200, 255)
	adornment.Transparency = 0.85
	adornment.AlwaysOnTop = false
	adornment.ZIndex = 1
	adornment.Visible = DetectRangeViz.isEnabled()
	adornment.Parent = rootPart

	local conn = Workspace:GetAttributeChangedSignal(ATTR):Connect(function()
		if adornment.Parent then
			adornment.Visible = DetectRangeViz.isEnabled()
		end
	end)

	return adornment, conn
end

return DetectRangeViz
