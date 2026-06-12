--!strict
--[[
	RaycastViz — visualización debug de los raycasts de detección de los bots.

	Toggle desde Command Bar de Studio:
	  workspace:SetAttribute("DebugBotRaycasts", true)   -- enable
	  workspace:SetAttribute("DebugBotRaycasts", false)  -- disable
	  workspace:SetAttribute("DebugBotRaycasts", nil)    -- equivalente a false

	Mientras está enabled, cada llamada a BotAI:_canSeeTarget renderiza una
	línea fina entre el origen del rayo y el destino con color según resultado:
	  • verde:  LOS confirmada (el rayo llegó al target)
	  • rojo:   LOS bloqueada (rayo chocó con obstáculo antes del target)
	  • amarillo: rayo no impactó nada (caso raro, p.ej. target sin
	              HumanoidRootPart o dirección fuera de rango efectivo)

	Las Parts viven 0.15s y se destruyen vía Debris — visible como un stream
	continuo de líneas mientras los bots evalúan targets.

	Coste: cada raycast renderiza 1 Part. A 10Hz × 16 bots × hasta 3
	raycasts/eval (multi-point) = ~480 Parts/sec máx en peor caso. Con
	Debris a 0.15s, ~72 Parts vivas en cualquier momento. Aceptable para
	sesión de debug; NO dejar enabled en producción.
]]

local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local RaycastViz = {}

local _folder: Folder? = nil

local function _ensureFolder(): Folder
	local existing = _folder
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "BotRaycastDebug"
	folder.Parent = Workspace
	_folder = folder
	return folder
end

local COLOR_HIT = Color3.fromRGB(80, 255, 80)    -- verde — LOS al target
local COLOR_BLOCKED = Color3.fromRGB(255, 80, 80) -- rojo — bloqueado
local COLOR_VOID = Color3.fromRGB(255, 220, 80)   -- amarillo — no hit

export type RayResult = "hit" | "blocked" | "void"

-- Bool cacheado tras GetAttributeChangedSignal (mismo patrón que
-- DetectRangeViz con _IS_STUDIO): isEnabled() se consulta por cada raycast
-- de LoS (10Hz × N bots), y leer el attribute del Workspace cada vez era el
-- único coste de producción de este módulo de debug.
local _enabled = Workspace:GetAttribute("DebugBotRaycasts") == true
Workspace:GetAttributeChangedSignal("DebugBotRaycasts"):Connect(function()
	_enabled = Workspace:GetAttribute("DebugBotRaycasts") == true
end)

function RaycastViz.isEnabled(): boolean
	return _enabled
end

function RaycastViz.draw(origin: Vector3, endPos: Vector3, result: RayResult)
	if not RaycastViz.isEnabled() then
		return
	end

	local diff = endPos - origin
	local len = diff.Magnitude
	if len < 0.05 then
		return
	end

	local part = Instance.new("Part")
	part.Name = "BotRayDbg"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = Vector3.new(0.15, 0.15, len)
	part.Material = Enum.Material.Neon
	part.Transparency = 0.35

	if result == "hit" then
		part.Color = COLOR_HIT
	elseif result == "blocked" then
		part.Color = COLOR_BLOCKED
	else
		part.Color = COLOR_VOID
	end

	-- CFrame.lookAt orienta la Part a lo largo del vector. El centro queda
	-- en el midpoint y la longitud Z = len.
	part.CFrame = CFrame.lookAt(origin + diff * 0.5, endPos)
	part.Parent = _ensureFolder()
	Debris:AddItem(part, 0.15)
end

return RaycastViz
