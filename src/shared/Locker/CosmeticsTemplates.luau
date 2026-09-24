--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local WeaponWrapParts = require(script.Parent.WeaponWrapParts)
local WeaponWrapPainter = require(script.Parent.WeaponWrapPainter)

local CosmeticsTemplates = {}

local WEAPONS_ROOT_NAME = "weapons"
local WEAPON_MODEL_NODE_NAME = "WeaponModel"

local function _getOptionalString(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
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

-- Los assets de Studio se nombran por el `Name` del catálogo ("Bunny"), no por el
-- id ("Hat1"): se busca por Name y luego por id. El nodo puede
-- ser el propio Accessory o un Model que lo contenga.
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

-- Una sola regla para partida, bots y previews. El hat se coloca a mano: alineando
-- su Attachment con el gemelo de la cabeza (normalmente Head.HatAttachment) o, si
-- el rig no lo trae, encima de la cabeza. Solo se suelda si al parentearlo Roblox no
-- lo ha soldado ya (lo hace un Humanoid cuando hay gemelo); sin Humanoid, como en la
-- cabeza del pase, nunca lo hace.
function CosmeticsTemplates.attachHatToCharacter(character: Model, accessory: Accessory)
	local handleNode = accessory:FindFirstChild("Handle")
	local headNode = character:FindFirstChild("Head")
	if not (handleNode and handleNode:IsA("BasePart") and headNode and headNode:IsA("BasePart")) then
		accessory.Parent = character
		return
	end
	local handle = handleNode :: BasePart
	local head = headNode :: BasePart

	local hatAttachment = handle:FindFirstChildWhichIsA("Attachment")
	-- Se busca antes de parentear: después, la búsqueda encontraría el propio
	-- Attachment del hat.
	local twinNode = if hatAttachment then character:FindFirstChild(hatAttachment.Name, true) else head:FindFirstChild("HatAttachment")
	local twin = if twinNode and twinNode:IsA("Attachment") then twinNode else nil

	if twin then
		handle.CFrame = twin.WorldCFrame * (if hatAttachment then hatAttachment.CFrame:Inverse() else CFrame.identity)
	else
		handle.CFrame = head.CFrame * CFrame.new(0, head.Size.Y * 0.5, 0)
	end
	handle.CanCollide = false
	handle.Massless = true

	accessory.Parent = character

	-- Solo cuenta un weld hacia el rig: el asset puede traer uno viejo de Studio.
	for _, joint in handle:GetChildren() do
		if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
			local other = if (joint :: any).Part0 == handle then (joint :: any).Part1 else (joint :: any).Part0
			if typeof(other) == "Instance" and other:IsDescendantOf(character) and not other:IsDescendantOf(accessory) then
				return
			end
		end
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "AccessoryWeld"
	weld.Part0 = handle
	weld.Part1 = if twin and twin.Parent and twin.Parent:IsA("BasePart") then twin.Parent else head
	weld.Parent = handle
end

-- Contrato de la Tool real (ServerStorage.WeaponTools): un Model descendiente
-- `WeaponModel` con PrimaryPart. Estricto a propósito: una Tool mal autorada no-opea.
function CosmeticsTemplates.applyWeaponWrapToTool(tool: Tool, wrapId: string)
	local weaponModelNode = tool:FindFirstChild(WEAPON_MODEL_NODE_NAME, true)
	if not weaponModelNode or not weaponModelNode:IsA("Model") then
		return
	end

	local primaryPart = (weaponModelNode :: Model).PrimaryPart
	if not primaryPart then
		return
	end

	WeaponWrapPainter.paintParts(WeaponWrapParts.get(tool, primaryPart), WeaponWrapPainter.getDefinition(wrapId))
end

-- Para modelos de display (Shared.Locker.weapons.*), que no siempre traen PrimaryPart.
function CosmeticsTemplates.applyWeaponWrapToModel(weaponModel: Instance, wrapId: string)
	WeaponWrapPainter.paint(weaponModel, WeaponWrapPainter.getDefinition(wrapId))
end

--[[
	`Shared.Locker.weapons.<categoría>.<weaponId>`, con fallback weaponId → Name
	del catálogo → "Default" como los previews del locker. Devuelve geometría pura:
	si el asset es una Tool se queda con su `WeaponModel`.
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
