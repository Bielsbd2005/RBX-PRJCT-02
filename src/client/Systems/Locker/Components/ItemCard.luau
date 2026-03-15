--!strict

--[[
    ItemCard
    Tarjeta de item reutilizable para el grid de la Store.
    Usa colores de rareza de StoreConstants.RarityThemes con físicas reactivas.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.fusion)
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value
local Computed = Fusion.Computed
local Spring = Fusion.Spring

local Constants = require(script.Parent.StoreConstants)

export type ItemCardProps = {
    itemName: string,
    price: string,
    rarity: string,
    itemImage: string,
    layoutOrder: number?,
    onClick: (() -> ())?,
    isOwned: boolean?,
    isEquipped: Fusion.UsedAs<boolean>?,
    isLevelLocked: boolean?,
    requiredLevel: number?,
    isSelected: Fusion.UsedAs<boolean>?,
    category: string?,
}

local function ItemCard(scope: Fusion.Scope<typeof(Fusion)>, props: ItemCardProps)
    local theme = Constants.getTheme(props.rarity)
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
    -- Valores Estáticos de UI
    ---------------------------------------------------------------------------
    local currencyIcon = props.isLevelLocked and Constants.Assets.LockIcon or Constants.Assets.CurrencyIcon
    local priceText = props.isLevelLocked and ("LVL " .. tostring(props.requiredLevel or 0)) or props.price
    local priceColor = props.isLevelLocked and Color3.fromRGB(255, 208, 77) or Color3.new(1, 1, 1)

    -- Lógica de tamaño de imagen basada en categoría
    local imageSize = (props.category == "Hats" or props.category == "KillEffects" or props.category == "Faces")
        and UDim2.fromScale(0.7, 0.7)
        or UDim2.fromScale(1, 1)

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
    -- Construcción del Componente
    ---------------------------------------------------------------------------
    return scope:New "Frame" {
        Name = props.itemName .. "Wrapper",
        BackgroundTransparency = 1,
        LayoutOrder = props.layoutOrder or 0,
        Size = UDim2.fromScale(1, 1),

        [Children] = {
            scope:New "ImageButton" {
                Name = props.itemName,
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
                [OnEvent "Activated"] = function()
                    if props.onClick then
                        props.onClick()
                    end
                end,

                [Children] = {
                    scope:New "UICorner" { CornerRadius = UDim.new(0.08, 0) },

                    scope:New "UIStroke" {
                        Color = strokeColor,
                        Thickness = 5,
                        Enabled = strokeEnabled,
                    },

                    -- Currency icon (Solo si no lo tiene)
                    not props.isOwned and scope:New "ImageLabel" {
                        Name = "Currency",
                        BackgroundTransparency = 1,
                        Image = currencyIcon,
                        Position = UDim2.fromScale(0.188, 0.799),
                        ScaleType = Enum.ScaleType.Fit,
                        Size = UDim2.fromOffset(37, 35),
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

                    -- Price (Solo si no lo tiene)
                    not props.isOwned and scope:New "TextLabel" {
                        Name = "Price",
                        BackgroundTransparency = 1,
                        FontFace = Constants.Font,
                        Position = L.PricePosition,
                        Size = L.PriceSize,
                        Text = priceText,
                        TextColor3 = priceColor,
                        TextScaled = true,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 2,
                        [Children] = {
                            scope:New "UIStroke" { Thickness = 2 },
                            scope:New "UITextSizeConstraint" { MaxTextSize = L.PriceMaxTextSize },
                        }
                    } or nil,

                    -- Rarity
                    scope:New "TextLabel" {
                        Name = "Rarity",
                        BackgroundTransparency = 1,
                        FontFace = Constants.Font,
                        Position = L.RarityPosition,
                        Size = L.RaritySize,
                        Text = string.upper(props.rarity or "Common"),
                        TextColor3 = theme.RarityText,
                        TextScaled = true,
                        ZIndex = 2,
                        [Children] = {
                            scope:New "UITextSizeConstraint" { MaxTextSize = L.RarityMaxTextSize },
                            scope:New "UIStroke" { Color = theme.RarityStroke, Thickness = L.RarityStrokeThickness },
                        },
                    },

                    -- Item image
                    scope:New "ImageLabel" {
                        Name = "ItemImage",
                        AnchorPoint = Vector2.new(0.5, 0.5),
                        BackgroundTransparency = 1,
                        Image = props.itemImage,
                        ImageColor3 = Color3.fromRGB(249, 253, 255),
                        Position = UDim2.fromScale(0.5, 0.5),
                        Size = imageSize,
                    },
                },
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
            },
        }
    }
end

return ItemCard
