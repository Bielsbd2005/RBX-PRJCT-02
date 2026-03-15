--!strict

--[[
    ActionFrame
    Frame que aparece desde abajo para comprar o equipar items.
    Incluye animaciones reactivas y combinadas (Hover/Press + Data Pop).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.fusion)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Computed = Fusion.Computed
local Spring = Fusion.Spring
local Value = Fusion.Value
local Observer = Fusion.Observer

local Constants = require(script.Parent.StoreConstants)

export type ActionFrameProps = {
    price: Fusion.UsedAs<string>,
    title: Fusion.UsedAs<string>?,
    isLocked: Fusion.UsedAs<boolean>?,
    isVisible: Fusion.UsedAs<boolean>,
    onPurchase: () -> (),
}

local function ActionFrame(scope: Fusion.Scope<typeof(Fusion)>, props: ActionFrameProps)

    ---------------------------------------------------------------------------
    -- Animación de Posición (Aparición/Desaparición)
    ---------------------------------------------------------------------------
    local targetY = Computed(scope, function(use)
        return use(props.isVisible) and 0.856 or 1.2
    end)
    local springY = Spring(scope, targetY, 25, 0.8)

    ---------------------------------------------------------------------------
    -- Estado Reactivo de Interacción y "Pop"
    ---------------------------------------------------------------------------
    local isHovered = Value(scope, false)
    local isPressed = Value(scope, false)
    local popMultiplier = Value(scope, 1)

    -- Observar cambios en el precio para disparar el "Pop" visual
    local obs = Observer(scope, props.price)
    table.insert(scope, obs:onChange(function()
        popMultiplier:set(1.1)
        task.delay(0.1, function()
            popMultiplier:set(1)
        end)
    end))

    -- Combinamos Hover, Press y el multiplicador del Pop en una sola escala
    local targetScale = Computed(scope, function(use)
        local base = use(popMultiplier)
        if use(isPressed) then return base * 0.93 end
        if use(isHovered) then return base * 1.03 end
        return base
    end)
    local springScale = Spring(scope, targetScale, 40, 0.6)

    ---------------------------------------------------------------------------
    -- UI Estética (Colores y Textos)
    ---------------------------------------------------------------------------
    local gradientColors = Computed(scope, function(use)
        local locked = props.isLocked and use(props.isLocked) or false
        if locked then
            return ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 150, 150)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 100, 100)),
            })
        else
            return ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(252, 255, 87)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(244, 204, 74)),
            })
        end
    end)

    local currencyIcon = Computed(scope, function(use)
        local locked = props.isLocked and use(props.isLocked) or false
        return locked and "rbxassetid://121709682417919" or "rbxassetid://96222277892751"
    end)

    local buttonTitle = Computed(scope, function(use)
        local locked = props.isLocked and use(props.isLocked) or false
        if locked then
            return "LOCKED"
        else
            return props.title and use(props.title) or "PURCHASE"
        end
    end)

    ---------------------------------------------------------------------------
    -- Renderizado del Componente
    ---------------------------------------------------------------------------
    return scope:New "Frame" {
        Name = "ActionFrame",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 0), -- Pegado a la izquierda
        Position = Computed(scope, function(use)
            return UDim2.fromScale(0, use(springY))
        end),
        Size = UDim2.fromScale(0.631, 0.092),

        [Children] = {
            -- Alinea el botón automáticamente a la izquierda
            scope:New "UIListLayout" {
                Name = "UIListLayout",
                FillDirection = Enum.FillDirection.Horizontal,
                HorizontalAlignment = Enum.HorizontalAlignment.Center,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                SortOrder = Enum.SortOrder.LayoutOrder,
            },

            scope:New "ImageButton" {
                Name = "PurchaseButton",
                BackgroundColor3 = Color3.new(1, 1, 1),
                Size = UDim2.fromScale(0.292, 1),

                -- Eventos de Físicas Reactivas
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
                [OnEvent "Activated"] = props.onPurchase,

                [Children] = {
                    scope:New "UIScale" {
                        Scale = springScale,
                    },

                    scope:New "UIStroke" {
                        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
                        Thickness = 4,
                    },

                    scope:New "UICorner" {
                        CornerRadius = UDim.new(0.2, 0),
                    },

                    scope:New "UIGradient" {
                        Color = gradientColors,
                        Rotation = 90,
                    },

                    scope:New "ImageLabel" {
                        Name = "CurrencyImage",
                        BackgroundTransparency = 1,
                        Image = currencyIcon,
                        Position = UDim2.fromScale(0.133, 0.441),
                        ScaleType = Enum.ScaleType.Fit,
                        Size = UDim2.fromScale(0.197, 0.555),
                        ZIndex = 2,
                    },

                    scope:New "TextLabel" {
                        Name = "Price",
                        BackgroundTransparency = 1,
                        FontFace = Font.new(
                            "rbxasset://fonts/families/HighwayGothic.json",
                            Enum.FontWeight.Bold,
                            Enum.FontStyle.Normal
                        ),
                        Position = UDim2.fromScale(0.393, 0.431),
                        Size = UDim2.fromScale(0.605, 0.565),
                        Text = props.price,
                        TextColor3 = Color3.fromRGB(253, 255, 255),
                        TextScaled = true,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 2,

                        [Children] = {
                            scope:New "UIStroke" { Thickness = 4 },
                            scope:New "UITextSizeConstraint" { MaxTextSize = 50 },
                        }
                    },

                    scope:New "TextLabel" {
                        Name = "Title",
                        BackgroundTransparency = 1,
                        FontFace = Font.new(
                            "rbxasset://fonts/families/HighwayGothic.json",
                            Enum.FontWeight.Bold,
                            Enum.FontStyle.Normal
                        ),
                        Position = UDim2.fromScale(0, 0.111),
                        Size = UDim2.fromScale(1, 0.330),
                        Text = buttonTitle,
                        TextColor3 = Color3.fromRGB(0, 0, 0),
                        TextScaled = true,
                        ZIndex = 2,

                        [Children] = {
                            scope:New "UITextSizeConstraint" { MaxTextSize = 50 },
                        }
                    },
                }
            },
        }
    }
end

return ActionFrame
