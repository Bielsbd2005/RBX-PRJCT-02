--!strict
--[[
	Etiqueta VIP delante del nombre (chat, killfeed, tarjeta de muerte).

	El servidor marca al jugador con el atributo `VipTag.ATTRIBUTE` (VIPItemsService);
	los clientes lo leen. El degradado va letra a letra en rich text: un UIGradient
	teñiría también el nombre, que comparte el TextLabel.
]]

local Players = game:GetService("Players")

local VipTag = {}

VipTag.ATTRIBUTE = "IsVIP"

local TEXT = "VIP"
local STOPS = {
	Color3.fromRGB(255, 147, 0),
	Color3.fromRGB(255, 234, 67),
	Color3.fromRGB(255, 147, 0),
}

local function _colorAt(t: number): Color3
	local scaled = t * (#STOPS - 1)
	local index = math.clamp(math.floor(scaled), 0, #STOPS - 2)
	return STOPS[index + 1]:Lerp(STOPS[index + 2], scaled - index)
end

local function _buildRichTag(): string
	local parts = table.create(#TEXT)
	for i = 1, #TEXT do
		local t = if #TEXT > 1 then (i - 1) / (#TEXT - 1) else 0
		parts[i] = `<font color="#{_colorAt(t):ToHex()}">{string.sub(TEXT, i, i)}</font>`
	end
	return `<b>{table.concat(parts)}</b>`
end

VipTag.RICH_TEXT = _buildRichTag()

function VipTag.isVIP(player: Player?): boolean
	return player ~= nil and player:GetAttribute(VipTag.ATTRIBUTE) == true
end

-- Para los feeds que sólo llevan el Name del jugador (los bots nunca son VIP).
function VipTag.isVIPName(name: string?): boolean
	if not name or name == "" then
		return false
	end
	local node = Players:FindFirstChild(name)
	return node ~= nil and node:IsA("Player") and VipTag.isVIP(node)
end

function VipTag.escape(text: string): string
	return (string.gsub(text, "[&<>\"']", {
		["&"] = "&amp;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		['"'] = "&quot;",
		["'"] = "&apos;",
	}))
end

-- Pinta `name` en el label con la etiqueta delante si es VIP. Activa RichText sólo
-- cuando hace falta para no cambiar cómo se muestra un nombre normal.
function VipTag.apply(label: TextLabel, name: string, isVIP: boolean)
	if isVIP and name ~= "" then
		label.RichText = true
		label.Text = `{VipTag.RICH_TEXT} {VipTag.escape(name)}`
	elseif label.RichText then
		label.Text = VipTag.escape(name)
	else
		label.Text = name
	end
end

return table.freeze(VipTag)
