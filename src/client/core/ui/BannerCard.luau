--!strict
--[[
	Tarjeta de jugador con banner de fondo: la de la pantalla de muerte
	(DeathScreen.Card) y su previsualización en el Locker
	(Workspace.Locker.Banner.Part.Card). Las dos comparten estructura:

	  <raíz>            → la imagen del banner si es un ImageLabel/ImageButton; si
	                      es un contenedor (BillboardGui…), la imagen es su primer
	                      hijo de imagen que no sea Name/Level.
	  Name[.Value]      → nombre del jugador.
	  Level[.Value]     → nivel con formato "Lv. X".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemsConfig"))

local BannerCard = {}

export type Refs = {
	image: (ImageLabel | ImageButton)?,
	name: TextLabel?,
	level: TextLabel?,
}

local LABEL_NAMES = { Name = true, Level = true }

local function isImage(node: Instance): boolean
	return node:IsA("ImageLabel") or node:IsA("ImageButton")
end

local function resolveImage(root: Instance): (ImageLabel | ImageButton)?
	if isImage(root) then
		return root :: any
	end
	for _, child in root:GetChildren() do
		if isImage(child) and not LABEL_NAMES[child.Name] then
			return child :: any
		end
	end
	return nil
end

local function resolveLabel(root: Instance, name: string): TextLabel?
	local node = root:FindFirstChild(name) or root:FindFirstChild(name, true)
	if not node then
		return nil
	end
	local valueNode = node:FindFirstChild("Value")
	if valueNode and valueNode:IsA("TextLabel") then
		return valueNode
	end
	if node:IsA("TextLabel") then
		return node
	end
	return nil
end

function BannerCard.resolve(root: Instance): Refs
	return {
		image = resolveImage(root),
		name = resolveLabel(root, "Name"),
		level = resolveLabel(root, "Level"),
	}
end

function BannerCard.getImage(bannerId: string?): string
	local banners = ItemsConfig.Banners
	local definition = (if bannerId then banners[bannerId] else nil) or banners.Default
	return definition.Image or ""
end

function BannerCard.populate(refs: Refs, name: string, level: number, bannerId: string?)
	local image: any = refs.image
	if image then
		image.Image = BannerCard.getImage(bannerId)
	end
	if refs.name then
		refs.name.Text = name
	end
	if refs.level then
		refs.level.Text = `Lv. {level}`
	end
end

return BannerCard
