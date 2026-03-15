--!strict

--[[
    SkinCard
    Componente para visualizar una skin de arma con efectos y animación.
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
local SkinApplier = require(ReplicatedStorage.Shared.Systems.Appearance.SkinApplier)

-- Constantes visuales del viewport
local FOV_IDEAL = 30
local DISTANCIA_MULTIPLIER = 0.52
local ROTACION_X = 0
local ROTACION_Y = 130
local ROTACION_Z = -12
local DESPLAZAMIENTO_X = 0.2

export type SkinData = {
    Rarity: string,
    BaseColor: Color3?,
    TextureID: string?,
    TextureColor: Color3?,
    StudsPerTile: number?,
    TextureTransparency: number?,
    Animated: boolean?,
    SecondaryPartColor: Color3?,
    SecondaryPartTexture: string?,
	SecondaryMaterial: Enum.Material?,
    Material: Enum.Material?,
	Particles: {
        Enabled: boolean,
        Texture: string,
        Color: ColorSequence,
        Size: NumberSequence,
        Lifetime: NumberRange,
        Rate: number,
        Speed: NumberRange
    }?
}

type SkinCardProps = {
    skinName: string,
    equippedWeapon: Fusion.UsedAs<string>,
    skinData: SkinData,
    layoutOrder: number,
    isSelected: Fusion.UsedAs<boolean>,
    isEquipped: Fusion.UsedAs<boolean>?,
    ownedCount: number?,
    onClick: () -> (),
}

local function SkinCard(scope: Fusion.Scope<typeof(Fusion)>, props: SkinCardProps)
    local rarity = props.skinData and props.skinData.Rarity or "Common"
    local theme = Constants.getTheme(rarity)
    local L = Constants.CardLayout

    ---------------------------------------------------------------------------
    -- Estado Reactivo Consolidado
    ---------------------------------------------------------------------------

    -- Helper para extraer isEquipped de forma segura (soporta State o boolean)
    local isEquippedState = Computed(scope, function(use)
        if type(props.isEquipped) == "table" then
            return use(props.isEquipped)
        end
        return props.isEquipped or false
    end)

    local strokeColor = Computed(scope, function(use)
        return use(isEquippedState) and Color3.new(1, 1, 1) or theme.Stroke
    end)

    local strokeEnabled = Computed(scope, function(use)
        if use(isEquippedState) or (props.ownedCount and props.ownedCount > 0) then
            return true
        end
        return not use(props.isSelected)
    end)

    ---------------------------------------------------------------------------
    -- Lógica de Animación 100% Fusion (Sin TweenService)
    ---------------------------------------------------------------------------
    local isHovered = Value(scope, false)
    local isPressed = Value(scope, false)

    local targetScale = Computed(scope, function(use)
        if use(isPressed) then return 0.93 end
        if use(isHovered) then return 1.05 end
        return 1
    end)

    -- Animación fluida reactiva
    local animatedScale = Spring(scope, targetScale, 30, 0.6)

    local animatedSize = Computed(scope, function(use)
        local scale = use(animatedScale)
        return UDim2.fromScale(scale, scale)
    end)

    ---------------------------------------------------------------------------
    -- Lógica del Viewport (Simplificada)
    ---------------------------------------------------------------------------
    local viewportFrame = scope:New "ViewportFrame" {
        Name = "ViewportFrame",
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
    }

    local function setupViewport()
        viewportFrame:ClearAllChildren()

        local weaponName = "Default" -- Asumimos que lo sacas dinámicamente si es necesario
        local weaponsFolder = ReplicatedStorage.Shared.Systems.Locker:WaitForChild("Weapons", 5)
        local baseModel = weaponsFolder and (weaponsFolder:FindFirstChild(weaponName) or weaponsFolder:FindFirstChild("Default"))

        if not baseModel then return end

        local clonedModel = baseModel:Clone()
        clonedModel.Parent = viewportFrame

        local modelCenter, updatedSize = clonedModel:GetBoundingBox()
        local orientacionFija = CFrame.fromEulerAnglesYXZ(
            math.rad(ROTACION_X), math.rad(ROTACION_Y), math.rad(ROTACION_Z)
        )

        clonedModel:PivotTo(CFrame.new(modelCenter.Position) * orientacionFija)

        local cam = Instance.new("Camera")
        cam.FieldOfView = FOV_IDEAL
        viewportFrame.CurrentCamera = cam
        cam.Parent = viewportFrame

        local maxDimension = math.max(updatedSize.X, updatedSize.Y, updatedSize.Z)
        local halfFov = math.rad(cam.FieldOfView / 2)
        local baseDistance = (maxDimension / 2) / math.tan(halfFov)
        local finalDistance = baseDistance * DISTANCIA_MULTIPLIER

        cam.CFrame = CFrame.new(
            modelCenter.Position + Vector3.new(0, 0, finalDistance),
            modelCenter.Position
        ) * CFrame.new(-DESPLAZAMIENTO_X, 0, 0)

        -- Aplicar skin
        local textures = SkinApplier.apply(clonedModel, props.skinData)
        local animConnection = SkinApplier.startAnimation(textures, props.skinData, viewportFrame)

        if animConnection then
            table.insert(scope, { Destroy = function() animConnection:Disconnect() end })
        end
    end

    -- Ejecutar setup en el siguiente frame para no bloquear el hilo de UI principal
    task.defer(setupViewport)

    ---------------------------------------------------------------------------
    -- Renderizado de Componentes
    ---------------------------------------------------------------------------
    return scope:New "Frame" {
        Name = props.skinName .. "Wrapper",
        BackgroundTransparency = 1,
        LayoutOrder = props.layoutOrder,
        Size = UDim2.fromScale(1, 1),

        [Children] = {
            scope:New "ImageButton" {
                Name = "WeaponSkin",
                AnchorPoint = Vector2.new(0.5, 0.5),
                AutoButtonColor = false,
                BackgroundColor3 = theme.Background,
                ClipsDescendants = true,
                Image = Constants.Assets.CardTexture,
                ImageColor3 = theme.ImageColor,
                Position = UDim2.fromScale(0.5, 0.5),
                -- Tamaño reactivo guiado por el Spring
                Size = animatedSize,

                -- Eventos de Interacción Reactivos
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
                    scope:New "UICorner" {
                        CornerRadius = UDim.new(0.08, 0),
                    },

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

                    -- Duplicate count badge
                    scope:New "TextLabel" {
                        Name = "Amount",
                        BackgroundColor3 = Color3.fromRGB(246, 56, 70),
                        FontFace = Font.new("rbxasset://fonts/families/LuckiestGuy.json"),
                        Position = UDim2.fromScale(0.85, -0.05),
                        Rotation = 14,
                        Size = UDim2.fromScale(0.25, 0.25),
                        Text = "x" .. tostring(props.ownedCount or 1),
                        TextColor3 = Color3.new(1, 1, 1),
                        TextScaled = true,
                        Visible = (props.ownedCount or 1) > 1,
                        ZIndex = 5,

                        [Children] = {
                            scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
                            scope:New "UIStroke" { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 2 },
                            scope:New "UIPadding" {
                                PaddingBottom = UDim.new(0.1, 0),
                                PaddingLeft = UDim.new(0.1, 0),
                                PaddingRight = UDim.new(0.1, 0),
                                PaddingTop = UDim.new(0.1, 0),
                            },
                            scope:New "UIAspectRatioConstraint" { AspectRatio = 1 },
                        }
                    },

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

                    -- El Viewport 3D instanciado arriba
                    viewportFrame,
                }
            },

            -- Checkmark overlay (Hermano del ImageButton, dentro del Wrapper)
            scope:New "TextLabel" {
                Name = "Equipped",
                BackgroundTransparency = 1,
                FontFace = Font.new(
                    "rbxasset://fonts/families/SourceSansPro.json",
                    Enum.FontWeight.Bold,
                    Enum.FontStyle.Normal
                ),
                Position = UDim2.fromScale(-0.136143, -0.1286),
                Size = UDim2.fromOffset(71, 88),
                Text = "✓",
                TextColor3 = Color3.new(0, 0, 0),
                TextScaled = true,
                Visible = isEquippedState,
                ZIndex = 5,

                [Children] = {
                    scope:New "UIStroke" {
                        Color = Color3.new(1, 1, 1),
                        Thickness = 4,
                    },
                }
            }
        }
    }
end

return SkinCard
