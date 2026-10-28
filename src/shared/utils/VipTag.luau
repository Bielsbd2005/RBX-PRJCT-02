--!strict
--[[
	Etiqueta VIP delante del nombre (chat, killfeed, tarjeta de muerte).

	El servidor marca al jugador con el atributo `VipTag.ATTRIBUTE` (VIPItemsService);
	los clientes lo leen. El color va en rich text: un UIGradient o TextColor3
	teñiría también el nombre, que comparte el TextLabel.
]]

local Players = game:GetService("Players")

local VipTag = {}

VipTag.ATTRIBUTE = "IsVIP"

local COLOR = Color3.fromRGB(255, 200, 0)

-- `[` no necesita escaparse en rich text: solo `<`, `>` y `&`.
VipTag.RICH_TEXT = `<b><font color="#{COLOR:ToHex()}">[VIP]</font></b>`

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
