--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemDefaults = require(Shared:WaitForChild("constants"):WaitForChild("ItemDefaults"))
local WeaponWrapPainter = require(Shared:WaitForChild("Locker"):WaitForChild("WeaponWrapPainter"))
local wrapPreviewTemplate = ReplicatedStorage:WaitForChild("Templates"):WaitForChild("Wrap")
local sharedWeaponAssets = Shared:WaitForChild("Locker"):WaitForChild("weapons")

-- WrapId se pinta con la definición de ItemsConfig, la misma que usa la partida.
export type WeaponWrapPreviewItem = {
    WrapId: string?,
    PreviewWeaponCategory: string?,
    PreviewWeaponId: string?,
    PreviewWeaponDisplayName: string?,
}

local WeaponWrapPreviewer = {}

local FOV_IDEAL = 27
local DISTANCIA_MULTIPLIER = 0.52
-- Valores de la propiedad Orientation tal cual en Studio: fromEulerAnglesYXZ usa
-- el mismo orden que Orientation.
local ROTACION_X = 20
local ROTACION_Y = 35
local ROTACION_Z = 20
local orientacionFija = CFrame.fromEulerAnglesYXZ(
    math.rad(ROTACION_X),
    math.rad(ROTACION_Y),
    math.rad(ROTACION_Z)
)
-- Este yaw de la cámara es lo que descentra el arma en la card.
local CAMARA_ROTACION_Y = 4
local orientacionCamara = CFrame.fromEulerAnglesYXZ(0, math.rad(CAMARA_ROTACION_Y), 0)

-- Copias ya ancladas de cada template: Render solo clona (Clone conserva
-- Anchored) en vez de recorrer descendientes en cada card.
local _preparedTemplateCache: { [Instance]: Instance } = {}

local function _getPreparedTemplate(template: Instance): Instance
	local cached = _preparedTemplateCache[template]
	if cached then
		return cached
	end
	local prepared = template:Clone()
	if prepared:IsA("BasePart") then
		(prepared :: BasePart).Anchored = true
	end
	for _, desc in prepared:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
		end
	end
	_preparedTemplateCache[template] = prepared
	return prepared
end

local function resolveWeaponTemplate(item: WeaponWrapPreviewItem): Instance?
    local weaponCategory = if type(item.PreviewWeaponCategory) == "string" and item.PreviewWeaponCategory ~= ""
        then item.PreviewWeaponCategory
        else nil
    if not weaponCategory then
        return nil
    end

    local categoryFolder = sharedWeaponAssets:FindFirstChild(weaponCategory)
    if not categoryFolder then
        return nil
    end

    local weaponId = if type(item.PreviewWeaponId) == "string" and item.PreviewWeaponId ~= ""
        then item.PreviewWeaponId
        else nil
    local displayName = if type(item.PreviewWeaponDisplayName) == "string" and item.PreviewWeaponDisplayName ~= ""
        then item.PreviewWeaponDisplayName
        else nil

    return (if weaponId then categoryFolder:FindFirstChild(weaponId) else nil)
        or (if displayName then categoryFolder:FindFirstChild(displayName) else nil)
        -- El modelo fallback en Locker.weapons.* debe llamarse igual que ItemDefaults.ITEM_ID.
        or categoryFolder:FindFirstChild(ItemDefaults.ITEM_ID)
end

-- Encuadre para el template genérico `Wrap` (el de Render es el de las cards de arma).
local WRAP_CENTERED_CAMERA_DISTANCE_MULT = 1.9
local WRAP_CENTERED_ROTATION_X_DEG = 14
local WRAP_CENTERED_ROTATION_Y_DEG = 0
local WRAP_CENTERED_ROTATION_Z_DEG = 0
local WRAP_CENTERED_ORIENTATION = CFrame.fromEulerAnglesYXZ(
    math.rad(WRAP_CENTERED_ROTATION_X_DEG),
    math.rad(WRAP_CENTERED_ROTATION_Y_DEG),
    math.rad(WRAP_CENTERED_ROTATION_Z_DEG)
)

