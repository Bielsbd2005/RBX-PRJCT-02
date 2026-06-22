--!strict
--[[
	CosmeticsTemplates.luau
	Helpers compartidos para aplicar cosméticos a un Character/Tool:
	  - findHatTemplate(hatId)
	  - applyWeaponWrapToTool(tool, wrapId)
	  - applyFaceToHead(head, faceId)

	Extraído de LoadoutService para que también lo consuma BotAppearance.
	Sin estado: cada función es idempotente sobre la instancia que recibe.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)

local CosmeticsTemplates = {}

local DEFAULT_WRAP_STUDS_PER_TILE = 3
local DEFAULT_WRAP_SCROLL_SPEED_U = 1
local DEFAULT_WRAP_SCROLL_SPEED_V = 0
local ANIMATED_WRAP_TEXTURE_TAG = "AnimatedWeaponWrapTexture"

local WEAPON_WRAP_TEXTURE_FACE_BY_NAME: { [string]: Enum.NormalId } = {
	ScrollTexture_Top = Enum.NormalId.Top,
	ScrollTexture_Bottom = Enum.NormalId.Bottom,
	ScrollTexture_Left = Enum.NormalId.Left,
	ScrollTexture_Right = Enum.NormalId.Right,
	ScrollTexture_Front = Enum.NormalId.Front,
	ScrollTexture_Back = Enum.NormalId.Back,
}

local WEAPON_WRAP_TEXTURE_ORDER = {
	"ScrollTexture_Top",
	"ScrollTexture_Bottom",
	"ScrollTexture_Left",
	"ScrollTexture_Right",
	"ScrollTexture_Front",
	"ScrollTexture_Back",
}

local WRAP_ORIGINAL_MATERIAL_ATTR = "WrapOriginalMaterial"

local function _getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function _getOptionalMaterial(value: any): Enum.Material?
	if typeof(value) == "EnumItem" and value.EnumType == Enum.Material then
		return value :: Enum.Material
	end
	return nil
end

-- Aplica (o restaura) el Material de la parte principal del arma. Guarda el
-- material original la primera vez que se toca la parte para poder volver a él
-- cuando una skin no define Material; así cambiar de skin nunca deja "pegado"
-- el material de la skin anterior.
local function _applyMaterialToPart(part: BasePart, material: Enum.Material?)
	if part:GetAttribute(WRAP_ORIGINAL_MATERIAL_ATTR) == nil then
		part:SetAttribute(WRAP_ORIGINAL_MATERIAL_ATTR, part.Material.Name)
	end

	if material then
		part.Material = material
		return
	end

	local originalName = part:GetAttribute(WRAP_ORIGINAL_MATERIAL_ATTR)
	if type(originalName) == "string" then
		local restored = (Enum.Material :: any)[originalName]
		if restored then
			part.Material = restored
		end
	end
end

local function _getHatsRoot(): Folder?
	local locker = Shared:FindFirstChild("Locker")
	if not locker then
		return nil
	end
	local hats = locker:FindFirstChild("Hats")
	if hats and hats:IsA("Folder") then
		return hats
	end
	return nil
end

function CosmeticsTemplates.findHatTemplate(hatId: string): Accessory?
	if hatId == "" then
		return nil
	end

	local hatsRoot = _getHatsRoot()
	if not hatsRoot then
		return nil
	end

	local direct = hatsRoot:FindFirstChild(hatId)
	if direct and direct:IsA("Accessory") then
		return direct
	end

	if direct and direct:IsA("Model") then
		local accessory = direct:FindFirstChildWhichIsA("Accessory", true)
		if accessory then
			return accessory
		end
	end

	return nil
end

function CosmeticsTemplates.applyWeaponWrapToTool(tool: Tool, wrapId: string)
	local weaponModelNode = tool:FindFirstChild("WeaponModel", true)
	if not weaponModelNode or not weaponModelNode:IsA("Model") then
		return
	end

	local weaponModel = weaponModelNode :: Model
	local primaryPart = weaponModel.PrimaryPart
	if not primaryPart then
		return
	end

	local wrapsConfig = ItemsConfig.WeaponWraps
	local wrapDefinition = if type(wrapsConfig) == "table" then wrapsConfig[wrapId] else nil
	local validDefinition = type(wrapDefinition) == "table"
	local textureId = if validDefinition then _getOptionalString(wrapDefinition.TextureID) else nil
	local baseColor = if validDefinition and typeof(wrapDefinition.BaseColor) == "Color3"
		then wrapDefinition.BaseColor
		else nil
	local material = if validDefinition then _getOptionalMaterial(wrapDefinition.Material) else nil
	local studsPerTile = if validDefinition
		then math.max(0.01, tonumber(wrapDefinition.StudsPerTile) or DEFAULT_WRAP_STUDS_PER_TILE)
		else DEFAULT_WRAP_STUDS_PER_TILE
	local animated = validDefinition and wrapDefinition.isAnimated == true
	local scrollSpeedU = if validDefinition then tonumber(wrapDefinition.ScrollSpeedU) or DEFAULT_WRAP_SCROLL_SPEED_U else DEFAULT_WRAP_SCROLL_SPEED_U
	local scrollSpeedV = if validDefinition then tonumber(wrapDefinition.ScrollSpeedV) or DEFAULT_WRAP_SCROLL_SPEED_V else DEFAULT_WRAP_SCROLL_SPEED_V

	for _, child in primaryPart:GetChildren() do
		if child:IsA("Texture") and string.sub(child.Name, 1, 14) == "ScrollTexture_" then
			if not textureId then
				child:Destroy()
			end
		end
	end

	if textureId then
		for _, textureName in WEAPON_WRAP_TEXTURE_ORDER do
			local existingTexture = primaryPart:FindFirstChild(textureName)
			local texture: Texture
			if existingTexture and existingTexture:IsA("Texture") then
				texture = existingTexture
			else
				texture = Instance.new("Texture")
				texture.Name = textureName
				texture.Face = WEAPON_WRAP_TEXTURE_FACE_BY_NAME[textureName]
				texture.Parent = primaryPart
			end

			texture.Texture = textureId
			texture.Transparency = 0
			texture.StudsPerTileU = studsPerTile
			texture.StudsPerTileV = studsPerTile
			texture.OffsetStudsU = 0
			texture.OffsetStudsV = 0
			texture:SetAttribute("WrapAnimated", animated)
			texture:SetAttribute("WrapScrollSpeedU", scrollSpeedU)
			texture:SetAttribute("WrapScrollSpeedV", scrollSpeedV)

			if animated then
				CollectionService:AddTag(texture, ANIMATED_WRAP_TEXTURE_TAG)
			else
				CollectionService:RemoveTag(texture, ANIMATED_WRAP_TEXTURE_TAG)
			end
		end
	elseif baseColor then
		primaryPart.Color = baseColor
	end

	_applyMaterialToPart(primaryPart, material)
end

function CosmeticsTemplates.applyFaceToHead(head: BasePart, faceId: string)
	local facesConfig = ItemsConfig.Faces
	if type(facesConfig) ~= "table" then
		return
	end

	local faceDefinition = facesConfig[faceId]
	if type(faceDefinition) ~= "table" then
		return
	end

	local textureId = _getOptionalString(faceDefinition.Image)
	if not textureId then
		return
	end

	local faceDecal = head:FindFirstChild("face")
	if not faceDecal or not faceDecal:IsA("Decal") then
		local createdFaceDecal = Instance.new("Decal")
		createdFaceDecal.Name = "face"
		createdFaceDecal.Face = Enum.NormalId.Front
		createdFaceDecal.Parent = head
		faceDecal = createdFaceDecal
	end

	(faceDecal :: Decal).Texture = textureId
end

return CosmeticsTemplates
