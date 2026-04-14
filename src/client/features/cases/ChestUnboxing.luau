--!strict
--[[
    ChestUnboxing.luau
    Animación de apertura de cofre AAA: vibración orgánica, interpolación fluida y aparición dinámica de skins.
]]

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local wrapTemplate = ReplicatedStorage:WaitForChild("Wrap")
local sharedWeaponAssets = Shared:WaitForChild("locker"):WaitForChild("weapons")

-- Requerimos la configuración y le decimos a Luau que confíe en su estructura base
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any

-- ==========================================
-- Tipos Personalizados
-- ==========================================
type SkinConfig = {
    TextureID: string?,
    BaseColor: Color3?,
    StudsPerTile: number?
}

local ChestUnboxing = {}

-- ==========================================
-- Constantes de Configuración
-- ==========================================
local VIBRATION_DURATION: number = 1.5
local VIBRATION_MAX_INTENSITY: number = 0.15
local VIBRATION_SPEED: number = 35 -- Velocidad del ruido de vibración

local OPEN_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_START_ORIENTATION = Vector3.new(-30, 0, 0)
local OPEN_END_ORIENTATION = Vector3.new(90, 0, 0)
local DEFAULT_STUDS_PER_TILE: number = 3

-- --- NUEVAS CONSTANTES PARA LA APARICIÓN DEL ARMA ---
-- Cuánto tiempo tarda el arma en aparecer y subir
local WEAPON_APPEAR_TWEEN_INFO = TweenInfo.new(0.8, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
-- Distancia (en studs) que subirá el arma desde abajo
local WEAPON_RISE_OFFSET: number = 2
-- --------------------------------------------------

local WRAP_TEXTURE_FACES: { [string]: Enum.NormalId } = {
    ScrollTexture_Back = Enum.NormalId.Back,
    ScrollTexture_Bottom = Enum.NormalId.Bottom,
    ScrollTexture_Left = Enum.NormalId.Left,
    ScrollTexture_Right = Enum.NormalId.Right,
    ScrollTexture_Front = Enum.NormalId.Front,
    ScrollTexture_Top = Enum.NormalId.Top,
}

local WRAP_TEXTURE_ORDER: { string } = {
    "ScrollTexture_Back",
    "ScrollTexture_Bottom",
    "ScrollTexture_Left",
    "ScrollTexture_Right",
    "ScrollTexture_Front",
    "ScrollTexture_Top",
}

-- ==========================================
-- Funciones Auxiliares
-- ==========================================

-- Calcula el CFrame de una pieza rotada un delta sobre X alrededor de su pivot cerrado.
local function cframeFromClosedPivotDelta(closedPivotCF: CFrame, pivotOffset: CFrame, deltaAngleX: number): CFrame
    local rotatedPivot = closedPivotCF * CFrame.Angles(deltaAngleX, 0, 0)
    return rotatedPivot * pivotOffset:Inverse()
end

-- Limpia y aplica los materiales y colores de la skin
local function applySkinToWrap(primaryPart: BasePart, skinConfig: SkinConfig)
    local textureId: string? = if type(skinConfig.TextureID) == "string" and skinConfig.TextureID ~= "" then skinConfig.TextureID else nil
    local baseColor: Color3? = skinConfig.BaseColor
    local studsPerTile: number = math.max(0.01, tonumber(skinConfig.StudsPerTile) or DEFAULT_STUDS_PER_TILE)

    if baseColor and typeof(baseColor) == "Color3" then
        primaryPart.Color = baseColor
    end

    -- Si no hay textura id, destruimos las existentes y salimos
    if not textureId then
        for _, child in primaryPart:GetChildren() do
            if child:IsA("Texture") and WRAP_TEXTURE_FACES[child.Name] then
                child:Destroy()
            end
        end
        return
    end

    -- Crear o actualizar texturas
    for _, textureName in WRAP_TEXTURE_ORDER do
        local texture = primaryPart:FindFirstChild(textureName) :: Texture?

        if not texture or not texture:IsA("Texture") then
            texture = Instance.new("Texture")
            assert(texture ~= nil, "Fallo al crear la textura") -- Convence al strict mode
            texture.Name = textureName
            texture.Face = WRAP_TEXTURE_FACES[textureName]
            texture.Parent = primaryPart
        end

        texture.Texture = textureId
        texture.Transparency = 0
        texture.StudsPerTileU = studsPerTile
        texture.StudsPerTileV = studsPerTile
    end
end

-- Búsqueda robusta del PrimaryPart
local function getPrimaryPart(instance: Instance): BasePart?
    if instance:IsA("Model") then
        if instance.PrimaryPart then
            return instance.PrimaryPart
        end

        local namedPrimary = instance:FindFirstChild("primaryPart", true)
        if namedPrimary and namedPrimary:IsA("BasePart") then return namedPrimary end

        local mainPart = instance:FindFirstChild("Main", true)
        if mainPart and mainPart:IsA("BasePart") then return mainPart end

        return instance:FindFirstChildWhichIsA("BasePart", true)
    elseif instance:IsA("BasePart") then
        return instance
    end
    return nil
end

local function resolveWeaponTemplate(weaponCategory: string, weaponId: string): Instance?
    local categoryFolder = sharedWeaponAssets:FindFirstChild(weaponCategory)
    if not categoryFolder then return nil end

    return categoryFolder:FindFirstChild(weaponId) or categoryFolder:FindFirstChild("Default")
end

-- ==========================================
-- Animación Principal
-- ==========================================

--[[
    Reproduce la animación de unboxing para la skin indicada.
    Yield: bloquea hasta que la animación completa (vibración + apertura + spawn).
    Retorna una función de cleanup que destruye el wrap clonado y resetea el cofre.
]]
function ChestUnboxing.play(skinId: string, weaponCategory: string, weaponId: string): () -> ()
    local chest = Workspace:FindFirstChild("Chest")
    if not chest then
        warn("[ChestUnboxing] Workspace.Chest no encontrado")
        return function() end
    end

    local openPart = chest:FindFirstChild("Open")
    local spawnPart = chest:FindFirstChild("Spawn")

    -- Verificación estricta de tipos
    if not openPart or not openPart:IsA("BasePart") or not spawnPart or not spawnPart:IsA("BasePart") then
        warn("[ChestUnboxing] Las partes 'Open' o 'Spawn' no existen o no son BaseParts")
        return function() end
    end

    openPart.Orientation = OPEN_START_ORIENTATION
    local closedCFrame = openPart.CFrame
    local pivotOffset = openPart.PivotOffset
    local closedPivotCF = openPart:GetPivot()

    local chestPivot: CFrame = if chest:IsA("Model") then chest:GetPivot()
                               elseif chest:IsA("BasePart") then chest.CFrame
                               else CFrame.new()

    -- ── Fase 1: Vibración AAA (Orgánica) ────────────────────
    local vibrateStart = os.clock()
    while os.clock() - vibrateStart < VIBRATION_DURATION do
        local elapsed = os.clock() - vibrateStart
        local progress = elapsed / VIBRATION_DURATION

        local easeProgress = TweenService:GetValue(progress, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        local intensity = easeProgress * VIBRATION_MAX_INTENSITY

        local timeFactor = elapsed * VIBRATION_SPEED
        local offsetX = math.noise(timeFactor, 0, 0) * intensity
        local offsetZ = math.noise(0, timeFactor, 0) * intensity
        local rotZ = math.noise(0, 0, timeFactor) * (intensity * 0.5)

        local shakeOffset = CFrame.new(offsetX, 0, offsetZ) * CFrame.Angles(0, 0, rotZ)

        if chest:IsA("Model") then
            chest:PivotTo(chestPivot * shakeOffset)
        elseif chest:IsA("BasePart") then
            chest.CFrame = chestPivot * shakeOffset
        end

        RunService.Heartbeat:Wait()
    end

    -- Restaurar posición original perfecta
    if chest:IsA("Model") then
        chest:PivotTo(chestPivot)
    elseif chest:IsA("BasePart") then
        chest.CFrame = chestPivot
    end

    -- ── Fase 2: Abrir tapa (rotar desde PivotOffset) ────────
    local openDelta = math.rad(OPEN_END_ORIENTATION.X - OPEN_START_ORIENTATION.X)
    local openTargetCFrame = cframeFromClosedPivotDelta(closedPivotCF, pivotOffset, openDelta)

    local openTween = TweenService:Create(openPart, OPEN_TWEEN_INFO, {
        CFrame = openTargetCFrame,
    })
    openTween:Play()
    openTween.Completed:Wait()

    -- ── Fase 3: Spawn y Animación de Aparición Dinámica ─────
    local spawnCFrame = spawnPart.CFrame
    local weaponTemplate = resolveWeaponTemplate(weaponCategory, weaponId) or wrapTemplate

    -- Clonamos el arma
    local clonedWrap = weaponTemplate:Clone()
    assert(clonedWrap ~= nil, "Fallo al clonar el arma")

    local primary = getPrimaryPart(clonedWrap)

    -- Acceso seguro a la configuración tipada
    local skinConfig: SkinConfig? = nil
    if type(ItemsConfig) == "table" and type(ItemsConfig.WeaponSkins) == "table" then
        skinConfig = ItemsConfig.WeaponSkins[skinId]
    end

    -- Aplicamos la skin ANTES de parentar para optimizar
    if primary and skinConfig then
        applySkinToWrap(primary, skinConfig)
    end

    -- --- CONFIGURACIÓN DE ANIMACIÓN DE APARICIÓN ---
    -- 1. Anclar y hacer invisible inicialmente
    for _, desc in clonedWrap:GetDescendants() do
        if desc:IsA("BasePart") then
            desc.Anchored = true
            desc.Transparency = 1 -- Hacemos todo invisible
        end
    end

    -- 2. Posición inicial: Abajo
    local startSpawnCFrame = spawnCFrame * CFrame.new(0, -WEAPON_RISE_OFFSET, 0)

    -- 3. Posicionamos el modelo
    if clonedWrap:IsA("Model") then
        clonedWrap:PivotTo(startSpawnCFrame)
    elseif clonedWrap:IsA("BasePart") then
        clonedWrap.CFrame = startSpawnCFrame
    end

    -- 4. Parentar al Workspace (ahora es visible/existe en el mundo)
    clonedWrap.Parent = Workspace

    -- 5. Crear Tweens para la aparición (Tamaño + Posición + Transparencia)
    local tweensToPlay = {}

    -- Animación de Posición (Subir)
    if clonedWrap:IsA("Model") then
        -- Los modelos se mueven con PivotTo, por lo que necesitamos un CFrameValue auxiliar
        -- para hacer tween del CFrame del modelo completo.
        local cframeValue = Instance.new("CFrameValue")
        cframeValue.Value = startSpawnCFrame
        cframeValue.Parent = clonedWrap

        cframeValue.Changed:Connect(function(newCFrame)
            if clonedWrap and clonedWrap.Parent then
                clonedWrap:PivotTo(newCFrame)
            end
        end)

        table.insert(tweensToPlay, TweenService:Create(cframeValue, WEAPON_APPEAR_TWEEN_INFO, {Value = spawnCFrame}))
    elseif clonedWrap:IsA("BasePart") then
        -- Si es solo una parte, hacemos tween directo
        table.insert(tweensToPlay, TweenService:Create(clonedWrap, WEAPON_APPEAR_TWEEN_INFO, {CFrame = spawnCFrame}))
    end

    -- Animación de Transparencia y Tamaño (para cada BasePart)
    for _, desc in clonedWrap:GetDescendants() do
        if desc:IsA("BasePart") then
            -- Guardamos el tamaño original
            local originalSize = desc.Size
            local originalTransparency = desc.Transparency

            -- Setear estado inicial: Sin tamaño y transparente
            desc.Size = Vector3.new(0, 0, 0)
            desc.Transparency = 1 -- Asegurarnos que esté transparente

            -- Creamos tweens para volver al estado original
            table.insert(tweensToPlay, TweenService:Create(desc, WEAPON_APPEAR_TWEEN_INFO, {
                Size = originalSize,
                Transparency = 0 -- O su transparencia original si no es 0
            }))
        end
    end

    -- 6. Reproducir todos los tweens simultáneamente
    for _, tween in tweensToPlay do
        tween:Play()
    end

    -- Esperamos a que la animación de aparición termine (usamos el primero como referencia)
    if #tweensToPlay > 0 then
        tweensToPlay[1].Completed:Wait()
    end
    -- --------------------------------------------------

    -- Retornar función de limpieza
    return function()
        if clonedWrap then
            clonedWrap:Destroy()
        end
        if openPart then
            openPart.CFrame = closedCFrame
            openPart.Orientation = OPEN_START_ORIENTATION
        end
    end
end

return ChestUnboxing
