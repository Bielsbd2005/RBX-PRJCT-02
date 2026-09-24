--!strict
--[[
	Único sitio que pinta un wrap sobre un arma: la partida (CosmeticsTemplates), el
	preview 3D del Locker (WeaponPreviewController) y las cards y escenas
	(WeaponWrapPreviewer) pasan por aquí para que el mismo wrap se vea igual en todas.

	Las texturas animadas solo se taguean con ANIMATED_TEXTURE_TAG y sus velocidades
	van en atributos: las anima WeaponWrapAnimator en el cliente, también dentro de
	ViewportFrames. Pintado en el server, tag y atributos replican.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local WeaponWrapParts = require(script.Parent.WeaponWrapParts)

export type WrapDefinition = {
	TextureID: string?,
	BaseColor: Color3?,
	Material: Enum.Material?,
	StudsPerTile: number?,
	isAnimated: boolean?,
	ScrollSpeedU: number?,
	ScrollSpeedV: number?,
}

local WeaponWrapPainter = {}

WeaponWrapPainter.ANIMATED_TEXTURE_TAG = "AnimatedWeaponWrapTexture"
WeaponWrapPainter.DEFAULT_STUDS_PER_TILE = 3

local DEFAULT_SCROLL_SPEED_U = 1
local DEFAULT_SCROLL_SPEED_V = 0
local TEXTURE_PREFIX = "ScrollTexture_"

local TEXTURE_FACES: { { name: string, face: Enum.NormalId } } = {
	{ name = "ScrollTexture_Top", face = Enum.NormalId.Top },
	{ name = "ScrollTexture_Bottom", face = Enum.NormalId.Bottom },
	{ name = "ScrollTexture_Left", face = Enum.NormalId.Left },
	{ name = "ScrollTexture_Right", face = Enum.NormalId.Right },
	{ name = "ScrollTexture_Front", face = Enum.NormalId.Front },
	{ name = "ScrollTexture_Back", face = Enum.NormalId.Back },
}

-- Valores de la pieza antes del primer wrap, para volver a ellos cuando un wrap no
-- define color o material (el preview del Locker repinta la misma instancia).
local ORIGINAL_MATERIAL_ATTR = "WrapOriginalMaterial"
local ORIGINAL_COLOR_ATTR = "WrapOriginalColor"

local function optionalString(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

local function optionalMaterial(value: any): Enum.Material?
	return if typeof(value) == "EnumItem" and value.EnumType == Enum.Material then value :: Enum.Material else nil
end

function WeaponWrapPainter.getDefinition(wrapId: string?): WrapDefinition?
	local catalog = ItemsConfig.WeaponWraps
	local definition = if wrapId and type(catalog) == "table" then catalog[wrapId] else nil
	return if type(definition) == "table" then definition :: WrapDefinition else nil
end

-- No todos los modelos de display traen PrimaryPart. "Main" es el nombre de una
-- BasePart del modelo 3D, no la WeaponCategory.
function WeaponWrapPainter.resolvePrimaryPart(root: Instance): BasePart?
	if root:IsA("BasePart") then
		return root
	end
	if not root:IsA("Model") then
		return nil
	end
	if root.PrimaryPart then
		return root.PrimaryPart
	end
	for _, candidateName in { "primaryPart", "Main" } do
		local node = root:FindFirstChild(candidateName, true)
		if node and node:IsA("BasePart") then
			return node
		end
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function applyColor(part: BasePart, color: Color3?)
	if part:GetAttribute(ORIGINAL_COLOR_ATTR) == nil then
		part:SetAttribute(ORIGINAL_COLOR_ATTR, part.Color)
	end
	local original = part:GetAttribute(ORIGINAL_COLOR_ATTR)
	local target = color or (if typeof(original) == "Color3" then original else nil)
	if target then
		part.Color = target
	end
end

local function applyMaterial(part: BasePart, material: Enum.Material?)
	if part:GetAttribute(ORIGINAL_MATERIAL_ATTR) == nil then
		part:SetAttribute(ORIGINAL_MATERIAL_ATTR, part.Material.Name)
	end
	if material then
		part.Material = material
		return
	end
	local originalName = part:GetAttribute(ORIGINAL_MATERIAL_ATTR)
	local restored = if type(originalName) == "string" then (Enum.Material :: any)[originalName] else nil
	if restored then
		part.Material = restored
	end
end

-- studsPerTileScale: para modelos escalados (el pase escala el arma de su escena),
-- o saldrían más tiles que en la card.
function WeaponWrapPainter.paintParts(parts: { BasePart }, definition: WrapDefinition?, studsPerTileScale: number?)
	local textureId = if definition then optionalString(definition.TextureID) else nil
	local baseColor = if definition and typeof(definition.BaseColor) == "Color3" then definition.BaseColor else nil
	local material = if definition then optionalMaterial(definition.Material) else nil
	local studsPerTile = math.max(0.01, tonumber(definition and definition.StudsPerTile) or WeaponWrapPainter.DEFAULT_STUDS_PER_TILE)
		* (studsPerTileScale or 1)
	local animated = definition ~= nil and definition.isAnimated == true
	local scrollSpeedU = tonumber(definition and definition.ScrollSpeedU) or DEFAULT_SCROLL_SPEED_U
	local scrollSpeedV = tonumber(definition and definition.ScrollSpeedV) or DEFAULT_SCROLL_SPEED_V

	for _, part in parts do
		-- También con textura: el color se ve a través de sus zonas transparentes.
		applyColor(part, baseColor)
		applyMaterial(part, material)

		if not textureId then
			for _, child in part:GetChildren() do
				if child:IsA("Texture") and string.sub(child.Name, 1, #TEXTURE_PREFIX) == TEXTURE_PREFIX then
					child:Destroy()
				end
			end
			continue
		end

		for _, entry in TEXTURE_FACES do
			local existing = part:FindFirstChild(entry.name)
			local texture: Texture
			if existing and existing:IsA("Texture") then
				texture = existing
			else
				texture = Instance.new("Texture")
				texture.Name = entry.name
				texture.Face = entry.face
				texture.Parent = part
			end
			texture.Texture = textureId
			texture.Transparency = 0
			texture.StudsPerTileU = studsPerTile
			texture.StudsPerTileV = studsPerTile
			texture.OffsetStudsU = 0
			texture.OffsetStudsV = 0
			texture:SetAttribute("WrapScrollSpeedU", scrollSpeedU)
			texture:SetAttribute("WrapScrollSpeedV", scrollSpeedV)
			if animated then
				CollectionService:AddTag(texture, WeaponWrapPainter.ANIMATED_TEXTURE_TAG)
			else
				CollectionService:RemoveTag(texture, WeaponWrapPainter.ANIMATED_TEXTURE_TAG)
			end
		end
	end
end

-- Pinta el PrimaryPart y las piezas de WeaponWrapParts. false si no hay dónde pintar.
function WeaponWrapPainter.paint(root: Instance, definition: WrapDefinition?, studsPerTileScale: number?): boolean
	local primaryPart = WeaponWrapPainter.resolvePrimaryPart(root)
	if not primaryPart then
		return false
	end
	WeaponWrapPainter.paintParts(WeaponWrapParts.get(root, primaryPart), definition, studsPerTileScale)
	return true
end

return WeaponWrapPainter
