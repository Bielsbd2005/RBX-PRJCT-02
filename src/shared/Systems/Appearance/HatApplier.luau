local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HatsFolder = ReplicatedStorage.Shared.Systems.Locker:WaitForChild("Hats")

local HatApplier = {}
local Debris = game:GetService("Debris")

function HatApplier.Clear(character)
    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Accessory") and child:GetAttribute("CosmeticHat") then
            child:Destroy()
        end
    end
end

function HatApplier.Apply(character, itemData)
    local head = character:FindFirstChild("Head")
    if not head then return end

    local hatTemplate = HatsFolder:FindFirstChild(itemData.Name)
    if not hatTemplate then
        warn("No se encontró el sombrero:", itemData.Name)
        return
    end
    HatApplier.Clear(character)
    local newHat = hatTemplate:Clone()
    local handle = newHat:FindFirstChild("Handle")

    if not handle then
        newHat:Destroy()
        return
    end

    newHat:SetAttribute("CosmeticHat", true)
    local hatAtt = handle:FindFirstChildOfClass("Attachment")
    local headAtt = head:FindFirstChild(hatAtt and hatAtt.Name or "HatAttachment")

    if hatAtt and headAtt then
        handle.CFrame = headAtt.WorldCFrame * hatAtt.CFrame:Inverse()
        local weld = Instance.new("WeldConstraint")
        weld.Name = "AccessoryWeld"
        weld.Part0 = handle
        weld.Part1 = head
        weld.Parent = handle
    end
    newHat.Parent = character
end

return HatApplier
