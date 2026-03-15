--[[
    FusionCameraController
    Full Fusion system: camera toggle (F key), GUI with 4 skin input slots,
    SkinsFrame picker using Locker's SkinCard, and close button.

    Ruta: StarterPlayerScripts > Client > FusionCamera
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

-- Fusion 0.3 imports
local Fusion = require(ReplicatedStorage.Packages.fusion)
local scoped = Fusion.scoped
local Children = Fusion.Children
local Value = Fusion.Value
local Computed = Fusion.Computed
local Spring = Fusion.Spring
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek
local Observer = Fusion.Observer

-- Shared modules
local CameraManager = require(ReplicatedStorage.Shared.Systems.Camera.CameraManager)
local EffectsManager = require(script.Parent.Parent.Locker.Modules.EffectsManager)
local SkinApplier = require(ReplicatedStorage.Shared.Systems.Appearance.SkinApplier)
local _ItemsDataUtils = require(ReplicatedStorage.Shared.Systems.Locker.Data.ItemsDataUtils)
local ItemsData = require(ReplicatedStorage.Shared.Systems.Locker.Data.ItemsData)
local BoxAnimation = require(ReplicatedStorage.Shared.Systems.Cases.BoxAnimation)
local DataController = require(ReplicatedStorage.Shared.Systems.Data.DataController)
local SkinCard = require(script.Parent.Parent.Locker.Components.SkinCard)
local Constants = require(script.Parent.Parent.Locker.Components.StoreConstants)

local player = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Scope principal
--------------------------------------------------------------------------------
local scope = scoped(Fusion)

--------------------------------------------------------------------------------
-- Estado reactivo
--------------------------------------------------------------------------------
local isFusionOpen = Value(scope, false)

-- 4 input slots: each holds a skin data table or nil
local inputSlots = {
    Value(scope, nil), -- Input1
    Value(scope, nil), -- Input2
    Value(scope, nil), -- Input3
    Value(scope, nil), -- Input4
}

-- Which input slot is currently being filled (1-4 or nil)
local activeInputIndex = Value(scope, nil)

-- SkinsFrame visibility
local skinsFrameVisible = Computed(scope, function(use)
    return use(activeInputIndex) ~= nil
end)

-- Player data (reactive)
local playerData = Value(scope, DataController:Get() or {})

DataController:OnReady(function()
    playerData:set(DataController:Get())
end)

local conn_data = DataController:OnRawChange(function()
    playerData:set(DataController:Get())
end)
table.insert(scope, conn_data)

--------------------------------------------------------------------------------
-- Fusion Logic States
--------------------------------------------------------------------------------
local fusionActionRF = ReplicatedStorage:WaitForChild("Cases"):WaitForChild("FusionAction")

local activeFusionInfo = Computed(scope, function(use)
    local data = use(playerData)
    local info = data and data.activeFusion or nil
    -- Server uses { cleared = true } sentinel since ReplicaService can't replicate nil
    if info and (info.cleared or not info.endTime) then return nil end
    return info
end)

local isFusing = Computed(scope, function(use)
    return use(activeFusionInfo) ~= nil
end)
local fusionEndTime = Computed(scope, function(use)
    local info = use(activeFusionInfo)
    return info and info.endTime or 0
end)
local currentTime = Value(scope, os.time())
local showFusionCollect = Value(scope, false)
local activeBoxCleanup = nil

-- Configuración de velocidades (Grados por segundo)
local velR1 = 60
local velR2 = -45
local velR3 = 30
local velR4 = 40
local velGear = 80 -- Velocidad del engranaje
local velR0 = 60

-- Función para aplicar rotación fluida usando DeltaTime (dt)
local function rotar(modelo, velocidad, eje, dt)
    if modelo and modelo.PrimaryPart then
        local deltaRotation = math.rad(velocidad * dt)
        modelo:PivotTo(modelo:GetPivot() * CFrame.fromAxisAngle(eje, deltaRotation))
    end
end

task.spawn(function()
    local lastTime = tick()
    while true do
        RunService.Heartbeat:Wait()
        local now = tick()
        local dt = now - lastTime
        lastTime = now

        currentTime:set(os.time())

        -- Si la fusión está en curso, aplica la rotación planetaria
        if peek(isFusing) then
            local planetarium = Workspace:FindFirstChild("Fusion") and Workspace.Fusion:FindFirstChild("Planetarium") and Workspace.Fusion.Planetarium:FindFirstChild("Gears")
            if planetarium then
                local r1 = planetarium:FindFirstChild("Ring1")
                local r2 = planetarium:FindFirstChild("Ring2")
                local r3 = planetarium:FindFirstChild("Ring3")
                local r4 = planetarium:FindFirstChild("Ring4")
                local r0 = planetarium:FindFirstChild("Ring0")
                local gear = planetarium:FindFirstChild("Gear")

                rotar(r1, velR1, Vector3.new(0, 1, 0), dt)
                rotar(r2, velR2, Vector3.new(0, 1, 0), dt)
                rotar(r3, velR3, Vector3.new(1, 0, 0), dt)
                rotar(r4, velR4, Vector3.new(1, 0, 0), dt)
                rotar(gear, velGear, Vector3.new(0, 1, 0), dt)
                rotar(r0, velR0, Vector3.new(0, 1, 0), dt)

                -- Update 3D Timer
                local timerModel = planetarium.Parent and planetarium.Parent:FindFirstChild("Timer")
                if timerModel and timerModel:FindFirstChild("Screen") then
                    local surfaceGui = timerModel.Screen:FindFirstChild("SurfaceGui")
                    if surfaceGui and surfaceGui:FindFirstChild("Timer") then
                        local diff = peek(fusionEndTime) - os.time()
                        if diff > 0 then
                            local m = math.floor(diff / 60)
                            local s = diff % 60
                            surfaceGui.Timer.Text = string.format("%02d:%02d", m, s)
                        else
                            surfaceGui.Timer.Text = "READY"
                        end
                    end
                end
            end
        else
            -- Not fusing, zero the timer
            local planetarium = Workspace:FindFirstChild("Fusion") and Workspace.Fusion:FindFirstChild("Planetarium")
            if planetarium then
                local timerModel = planetarium:FindFirstChild("Timer")
                if timerModel and timerModel:FindFirstChild("Screen") then
                    local surfaceGui = timerModel.Screen:FindFirstChild("SurfaceGui")
                    if surfaceGui and surfaceGui:FindFirstChild("Timer") then
                        if surfaceGui.Timer.Text ~= "00:00" then
                            surfaceGui.Timer.Text = "00:00"
                        end
                    end
                end
            end
        end
    end
end)

local function findSkinDataByName(name)
    if ItemsData.Arsenal and ItemsData.Arsenal.WeaponSkins then
        for _, skin in ipairs(ItemsData.Arsenal.WeaponSkins) do
            if skin.Name == name then return skin end
        end
    end
    return nil
end

local isFull = Computed(scope, function(use)
    return use(inputSlots[1]) and use(inputSlots[2]) and use(inputSlots[3]) and use(inputSlots[4])
end)

local matchRarity = Computed(scope, function(use)
    if not use(isFull) then return nil end

    local r1 = use(inputSlots[1]).Rarity or "Common"
    local r2 = use(inputSlots[2]).Rarity or "Common"
    local r3 = use(inputSlots[3]).Rarity or "Common"
    local r4 = use(inputSlots[4]).Rarity or "Common"

    r1, r2, r3, r4 = string.lower(r1), string.lower(r2), string.lower(r3), string.lower(r4)

    if r1 == r2 and r2 == r3 and r3 == r4 then
        return r1
    end
    return nil
end)

local targetRarityTheme = Computed(scope, function(use)
    local match = use(matchRarity)
    if not match then
        -- Fallback: if there's an active fusion, derive from sourceSkins rarity
        local info = use(activeFusionInfo)
        if info and info.sourceSkins and #info.sourceSkins > 0 then
            local firstSkin = findSkinDataByName(info.sourceSkins[1])
            if firstSkin then
                local srcRarity = string.lower(firstSkin.Rarity or "common")
                local nextRarities = {
                    common = "Rare", rare = "Epic",
                    epic = "Legendary", legendary = "Legendary",
                }
                local target = nextRarities[srcRarity] or "Common"
                return Constants.getTheme(target)
            end
        end
        return nil
    end

    local nextRarities = {
        common = "Rare",
        rare = "Epic",
        epic = "Legendary",
        -- Max rarity reached, no target
    }

    local target = nextRarities[match]
    if not target then return nil end
    return Constants.getTheme(target)
end)

local subtitleColor = Computed(scope, function(use)
    if use(isFull) then
        if not use(matchRarity) then
            return Color3.fromRGB(255, 60, 60) -- Red error (mismatch)
        elseif use(matchRarity) == "legendary" then
            return Color3.fromRGB(255, 60, 60) -- Red error (max rarity)
        end
    end
    return Color3.new(1, 1, 1) -- White
end)

local subtitleText = Computed(scope, function(use)
    if use(isFull) then
        if not use(matchRarity) then
            return "THEY MUST BE THE SAME RARITY"
        elseif use(matchRarity) == "legendary" then
            return "MAX RARITY REACHED! CANNOT FUSE."
        end
    end
    return "CHOOSE SKINS OF THE SAME RARITY"
end)

local fusionButtonText = Computed(scope, function(use)
    if not use(isFusing) then return "START FUSION" end
    local diff = use(fusionEndTime) - use(currentTime)
    if diff <= 0 then return "COLLECT" end
    return "CANCEL FUSION"
end)

--------------------------------------------------------------------------------
-- Viewport setup for input slot previews
--------------------------------------------------------------------------------
local VIEWPORT_FOV = 30
local VIEWPORT_DIST_MULT = 0.52
local VIEWPORT_ROT_X = 0
local VIEWPORT_ROT_Y = 130
local VIEWPORT_ROT_Z = -12
local VIEWPORT_OFFSET_X = 0.2

local function setupSlotViewport(viewportFrame, skinData)
    viewportFrame:ClearAllChildren()
    if not skinData then return end

    local weaponsFolder = ReplicatedStorage.Shared.Systems.Locker:WaitForChild("Weapons", 5)
    local baseModel = weaponsFolder and (weaponsFolder:FindFirstChild("Default"))
    if not baseModel then return end

    local clonedModel = baseModel:Clone()
    clonedModel.Parent = viewportFrame

    local modelCenter, updatedSize = clonedModel:GetBoundingBox()
    local orientacionFija = CFrame.fromEulerAnglesYXZ(
        math.rad(VIEWPORT_ROT_X), math.rad(VIEWPORT_ROT_Y), math.rad(VIEWPORT_ROT_Z)
    )
    clonedModel:PivotTo(CFrame.new(modelCenter.Position) * orientacionFija)

    local cam = Instance.new("Camera")
    cam.FieldOfView = VIEWPORT_FOV
    viewportFrame.CurrentCamera = cam
    cam.Parent = viewportFrame

    local maxDim = math.max(updatedSize.X, updatedSize.Y, updatedSize.Z)
    local halfFov = math.rad(cam.FieldOfView / 2)
    local baseDistance = (maxDim / 2) / math.tan(halfFov)
    local finalDistance = baseDistance * VIEWPORT_DIST_MULT

    cam.CFrame = CFrame.new(
        modelCenter.Position + Vector3.new(0, 0, finalDistance),
        modelCenter.Position
    ) * CFrame.new(-VIEWPORT_OFFSET_X, 0, 0)

    -- Apply skin
    local textures = SkinApplier.apply(clonedModel, skinData)
    local animConn = SkinApplier.startAnimation(textures, skinData, viewportFrame)
    if animConn then
        table.insert(scope, { Destroy = function() animConn:Disconnect() end })
    end
end

--------------------------------------------------------------------------------
-- Camera open/close
--------------------------------------------------------------------------------
-- Reactive restoration: whenever activeFusionInfo changes (data loads / fusion starts)
local function restoreSlotsFromFusion()
    local info = peek(activeFusionInfo)
    if info and info.sourceSkins then
        for i, skinName in ipairs(info.sourceSkins) do
            if i <= 4 and not peek(inputSlots[i]) then
                local skinInfo = findSkinDataByName(skinName)
                if skinInfo then
                    inputSlots[i]:set(skinInfo)
                end
            end
        end
    else
        -- Fusion cleared (collected or cancelled): reset all slots
        for i = 1, 4 do
            inputSlots[i]:set(nil)
        end
    end
end

local obsActiveFusion = Observer(scope, activeFusionInfo)
table.insert(scope, obsActiveFusion:onChange(function()
    restoreSlotsFromFusion()
end))

local function openFusion()
    isFusionOpen:set(true)

    -- Restore slots from activeFusion if a fusion is in progress
    restoreSlotsFromFusion()

    local cameraPart = Workspace:WaitForChild("Cameras"):WaitForChild("Fusion", 10)
    if cameraPart then
        CameraManager.setTarget(cameraPart, true, nil, 22)
    else
        warn("[FusionCamera] Workspace.Cameras.Fusion not found!")
        isFusionOpen:set(false)
    end
end

local function closeFusionCollect()
    if activeBoxCleanup then
        activeBoxCleanup()
        activeBoxCleanup = nil
    end
    showFusionCollect:set(false)

    -- Clear slots since fusion is complete
    for i = 1, 4 do
        inputSlots[i]:set(nil)
    end

    -- Restore fusion camera
    local cameraPart = Workspace:FindFirstChild("Cameras") and Workspace.Cameras:FindFirstChild("Fusion")
    if cameraPart then
        CameraManager.setTarget(cameraPart, true, nil, 22)
    end
    isFusionOpen:set(true)
end

local function closeFusion()
    if not peek(isFusionOpen) then return end

    isFusionOpen:set(false)
    activeInputIndex:set(nil)

    -- Only clear slots if NOT in an active fusion
    if not peek(isFusing) then
        for _, slot in inputSlots do
            slot:set(nil)
        end
    end

    task.spawn(function()
        EffectsManager.fadeToBlack(0.2)
        CameraManager.reset(true)
        EffectsManager.fadeFromBlack(0.2)
    end)
end

local function toggleFusion()
    if peek(isFusionOpen) then
        closeFusion()
    else
        openFusion()
    end
end

--------------------------------------------------------------------------------
-- Create a single Input Slot (reusable for Input1-4)
--------------------------------------------------------------------------------
local function createInputSlot(scope, index, position)
    local slotData = inputSlots[index]

    local hasSkin = Computed(scope, function(use)
        return use(slotData) ~= nil
    end)

    local skinRarity = Computed(scope, function(use)
        local data = use(slotData)
        if data then
            return string.upper(data.Rarity or "COMMON")
        end
        return "COMMON"
    end)

    local rarityStrokeColor = Computed(scope, function(use)
        local data = use(slotData)
        if data then
            local theme = Constants.getTheme(data.Rarity or "Common")
            return theme.RarityStroke
        end
        return Color3.fromRGB(143, 143, 143)
    end)

    -- Hover / press animation (same pattern as SkinCard)
    local isHovered = Value(scope, false)
    local isPressed = Value(scope, false)

    local targetScale = Computed(scope, function(use)
        if use(isPressed) then return 0.93 end
        if use(isHovered) then return 1.05 end
        return 1
    end)

    local animatedScale = Spring(scope, targetScale, 30, 0.6)

    local animatedSize = Computed(scope, function(use)
        local scale = use(animatedScale)
        return UDim2.fromScale(scale, scale)
    end)

    -- Active (blue) stroke when this slot is being filled
    local isActive = Computed(scope, function(use)
        return use(activeInputIndex) == index
    end)

    local strokeColor = Computed(scope, function(use)
        if use(isActive) then
            return Color3.fromRGB(85, 126, 239) -- Blue
        end
        return Color3.new(0, 0, 0) -- Default black
    end)

    -- Viewport for showing selected skin
    local viewportFrame = scope:New "ViewportFrame" {
        Name = "ViewportFrame",
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
    }

    -- Update viewport when slot data changes
    local obsSlot = Observer(scope, slotData)
    obsSlot:onChange(function()
        local data = peek(slotData)
        task.defer(function()
            setupSlotViewport(viewportFrame, data)
        end)
    end)

    -- Wrapper for hover scale animation
    return scope:New "Frame" {
        Name = "Input" .. index .. "Wrapper",
        BackgroundTransparency = 1,
        Position = position,
        Size = UDim2.fromScale(0.0849495, 0.192893),

        [Children] = {
            scope:New "ImageButton" {
                Name = "Input" .. index,
                AnchorPoint = Vector2.new(0.5, 0.5),
                AutoButtonColor = false,
                BackgroundColor3 = Computed(scope, function(use)
                    local data = use(slotData)
                    if data then
                        local theme = Constants.getTheme(data.Rarity or "Common")
                        return theme.Background
                    end
                    return Color3.fromRGB(82, 82, 82)
                end),
                ClipsDescendants = true,
                Image = Computed(scope, function(use)
                    local data = use(slotData)
                    if data then
                        return "rbxassetid://71136216021149" -- Card texture
                    end
                    return "rbxassetid://100090954804591" -- Default pattern
                end),
                ImageColor3 = Computed(scope, function(use)
                    local data = use(slotData)
                    if data then
                        local theme = Constants.getTheme(data.Rarity or "Common")
                        return theme.ImageColor
                    end
                    return Color3.fromRGB(54, 54, 54)
                end),
                ImageTransparency = 0.14,
                Position = UDim2.fromScale(0.5, 0.5),
                Size = animatedSize,

                [OnEvent "MouseEnter"] = function() isHovered:set(true) end,
                [OnEvent "MouseLeave"] = function() isHovered:set(false); isPressed:set(false) end,
                [OnEvent "InputBegan"] = function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        isPressed:set(true)
                    end
                end,
                [OnEvent "InputEnded"] = function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        isPressed:set(false)
                    end
                end,
                [OnEvent "Activated"] = function()
                    if peek(isFusing) then return end -- disable input clicks while fusing
                    if not peek(slotData) then
                        activeInputIndex:set(index)
                    end
                end,

                [Children] = {
                    scope:New "UIStroke" {
                        Name = "UIStroke",
                        Thickness = 6,
                        Color = strokeColor,
                    },

                    scope:New "UICorner" {
                        Name = "UICorner",
                        CornerRadius = UDim.new(0.08, 0),
                    },

                    -- "+" text (visible when no skin selected)
                    scope:New "TextLabel" {
                        Name = "Add",
                        BackgroundTransparency = 1,
                        FontFace = Font.new(
                            "rbxasset://fonts/families/GothamSSm.json",
                            Enum.FontWeight.Bold,
                            Enum.FontStyle.Normal
                        ),
                        Size = UDim2.fromScale(1, 1),
                        Text = "+",
                        TextColor3 = Color3.fromRGB(253, 255, 255),
                        TextScaled = true,
                        ZIndex = 2,
                        Visible = Computed(scope, function(use)
                            return not use(hasSkin)
                        end),

                        [Children] = {
                            scope:New "UIStroke" {
                                Name = "UIStroke",
                                Thickness = 5,
                            },
                        }
                    },

                    -- Skin preview frame (visible when skin is selected)
                    scope:New "Frame" {
                        Name = "Skin",
                        BackgroundTransparency = 1,
                        Size = UDim2.fromScale(1, 1),
                        Visible = hasSkin,

                        [Children] = {
                            viewportFrame,

                            -- Rarity label
                            scope:New "TextLabel" {
                                Name = "Rarity",
                                BackgroundTransparency = 1,
                                FontFace = Font.new(
                                    "rbxasset://fonts/families/HighwayGothic.json",
                                    Enum.FontWeight.Bold,
                                    Enum.FontStyle.Normal
                                ),
                                Position = UDim2.fromScale(0, 0.0225),
                                Size = UDim2.fromScale(1, 0.1685),
                                Text = skinRarity,
                                TextColor3 = Color3.new(1, 1, 1),
                                TextScaled = true,
                                ZIndex = 2,

                                [Children] = {
                                    scope:New "UITextSizeConstraint" {
                                        Name = "UITextSizeConstraint",
                                        MaxTextSize = 46,
                                    },
                                    scope:New "UIStroke" {
                                        Name = "UIStroke",
                                        Color = rarityStrokeColor,
                                        Thickness = 2.1,
                                    },
                                }
                            },

                            -- Remove button
                            scope:New "TextButton" {
                                Name = "Remove",
                                BackgroundColor3 = Color3.fromRGB(246, 56, 70),
                                FontFace = Font.new("rbxasset://fonts/families/LuckiestGuy.json"),
                                Position = UDim2.fromScale(0.85, -0.05),
                                Rotation = 14,
                                Size = UDim2.fromScale(0.25, 0.25),
                                Text = "X",
                                TextColor3 = Color3.new(1, 1, 1),
                                TextScaled = true,
                                ZIndex = 5,

                                [OnEvent "Activated"] = function()
                                    if peek(isFusing) then return end
                                    slotData:set(nil)
                                end,

                                [Children] = {
                                    scope:New "UICorner" {
                                        Name = "UICorner",
                                        CornerRadius = UDim.new(0.5, 0),
                                    },
                                    scope:New "UIStroke" {
                                        Name = "UIStroke",
                                        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
                                        Thickness = 4,
                                    },
                                    scope:New "UIPadding" {
                                        Name = "UIPadding",
                                        PaddingBottom = UDim.new(0.1, 0),
                                        PaddingLeft = UDim.new(0.1, 0),
                                        PaddingRight = UDim.new(0.1, 0),
                                        PaddingTop = UDim.new(0.1, 0),
                                    },
                                    scope:New "UIAspectRatioConstraint" {
                                        Name = "UIAspectRatioConstraint",
                                    },
                                }
                            },
                        }
                    },
                }
            },
        }
    }
end

--------------------------------------------------------------------------------
-- Create SkinsFrame (grid of owned skins, same logic as Locker)
--------------------------------------------------------------------------------
local function createSkinsFrame(scope)
    -- Filter owned skins reactively
    local ownedSkins = Computed(scope, function(use)
        local data = use(playerData)
        local allSkins = ItemsData.Arsenal and ItemsData.Arsenal.WeaponSkins or {}

        local filtered = {}
        local ownedCount = {}

        if data and data.inventory and data.inventory.WeaponSkins then
            for _, name in data.inventory.WeaponSkins do
                ownedCount[name] = (ownedCount[name] or 0) + 1
            end
        end
        -- Default always visible
        ownedCount["Default"] = (ownedCount["Default"] or 0) + 1

        for _, item in allSkins do
            if ownedCount[item.Name] and ownedCount[item.Name] > 0 then
                -- Clone to avoid mutating original
                local entry = table.clone(item)
                entry._ownedCount = ownedCount[item.Name]
                table.insert(filtered, entry)
            end
        end

        return filtered
    end)

    -- Build skin cards
    local skinCards = Computed(scope, function(use)
        local skins = use(ownedSkins)
        local cards = {}

        table.insert(cards, scope:New "UIGridLayout" {
            Name = "UIGridLayout",
            CellPadding = UDim2.new(0.04, 0, 0, 24),
            CellSize = UDim2.new(0.3, 0, 0, 222),
            SortOrder = Enum.SortOrder.LayoutOrder,
        })

        table.insert(cards, scope:New "UIPadding" {
            Name = "UIPadding",
            PaddingBottom = UDim.new(0, 25),
            PaddingLeft = UDim.new(0, 25),
            PaddingRight = UDim.new(0, 25),
            PaddingTop = UDim.new(0, 15),
        })

        -- Count how many copies of each skin are used across the 4 slots
        local usedCounts = {}
        for _, slotValue in inputSlots do
            local slotSkin = use(slotValue)
            if slotSkin then
                usedCounts[slotSkin.Name] = (usedCounts[slotSkin.Name] or 0) + 1
            end
        end

        -- Sort: by rarity descending
        local RARITY_WEIGHTS = { Legendary = 4, Epic = 3, Rare = 2, Common = 1 }
        local sorted = table.clone(skins)
        table.sort(sorted, function(a, b)
            local ra = RARITY_WEIGHTS[a.Rarity] or 0
            local rb = RARITY_WEIGHTS[b.Rarity] or 0
            if ra ~= rb then return ra > rb end
            return a.Name < b.Name
        end)

        local layoutIndex = 0
        for _, skinItem in sorted do
            -- Calculate remaining copies (total owned - used in slots)
            local totalOwned = skinItem._ownedCount or 1
            local usedInSlots = usedCounts[skinItem.Name] or 0
            local remaining = totalOwned - usedInSlots

            -- Skip skins with no remaining copies
            if remaining > 0 then
                layoutIndex += 1

                table.insert(cards, SkinCard(scope, {
                    skinName = skinItem.Name,
                    skinData = skinItem,
                    equippedWeapon = "Default",
                    layoutOrder = layoutIndex,
                    ownedCount = remaining,
                    isEquipped = false,
                    isSelected = false,
                    onClick = function()
                        local idx = peek(activeInputIndex)
                        if idx and idx >= 1 and idx <= 4 then
                            inputSlots[idx]:set(skinItem)
                            activeInputIndex:set(nil) -- Close SkinsFrame
                        end
                    end,
                }))
            end
        end

        return cards
    end)

    -- Canvas size based on item count
    local canvasSize = Computed(scope, function(use)
        local skins = use(ownedSkins)
        local count = #skins
        local rows = math.ceil(count / 3)
        if rows == 0 then return UDim2.new(0, 0, 0, 0) end
        local cellHeight = 222
        local padY = 24
        local totalHeight = (rows * cellHeight) + ((rows - 1) * padY) + 40
        return UDim2.new(0, 0, 0, totalHeight)
    end)

    return scope:New "Frame" {
        Name = "SkinsFrame",
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.fromRGB(25, 25, 25),
        Position = UDim2.fromScale(0.500146, 0.423751),
        Size = UDim2.fromScale(0.356, 0.708001),
        Visible = skinsFrameVisible,

        [Children] = {
            scope:New "UICorner" {
                Name = "UICorner",
                CornerRadius = UDim.new(0.05, 0),
            },

            scope:New "UIStroke" {
                Name = "UIStroke",
                Thickness = 4,
            },

            scope:New "ScrollingFrame" {
                Name = "ItemGrid",
                BackgroundTransparency = 1,
                BottomImage = "",
                CanvasSize = canvasSize,
                Position = UDim2.fromScale(0, 0.014),
                ScrollBarThickness = 10,
                ScrollBarImageColor3 = Color3.new(1, 1, 1),
                Size = UDim2.fromScale(0.987, 0.986),
                TopImage = "",

                [Children] = skinCards,
            },

            -- Close SkinsFrame button (small X at top-right)
            scope:New "TextButton" {
                Name = "CloseSkinsFrame",
                BackgroundColor3 = Color3.fromRGB(202, 44, 73),
                Position = UDim2.fromScale(0.92, 0.01),
                Size = UDim2.fromScale(0.06, 0.04),
                Text = "X",
                TextColor3 = Color3.new(1, 1, 1),
                TextScaled = true,
                FontFace = Font.new(
                    "rbxasset://fonts/families/HighwayGothic.json",
                    Enum.FontWeight.Bold,
                    Enum.FontStyle.Normal
                ),
                ZIndex = 10,

                [OnEvent "Activated"] = function()
                    activeInputIndex:set(nil)
                end,

                [Children] = {
                    scope:New "UICorner" {
                        Name = "UICorner",
                        CornerRadius = UDim.new(0.15, 0),
                    },
                    scope:New "UIStroke" {
                        Name = "UIStroke",
                        Thickness = 2,
                    },
                }
            },
        }
    }
end

--------------------------------------------------------------------------------
-- Build ScreenGui
--------------------------------------------------------------------------------
local _fusionGui = scope:New "ScreenGui" {
    Name = "Fusion",
    Parent = player.PlayerGui,
    IgnoreGuiInset = true,
    ScreenInsets = Enum.ScreenInsets.None,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Enabled = isFusionOpen,

    [Children] = {
        -- Title
        scope:New "TextLabel" {
            Name = "Choose4SKins",
            BackgroundTransparency = 1,
            FontFace = Font.new(
                "rbxasset://fonts/families/SourceSansPro.json",
                Enum.FontWeight.Bold,
                Enum.FontStyle.Normal
            ),
            Position = UDim2.fromScale(0.102247, 0.142734),
            Size = UDim2.fromScale(0.18929, 0.0443297),
            Text = "CHOOSE 4 SKINS TO FUSE",
            TextColor3 = Color3.new(1, 1, 1),
            TextScaled = true,

            [Children] = {
                scope:New "UIStroke" {
                    Name = "UIStroke",
                    Thickness = 4,
                },
            }
        },


        -- Subtitle
        scope:New "TextLabel" {
            Name = "Subtitle",
            BackgroundTransparency = 1,
            FontFace = Font.new(
                "rbxasset://fonts/families/SourceSansPro.json",
                Enum.FontWeight.Bold,
                Enum.FontStyle.Italic
            ),
            Position = UDim2.fromScale(0.102247, 0.187533),
            Size = UDim2.fromScale(0.18929, 0.0255287),
            Text = subtitleText,
            TextColor3 = subtitleColor,
            TextScaled = true,

            [Children] = {
                scope:New "UIStroke" {
                    Name = "UIStroke",
                    Thickness = 2,
                },
            }
        },

        -- Gradient (bottom decorative)
        scope:New "Frame" {
            Name = "GradientBlue",
            BackgroundColor3 = Color3.fromRGB(255, 133, 102),
            BorderColor3 = Color3.new(),
            BorderSizePixel = 0,
            Position = UDim2.fromScale(0, 0.65987),
            Size = UDim2.fromScale(1, 0.247451),
            ZIndex = -1,

            [Children] = {
                scope:New "UIGradient" {
                    Name = "UIGradient",
                    Rotation = 270,
                    Transparency = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 0),
                        NumberSequenceKeypoint.new(0.257541, 0.625),
                        NumberSequenceKeypoint.new(1, 1),
                    }),
                },
            }
        },

        -- Main Container
        scope:New "Frame" {
            Name = "Container",
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 1),

            [Children] = {
                -- Start Fusion Button
                scope:New "ImageButton" {
                    Name = "StartFusion",
                    AutoButtonColor = false,
                    BackgroundColor3 = Computed(scope, function(use)
                        local theme = use(targetRarityTheme)
                        return theme and theme.ImageColor or Color3.fromRGB(73, 128, 245)
                    end),
                    Position = UDim2.fromScale(0.404531, 0.872066),
                    Size = UDim2.fromScale(0.190104, 0.0769231),

                    [OnEvent "Activated"] = function()
                        local cFusing = peek(isFusing)
                        local diff = peek(fusionEndTime) - os.time()

                        if not cFusing then
                            -- START
                            local mRarity = peek(matchRarity)
                            if peek(isFull) and mRarity and mRarity ~= "legendary" then
                                local skinsToFuse = {
                                    peek(inputSlots[1]).Name,
                                    peek(inputSlots[2]).Name,
                                    peek(inputSlots[3]).Name,
                                    peek(inputSlots[4]).Name,
                                }
                                local res = fusionActionRF:InvokeServer("Start", skinsToFuse)
                                if not res.success then
                                    warn("[Fusion] failed to start:", res.message)
                                end
                            end
                        elseif diff <= 0 then
                            -- COLLECT
                            local res = fusionActionRF:InvokeServer("Collect")
                            if res.success and res.resultSkin then
                                local skinName = res.resultSkin
                                local skinObj = nil
                                if ItemsData.Arsenal and ItemsData.Arsenal.WeaponSkins then
                                    for _, skin in ipairs(ItemsData.Arsenal.WeaponSkins) do
                                        if skin.Name == skinName then
                                            skinObj = skin
                                            break
                                        end
                                    end
                                end

                                if skinObj then
                                    local casesWS = workspace:FindFirstChild("Cases")
                                    local box = casesWS and casesWS:FindFirstChildWhichIsA("Model")
                                    if box then
                                        isFusionOpen:set(false) -- hide gui during animation
                                        activeBoxCleanup = BoxAnimation.iniciarSecuencia(box, skinObj, function()
                                            showFusionCollect:set(true)
                                        end)
                                    end
                                end
                                -- Local slots clearing
                                for i=1,4 do inputSlots[i]:set(nil) end
                            else
                                warn("[Fusion] failed to collect:", res.message)
                            end
                        else
                            -- CANCEL
                            local res = fusionActionRF:InvokeServer("Cancel")
                            if not res.success then
                                warn("[Fusion] failed to cancel:", res.message)
                            end
                        end
                    end,

                    [Children] = {
                        scope:New "UIStroke" {
                            Name = "UIStroke",
                            Thickness = 4,
                        },

                        scope:New "UICorner" {
                            Name = "UICorner",
                        },

                        scope:New "Frame" {
                            Name = "Frame",
                            BackgroundColor3 = Computed(scope, function(use)
                                local theme = use(targetRarityTheme)
                                return theme and theme.Background or Color3.fromRGB(113, 165, 247)
                            end),
                            Position = UDim2.fromScale(0.0212764, 0.0843373),
                            Size = UDim2.fromScale(0.956164, 0.0843373),

                            [Children] = {
                                scope:New "UICorner" {
                                    Name = "UICorner",
                                },
                            }
                        },

                        scope:New "TextLabel" {
                            Name = "TextLabel",
                            BackgroundTransparency = 1,
                            FontFace = Font.new(
                                "rbxasset://fonts/families/SourceSansPro.json",
                                Enum.FontWeight.Bold,
                                Enum.FontStyle.Normal
                            ),
                            Position = UDim2.fromScale(0, 0.199306),
                            Size = UDim2.fromScale(1, 0.595876),
                            Text = fusionButtonText,
                            TextColor3 = Color3.new(1, 1, 1),
                            TextScaled = true,

                            [Children] = {
                                scope:New "UIStroke" {
                                    Name = "UIStroke",
                                    Thickness = 3,
                                },
                            }
                        },
                    }
                },

                -- Bottom Bar
                scope:New "Frame" {
                    Name = "BottomBar",
                    BackgroundColor3 = Color3.fromRGB(14, 26, 49),
                    BorderColor3 = Color3.new(),
                    BorderSizePixel = 0,
                    Position = UDim2.fromScale(0, 0.907322),
                    Size = UDim2.fromScale(1, 0.0926784),
                    ZIndex = -1,
                },

                -- Result Title
                scope:New "TextLabel" {
                    Name = "Title",
                    BackgroundTransparency = 1,
                    FontFace = Font.new(
                        "rbxasset://fonts/families/SourceSansPro.json",
                        Enum.FontWeight.Bold,
                        Enum.FontStyle.Normal
                    ),
                    Position = UDim2.fromScale(0.768229, 0.25445),
                    Size = UDim2.fromScale(0.189583, 0.0430478),
                    Text = "RESULT",
                    TextColor3 = Color3.new(1, 1, 1),
                    TextScaled = true,

                    [Children] = {
                        scope:New "UIStroke" {
                            Name = "UIStroke",
                            Thickness = 4,
                        },
                    }
                },

                -- 4 Input Slots
                createInputSlot(scope, 1, UDim2.fromScale(0.102247, 0.236456)),
                createInputSlot(scope, 2, UDim2.fromScale(0.205893, 0.236456)),
                createInputSlot(scope, 3, UDim2.fromScale(0.103289, 0.460738)),
                createInputSlot(scope, 4, UDim2.fromScale(0.206935, 0.460738)),

                -- SkinsFrame (populated dynamically)
                createSkinsFrame(scope),

                -- Output slot
                scope:New "ImageButton" {
                    Name = "Output",
                    AutoButtonColor = false,
                    BackgroundColor3 = Computed(scope, function(use)
                        local theme = use(targetRarityTheme)
                        return theme and theme.Background or Color3.fromRGB(82, 82, 82)
                    end),
                    ClipsDescendants = true,
                    Image = Computed(scope, function(use)
                        local theme = use(targetRarityTheme)
                        return theme and "rbxassetid://71136216021149" or "rbxassetid://100090954804591"
                    end),
                    ImageColor3 = Computed(scope, function(use)
                        local theme = use(targetRarityTheme)
                        return theme and theme.ImageColor or Color3.fromRGB(54, 54, 54)
                    end),
                    ImageTransparency = 0.14,
                    Position = UDim2.fromScale(0.81631, 0.336549),
                    Size = UDim2.fromScale(0.0978535, 0.220234),

                    [Children] = {
                        scope:New "UIStroke" {
                            Name = "UIStroke",
                            Thickness = 6,
                        },

                        scope:New "UICorner" {
                            Name = "UICorner",
                            CornerRadius = UDim.new(0.08, 0),
                        },

                        scope:New "TextLabel" {
                            Name = "Cash",
                            BackgroundTransparency = 1,
                            FontFace = Font.new(
                                "rbxasset://fonts/families/GothamSSm.json",
                                Enum.FontWeight.Bold,
                                Enum.FontStyle.Normal
                            ),
                            Size = UDim2.fromScale(1, 1),
                            Text = "+",
                            TextColor3 = Color3.fromRGB(253, 255, 255),
                            TextScaled = true,
                            Visible = false,
                            ZIndex = 2,

                            [Children] = {
                                scope:New "UIStroke" {
                                    Name = "UIStroke",
                                    Thickness = 5,
                                },
                            }
                        },

                        scope:New "ImageLabel" {
                            Name = "ItemImage",
                            BackgroundTransparency = 1,
                            Image = "rbxassetid://87132897706192",
                            ImageColor3 = Color3.new(0, 0, 0),
                            Position = UDim2.fromScale(0, 0),
                            ScaleType = Enum.ScaleType.Fit,
                            Size = UDim2.fromScale(1, 1),

                            [Children] = {
                                scope:New "TextLabel" {
                                    Name = "TextLabel",
                                    BackgroundTransparency = 1,
                                    FontFace = Font.new(
                                        "rbxasset://fonts/families/SourceSansPro.json",
                                        Enum.FontWeight.Bold,
                                        Enum.FontStyle.Italic
                                    ),
                                    Position = UDim2.fromScale(0, 0.737626),
                                    Size = UDim2.fromScale(1, 0.176146),
                                    Text = "Random",
                                    TextColor3 = Color3.new(1, 1, 1),
                                    TextScaled = true,

                                    [Children] = {
                                        scope:New "UIStroke" {
                                            Name = "UIStroke",
                                            Thickness = 3,
                                        },
                                    }
                                },
                            }
                        },
                    }
                },

                -- Result Gradient
                scope:New "ImageLabel" {
                    Name = "Gradient",
                    BackgroundTransparency = 1,
                    Image = "rbxassetid://108673277431689",
                    ImageColor3 = Computed(scope, function(use)
                        local theme = use(targetRarityTheme)
                        return theme and theme.Background or Color3.new(1, 1, 1)
                    end),
                    Position = UDim2.fromScale(0.768229, 0.23633),
                    Size = UDim2.fromOffset(364, 454),
                    ZIndex = -1,
                },
            }
        },

        -- Close Button
        scope:New "ImageButton" {
            Name = "CloseBtn",
            AutoButtonColor = false,
            BackgroundColor3 = Color3.fromRGB(202, 44, 73),
            Position = UDim2.fromScale(0.349075, 0.882686),
            Size = UDim2.fromScale(0.0375, 0.0574606),

            [OnEvent "Activated"] = function()
                closeFusion()
            end,

            [Children] = {
                scope:New "UICorner" {
                    Name = "UICorner",
                    CornerRadius = UDim.new(0.15, 0),
                },

                scope:New "TextLabel" {
                    Name = "TextLabel",
                    BackgroundColor3 = Color3.fromRGB(255, 63, 77),
                    FontFace = Font.new(
                        "rbxasset://fonts/families/HighwayGothic.json",
                        Enum.FontWeight.Bold,
                        Enum.FontStyle.Normal
                    ),
                    Size = UDim2.fromScale(1, 0.901879),
                    Text = "X",
                    TextColor3 = Color3.new(1, 1, 1),
                    TextSize = 39,
                    TextWrapped = true,

                    [Children] = {
                        scope:New "UICorner" {
                            Name = "UICorner",
                            CornerRadius = UDim.new(0.15, 0),
                        },
                        scope:New "UIStroke" {
                            Name = "UIStroke",
                            Thickness = 3,
                        },
                    }
                },

                scope:New "UIStroke" {
                    Name = "UIStroke",
                    Thickness = 3,
                },
            }
        },
    }
}

