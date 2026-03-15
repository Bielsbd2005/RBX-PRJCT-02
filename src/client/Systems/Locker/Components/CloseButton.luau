--!strict

--[[
    CloseButton
    Botón X rojo reutilizable para cerrar GUIs.
    Soporta animaciones reactivas multiplataforma (PC y Móvil).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.fusion)
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value
local Computed = Fusion.Computed
local Spring = Fusion.Spring

local Constants = require(script.Parent.StoreConstants)

export type CloseButtonProps = {
    position: UDim2?,
    size: UDim2?,
    onClose: () -> (),
}

local function CloseButton(scope: Fusion.Scope<typeof(Fusion)>, props: CloseButtonProps)
    ---------------------------------------------------------------------------
    -- Estado Reactivo de Interacción
    ---------------------------------------------------------------------------
    local isHovering = Value(scope, false)
    local isPressed = Value(scope, false)

    local targetScale = Computed(scope, function(use)
        if use(isPressed) then
            return 0.9 -- Se hunde al pulsar
        elseif use(isHovering) then
            return 1.1 -- Se expande al pasar el ratón
        else
            return 1   -- Normal
        end
    end)

    local scaleSpring = Spring(scope, targetScale, 40, 0.5)

    ---------------------------------------------------------------------------
    -- Renderizado del Componente
    ---------------------------------------------------------------------------
    return scope:New "ImageButton" {
        Name = "Close",
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Constants.Colors.CloseBase,
        Position = props.position or UDim2.fromScale(0.9665, 0.1455),
        Size = props.size or UDim2.fromScale(0.041, 0.07),

        -- Eventos Reactivos (Multiplataforma)
        [OnEvent "MouseEnter"] = function() isHovering:set(true) end,
        [OnEvent "MouseLeave"] = function() isHovering:set(false); isPressed:set(false) end,
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
        [OnEvent "Activated"] = props.onClose,

        [Children] = {
            scope:New "UIScale" {
                Scale = scaleSpring,
            },

            scope:New "UICorner" {
                Name = "UICorner",
                CornerRadius = UDim.new(0.15, 0),
            },

            scope:New "UIAspectRatioConstraint" {
                AspectRatio = 1,
            },

            scope:New "TextLabel" {
                Name = "TextLabel",
                BackgroundColor3 = Constants.Colors.CloseTop,
                FontFace = Constants.Font,
                Position = UDim2.fromScale(0, -0.013),
                Size = UDim2.fromScale(1, 0.9),
                Text = "X",
                TextColor3 = Color3.new(1, 1, 1),
                TextScaled = true,
                TextWrapped = true,

                [Children] = {
                    scope:New "UICorner" {
                        Name = "UICorner",
                        CornerRadius = UDim.new(0.15, 0),
                    },
                    scope:New "UITextSizeConstraint" {
                        MaxTextSize = 40,
                    },
                },
            },

            scope:New "UIStroke" {
                Name = "UIStroke",
                Thickness = 3,
            },
        },
    }
end

return CloseButton