function WeaponWrapPreviewer.reframeCentered(vp: ViewportFrame): ()
    local cam = vp.CurrentCamera
    if not cam then return end
    local worldModel = vp:FindFirstChildOfClass("WorldModel")
    if not worldModel then return end

    local wrap: Instance? = worldModel:FindFirstChildWhichIsA("Model")
        or worldModel:FindFirstChildWhichIsA("BasePart")
    if not wrap then return end

    local pivotCenter: Vector3
    if wrap:IsA("Model") then
        local cf, _ = wrap:GetBoundingBox()
        pivotCenter = cf.Position
        wrap:PivotTo(CFrame.new(pivotCenter) * WRAP_CENTERED_ORIENTATION)
    else
        local part = wrap :: BasePart
        pivotCenter = part.Position
        part.CFrame = CFrame.new(pivotCenter) * WRAP_CENTERED_ORIENTATION
    end

    local centerPos: Vector3
    local size: Vector3
    if wrap:IsA("Model") then
        local cf, sz = wrap:GetBoundingBox()
        centerPos = cf.Position
        size = sz
    else
        local part = wrap :: BasePart
        centerPos = part.Position
        size = part.Size
    end

    local maxDim = math.max(size.X, size.Y, size.Z)
    local halfFov = math.rad(cam.FieldOfView / 2)
    local distance = (maxDim / 2) / math.tan(halfFov) * WRAP_CENTERED_CAMERA_DISTANCE_MULT

    cam.CFrame = CFrame.new(
        centerPos + Vector3.new(0, 0, distance),
        centerPos
    )
end

-- Devuelve el template sin clonar.
function WeaponWrapPreviewer.resolveWeaponTemplate(item: WeaponWrapPreviewItem): Instance?
    return resolveWeaponTemplate(item)
end


-- Devuelve (ok, usedWeaponTemplate). Si usedWeaponTemplate es false se pintó el
-- bloque genérico `Wrap` y el caller debe llamar después a `reframeCentered`.
function WeaponWrapPreviewer.Render(viewportNode: ViewportFrame, item: WeaponWrapPreviewItem, previewJanitor: any): (boolean, boolean)
    local worldModel = Instance.new("WorldModel")
    worldModel.Parent = viewportNode
    previewJanitor:Add(worldModel, "Destroy")

    local weaponTemplate = resolveWeaponTemplate(item)
    local usedWeaponTemplate = weaponTemplate ~= nil
    local previewTemplate = weaponTemplate or wrapPreviewTemplate
    local preparedTemplate = _getPreparedTemplate(previewTemplate)
    local clonedWrap = preparedTemplate:Clone()
    clonedWrap.Parent = worldModel
    previewJanitor:Add(clonedWrap, "Destroy")

    if not WeaponWrapPainter.paint(clonedWrap, WeaponWrapPainter.getDefinition(item.WrapId)) then
        return false, usedWeaponTemplate
    end

    local modelCenter: CFrame
    local updatedSize: Vector3
    if clonedWrap:IsA("Model") then
        modelCenter = clonedWrap:GetBoundingBox()
        clonedWrap:PivotTo(CFrame.new(modelCenter.Position) * orientacionFija)
        modelCenter, updatedSize = clonedWrap:GetBoundingBox()
    elseif clonedWrap:IsA("BasePart") then
        modelCenter = clonedWrap.CFrame
        updatedSize = clonedWrap.Size
        clonedWrap.CFrame = CFrame.new(modelCenter.Position) * orientacionFija
    else
        return false, usedWeaponTemplate
    end

    local cam = Instance.new("Camera")
    cam.FieldOfView = FOV_IDEAL
    viewportNode.CurrentCamera = cam
    cam.Parent = viewportNode
    previewJanitor:Add(cam, "Destroy")

    local maxDimension = math.max(updatedSize.X, updatedSize.Y, updatedSize.Z)
    local halfFov = math.rad(cam.FieldOfView / 2)
    local baseDistance = (maxDimension / 2) / math.tan(halfFov)
    local finalDistance = baseDistance * DISTANCIA_MULTIPLIER

    cam.CFrame = CFrame.new(modelCenter.Position + Vector3.new(0, 0, finalDistance)) * orientacionCamara

    viewportNode.Visible = true
    return true, usedWeaponTemplate
end

return WeaponWrapPreviewer
