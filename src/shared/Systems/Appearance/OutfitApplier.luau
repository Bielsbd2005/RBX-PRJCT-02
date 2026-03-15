local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SkinApplier = require(ReplicatedStorage.Shared.Systems.Appearance.SkinApplier)

local OutfitApplier = {}

local TEXTURE_PREFIX = "ShirtTexture_"
local DEFAULT_MATERIAL = Enum.Material.Plastic

local function applyBaseProperties(part: BasePart, color: Color3?, material: Enum.Material?)
	part.Color = color or part.Color
	part.Material = material or DEFAULT_MATERIAL
	part.Transparency = 0
end

local function clearShirtTextures(part: BasePart)
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("Texture") and child.Name:find(TEXTURE_PREFIX) then
			child:Destroy()
		end
	end
end

function OutfitApplier.Apply(character: Model, outfitData: table)
	if not character or not outfitData then return end
	local targetFolder = character:FindFirstChild("Clothing") or character
	for _, part in ipairs(targetFolder:GetChildren()) do
		if not part:IsA("BasePart") then continue end

		local partName = part.Name

		if partName:find("T%-Shirt") then
			applyBaseProperties(part, outfitData.ShirtBaseColor, outfitData.ShirtMaterial)

			clearShirtTextures(part)

			local textureId = outfitData.ShirtTextureID
			if textureId and textureId ~= "" then
				SkinApplier.applyTexturesToPart(part, textureId, {
					namePrefix = TEXTURE_PREFIX,
					transparency = outfitData.ShirtTextureTransparency or 0,
					studsPerTile = outfitData.ShirtStudsPerTile or 1,
					color = Color3.new(1, 1, 1),
				})
			end

		elseif partName:find("Pant") then
			applyBaseProperties(part, outfitData.PantColor, outfitData.PantMaterial)
		end
	end
end

return OutfitApplier
