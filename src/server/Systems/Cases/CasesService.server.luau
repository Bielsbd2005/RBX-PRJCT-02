--!strict

--[[
    CasesService
    Servicio servidor para apertura de cajas.
    Valida, hace el roll autoritativo, deduce moneda/spins y otorga el premio.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-- Asumimos que estos módulos exportan sus tipos, o usamos 'any' solo en la importación
local DataManager = require(ServerScriptService.Server.Systems.Data.DataManager) :: any
local LootConfig = require(ReplicatedStorage.Shared.Systems.Cases.Data.LootConfig) :: any
local LootRoller = require(ReplicatedStorage.Shared.Systems.Cases.LootRoller) :: any

local CasesService = {}

----- Tipos Internos -----
export type CaseResponse = {
    success: boolean,
    message: string?,
    skinName: string?,
    rarity: string?,
    isDuplicate: boolean?
}

type PlayerData = {
    cash: number?,
    luckySpins: number?,
    caseSpins: { [string]: number }?,
    inventory: {
        WeaponSkins: { string }?
    }?
}

----- Configuración -----
local COOLDOWN_TIME = 1 -- Más alto que el de la tienda por la animación

----- Inicialización de RemoteFunction -----
local casesFolder = ReplicatedStorage:FindFirstChild("Cases")
if not casesFolder then
    casesFolder = Instance.new("Folder")
    casesFolder.Name = "Cases"
    casesFolder.Parent = ReplicatedStorage
end

local function GetRemote(name: string): RemoteFunction
    local remote = casesFolder:FindFirstChild(name)
    if not remote then
        remote = Instance.new("RemoteFunction")
        remote.Name = name
        remote.Parent = casesFolder
    end
    return remote :: RemoteFunction
end

local openCaseRF = GetRemote("OpenCase")

----- Cooldowns -----
local playerCooldowns: { [Player]: number } = {}

local function CheckCooldown(player: Player): boolean
    local now = os.clock()
    local last = playerCooldowns[player] or 0
    if (now - last) < COOLDOWN_TIME then return true end
    playerCooldowns[player] = now
    return false
end

--------------------------------------------------------------------------------
-- Logic: Open Case
--------------------------------------------------------------------------------
-- Usamos 'unknown' en lugar de 'any' para parámetros que vienen del cliente (seguridad)
openCaseRF.OnServerInvoke = function(player: Player, caseNameRaw: unknown, useLuckyRaw: unknown): CaseResponse
    if CheckCooldown(player) then
        return { success = false, message = "Esperando animación..." }
    end

    -- 1. Validar tipos estrictamente en la frontera de red
    if type(caseNameRaw) ~= "string" or type(useLuckyRaw) ~= "boolean" then
        return { success = false, message = "Argumentos inválidos" }
    end

    local caseName: string = caseNameRaw
    local useLucky: boolean = useLuckyRaw

    -- 2. Verificar que la caja existe en config
    local boxConfig = LootConfig[caseName]
    if not boxConfig then
        return { success = false, message = "Caja no encontrada" }
    end

    -- 3. Obtener datos del jugador
    local data: PlayerData = DataManager:Get(player)
    if not data then
        return { success = false, message = "Error de datos del jugador" }
    end

    -- 4. Validar Lucky Spin
    if useLucky then
        if not boxConfig.LuckySpin then
            return { success = false, message = "Esta caja no acepta Lucky Spin" }
        end
        if (data.luckySpins or 0) < 1 then
            return { success = false, message = "No tienes Lucky Spins" }
        end
    end

    -- 5. Validar pago (caseSpins gratuitos O cash)
    local hasFreeSpins = data.caseSpins and (data.caseSpins[caseName] or 0) >= 1
    local isRobux = boxConfig.Currency == "Robux"
    local price = boxConfig.Price or 0

    if not hasFreeSpins then
        -- FIX CRÍTICO: Si es de Robux y no tiene giros guardados, bloquear inmediatamente.
        if isRobux then
            return { success = false, message = "Las cajas premium deben comprarse en la tienda." }
        end

        -- Si no es de Robux, comprobar el dinero en efectivo
        if (data.cash or 0) < price then
            return { success = false, message = "Dinero insuficiente" }
        end
    end

    -- 6. Roll autoritativo en el servidor
    local skinName, rarity = LootRoller.roll(boxConfig, useLucky)

    -- 7. Preparar actualizaciones de datos
    local updates: { [string]: any } = {}

    -- Deducir Lucky Spin si se usó
    if useLucky then
        updates["luckySpins"] = (data.luckySpins or 0) - 1
    end

    -- Deducir pago (Giro gratis tiene prioridad sobre el dinero)
    if hasFreeSpins then
        local currentSpins = (data.caseSpins and data.caseSpins[caseName]) or 0
        local newSpins = data.caseSpins and table.clone(data.caseSpins) or {}
        newSpins[caseName] = currentSpins - 1
        updates["caseSpins"] = newSpins
    else
        updates["cash"] = (data.cash or 0) - price
    end

    -- 8. Otorgar premio (skin al inventario)
    local currentSkins = (data.inventory and data.inventory.WeaponSkins) or {}
    local newSkins = table.clone(currentSkins)
    table.insert(newSkins, skinName)
    updates["inventory.WeaponSkins"] = newSkins

    -- 9. Aplicar todas las actualizaciones atómicamente
    local success = DataManager:BatchUpdate(player, updates)

    if not success then
        return { success = false, message = "Error procesando la transacción" }
    end

    print(string.format("[Cases] %s abrió %s → %s (%s)", player.Name, caseName, skinName, rarity))

    return {
        success = true,
        skinName = skinName,
        rarity = rarity,
        isDuplicate = false, -- Legacy support para tu UI
    }
end

-- Limpieza
Players.PlayerRemoving:Connect(function(player)
    playerCooldowns[player] = nil
end)

return CasesService
