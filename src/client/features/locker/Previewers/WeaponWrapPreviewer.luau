--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemDefaults = require(Shared:WaitForChild("constants"):WaitForChild("ItemDefaults"))
local wrapPreviewTemplate = ReplicatedStorage:WaitForChild("Wrap")
local sharedWeaponAssets = Shared:WaitForChild("Locker"):WaitForChild("weapons")

export type WeaponWrapPreviewItem = {
    TextureID: string?,
    BaseColor: Color3?,
    isAnimated: boolean?,
    StudsPerTile: number?,
    PreviewWeaponCategory: string?,
    PreviewWeaponId: string?,
    PreviewWeaponDisplayName: string?,
}

local WeaponWrapPreviewer = {}

-- Constantes visuales del viewport
local DEFAULT_WRAP_STUDS_PER_TILE = 3
local WRAP_TEXTURE_SCROLL_SPEED_U = 1
local WRAP_TEXTURE_SCROLL_SPEED_V = 0
local FOV_IDEAL = 30
local DISTANCIA_MULTIPLIER = 0.52
local DESPLAZAMIENTO_X = 0.2
local ROTACION_X = 0
local ROTACION_Y = 130
local ROTACION_Z = -12
local orientacionFija = CFrame.fromEulerAnglesYXZ(
    math.rad(ROTACION_X),
    math.rad(ROTACION_Y),
    math.rad(ROTACION_Z)
)

local WEAPON_WRAP_TEXTURE_FACE_BY_NAME = {
    ScrollTexture_Back = Enum.NormalId.Back,
    ScrollTexture_Bottom = Enum.NormalId.Bottom,
    ScrollTexture_Left = Enum.NormalId.Left,
    ScrollTexture_Right = Enum.NormalId.Right,
    ScrollTexture_Front = Enum.NormalId.Front,
    ScrollTexture_Top = Enum.NormalId.Top,
} :: { [string]: Enum.NormalId }

local WEAPON_WRAP_TEXTURE_ORDER = {
    "ScrollTexture_Back",
    "ScrollTexture_Bottom",
    "ScrollTexture_Left",
    "ScrollTexture_Right",
    "ScrollTexture_Front",
    "ScrollTexture_Top",
} :: { string }

local activeAnimatedWrapTextures = {} :: { [Texture]: boolean }
local activeAnimatedWrapConnection: RBXScriptConnection? = nil

local function stopActiveAnimatedWrapLoopIfIdle(): ()
    if next(activeAnimatedWrapTextures) ~= nil then
        return
    end

    if activeAnimatedWrapConnection then
        activeAnimatedWrapConnection:Disconnect()
        activeAnimatedWrapConnection = nil
    end
end

local function ensureActiveAnimatedWrapLoop(): ()
    if activeAnimatedWrapConnection then
        return
    end

    activeAnimatedWrapConnection = RunService.Heartbeat:Connect(function(dt)
        for texture in activeAnimatedWrapTextures do
            if texture.Parent == nil then
                activeAnimatedWrapTextures[texture] = nil
            else
                local tileU = if texture.StudsPerTileU ~= 0 then texture.StudsPerTileU else 1
                local tileV = if texture.StudsPerTileV ~= 0 then texture.StudsPerTileV else 1
                texture.OffsetStudsU = (texture.OffsetStudsU + WRAP_TEXTURE_SCROLL_SPEED_U * dt) % tileU
                texture.OffsetStudsV = (texture.OffsetStudsV + WRAP_TEXTURE_SCROLL_SPEED_V * dt) % tileV
            end
        end

        stopActiveAnimatedWrapLoopIfIdle()
    end)
end

local function registerAnimatedWrapTextures(previewJanitor: any, textures: { Texture }): ()
    if #textures <= 0 then
        return
    end

    for _, texture in textures do
        activeAnimatedWrapTextures[texture] = true
    end

    ensureActiveAnimatedWrapLoop()

    previewJanitor:Add(function()
        for _, texture in textures do
            activeAnimatedWrapTextures[texture] = nil
        end
        stopActiveAnimatedWrapLoopIfIdle()
    end, true)
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
        -- "Default" aquí es el nombre del Tool fallback en Locker.weapons.*; por convención
        -- coincide con el item-id default del catálogo, así que reusamos ItemDefaults.ITEM_ID.
        or categoryFolder:FindFirstChild(ItemDefaults.ITEM_ID)
end

