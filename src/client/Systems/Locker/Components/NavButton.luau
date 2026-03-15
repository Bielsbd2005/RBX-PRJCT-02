--!strict

--[[
    NavButton
    Botón de opción de navegación para el Locker.
    Muestra una imagen, título, y crece hacia la izquierda cuando está seleccionado.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.fusion)
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Computed = Fusion.Computed
local Spring = Fusion.Spring
local Value = Fusion.Value

local Constants = require(script.Parent.StoreConstants)

export type NavButtonProps = {
    name: string,
    title: string,
    image: string,
    layoutOrder: number,
    isSelected: Fusion.UsedAs<boolean>, -- Permite tanto boolean estáticos como estados reactivos
    onClick: (() -> ())?,
}

local function NavButton(scope: Fusion.Scope<typeof(Fusion)>, props: NavButtonProps)

    ---------------------------------------------------------------------------
    -- Estado Reactivo
    ---------------------------------------------------------------------------
    local isSelectedState = Computed(scope, function(use)
        if type(props.isSelected) == "table" then return use(props.isSelected) end
        return props.isSelected or false
    end)

    local isHovered = Value(scope, false)
    local isPressed = Value(scope, false)

    -- Color de fondo reactivo
    local backgroundColor = Computed(scope, function(use)
        return use(isSelectedState) and Constants.Colors.NavOptionActive or Constants.Colors.TabInactive
    end)

    ---------------------------------------------------------------------------
    -- Físicas de Animación Combinadas
    ---------------------------------------------------------------------------
    local targetSize = Computed(scope, function(use)
        local selected = use(isSelectedState)

        -- Multiplicador táctil para Hover y Click
        local interactionScale = 1
        if use(isPressed) then
            interactionScale = 0.95
        elseif use(isHovered) then
            interactionScale = 1.05
        end

        -- Base dependiente de si está seleccionado (crece en X)
        local baseWidth = selected and 1.509 or 1
        local baseHeight = 1

        return UDim2.fromScale(baseWidth * interactionScale, baseHeight * interactionScale)
    end)

    -- Un único resorte controla todas las transiciones (selección, hover, click)
    local animatedSize = Spring(scope, targetSize, 30, 0.6)

    ---------------------------------------------------------------------------
    -- Renderizado del Componente
    ---------------------------------------------------------------------------
    return scope:New "Frame" {
        Name = props.name .. "Wrapper",
        BackgroundTransparency = 1,
        LayoutOrder = props.layoutOrder,
        -- El Wrapper mantiene el espacio reservado original en el layout
        Size = UDim2.fromScale(1, 0.301205),

        [Children] = {
            scope:New "ImageButton" {
                Name = props.name,
                AnchorPoint = Vector2.new(1, 0.5), -- Anclado a la derecha
                AutoButtonColor = false,
                BackgroundColor3 = backgroundColor,
                Image = Constants.Assets.Placeholder,
                ImageTransparency = 1,
                Position = UDim2.fromScale(1, 0.5), -- Pegado al borde derecho del Wrapper
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
                [OnEvent "Activated"] = function()
                    if props.onClick then
                        props.onClick()
                    end
                end,

                [Children] = {
                    scope:New "UICorner" { Name = "UICorner" },

                    scope:New "ImageLabel" {
                        Name = "OptionImage",
                        BackgroundTransparency = 1,
                        Image = props.image,
                        Position = UDim2.fromScale(0, -0.199615),
                        ScaleType = Enum.ScaleType.Fit,
                        Size = UDim2.fromScale(1, 0.848708),
                    },

                    scope:New "TextLabel" {
                        Name = "Title",
                        BackgroundTransparency = 1,
                        FontFace = Font.new(
                            "rbxasset://fonts/families/SourceSansPro.json",
                            Enum.FontWeight.Bold,
                            Enum.FontStyle.Normal
                        ),
                        Position = UDim2.fromScale(0, 0.668258),
                        Size = UDim2.fromScale(1, 0.246377),
                        Text = props.title,
                        TextColor3 = Color3.new(1, 1, 1),
                        TextScaled = true,

                        [Children] = {
                            scope:New "UIStroke" {
                                Name = "InnerStroke",
                                Thickness = 4,
                            },
                        },
                    },

                    scope:New "UIStroke" {
                        Name = "BorderStroke",
                        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
                        Thickness = 4,
                    },
                },
            },
        },
    }
end

return NavButton
