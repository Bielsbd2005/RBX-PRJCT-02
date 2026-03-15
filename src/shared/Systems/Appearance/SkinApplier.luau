local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local SkinApplier = {}

local DEFAULT_TILE_SIZE = 2
local TEXTURE_SPEED_U = 0.5
local TEXTURE_SPEED_V = 0
local FACES = Enum.NormalId:GetEnumItems()
local SKIN_TAG = "RenderSkinElement"
local Color3_new = Color3.new
local Instance_new = Instance.new

-- Low-level: Aplicación de Texturas
function SkinApplier.applyTexturesToPart(
    part: BasePart,
    textureId: string,
    config: table
): { Texture }
    local textures = {}
    local studs = config.studsPerTile or DEFAULT_TILE_SIZE
    local color = config.color or Color3_new(1, 1, 1)
    local trans = config.transparency or 0
    local prefix = config.namePrefix or "SkinTexture_"

    -- Creamos las texturas antes de parentarlas para evitar recálculos de renderizado
    for i = 1, 6 do
        local face = FACES[i]
        local t = Instance_new("Texture")
        t.Name = prefix .. face.Name
        t.Face = face
        t.Texture = textureId
        t.Transparency = trans
        t.StudsPerTileU = studs
        t.StudsPerTileV = studs
        t.Color3 = color

        -- Marcamos para limpieza rápida
        CollectionService:AddTag(t, SKIN_TAG)

        t.Parent = part
        textures[i] = t
    end

    return textures
end

function SkinApplier.cleanup(model: Model)
    if not model then return end
    for _, item in ipairs(model:GetDescendants()) do
        if CollectionService:HasTag(item, SKIN_TAG) then
            item:Destroy()
        end
    end
end

function SkinApplier.apply(model: Model, skinData: table): { Texture }
    if not model or not skinData then return {} end

    SkinApplier.cleanup(model)

    local textures = {}
    local textureCount = 0
    local descendants = model:GetDescendants() -- Cacheamos la tabla

    for i = 1, #descendants do
        local part = descendants[i]
        if not part:IsA("BasePart") or part.Transparency == 1 then continue end

        if part.Name == "SecondaryPart" then
            part.Color = skinData.SecondaryPartColor or part.Color
            if skinData.SecondaryMaterial then part.Material = skinData.SecondaryMaterial end

            if part:IsA("MeshPart") then
                part.TextureID = skinData.SecondaryPartTexture or ""
            elseif skinData.SecondaryPartTexture and skinData.SecondaryPartTexture ~= "" then
                local created = SkinApplier.applyTexturesToPart(part, skinData.SecondaryPartTexture, {
                    namePrefix = "SecondaryTexture_",
                    transparency = skinData.TextureTransparency,
                    studsPerTile = skinData.StudsPerTile
                })
                for j = 1, #created do
                    textureCount += 1
                    textures[textureCount] = created[j]
                end
            end
        else
            -- Primary Style
            part.Color = skinData.BaseColor or part.Color
            part.Material = skinData.Material or Enum.Material.Plastic

            if skinData.TextureID and skinData.TextureID ~= "" then
                local created = SkinApplier.applyTexturesToPart(part, skinData.TextureID, {
                    namePrefix = "SkinTexture_",
                    transparency = skinData.TextureTransparency,
                    studsPerTile = skinData.StudsPerTile,
                    color = skinData.TextureColor
                })
                for j = 1, #created do
                    textureCount += 1
                    textures[textureCount] = created[j]
                end
            end

            -- Partículas optimizadas
            if part == model.PrimaryPart and skinData.Particles and skinData.Particles.Enabled then
                local p = Instance_new("ParticleEmitter")
                p.Name = "SkinParticles"
                local pData = skinData.Particles
                p.Texture = pData.Texture
                p.Color = pData.Color
                p.Size = pData.Size
                p.Lifetime = pData.Lifetime
                p.Rate = pData.Rate
                p.Speed = pData.Speed
                CollectionService:AddTag(p, SKIN_TAG)
                p.Parent = part
            end
        end
    end

    return textures
end

function SkinApplier.startAnimation(textures: { Texture }, skinData: table, parentCheck: Instance?): RBXScriptConnection?
    if not skinData.Animated or #textures == 0 then return nil end

    local tileSize = skinData.StudsPerTile or DEFAULT_TILE_SIZE
    local currentU = 0
    local currentV = 0
    local speedU = TEXTURE_SPEED_U
    local speedV = TEXTURE_SPEED_V

    return RunService.Heartbeat:Connect(function(dt)
        if parentCheck and not parentCheck.Parent then
            return
        end

        currentU = (currentU + speedU * dt) % tileSize
        currentV = (currentV + speedV * dt) % tileSize

		for i = 1, #textures do
            local t = textures[i]
            t.OffsetStudsU = currentU
            t.OffsetStudsV = currentV
        end
    end)
end

return SkinApplier