--------------------------------------------------------------------------------
-- Fusion Collect ScreenGui (shown during BoxAnimation reveal)
--------------------------------------------------------------------------------
local _fusionCollectGui = scope:New "ScreenGui" {
    Name = "FusionCollect",
    Parent = player.PlayerGui,
    IgnoreGuiInset = true,
    DisplayOrder = 20,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Enabled = showFusionCollect,

    [Children] = {
        scope:New "ImageButton" {
            Name = "CollectButton",
            AnchorPoint = Vector2.new(0.5, 0.5),
            AutoButtonColor = false,
            BackgroundColor3 = Color3.fromRGB(85, 239, 126),
            Position = UDim2.fromScale(0.5, 0.9),
            Size = UDim2.fromOffset(300, 80),

            [OnEvent "Activated"] = function()
                closeFusionCollect()
            end,

            [Children] = {
                scope:New "UICorner" {
                    Name = "UICorner",
                    CornerRadius = UDim.new(0.2, 0),
                },

                scope:New "UIStroke" {
                    Name = "BorderStroke",
                    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
                    Thickness = 4,
                },

                scope:New "TextLabel" {
                    Name = "CollectText",
                    BackgroundTransparency = 1,
                    FontFace = Font.new(
                        "rbxasset://fonts/families/HighwayGothic.json",
                        Enum.FontWeight.Bold,
                        Enum.FontStyle.Normal
                    ),
                    Size = UDim2.fromScale(1, 1),
                    Text = "COLLECT",
                    TextColor3 = Color3.new(1, 1, 1),
                    TextScaled = true,

                    [Children] = {
                        scope:New "UITextSizeConstraint" {
                            Name = "UITextSizeConstraint",
                            MaxTextSize = 40,
                        },
                        scope:New "UIStroke" {
                            Name = "InnerStroke",
                            Thickness = 4,
                        },
                    }
                },
            }
        },
    }
}

--------------------------------------------------------------------------------
-- Input: F key toggle
--------------------------------------------------------------------------------
table.insert(scope, UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.F then
        toggleFusion()
    end
end))

print("[FusionCamera] Controller loaded")
