--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemDefaults = require(Shared:WaitForChild("constants"):WaitForChild("ItemDefaults"))
local wrapPreviewTemplate = ReplicatedStorage:WaitForChild("Wrap")
local sharedWeaponAssets = Shared:WaitForChild("Locker"):WaitForChild("weapons")

export type WeaponWrapPreviewItem = {
    TextureID: string?,
    BaseColor: Color3?,
    Material: Enum.Material?,
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
local FOV_IDEAL = 27
local DISTANCIA_MULTIPLIER = 0.52
-- Orientación del modelo y de la cámara, calibradas en Studio (son los valores
-- de la propiedad Orientation tal cual: fromEulerAnglesYXZ es el mismo orden
-- Y→X→Z que usa Roblox para Orientation).
local ROTACION_X = 20
local ROTACION_Y = 35
local ROTACION_Z = 20
local orientacionFija = CFrame.fromEulerAnglesYXZ(
    math.rad(ROTACION_X),
    math.rad(ROTACION_Y),
    math.rad(ROTACION_Z)
)
-- La cámara mira de frente al modelo con un yaw de 4°, en vez de apuntar al
-- centro exacto: ese pelín de giro es lo que descentra el arma en la card.
local CAMARA_ROTACION_Y = 4
local orientacionCamara = CFrame.fromEulerAnglesYXZ(0, math.rad(CAMARA_ROTACION_Y), 0)

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

-- Cacheamos StudsPerTileU/V por texture al registrar en lugar de leerlos por
-- frame (se fijan una sola vez en applyWrapAppearanceToPrimaryPart).
type AnimatedWrapEntry = { tileU: number, tileV: number }
local activeAnimatedWrapTextures = {} :: { [Texture]: AnimatedWrapEntry }
local activeAnimatedWrapConnection: RBXScriptConnection? = nil

-- Audit mobile: en dispositivos táctiles acumulamos dt y sólo avanzamos el
-- scroll a 30 Hz (mismo patrón que WeaponWrapAnimator) para no escribir
-- OffsetStudsU/V cada frame en GPUs móviles.
local _isMobile = UserInputService.TouchEnabled
local _THROTTLE_INTERVAL = if _isMobile then 1 / 30 else 0
local _throttleAccum = 0

-- Audit mobile: cache de templates preprocesados (ya anclados). Antes cada
-- Render iteraba GetDescendants() del clone para Anchored = true; con
-- 30+ wraps visibles + notifications + battlepass eran muchos iter loops.
-- Clonamos UNA vez con todos los BaseParts anchored y guardamos el clone
-- preparado en la cache; Render solo hace `prepared:Clone()` (Roblox copia
-- Anchored intacto en el nuevo clone).
local _preparedTemplateCache: { [Instance]: Instance } = {}

local function _getPreparedTemplate(template: Instance): Instance
	local cached = _preparedTemplateCache[template]
	if cached then
		return cached
	end
	local prepared = template:Clone()
	prepared.Parent = nil
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
        if _THROTTLE_INTERVAL > 0 then
            _throttleAccum += dt
            if _throttleAccum < _THROTTLE_INTERVAL then
                return
            end
            dt = _throttleAccum
            _throttleAccum = 0
        end

        for texture, entry in activeAnimatedWrapTextures do
            if texture.Parent == nil then
                activeAnimatedWrapTextures[texture] = nil
            else
                texture.OffsetStudsU = (texture.OffsetStudsU + WRAP_TEXTURE_SCROLL_SPEED_U * dt) % entry.tileU
                texture.OffsetStudsV = (texture.OffsetStudsV + WRAP_TEXTURE_SCROLL_SPEED_V * dt) % entry.tileV
            end
        end

        stopActiveAnimatedWrapLoopIfIdle()
    end)
end

