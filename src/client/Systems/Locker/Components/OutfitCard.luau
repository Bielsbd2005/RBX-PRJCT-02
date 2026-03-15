--!strict

--[[
    OutfitCard
    Componente para visualizar un outfit en un ViewportFrame con físicas reactivas.
    Usa colores de rareza de StoreConstants.RarityThemes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.fusion)
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value
local Computed = Fusion.Computed
local Spring = Fusion.Spring

local Constants = require(script.Parent.StoreConstants)
local OutfitApplier = require(ReplicatedStorage.Shared.Systems.Appearance.OutfitApplier)

-- Constantes visuales
local FOV_IDEAL = 30
local DISTANCIA_MULTIPLIER = 1.6
local ROTACION_X = 0
local ROTACION_Y = 180
local ROTACION_Z = 0
local DESPLAZAMIENTO_Y = 0

export type OutfitData = {
    Rarity: string,
    Price: number?,
    ShirtBaseColor: Color3?,
    ShirtTextureID: string?,
    ShirtStudsPerTile: number?,
    ShirtTextureTransparency: number?,
    ShirtMaterial: Enum.Material?,
	PantMaterial: Enum.Material?,
    PantColor: Color3?,
}

type OutfitCardProps = {
    outfitName: string,
    outfitData: OutfitData,
    layoutOrder: number,
    isSelected: Fusion.UsedAs<boolean>,
    isOwned: boolean?,
    isEquipped: Fusion.UsedAs<boolean>?,
    onClick: () -> (),
}

local function OutfitCard(scope: Fusion.Scope<typeof(Fusion)>, props: OutfitCardProps)
    local rarity = props.outfitData and props.outfitData.Rarity or "Common"
    local theme = Constants.getTheme(rarity)
    local L = Constants.CardLayout

    ---------------------------------------------------------------------------
    -- Resolución de Estado Reactivo
    ---------------------------------------------------------------------------
    local isEquippedState = Computed(scope, function(use)
        if type(props.isEquipped) == "table" then return use(props.isEquipped) end
        return props.isEquipped or false
    end)

    local isSelectedState = Computed(scope, function(use)
        if type(props.isSelected) == "table" then return use(props.isSelected) end
        return props.isSelected or false
    end)

    local showOwned = Computed(scope, function(use)
        return (props.isOwned == true) and not use(isEquippedState)
    end)

    local strokeColor = Computed(scope, function(use)
        return use(isEquippedState) and Color3.new(1, 1, 1) or theme.Stroke
    end)

    local strokeEnabled = Computed(scope, function(use)
        if use(isEquippedState) or props.isOwned then return true end
        return not use(isSelectedState)
    end)

    ---------------------------------------------------------------------------
    -- Animación Reactiva (Interacciones)
    ---------------------------------------------------------------------------
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

    ---------------------------------------------------------------------------
    -- Configuración del ViewportFrame
    ---------------------------------------------------------------------------
    local viewportFrame = scope:New "ViewportFrame" {
        Name = "ViewportFrame",
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
    }

    local function setupViewport()
        viewportFrame:ClearAllChildren()

        local template = ReplicatedStorage.Shared.Systems.Locker.Templates:WaitForChild("ClothingTemplate", 5)
        if not template then return end

        local clonedChar = template:Clone()
        clonedChar.Parent = viewportFrame

        local modelCenter, updatedSize = clonedChar:GetBoundingBox()
        local orientacionFija = CFrame.fromEulerAnglesYXZ(
            math.rad(ROTACION_X),
            math.rad(ROTACION_Y),
            math.rad(ROTACION_Z)
        )

        clonedChar:PivotTo(CFrame.new(modelCenter.Position) * orientacionFija)

        local cam = Instance.new("Camera")
        cam.FieldOfView = FOV_IDEAL
        viewportFrame.CurrentCamera = cam
        cam.Parent = viewportFrame

        local maxDimension = math.max(updatedSize.X, updatedSize.Y, updatedSize.Z)
        local halfFov = math.rad(cam.FieldOfView / 2)
        local baseDistance = (maxDimension / 2) / math.tan(halfFov)
        local finalDistance = baseDistance * DISTANCIA_MULTIPLIER

        cam.CFrame = CFrame.new(
            modelCenter.Position + Vector3.new(0, DESPLAZAMIENTO_Y, finalDistance),
            modelCenter.Position + Vector3.new(0, DESPLAZAMIENTO_Y, 0)
        )

        -- Aplicar Ropa
        OutfitApplier.Apply(clonedChar, props.outfitData)

        -- Animación Idle
        local humanoid = clonedChar:FindFirstChild("Humanoid")
        local animator = humanoid and humanoid:FindFirstChild("Animator")
        if animator then
            local animation = Instance.new("Animation")
            animation.AnimationId = Constants.AnimationIds.Idle
            local track = animator:LoadAnimation(animation)
            track.Looped = true
            track:Play()
        end
    end

    -- Poblar el ViewportFrame sin bloquear el renderizado actual
    task.defer(setupViewport)

    ---------------------------------------------------------------------------
    -- Construcción del Componente
    ---------------------------------------------------------------------------
    return scope:New "Frame" {
        Name = "OutfitCardWrapper",
        BackgroundTransparency = 1,
        LayoutOrder = props.layoutOrder,
        Size = UDim2.fromScale(1, 1),

        [Children] = {
            scope:New "ImageButton" {
                Name = "OutfitCard",
                AnchorPoint = Vector2.new(0.5, 0.5),
                AutoButtonColor = false,
                BackgroundColor3 = theme.Background,
                ClipsDescendants = true,
                Image = Constants.Assets.CardTexture,
                ImageColor3 = theme.ImageColor,
                Position = UDim2.fromScale(0.5, 0.5),
                Size = animatedSize, -- Físicas conectadas

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
                [OnEvent "Activated"] = props.onClick,

                [Children] = {
                    scope:New "UICorner" { CornerRadius = UDim.new(0.08, 0) },

                    scope:New "UIStroke" {
                        Color = strokeColor,
                        Thickness = 5,
                        Enabled = strokeEnabled,
                    },

                    -- Rarity label
                    scope:New "TextLabel" {
                        Name = "Rarity",
                        BackgroundTransparency = 1,
                        FontFace = Constants.Font,
                        Position = L.RarityPosition,
                        Size = L.RaritySize,
                        Text = string.upper(rarity),
                        TextColor3 = theme.RarityText,
                        TextScaled = true,
                        ZIndex = 2,
                        [Children] = {
                            scope:New "UITextSizeConstraint" { MaxTextSize = L.RarityMaxTextSize },
                            scope:New "UIStroke" {
                                Color = theme.RarityStroke,
                                Thickness = L.RarityStrokeThickness,
                            },
                        }
                    },

                    -- Icono de moneda (Solo si no lo tiene)
                    not props.isOwned and scope:New "ImageLabel" {
                        Name = "Currency",
                        BackgroundTransparency = 1,
                        Image = Constants.Assets.CurrencyIcon,
                        Position = UDim2.fromScale(0.188, 0.799),
                        ScaleType = Enum.ScaleType.Fit,
                        Size = UDim2.fromOffset(37, 35),
                    } or nil,

                    -- Precio (Solo si no lo tiene)
                    not props.isOwned and scope:New "TextLabel" {
                        Name = "Price",
                        BackgroundTransparency = 1,
                        FontFace = Constants.Font,
                        Position = L.PricePosition,
                        Size = L.PriceSize,
                        Text = tostring(props.outfitData.Price or 0),
                        TextColor3 = Color3.new(1, 1, 1),
                        TextScaled = true,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 2,
                        [Children] = {
                            scope:New "UIStroke" { Thickness = 2 },
                            scope:New "UITextSizeConstraint" { MaxTextSize = L.PriceMaxTextSize },
                        }
                    } or nil,

                    -- Status: EQUIPPED
                    scope:New "TextLabel" {
                        Name = "EquippedStatusLabel",
                        BackgroundTransparency = 1,
                        FontFace = Constants.Font,
                        Position = UDim2.fromScale(0, 0.8145),
                        Size = UDim2.fromScale(1, 0.129),
                        Text = "EQUIPPED",
                        TextColor3 = Color3.new(1, 1, 1),
                        TextScaled = true,
                        TextWrapped = true,
                        TextXAlignment = Enum.TextXAlignment.Center,
                        Visible = isEquippedState,
                        ZIndex = 2,
                        [Children] = {
                            scope:New "UIStroke" { Thickness = 2 },
                            scope:New "UITextSizeConstraint" { MaxTextSize = L.PriceMaxTextSize },
                        },
                    },

                    -- Status: OWNED
                    scope:New "TextLabel" {
                        Name = "OwnedStatusLabel",
                        BackgroundTransparency = 1,
                        FontFace = Constants.Font,
                        Position = UDim2.fromScale(0, 0.8145),
                        Size = UDim2.fromScale(1, 0.129),
                        Text = "OWNED",
                        TextColor3 = Color3.fromRGB(200, 200, 200),
                        TextScaled = true,
                        TextWrapped = true,
                        TextXAlignment = Enum.TextXAlignment.Center,
                        Visible = showOwned,
                        ZIndex = 2,
                        [Children] = {
                            scope:New "UIStroke" { Thickness = 2 },
                            scope:New "UITextSizeConstraint" { MaxTextSize = L.PriceMaxTextSize },
                        },
                    },

                    -- El Viewport 3D
                    viewportFrame,
                }
            },

            -- Checkmark verde sobre la tarjeta (Hermano del ImageButton)
            scope:New "TextLabel" {
                Name = "EquippedCheck",
                BackgroundTransparency = 1,
                FontFace = Font.new(
                    "rbxasset://fonts/families/SourceSansPro.json",
                    Enum.FontWeight.Bold,
                    Enum.FontStyle.Normal
                ),
                Position = UDim2.fromScale(-0.136, -0.128),
                Size = UDim2.fromOffset(71, 88),
                Text = "✓",
                TextColor3 = Color3.new(0, 0, 0),
                TextScaled = true,
                Visible = isEquippedState,
                ZIndex = 5,
                [Children] = {
                    scope:New "UIStroke" { Color = Color3.new(1, 1, 1), Thickness = 4 },
                }
            }
        }
    }
end

return OutfitCard
