--!strict
--[[
    SlotUnboxing.luau
    Animación de unboxing tipo slot machine vertical.
    Sustituye a ChestUnboxing (animación 3D del cofre).

    Estructura GUI esperada:
        unboxingFrame
          Layout
            UIListLayout
            Lane1            -- vacío; se rellena con 5 items en runtime (ImageLabels de armas)
            Lane2            -- vacío; se rellena con 5 items en runtime (ViewportFrames de wraps)
          Collect
          Equip

    Flujo:
      1. Lane1 visible, Lane2 oculto. Crea 5 items por lane y los inicia en
         estados 1..5 con contenido aleatorio del pool correspondiente.
      2. Reel de Lane1: cicla los 5 items (cada uno transita 1→2→3→4→5 y respawna)
         con deceleración progresiva. Aterriza en el arma del resultado.
      3. Tease (todos bajan), darken (oscurece no-centro), snapback (vuelve), bounce + glow.
      4. Hace Lane2 visible y repite con wraps. Aplica color de rareza al glow del centro.
      5. Muestra Collect / Equip y devuelve función de cleanup.
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local cases = script.Parent
local features = cases.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local CasesConfig = require(Shared.constants.CasesConfig) :: any
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local WeaponSkinWrapPreviewer = require(features.locker.Previewers.WeaponSkinWrapPreviewer)

export type OwnedWeapon = { category: string, weaponId: string }
export type SummonResult = {
    caseId: string,
    skinId: string,
    weaponCategory: string,
    weaponId: string,
    isPity: boolean,
    newPity: number,
}

type LaneItem = {
    frame: Frame,
    scale: UIScale,
    icon: GuiObject,
    state: number,
    previewJanitor: any?,
}

-- ──────────────────────────────────────────────
-- Constantes (verbatim del snippet de referencia)
-- ──────────────────────────────────────────────
local STATES = {
    { Y = -0.166, Scale = 1.0, Alpha = 1 },
    { Y =  0.166, Scale = 1.0, Alpha = 0 },
    { Y =  0.500, Scale = 2.4, Alpha = 0 },
    { Y =  0.833, Scale = 1.0, Alpha = 0 },
    { Y =  1.166, Scale = 1.0, Alpha = 1 },
}
local SPIN_DURATION           = 2.0
local SPIN_SPEED              = 0.075
local DECELERATION_MULTIPLIER = 1.15
local STOP_THRESHOLD_TIME     = 0.25
local Y_TEASE_OFFSET          = 0.22
local TIME_TEASE              = 0.65
local HANG_TIME               = 0.4
local TIME_SNAPBACK           = 0.35
local COLOR_FLASH             = Color3.fromRGB(255, 215, 0)
local COLOR_DARKEN            = Color3.fromRGB(60, 60, 60)
local ITEMS_PER_LANE          = 5
local CENTER_STATE            = 3
local RESPAWN_Y               = -0.5
local CENTER_BOUNCE_SCALE     = 1.15
local CENTER_BOUNCE_TIME      = 0.5
local GLOW_FADE_TIME          = 0.4
local GLOW_TARGET_SIZE        = 1.3
local GLOW_TARGET_POS         = -0.15
local ITEM_INSET              = 0.1
local ITEM_INNER_SIZE         = 0.8

-- ──────────────────────────────────────────────
-- Helpers
-- ──────────────────────────────────────────────

local function setIconAlpha(icon: GuiObject, alpha: number)
    if icon:IsA("ImageLabel") or icon:IsA("ImageButton") or icon:IsA("ViewportFrame") then
        (icon :: any).ImageTransparency = alpha
    end
end

local function applyState(item: LaneItem, stateIdx: number)
    local s = STATES[stateIdx]
    item.frame.Position = UDim2.fromScale(0.5, s.Y)
    item.scale.Scale = s.Scale
    setIconAlpha(item.icon, s.Alpha)
    item.state = stateIdx
end

local function buildWeaponImageMap(
    ownedWeapons: { OwnedWeapon }
): ({ string }, { [string]: string })
    local keys = {} :: { string }
    local map = {} :: { [string]: string }
    for _, entry in ownedWeapons do
        local key = entry.category .. ":" .. entry.weaponId
        if map[key] then continue end
        local categoryCfg = ItemsConfig[entry.category]
        local cfg = if type(categoryCfg) == "table" then categoryCfg[entry.weaponId] else nil
        local image = if cfg and type(cfg.Image) == "string" and cfg.Image ~= "" then cfg.Image else nil
        if not image then continue end
        table.insert(keys, key)
        map[key] = image
    end
    return keys, map
end

local function buildWrapsList(caseDef: any?): { string }
    local keys = {} :: { string }
    if not caseDef or type(caseDef.Drops) ~= "table" then return keys end
    local seen = {} :: { [string]: boolean }
    for _, drop in caseDef.Drops do
        local skinId = drop.SkinId
        if seen[skinId] then continue end
        local skinCfg = if ItemsConfig.WeaponSkins then ItemsConfig.WeaponSkins[skinId] else nil
        if not skinCfg then continue end
        seen[skinId] = true
        table.insert(keys, skinId)
    end
    return keys
end

local function pickRandom(pool: { string }): string
    if #pool == 0 then return "" end
    return pool[math.random(1, #pool)]
end

local function findCenterItem(items: { LaneItem }): LaneItem?
    for _, item in items do
        if item.state == CENTER_STATE then return item end
    end
    return nil
end

local function getRarityColor(rarity: string?): Color3
    local gradients = CasesConfig.RarityGradients
    if not gradients then return COLOR_FLASH end
    local style = gradients[rarity or ""] or gradients.Default
    if not style then return COLOR_FLASH end
    return (style.StrokeColor or style.EndColor) :: Color3
end

local function createLaneItem(
    laneFrame: GuiObject,
    isLane2: boolean,
    masterJanitor: any
): LaneItem
    local frame = Instance.new("Frame")
    frame.Name = "Item"
    frame.Size = UDim2.new(1, 0, 0.333, 0)
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.Position = UDim2.fromScale(0.5, 0)
    frame.BackgroundTransparency = 1
    frame.BorderSizePixel = 0
    frame.Parent = laneFrame

    local scale = Instance.new("UIScale")
    scale.Parent = frame

    local icon: GuiObject
    local previewJanitor: any? = nil
    if isLane2 then
        local vp = Instance.new("ViewportFrame")
        vp.BackgroundTransparency = 1
        vp.BorderSizePixel = 0
        icon = vp
        previewJanitor = Janitor.new()
        masterJanitor:Add(previewJanitor, "Destroy")
    else
        local img = Instance.new("ImageLabel")
        img.BackgroundTransparency = 1
        img.BorderSizePixel = 0
        img.ScaleType = Enum.ScaleType.Fit
        icon = img
    end
    icon.Size = UDim2.fromScale(ITEM_INNER_SIZE, ITEM_INNER_SIZE)
    icon.Position = UDim2.fromScale(ITEM_INSET, ITEM_INSET)
    icon.Parent = frame

    masterJanitor:Add(frame, "Destroy")

    return {
        frame = frame,
        scale = scale,
        icon = icon,
        state = 0,
        previewJanitor = previewJanitor,
    }
end

local function applyWeaponContent(
    item: LaneItem,
    weaponKey: string,
    weaponImageMap: { [string]: string }
)
    if not item.icon:IsA("ImageLabel") then return end
    local image = weaponImageMap[weaponKey]
    if not image or image == "" then return end -- no machacar con vacío si el lookup falla
    local imgLabel = item.icon :: ImageLabel
    imgLabel.Image = image
end

-- El previewer calibra la cámara para el card del locker (cerca, descentrada y rotada).
-- Para el reel queremos el wrap con una pequeña inclinación X y centrado, con margen.
local WRAP_CAMERA_DISTANCE_MULT = 1.9
local WRAP_ROTATION_X_DEG = 14
local WRAP_ROTATION_Y_DEG = 0
local WRAP_ROTATION_Z_DEG = 0
local WRAP_ORIENTATION = CFrame.fromEulerAnglesYXZ(
    math.rad(WRAP_ROTATION_X_DEG),
    math.rad(WRAP_ROTATION_Y_DEG),
    math.rad(WRAP_ROTATION_Z_DEG)
)

local function reframeWrapCentered(vp: ViewportFrame)
    local cam = vp.CurrentCamera
    if not cam then return end
    local worldModel = vp:FindFirstChildOfClass("WorldModel")
    if not worldModel then return end

    local wrap: Instance? = worldModel:FindFirstChildWhichIsA("Model")
        or worldModel:FindFirstChildWhichIsA("BasePart")
    if not wrap then return end

    -- Sobreescribir la orientación que aplicó el previewer (orientacionFija) por
    -- la nuestra (X=14°, Y=0°, Z=0°), pivoteando alrededor del centro del bbox.
    local pivotCenter: Vector3
    if wrap:IsA("Model") then
        local cf, _ = wrap:GetBoundingBox()
        pivotCenter = cf.Position
        wrap:PivotTo(CFrame.new(pivotCenter) * WRAP_ORIENTATION)
    elseif wrap:IsA("BasePart") then
        pivotCenter = wrap.Position
        wrap.CFrame = CFrame.new(pivotCenter) * WRAP_ORIENTATION
    else
        return
    end

    -- Recalcular bounding box tras la reorientación
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
    local distance = (maxDim / 2) / math.tan(halfFov) * WRAP_CAMERA_DISTANCE_MULT

    cam.CFrame = CFrame.new(
        centerPos + Vector3.new(0, 0, distance),
        centerPos
    )
end

local function applyWrapContent(item: LaneItem, skinId: string)
    if not item.previewJanitor then return end
    if not item.icon:IsA("ViewportFrame") then return end
    item.previewJanitor:Cleanup()

    local skinCfg = if ItemsConfig.WeaponSkins then ItemsConfig.WeaponSkins[skinId] else nil
    if not skinCfg then return end

    -- Siempre la plantilla genérica ReplicatedStorage.Wrap (textura sobre Wrap.Main).
    -- No pasamos PreviewWeaponCategory/Key para que el previewer caiga al template genérico.
    local vp = item.icon :: ViewportFrame
    WeaponSkinWrapPreviewer.Render(vp, {
        TextureID = skinCfg.TextureID,
        BaseColor = skinCfg.BaseColor,
        Animated = false,
        StudsPerTile = skinCfg.StudsPerTile,
    }, item.previewJanitor)
    reframeWrapCentered(vp)
end

local function playReel(
    items: { LaneItem },
    pool: { string },
    applyContent: (LaneItem, string) -> (),
    resultKey: string
)
    if #items ~= ITEMS_PER_LANE or #pool == 0 then return end

    local startTime = os.clock()
    local currentCycleTime = SPIN_SPEED
    local stopPhase = 0

    while true do
        local elapsed = os.clock() - startTime
        if elapsed >= SPIN_DURATION and stopPhase == 0 then
            stopPhase = 1
        end
        if stopPhase == 1 then
            currentCycleTime = currentCycleTime * DECELERATION_MULTIPLIER
            if currentCycleTime >= STOP_THRESHOLD_TIME then
                stopPhase = 2
            end
        end
        if stopPhase == 2 then break end

        local motionInfo = TweenInfo.new(currentCycleTime, Enum.EasingStyle.Linear)
        local visualInfo = TweenInfo.new(currentCycleTime * 1.5, Enum.EasingStyle.Sine)

        -- Durante la deceleración inyectamos el resultKey en cada respawn (state 5 → 1).
        -- Como un item respawnado en el iter K aterriza en el centro al iter K+2, esto
        -- hace que el centro muestre el resultado durante toda la fase de freno (slide
        -- natural — no se cambia el contenido del item ya visible en el centro).
        local decelerating = stopPhase == 1

        for _, item in items do
            if item.state == 5 then
                item.state = 0
                item.frame.Position = UDim2.fromScale(0.5, RESPAWN_Y)
                item.scale.Scale = STATES[1].Scale
                setIconAlpha(item.icon, STATES[1].Alpha)
                local injectKey = if decelerating then resultKey else pickRandom(pool)
                applyContent(item, injectKey)
            end

            item.state = item.state + 1
            local target = STATES[item.state]

            TweenService:Create(item.frame, motionInfo, {
                Position = UDim2.fromScale(0.5, target.Y),
            }):Play()
            TweenService:Create(item.scale, visualInfo, { Scale = target.Scale }):Play()
            if item.icon:IsA("ImageLabel") or item.icon:IsA("ImageButton") or item.icon:IsA("ViewportFrame") then
                TweenService:Create(item.icon, visualInfo, {
                    ImageTransparency = target.Alpha,
                }):Play()
            end
        end

        task.wait(currentCycleTime)
    end

    -- Safety net: si por alguna razón el centro no acabó con el resultKey (p.ej.
    -- decel demasiado corta para que el slide alcance al centro), lo sincronizamos.
    -- Ya no debería ser visible: durante la decel los items inyectados ya pasaron
    -- por el centro, así que esto suele ser un no-op (mismo contenido).
    local centerItem = findCenterItem(items)
    if centerItem then
        applyContent(centerItem, resultKey)
    end
end

local function pulseAndGlow(
    items: { LaneItem },
    centerItem: LaneItem,
    glowColor: Color3,
    cloneIconForGlow: boolean,
    masterJanitor: any
)
    -- Subir el centro por encima del resto para que el scale-up no quede tapado
    centerItem.frame.ZIndex = centerItem.frame.ZIndex + 9
    if centerItem.icon:IsA("GuiObject") then
        centerItem.icon.ZIndex = centerItem.icon.ZIndex + 9
    end

    -- Tease: todos los items bajan
    local teaseInfo = TweenInfo.new(TIME_TEASE, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
    for _, item in items do
        local target = STATES[item.state]
        TweenService:Create(item.frame, teaseInfo, {
            Position = UDim2.fromScale(0.5, target.Y + Y_TEASE_OFFSET),
        }):Play()
    end
    task.wait(TIME_TEASE)

    -- Hang: oscurece no-centro
    local darkenInfo = TweenInfo.new(HANG_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    for _, item in items do
        if item ~= centerItem then
            if item.icon:IsA("ImageLabel") or item.icon:IsA("ImageButton") or item.icon:IsA("ViewportFrame") then
                TweenService:Create(item.icon, darkenInfo, {
                    ImageColor3 = COLOR_DARKEN,
                }):Play()
            end
        end
    end
    task.wait(HANG_TIME)

    -- Snapback elastic
    local snapInfo = TweenInfo.new(TIME_SNAPBACK, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
    for _, item in items do
        local target = STATES[item.state]
        TweenService:Create(item.frame, snapInfo, {
            Position = UDim2.fromScale(0.5, target.Y),
        }):Play()
        if item ~= centerItem then
            TweenService:Create(item.scale, snapInfo, { Scale = target.Scale }):Play()
        end
    end

    -- Bounce del centro
    centerItem.scale.Scale = STATES[CENTER_STATE].Scale * CENTER_BOUNCE_SCALE
    TweenService:Create(centerItem.scale,
        TweenInfo.new(CENTER_BOUNCE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
        { Scale = STATES[CENTER_STATE].Scale }
    ):Play()

    -- Glow
    local glow: GuiObject
    if cloneIconForGlow and centerItem.icon:IsA("ImageLabel") then
        local cloned = (centerItem.icon :: ImageLabel):Clone()
        cloned.Name = "GlowEffect"
        cloned.ImageColor3 = glowColor
        cloned.ImageTransparency = 0
        cloned.ZIndex = centerItem.icon.ZIndex - 1
        cloned.Size = UDim2.fromScale(ITEM_INNER_SIZE, ITEM_INNER_SIZE)
        cloned.Position = UDim2.fromScale(ITEM_INSET, ITEM_INSET)
        cloned.Parent = centerItem.frame
        glow = cloned
    else
        local ghost = Instance.new("ImageLabel")
        ghost.Name = "GlowEffect"
        ghost.BackgroundColor3 = glowColor
        ghost.BackgroundTransparency = 0
        ghost.Image = ""
        ghost.BorderSizePixel = 0
        ghost.Size = UDim2.fromScale(ITEM_INNER_SIZE, ITEM_INNER_SIZE)
        ghost.Position = UDim2.fromScale(ITEM_INSET, ITEM_INSET)
        ghost.ZIndex = centerItem.icon.ZIndex - 1
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.5, 0)
        corner.Parent = ghost
        ghost.Parent = centerItem.frame
        glow = ghost
    end
    masterJanitor:Add(glow, "Destroy")

    local glowInfo = TweenInfo.new(GLOW_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    if glow:IsA("ImageLabel") and (glow :: ImageLabel).Image ~= "" then
        TweenService:Create(glow, glowInfo, {
            Size = UDim2.fromScale(GLOW_TARGET_SIZE, GLOW_TARGET_SIZE),
            Position = UDim2.fromScale(GLOW_TARGET_POS, GLOW_TARGET_POS),
            ImageTransparency = 1,
        }):Play()
    else
        TweenService:Create(glow, glowInfo, {
            Size = UDim2.fromScale(GLOW_TARGET_SIZE, GLOW_TARGET_SIZE),
            Position = UDim2.fromScale(GLOW_TARGET_POS, GLOW_TARGET_POS),
            BackgroundTransparency = 1,
        }):Play()
    end

    task.wait(TIME_SNAPBACK)
end

-- ──────────────────────────────────────────────
-- API
-- ──────────────────────────────────────────────

local SlotUnboxing = {}

-- Reencuadre estándar de wraps en cualquier ViewportFrame del feature Cases
-- (drops list + reel del unboxing). Aplica orientación (14°, 0°, 0°) y distancia
-- de cámara con margen, sobre la plantilla genérica ReplicatedStorage.Wrap.
SlotUnboxing.reframeWrap = reframeWrapCentered

function SlotUnboxing.play(
    result: SummonResult,
    ownedWeapons: { OwnedWeapon },
    unboxingFrame: GuiObject
): () -> ()
    local masterJanitor = Janitor.new()

    local layout = unboxingFrame:FindFirstChild("Layout")
    local lane1 = if layout then layout:FindFirstChild("Lane1") else nil
    local lane2 = if layout then layout:FindFirstChild("Lane2") else nil
    local collectButton = unboxingFrame:FindFirstChild("Collect")
    local equipButton   = unboxingFrame:FindFirstChild("Equip")

    if not lane1 or not lane1:IsA("GuiObject")
        or not lane2 or not lane2:IsA("GuiObject") then
        warn("[SlotUnboxing] Faltan Lane1/Lane2 dentro de Unboxing.Layout")
        return function() masterJanitor:Destroy() end
    end

    -- Limpiar items dinámicos de un summon previo
    for _, child in (lane1 :: GuiObject):GetChildren() do
        if child:IsA("Frame") and child.Name == "Item" then child:Destroy() end
    end
    for _, child in (lane2 :: GuiObject):GetChildren() do
        if child:IsA("Frame") and child.Name == "Item" then child:Destroy() end
    end

    lane1.Visible = true
    lane2.Visible = false
    if collectButton and collectButton:IsA("GuiObject") then collectButton.Visible = false end
    if equipButton and equipButton:IsA("GuiObject") then equipButton.Visible = false end

    -- Pool de armas (Lane1)
    local weaponKeys, weaponImageMap = buildWeaponImageMap(ownedWeapons)
    local resultWeaponKey = result.weaponCategory .. ":" .. result.weaponId
    if not weaponImageMap[resultWeaponKey] then
        local categoryCfg = ItemsConfig[result.weaponCategory]
        local cfg = if type(categoryCfg) == "table" then categoryCfg[result.weaponId] else nil
        local image = if cfg and type(cfg.Image) == "string" and cfg.Image ~= "" then cfg.Image else nil
        if image then
            table.insert(weaponKeys, resultWeaponKey)
            weaponImageMap[resultWeaponKey] = image
        else
            -- El server puede picar weaponId="Default" (existe en Inventory pero no
            -- en ItemsConfig.Main/Special). Aliasamos al primer asset válido del map
            -- para que el reel nunca termine con la imagen en blanco.
            for _, fallbackImg in weaponImageMap do
                table.insert(weaponKeys, resultWeaponKey)
                weaponImageMap[resultWeaponKey] = fallbackImg
                break
            end
        end
    end
    if #weaponKeys == 0 then
        local defaultCfg = if type(ItemsConfig.Main) == "table" then ItemsConfig.Main.Default else nil
        local image = if defaultCfg and type(defaultCfg.Image) == "string" and defaultCfg.Image ~= "" then defaultCfg.Image else nil
        if image then
            local k = "Main:Default"
            table.insert(weaponKeys, k)
            weaponImageMap[k] = image
        end
    end

    -- Precargar la imagen del resultado para evitar el flash en blanco mientras
    -- Roblox descarga el asset en el momento exacto del swap final.
    local resultImage = weaponImageMap[resultWeaponKey]
    if resultImage and resultImage ~= "" then
        task.spawn(function()
            pcall(ContentProvider.PreloadAsync, ContentProvider, { resultImage })
        end)
    end

    -- Pool de wraps (Lane2)
    local caseDef = CasesConfig.Cases[result.caseId]
    local wrapKeys = buildWrapsList(caseDef)
    local hasResult = false
    for _, k in wrapKeys do
        if k == result.skinId then hasResult = true break end
    end
    if not hasResult then
        local skinCfg = if ItemsConfig.WeaponSkins then ItemsConfig.WeaponSkins[result.skinId] else nil
        if skinCfg then table.insert(wrapKeys, result.skinId) end
    end

    -- Crear los 5 items de Lane1, semilla aleatoria
    local lane1Items = {} :: { LaneItem }
    for i = 1, ITEMS_PER_LANE do
        local item = createLaneItem(lane1 :: GuiObject, false, masterJanitor)
        table.insert(lane1Items, item)
        applyState(item, i)
        if #weaponKeys > 0 then
            applyWeaponContent(item, pickRandom(weaponKeys), weaponImageMap)
        end
    end

    -- Reel 1: armas
    playReel(lane1Items, weaponKeys, function(item, key)
        applyWeaponContent(item, key, weaponImageMap)
    end, resultWeaponKey)

    local lane1Center = findCenterItem(lane1Items)
    if lane1Center then
        pulseAndGlow(lane1Items, lane1Center, COLOR_FLASH, true, masterJanitor)
    end

    -- Lane2 visible y reel
    lane2.Visible = true
    local lane2Items = {} :: { LaneItem }
    for i = 1, ITEMS_PER_LANE do
        local item = createLaneItem(lane2 :: GuiObject, true, masterJanitor)
        table.insert(lane2Items, item)
        applyState(item, i)
        if #wrapKeys > 0 then
            applyWrapContent(item, pickRandom(wrapKeys))
        end
    end

    playReel(lane2Items, wrapKeys, function(item, key)
        applyWrapContent(item, key)
    end, result.skinId)

    local skinCfg = if ItemsConfig.WeaponSkins then ItemsConfig.WeaponSkins[result.skinId] else nil
    local rarity = if skinCfg and type(skinCfg.Rarity) == "string" then skinCfg.Rarity else nil
    local lane2GlowColor = getRarityColor(rarity)

    local lane2Center = findCenterItem(lane2Items)
    if lane2Center then
        pulseAndGlow(lane2Items, lane2Center, lane2GlowColor, false, masterJanitor)
    end

    if collectButton and collectButton:IsA("GuiObject") then collectButton.Visible = true end
    if equipButton and equipButton:IsA("GuiObject") then equipButton.Visible = true end

    return function()
        lane1.Visible = false
        lane2.Visible = false
        if collectButton and collectButton:IsA("GuiObject") then collectButton.Visible = false end
        if equipButton and equipButton:IsA("GuiObject") then equipButton.Visible = false end
        masterJanitor:Destroy()
    end
end

return SlotUnboxing
