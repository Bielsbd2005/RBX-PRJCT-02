--!strict
--[[
	Tarjeta de jugador: la de la pantalla de muerte (DeathScreen.Card) y su
	previsualización en el Locker (Workspace.Locker.Banner.Part.BillboardGui.Card).
	Las dos comparten estructura; cada nodo se busca por nombre a cualquier
	profundidad bajo la Card:

	  Name           → nombre del jugador, con el tag VIP.
	  Level          → nivel con formato "Lv. X".
	  (Name y Level: el propio TextLabel, su hijo Value o su primer TextLabel.)
	  Profile        → ImageLabel con la foto de perfil (headshot del avatar).
	  Border         → ImageLabel con el borde equipado (ItemsConfig.Borders); se
	                   oculta si no lleva.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared:WaitForChild("constants"):WaitForChild("ItemsConfig"))
local VipTag = require(Shared:WaitForChild("utils"):WaitForChild("VipTag"))

local PlayerCard = {}

type Image = ImageLabel | ImageButton

export type Refs = {
	name: TextLabel?,
	level: TextLabel?,
	profile: Image?,
	-- La Image de Studio de Profile: la que se queda sin foto (bots, sin asesino).
	profileFallback: string,
	border: Image?,
}

export type Content = {
	name: string,
	level: number,
	userId: number?,
	isVIP: boolean?,
	borderId: string?,
}

-- Por descendientes y no FindFirstChild(name, true): "Border" puede repetirse en
-- nodos que no son imagen.
local function findImage(root: Instance, name: string): Image?
	for _, node in root:GetDescendants() do
		if node.Name == name and (node:IsA("ImageLabel") or node:IsA("ImageButton")) then
			return node :: any
		end
	end
	return nil
end

local function resolveLabel(root: Instance, name: string): TextLabel?
	local node = root:FindFirstChild(name) or root:FindFirstChild(name, true)
	local label: TextLabel? = nil
	if node then
		local valueNode = node:FindFirstChild("Value")
		if valueNode and valueNode:IsA("TextLabel") then
			label = valueNode
		elseif node:IsA("TextLabel") then
			label = node
		else
			label = node:FindFirstChildWhichIsA("TextLabel", true)
		end
	end
	if not label then
		warn(`[PlayerCard] Sin TextLabel "{name}" bajo {root:GetFullName()}: no se pintará.`)
	end
	return label
end

function PlayerCard.resolve(root: Instance): Refs
	local profile = findImage(root, "Profile")
	return {
		name = resolveLabel(root, "Name"),
		level = resolveLabel(root, "Level"),
		profile = profile,
		profileFallback = if profile then profile.Image else "",
		border = findImage(root, "Border"),
	}
end

-- Los bots tienen userId negativo y no hay avatar que pedir.
function PlayerCard.headshotFor(userId: number?): string?
	if userId and userId > 0 then
		return `rbxthumb://type=AvatarHeadShot&id={userId}&w=150&h=150`
	end
	return nil
end

function PlayerCard.paintBorder(image: Image, borderId: string?)
	local definition = if borderId then ItemsConfig.Borders[borderId] else nil
	image.Image = if definition then definition.Image or "" else ""
	image.Visible = definition ~= nil
end

function PlayerCard.populate(refs: Refs, content: Content)
	if refs.name then
		VipTag.apply(refs.name, content.name, content.isVIP == true)
	end
	if refs.level then
		refs.level.Text = `Lv. {content.level}`
	end
	if refs.profile then
		refs.profile.Image = PlayerCard.headshotFor(content.userId) or refs.profileFallback
	end
	if refs.border then
		PlayerCard.paintBorder(refs.border, content.borderId)
	end
end

return PlayerCard