local function registerAnimatedWrapTextures(previewJanitor: any, textures: { Texture }, studsPerTile: number): ()
    if #textures <= 0 then
        return
    end

    local tile = if studsPerTile ~= 0 then math.abs(studsPerTile) else 1
    for _, texture in textures do
        activeAnimatedWrapTextures[texture] = { tileU = tile, tileV = tile }
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
    local material = if typeof(item.Material) == "EnumItem" and item.Material.EnumType == Enum.Material then item.Material else nil
    local animated = item.isAnimated == true
    local studsPerTile = math.max(0.01, tonumber(item.StudsPerTile) or DEFAULT_WRAP_STUDS_PER_TILE)
    local animatedTextures = {} :: { Texture }

    if not textureId and typeof(baseColor) == "Color3" then
        previewPrimaryPart.Color = baseColor
    end

    if material then
        previewPrimaryPart.Material = material
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
        registerAnimatedWrapTextures(previewJanitor, animatedTextures, studsPerTile)
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

-- StudsPerTile que se usa cuando el wrap no trae uno. Público porque quien pinte
-- un wrap sobre un modelo ESCALADO tiene que multiplicarlo por la escala para que
-- se vea con el mismo tamaño de tile que en el viewport.
WeaponWrapPreviewer.DEFAULT_STUDS_PER_TILE = DEFAULT_WRAP_STUDS_PER_TILE

-- Template del arma de PreviewWeapon* (sin clonar), o nil si no hay ninguna
-- resoluble. Para pintar un arma fuera de un ViewportFrame — el mundo, por
-- ejemplo— sin repetir aquí la búsqueda en Shared.Locker.weapons.*.
function WeaponWrapPreviewer.resolveWeaponTemplate(item: WeaponWrapPreviewItem): Instance?
    return resolveWeaponTemplate(item)
end

-- Aplica el aspecto del wrap (textura/color/material, scroll animado incluido)
-- sobre un clon ya existente: el MISMO camino que usa Render dentro del viewport,
-- para que un wrap se vea igual en el mundo que en la card. Devuelve false si el
-- clon no tiene una parte donde pintar.
function WeaponWrapPreviewer.applyAppearance(instance: Instance, item: WeaponWrapPreviewItem, previewJanitor: any): boolean
    local primaryPart = getWrapPreviewPrimaryPart(instance)
    if not primaryPart then
        return false
    end
    applyWrapAppearanceToPrimaryPart(primaryPart, item, previewJanitor)
    return true
end

-- Devuelve (ok, usedWeaponTemplate). El segundo valor dice si se pintó el arma
-- (PreviewWeapon* resueltos) o el bloque genérico `Wrap`: el encuadre que deja
-- Render es el de las cards de arma, así que quien pinte el genérico es quien
-- debe llamar después a `reframeCentered`. Los callers que solo miran el primer
-- valor siguen funcionando igual.
function WeaponWrapPreviewer.Render(viewportNode: ViewportFrame, item: WeaponWrapPreviewItem, previewJanitor: any): (boolean, boolean)
    local worldModel = Instance.new("WorldModel")
    worldModel.Parent = viewportNode
    previewJanitor:Add(worldModel, "Destroy")

    local weaponTemplate = resolveWeaponTemplate(item)
    local usedWeaponTemplate = weaponTemplate ~= nil
    local previewTemplate = weaponTemplate or wrapPreviewTemplate
    -- Clonamos desde la copia preprocesada (todos los BaseParts ya anchored).
    -- Roblox preserva Anchored en el Clone; el iterar GetDescendants en
    -- cada Render era pago por las 30+ cards visibles del locker.
    local preparedTemplate = _getPreparedTemplate(previewTemplate)
    local clonedWrap = preparedTemplate:Clone()
    clonedWrap.Parent = worldModel
    previewJanitor:Add(clonedWrap, "Destroy")

    local previewPrimaryPart = getWrapPreviewPrimaryPart(clonedWrap)
    if not previewPrimaryPart then
        return false, usedWeaponTemplate
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