local function getWrapPreviewPrimaryPart(previewInstance: Instance): BasePart?
    if previewInstance:IsA("Model") then
        local primaryPart = previewInstance.PrimaryPart
        if primaryPart then
            return primaryPart
        end

        local namedPrimary = previewInstance:FindFirstChild("primaryPart", true)
        if namedPrimary and namedPrimary:IsA("BasePart") then
            return namedPrimary
        end

        -- "Main" here is a BasePart name inside the weapon 3D model, unrelated to WeaponCategory.
        local mainPart = previewInstance:FindFirstChild("Main", true)
        if mainPart and mainPart:IsA("BasePart") then
            return mainPart
        end

        return previewInstance:FindFirstChildWhichIsA("BasePart", true)
    end

    if previewInstance:IsA("BasePart") then
        return previewInstance
    end

    return nil
end

local function applyWrapAppearanceToPrimaryPart(previewPrimaryPart: BasePart, item: WeaponWrapPreviewItem, previewJanitor: any): ()
    local textureId = if type(item.TextureID) == "string" and item.TextureID ~= "" then item.TextureID else nil
    local baseColor = item.BaseColor
    local animated = item.isAnimated == true
    local studsPerTile = math.max(0.01, tonumber(item.StudsPerTile) or DEFAULT_WRAP_STUDS_PER_TILE)
    local animatedTextures = {} :: { Texture }

    if not textureId and typeof(baseColor) == "Color3" then
        previewPrimaryPart.Color = baseColor
    end

    for _, child in previewPrimaryPart:GetChildren() do
        if child:IsA("Texture") and string.sub(child.Name, 1, 14) == "ScrollTexture_" then
            if not textureId then
                child:Destroy()
            end
        end
    end

    if textureId then
        for _, textureName in WEAPON_WRAP_TEXTURE_ORDER do
            local existingTexture = previewPrimaryPart:FindFirstChild(textureName)
            local texture: Texture
            if existingTexture and existingTexture:IsA("Texture") then
                texture = existingTexture
            else
                texture = Instance.new("Texture")
                texture.Name = textureName
                texture.Face = WEAPON_WRAP_TEXTURE_FACE_BY_NAME[textureName]
                texture.Parent = previewPrimaryPart
            end

            texture.Texture = textureId
            texture.Transparency = 0
            texture.StudsPerTileU = studsPerTile
            texture.StudsPerTileV = studsPerTile
            texture.OffsetStudsU = 0
            texture.OffsetStudsV = 0
            table.insert(animatedTextures, texture)
        end
    end

    if textureId and animated and #animatedTextures > 0 then
        registerAnimatedWrapTextures(previewJanitor, animatedTextures)
    end
end

-- El previewer calibra la cámara para el card del locker con el modelo del arma
-- (cerca, descentrada y rotada). Cuando se usa el template genérico `Wrap`,
-- preferimos verlo con una pequeña inclinación X y centrado, con margen.
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
    elseif wrap:IsA("BasePart") then
        pivotCenter = wrap.Position
        wrap.CFrame = CFrame.new(pivotCenter) * WRAP_CENTERED_ORIENTATION
    else
        return
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

function WeaponWrapPreviewer.Render(viewportNode: ViewportFrame, item: WeaponWrapPreviewItem, previewJanitor: any): boolean
    local worldModel = Instance.new("WorldModel")
    worldModel.Parent = viewportNode
    previewJanitor:Add(worldModel, "Destroy")

    local previewTemplate = resolveWeaponTemplate(item) or wrapPreviewTemplate
    local clonedWrap = previewTemplate:Clone()
    clonedWrap.Parent = worldModel
    previewJanitor:Add(clonedWrap, "Destroy")

    for _, descendant in clonedWrap:GetDescendants() do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
        end
    end

    local previewPrimaryPart = getWrapPreviewPrimaryPart(clonedWrap)
    if not previewPrimaryPart then
        return false
    end

    applyWrapAppearanceToPrimaryPart(previewPrimaryPart, item, previewJanitor)

    local modelCenter: CFrame
    local updatedSize: Vector3
    if clonedWrap:IsA("Model") then
        modelCenter, updatedSize = clonedWrap:GetBoundingBox()
        clonedWrap:PivotTo(CFrame.new(modelCenter.Position) * orientacionFija)
        modelCenter, updatedSize = clonedWrap:GetBoundingBox()
    elseif clonedWrap:IsA("BasePart") then
        modelCenter = clonedWrap.CFrame
        updatedSize = clonedWrap.Size
        clonedWrap.CFrame = CFrame.new(modelCenter.Position) * orientacionFija
        modelCenter = clonedWrap.CFrame
        updatedSize = clonedWrap.Size
    else
        return false
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

    cam.CFrame = CFrame.new(
        modelCenter.Position + Vector3.new(0, 0, finalDistance),
        modelCenter.Position
    ) * CFrame.new(-DESPLAZAMIENTO_X, 0, 0)

    viewportNode.Visible = true
    return true
end

return WeaponWrapPreviewer
