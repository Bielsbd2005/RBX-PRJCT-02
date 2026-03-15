--!strict

--[[
    FusionService.server.luau
    Handles secure fusion of weapon skins on the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local _Players = game:GetService("Players")

local DataManager = require(ServerScriptService.Server.Systems.Data.DataManager) :: any
local ItemsData = require(ReplicatedStorage.Shared.Systems.Locker.Data.ItemsData) :: any

local FusionService = {}


-- Types
type FusionResponse = {
    success: boolean,
    message: string,
    resultSkin: string?
}


-- Initialize RemoteFunction
local casesFolder = ReplicatedStorage:FindFirstChild("Cases")
if not casesFolder then
    casesFolder = Instance.new("Folder")
    casesFolder.Name = "Cases"
    casesFolder.Parent = ReplicatedStorage
end

local fusionActionRF = casesFolder:FindFirstChild("FusionAction")
if not fusionActionRF then
    fusionActionRF = Instance.new("RemoteFunction")
    fusionActionRF.Name = "FusionAction"
    fusionActionRF.Parent = casesFolder
end

-- Security: per-player rate limit and collect mutex
local lastCallTime: { [Player]: number } = {}
local isCollecting: { [Player]: boolean } = {}
game:GetService("Players").PlayerRemoving:Connect(function(p)
    lastCallTime[p] = nil
    isCollecting[p] = nil
end)


-- Helpers
local NEXT_RARITY = {
    common = "Rare",
    rare = "Epic",
    epic = "Legendary",
    legendary = "Legendary"
}
local function getTargetRarity(sourceRarity: string): string
    return NEXT_RARITY[string.lower(sourceRarity)] or "Rare"
end

local function getRandomSkinOfRarity(targetRarity: string): string?
    local possible = {}
    if ItemsData.Arsenal and ItemsData.Arsenal.WeaponSkins then
        for _, skin in ipairs(ItemsData.Arsenal.WeaponSkins) do
            if string.lower(skin.Rarity) == string.lower(targetRarity) then
                table.insert(possible, skin.Name)
            end
        end
    end
    if #possible > 0 then
        return possible[math.random(1, #possible)]
    end
    return nil
end

-- Remote Function Handler
fusionActionRF.OnServerInvoke = function(player: Player, action: unknown, args: unknown): FusionResponse
    if type(action) ~= "string" then return { success = false, message = "Invalid action" } end

    -- Rate-limit: max 1 call per 0.5 seconds per player
    local now = os.clock()
    if lastCallTime[player] and now - lastCallTime[player] < 0.5 then
        return { success = false, message = "Too many requests" }
    end
    lastCallTime[player] = now

    local data = DataManager:Get(player)
    if not data then return { success = false, message = "Data not loaded" } end

    local currentInventory = data.inventory and data.inventory.WeaponSkins or {}
    local activeFusion = data.activeFusion

    if action == "Start" then
        if activeFusion and not activeFusion.cleared then return { success = false, message = "Fusion already in progress" } end
        if type(args) ~= "table" then return { success = false, message = "Invalid skins format" } end

        local skinsToFuse: {string} = args :: any
        if #skinsToFuse ~= 4 then return { success = false, message = "You must provide exactly 4 skins" } end

        -- 1. Count ownership securely
        local ownedCount = {}
        for _, skinName in ipairs(currentInventory) do
            ownedCount[skinName] = (ownedCount[skinName] or 0) + 1
        end

        local requiredCount = {}
        for _, skinName in ipairs(skinsToFuse) do
            if type(skinName) ~= "string" then return {success = false, message = "Invalid skin name"} end
            requiredCount[skinName] = (requiredCount[skinName] or 0) + 1
        end

        for skinName, count in pairs(requiredCount) do
            if (ownedCount[skinName] or 0) < count then
                return { success = false, message = "You do not own enough of " .. skinName }
            end
        end

        -- 2. Validate rarity match
        local rarityMatch = nil
        local allMatch = true
        for _, skinName in ipairs(skinsToFuse) do
            local foundInfo = nil
            for _, info in ipairs(ItemsData.Arsenal.WeaponSkins) do
                if info.Name == skinName then foundInfo = info; break end
            end
            if not foundInfo then return { success = false, message = "Invalid skin: " .. skinName } end

            if not rarityMatch then
                rarityMatch = string.lower(foundInfo.Rarity)
            elseif string.lower(foundInfo.Rarity) ~= rarityMatch then
                allMatch = false
                break
            end
        end

        if not allMatch or not rarityMatch then
            return { success = false, message = "All skins must be the same rarity" }
        end
        if rarityMatch == "legendary" then
            return { success = false, message = "Cannot fuse Legendary skins" }
        end

        -- 3. Calculate target & reward
        local targetRarity = getTargetRarity(rarityMatch)
        local rewardSkin = getRandomSkinOfRarity(targetRarity)
        if not rewardSkin then return { success = false, message = "Could not generate reward" } end

        -- 4. Deduct inventory
        local newInventory = {}
        local consumed = table.clone(requiredCount)
        for _, skinName in ipairs(currentInventory) do
            if consumed[skinName] and consumed[skinName] > 0 then
                consumed[skinName] -= 1
            else
                table.insert(newInventory, skinName)
            end
        end

        -- 5. Save state
        local success = DataManager:BatchUpdate(player, {
            ["inventory.WeaponSkins"] = newInventory,
            ["activeFusion"] = {
                endTime = os.time() + (15 * 60), -- 15 minutes
                resultSkin = rewardSkin,
                sourceSkins = skinsToFuse
            }
        })

        if success then
            local pName = player.Name
            print(string.format("[Fusion] %s started fusion on %s x4", pName, tostring(skinsToFuse[1])))
            return { success = true, message = "Started" }
        end
        return { success = false, message = "Database error" }

    elseif action == "Cancel" then
        if not activeFusion or activeFusion.cleared then return { success = false, message = "No fusion in progress" } end

        -- Validate sourceSkins before refunding (guards against corrupted data)
        local newInventory = table.clone(currentInventory)
        if type(activeFusion.sourceSkins) == "table" then
            for _, skinName in ipairs(activeFusion.sourceSkins) do
                if type(skinName) == "string" and skinName ~= "" then
                    -- Verify it's a real skin in ItemsData
                    local valid = false
                    for _, info in ipairs(ItemsData.Arsenal.WeaponSkins) do
                        if info.Name == skinName then valid = true; break end
                    end
                    if valid then
                        table.insert(newInventory, skinName)
                    end
                end
            end
        end

        -- Use BatchUpdate to prevent item duplication if one save fails
        local success = DataManager:BatchUpdate(player, {
            ["inventory.WeaponSkins"] = newInventory,
            ["activeFusion"] = { cleared = true }
        })

        if success then
            return { success = true, message = "Refunded" }
        else
            return { success = false, message = "Database error during cancel" }
        end

    elseif action == "Collect" then
        if not activeFusion or activeFusion.cleared then return { success = false, message = "No fusion in progress" } end

        -- Mutex: prevent double-collect race condition
        if isCollecting[player] then
            return { success = false, message = "Already collecting, please wait" }
        end
        isCollecting[player] = true

        if os.time() < activeFusion.endTime then
            isCollecting[player] = nil
            return { success = false, message = "Fusion is not ready yet!" }
        end

        local rewardSkin = activeFusion.resultSkin

        -- Award Skin
        local newInventory = table.clone(currentInventory)
        table.insert(newInventory, rewardSkin)

        -- Use BatchUpdate to prevent item duplication if one save fails
        local success = DataManager:BatchUpdate(player, {
            ["inventory.WeaponSkins"] = newInventory,
            ["activeFusion"] = { cleared = true }
        })

        isCollecting[player] = nil -- Free the mutex regardless of DB result

        if success then
            print(string.format("[Fusion] %s collected %s", player.Name, rewardSkin))
            return { success = true, message = "Collected", resultSkin = rewardSkin }
        else
            return { success = false, message = "Database error during collect" }
        end
    end

    return { success = false, message = "Unknown action" }
end

return FusionService
