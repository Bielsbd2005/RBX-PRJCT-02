--!strict
--[[
	CosmeticsTemplates.luau
	Helpers compartidos para aplicar cosméticos a un Character/Tool:
	  - findHatTemplate(hatId)
	  - findWeaponDisplayTemplate(category, weaponId)
	  - applyWeaponWrapToTool(tool, wrapId)
	  - applyWeaponWrapToModel(weaponModel, wrapId)
	  - applyFaceToHead(head, faceId)

	Extraído de LoadoutService para que también lo consuma BotAppearance.
	Sin estado: cada función es idempotente sobre la instancia que recibe.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)

local CosmeticsTemplates = {}

local WEAPONS_ROOT_NAME = "weapons"
local WEAPON_MODEL_NODE_NAME = "WeaponModel"

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

-- Mismo orden de resolución que los previews del locker
-- (WeaponPreviewController.getWeaponPreviewPrimaryPart y el gemelo de
-- WeaponWrapPreviewer): los modelos de display se autoran en Studio y no todos
-- traen PrimaryPart seteado, así que hay que caer a los nombres de convención.
local function _resolveWeaponPrimaryPart(root: Instance): BasePart?
	if root:IsA("BasePart") then
		return root :: BasePart
	end
	if not root:IsA("Model") then
		return nil
	end

	local model = root :: Model
	if model.PrimaryPart then
		return model.PrimaryPart
	end

	-- "Main" aquí es un nombre de BasePart dentro del modelo 3D del arma; nada
	-- que ver con WeaponCategory.MAIN.
	for _, candidateName in { "primaryPart", "Main" } do
		local node = model:FindFirstChild(candidateName, true)
		if node and node:IsA("BasePart") then
			return node :: BasePart
		end
	end

	return model:FindFirstChildWhichIsA("BasePart", true)
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

-- Resuelve el Accessory de un hat. Los assets se autoran en Studio nombrados por el
-- `Name` del catálogo ("Bunny"), no por el id ("Hat1"), así que se busca por Name
-- primero y se cae al id — mismo orden que el preview del locker (HatApplier). El
-- nodo puede ser el propio Accessory o un Model que lo contenga.
function CosmeticsTemplates.findHatTemplate(hatId: string): Accessory?
	if hatId == "" then
		return nil
	end

	local hatsRoot = _getHatsRoot()
	if not hatsRoot then
		return nil
	end

	local hatsConfig = ItemsConfig.Hats
	local definition = if type(hatsConfig) == "table" then hatsConfig[hatId] else nil
	local hatName = if type(definition) == "table" then _getOptionalString(definition.Name) else nil

	for _, candidateName in { hatName, hatId } do
		local node = if candidateName then hatsRoot:FindFirstChild(candidateName) else nil
		if node then
			if node:IsA("Accessory") then
				return node
			end
			if node:IsA("Model") then
				local accessory = node:FindFirstChildWhichIsA("Accessory", true)
				if accessory then
					return accessory
				end
			end
		end
	end

	return nil
end

-- Parentear un Accessory a un personaje solo lo suelda si su Attachment tiene
-- gemelo en el rig (normalmente Head.HatAttachment). Los bodies del juego se
-- autoran en Studio y no todos lo traen: ahí el hat se quedaba suelto — equipado
-- en datos pero invisible o caído en partida. Este helper reproduce el fallback
-- que ya hacía el preview del locker (HatApplier): si no hay gemelo, se coloca
-- sobre la cabeza y se suelda a mano.
function CosmeticsTemplates.attachHatToCharacter(character: Model, accessory: Accessory)
	accessory.Parent = character

	local handleNode = accessory:FindFirstChild("Handle")
	if not (handleNode and handleNode:IsA("BasePart")) then
		return
	end
	local handle = handleNode :: BasePart

	local hatAttachment: Attachment? = nil
	for _, child in handle:GetChildren() do
		if child:IsA("Attachment") then
			hatAttachment = child
			break
		end
	end

	-- Con gemelo en el rig, Roblox ya ha soldado el accessory al parentearlo: no
	-- se toca nada (un segundo weld pelearía con el suyo).
	if hatAttachment then
		local twin = character:FindFirstChild(hatAttachment.Name, true)
		if twin and twin:IsA("Attachment") then
			return
		end
	end

	local headNode = character:FindFirstChild("Head")
	if not (headNode and headNode:IsA("BasePart")) then
		return
	end
	local head = headNode :: BasePart

	handle.CFrame = head.CFrame * CFrame.new(0, head.Size.Y * 0.5, 0)
	handle.CanCollide = false
	handle.Massless = true

	local weld = Instance.new("WeldConstraint")
	weld.Name = "AccessoryWeld"
	weld.Part0 = handle
	weld.Part1 = head
	weld.Parent = handle
end

local function _applyWrapToPrimaryPart(primaryPart: BasePart, wrapId: string)
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

-- Contrato de la Tool real (ServerStorage.WeaponTools): un Model descendiente
-- llamado `WeaponModel` con PrimaryPart seteado. Se mantiene estricto a
-- propósito — una Tool mal autorada debe no-opear, no adivinar una parte.
function CosmeticsTemplates.applyWeaponWrapToTool(tool: Tool, wrapId: string)
	local weaponModelNode = tool:FindFirstChild(WEAPON_MODEL_NODE_NAME, true)
	if not weaponModelNode or not weaponModelNode:IsA("Model") then
		return
	end

	local primaryPart = (weaponModelNode :: Model).PrimaryPart
	if not primaryPart then
		return
	end

	_applyWrapToPrimaryPart(primaryPart, wrapId)
end

-- Variante para modelos de display sueltos (Shared.Locker.weapons.*), que no
-- son Tools y no siempre traen PrimaryPart. Misma skin, misma animación: las
-- textures quedan tagueadas igual y WeaponWrapAnimator las mueve en cliente.
function CosmeticsTemplates.applyWeaponWrapToModel(weaponModel: Instance, wrapId: string)
	local primaryPart = _resolveWeaponPrimaryPart(weaponModel)
	if not primaryPart then
		return
	end

	_applyWrapToPrimaryPart(primaryPart, wrapId)
end

--[[
	Modelo de display de un arma: `Shared.Locker.weapons.<categoría>.<weaponId>`,
	con la misma cadena de fallback que los previews del locker
	(weaponId → Name del catálogo → "Default").

	Devuelve geometría pura, nunca una Tool: si el asset se autoró como Tool nos
	quedamos con su `WeaponModel`. Quien sólo quiere *enseñar* un arma no debe
	arrastrar Handle, scripts, sonidos ni el tag de WeaponsSystem.
]]
function CosmeticsTemplates.findWeaponDisplayTemplate(category: string, weaponId: string): Instance?
	local locker = Shared:FindFirstChild("Locker")
	local weaponsRoot = if locker then locker:FindFirstChild(WEAPONS_ROOT_NAME) else nil
	local categoryFolder = if weaponsRoot then weaponsRoot:FindFirstChild(category) else nil
	if not categoryFolder then
		return nil
	end

	local categoryConfig = (ItemsConfig :: any)[category]
	local definition = if type(categoryConfig) == "table" then categoryConfig[weaponId] else nil
	local displayName = if type(definition) == "table" then _getOptionalString(definition.Name) else nil

	local node = (if weaponId ~= "" then categoryFolder:FindFirstChild(weaponId) else nil)
		or (if displayName then categoryFolder:FindFirstChild(displayName) else nil)
		or categoryFolder:FindFirstChild(ItemDefaults.ITEM_ID)
	if not node then
		return nil
	end

	if node:IsA("Tool") then
		local inner = node:FindFirstChild(WEAPON_MODEL_NODE_NAME, true)
		return if inner and inner:IsA("Model") then inner else nil
	end

	if node:IsA("Model") or node:IsA("BasePart") then
		return node
	end

	return nil
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
