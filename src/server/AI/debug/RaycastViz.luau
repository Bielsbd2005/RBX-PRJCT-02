--!strict
--[[
	Debug de los raycasts de LoS de los bots (BotAI:_canSeeTarget). Toggle desde la Command Bar:
	  workspace:SetAttribute("DebugBotRaycasts", true)
	Crea una Part por raycast: no dejarlo activo en producción.
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

local COLOR_HIT = Color3.fromRGB(80, 255, 80)
local COLOR_BLOCKED = Color3.fromRGB(255, 80, 80)
local COLOR_VOID = Color3.fromRGB(255, 220, 80)

export type RayResult = "hit" | "blocked" | "void"

-- Bool cacheado: isEnabled() se consulta en cada raycast de LoS de cada bot y
-- leer el attribute del Workspace cada vez sería coste en producción.
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

	part.CFrame = CFrame.lookAt(origin + diff * 0.5, endPos)
	part.Parent = _ensureFolder()
	Debris:AddItem(part, 0.15)
end

return RaycastViz
