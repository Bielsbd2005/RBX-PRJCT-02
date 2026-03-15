--[[
	TabButton
	Botón de pestaña reutilizable (Arsenal, Cosmetics, etc.)

	Props:
		text: string         — Texto del botón
		color: Color3        — Color de fondo
		position: UDim2      — Posición en la pantalla
		size: UDim2?         — Tamaño (por defecto proporcional)
		layoutOrder: number? — Orden en layout
		onClick: (() -> ())? — Callback al presionar
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.fusion)
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value

local Constants = require(script.Parent.StoreConstants)

type TabButtonProps = {
	text: string,
	color: any, -- Color3 o StateObject<Color3> para reactivo
	position: UDim2,
	size: UDim2?,
	layoutOrder: number?,
	onClick: (() -> ())?,
}

local function TabButton(scope: Fusion.Scope<typeof(Fusion)>, props: TabButtonProps)
	local isHovering = Value(scope, false)
	local isPressed = Value(scope, false)

	local scaleSpring = Fusion.Spring(scope, Fusion.Computed(scope, function(use)
		if use(isPressed) then
			return 0.95
		elseif use(isHovering) then
			return 1.05
		else
			return 1
		end
	end), 40, 0.5)

	return scope:New "TextButton" {
		Name = props.text,
		AnchorPoint = Vector2.new(0.5, 0.5), -- Centrado para escalar desde el medio
		AutoButtonColor = false,
		BackgroundColor3 = props.color,
		FontFace = Constants.Font,
		LayoutOrder = props.layoutOrder or 0,
		Position = props.position,
		Size = props.size or UDim2.fromScale(0.139, 0.071),
		Text = props.text,
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Bottom,

		[OnEvent "MouseEnter"] = function() isHovering:set(true) end,
		[OnEvent "MouseLeave"] = function() isHovering:set(false) isPressed:set(false) end,
		[OnEvent "MouseButton1Down"] = function() isPressed:set(true) end,
		[OnEvent "MouseButton1Up"] = function() isPressed:set(false) end,

		[OnEvent "Activated"] = function()
			if props.onClick then
				props.onClick()
			end
		end,

		[Children] = {
			scope:New "UIScale" {
				Scale = scaleSpring,
			},
			scope:New "UICorner" {
				Name = "UICorner",
				CornerRadius = UDim.new(0.2, 0),
			},

			scope:New "UITextSizeConstraint" {
				MaxTextSize = 40,
			},

			scope:New "UIPadding" {
				Name = "UIPadding",
				PaddingBottom = UDim.new(0.2, 0),
			},

			-- Stroke exterior (borde)
			scope:New "UIStroke" {
				Name = "BorderStroke",
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Thickness = 4,
			},

			-- Stroke interior
			scope:New "UIStroke" {
				Name = "InnerStroke",
				Thickness = 4,
			},
		},
	}
end

return TabButton
