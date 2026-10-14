--!strict
--[[
	Único sitio que pinta un wrap sobre un arma: la partida (CosmeticsTemplates), el
	preview 3D del Locker (WeaponPreviewController) y las cards y escenas
	(WeaponWrapPreviewer) pasan por aquí para que el mismo wrap se vea igual en todas.

	TextureID fija va en MeshPart.TextureID (UV de la malla). Solo la animada usa las
	Texture por cara: se taguean con ANIMATED_TEXTURE_TAG y sus velocidades van en
	atributos; las anima WeaponWrapAnimator en el cliente, también dentro de
	ViewportFrames. Pintado en el server, tag y atributos replican.

	Un wrap lleva además SurfaceAppearance si en Shared.Locker.wraps hay uno con su id
	o su Name (ver el README de esa carpeta): no se declara en ItemsConfig.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local WeaponWrapParts = require(script.Parent.WeaponWrapParts)

export type WrapDefinition = {
	Name: string?,
	TextureID: string?,
	BaseColor: Color3?,
	Material: Enum.Material?,
	StudsPerTile: number?,
	isAnimated: boolean?,
	ScrollSpeedU: number?,
	ScrollSpeedV: number?,
	-- No viene del catálogo: lo añade getDefinition desde Shared.Locker.wraps.
	SurfaceAppearance: SurfaceAppearance?,
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
local ORIGINAL_TEXTURE_ATTR = "WrapOriginalTextureId"

-- Deben coincidir con tools/weapons/StudioMigration.luau, que los limpia del display.
local WRAP_SURFACE_NAME = "WrapSurfaceAppearance"
local ORIGINAL_SURFACES_STASH_NAME = "WrapOriginalSurfaces"

local SURFACES_FOLDER_NAME = "wraps"
local surfaceTemplates: { [string]: SurfaceAppearance }? = nil

local function optionalString(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

local function optionalMaterial(value: any): Enum.Material?
	return if typeof(value) == "EnumItem" and value.EnumType == Enum.Material then value :: Enum.Material else nil
end

local function getCatalogEntry(wrapId: string): WrapDefinition?
	local catalog = ItemsConfig.WeaponWraps
	local definition = if type(catalog) == "table" then catalog[wrapId] else nil
	return if type(definition) == "table" then definition :: WrapDefinition else nil
end

-- Indexa por nombre todo SurfaceAppearance de Shared.Locker.wraps, a cualquier
-- profundidad: las subcarpetas son solo para ordenar. Como los Hats, en Studio se
-- nombran por el id o por el `Name` del catálogo.
local function getSurfaceTemplate(wrapId: string, definition: WrapDefinition): SurfaceAppearance?
	if not surfaceTemplates then
		local folder = script.Parent:FindFirstChild(SURFACES_FOLDER_NAME)
		if not folder then
			return nil
		end
		local knownNames: { [string]: true } = {}
		if RunService:IsStudio() and type(ItemsConfig.WeaponWraps) == "table" then
			for id, entry in ItemsConfig.WeaponWraps do
				knownNames[id] = true
				if type(entry) == "table" and type(entry.Name) == "string" then
					knownNames[entry.Name] = true
				end
			end
		end
		local templates: { [string]: SurfaceAppearance } = {}
		for _, node in folder:GetDescendants() do
			if not node:IsA("SurfaceAppearance") then
				continue
			end
			if RunService:IsStudio() then
				if templates[node.Name] then
					warn(`[WeaponWrapPainter] SurfaceAppearance duplicado en Locker.wraps: {node.Name}`)
				elseif not knownNames[node.Name] then
					warn(`[WeaponWrapPainter] {node:GetFullName()} no corresponde a ningún wrap de ItemsConfig.WeaponWraps`)
				end
			end
			templates[node.Name] = node
		end
		surfaceTemplates = templates
	end
	local templates = surfaceTemplates :: { [string]: SurfaceAppearance }
	return templates[wrapId] or (if definition.Name then templates[definition.Name] else nil)
end

function WeaponWrapPainter.getDefinition(wrapId: string?): WrapDefinition?
	local definition = if wrapId then getCatalogEntry(wrapId) else nil
	if not (wrapId and definition) then
		return nil
	end
	local surface = getSurfaceTemplate(wrapId, definition)
	if not surface then
		return definition
	end
	local resolved = table.clone(definition)
	resolved.SurfaceAppearance = surface
	return resolved
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

local function applyMeshTexture(part: MeshPart, textureId: string?)
	local original = part:GetAttribute(ORIGINAL_TEXTURE_ATTR)
	if textureId then
		if original == nil then
			part:SetAttribute(ORIGINAL_TEXTURE_ATTR, part.TextureID)
		end
		part.TextureID = textureId
	elseif type(original) == "string" then
		part.TextureID = original
	end
end

-- Un SurfaceAppearance solo actúa como hijo directo de un MeshPart: el propio del arma
-- se aparca en un Folder dentro de la pieza (sobrevive a Clone y replica) mientras
-- manda el del wrap, y vuelve cuando el siguiente wrap no trae ninguno.
-- hideOriginals: el wrap pinta MeshPart.TextureID, que un SurfaceAppearance taparía.
local function applySurface(part: BasePart, template: SurfaceAppearance?, hideOriginals: boolean)
	local current = part:FindFirstChild(WRAP_SURFACE_NAME)
	if current then
		current:Destroy()
	end
	local stash: Instance? = part:FindFirstChild(ORIGINAL_SURFACES_STASH_NAME)

	if not (part:IsA("MeshPart") and (template or hideOriginals)) then
		if stash then
			for _, original in stash:GetChildren() do
				original.Parent = part
			end
			stash:Destroy()
		end
		return
	end

	for _, child in part:GetChildren() do
		if child:IsA("SurfaceAppearance") then
			if not stash then
				local created = Instance.new("Folder")
				created.Name = ORIGINAL_SURFACES_STASH_NAME
				created.Parent = part
				stash = created
			end
			child.Parent = stash
		end
	end

	if template then
		local surface = template:Clone()
		surface.Name = WRAP_SURFACE_NAME
		surface.Parent = part
	end
end

-- studsPerTileScale: para modelos escalados, o saldrían más tiles que en la card.
function WeaponWrapPainter.paintParts(parts: { BasePart }, definition: WrapDefinition?, studsPerTileScale: number?)
	local textureId = if definition then optionalString(definition.TextureID) else nil
	local baseColor = if definition and typeof(definition.BaseColor) == "Color3" then definition.BaseColor else nil
	local material = if definition then optionalMaterial(definition.Material) else nil
	local surfaceTemplate = if definition then definition.SurfaceAppearance else nil
	local studsPerTile = math.max(0.01, tonumber(definition and definition.StudsPerTile) or WeaponWrapPainter.DEFAULT_STUDS_PER_TILE)
		* (studsPerTileScale or 1)
	local animated = definition ~= nil and definition.isAnimated == true
	local scrollSpeedU = tonumber(definition and definition.ScrollSpeedU) or DEFAULT_SCROLL_SPEED_U
	local scrollSpeedV = tonumber(definition and definition.ScrollSpeedV) or DEFAULT_SCROLL_SPEED_V

	for _, part in parts do
		-- Una pieza que no es MeshPart no tiene TextureID: su textura fija va por caras.
		local meshTextureId = if not animated and part:IsA("MeshPart") then textureId else nil
		local faceTextureId = if meshTextureId then nil else textureId

		-- También con textura: el color tiñe la de malla y asoma por las zonas transparentes.
		applyColor(part, baseColor)
		applyMaterial(part, material)
		applySurface(part, surfaceTemplate, meshTextureId ~= nil)
		if part:IsA("MeshPart") then
			applyMeshTexture(part, meshTextureId)
		end

		if not faceTextureId then
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
			texture.Texture = faceTextureId
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
