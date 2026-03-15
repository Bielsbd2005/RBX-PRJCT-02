--!strict

--[[
    LootRoller
    Módulo compartido para el rolleo de loot por rareza.
    Usado por el servidor para el roll autoritativo y por el cliente para colores de rareza.
]]

local LootRoller = {}

----- Tipos Exportados -----
export type Rarity = "Common" | "Rare" | "Epic" | "Legendary"

export type Chances = {
    Common: number?,
    Rare: number?,
    Epic: number?,
    Legendary: number?
}

export type BoxConfig = {
    Chances: Chances,
    LuckyChances: Chances?,
    Pools: {
        [string]: { string } -- Diccionario de Rareza -> Lista de nombres de items
    }
}

----- Constantes Inmutables -----
local RARITY_COLORS: { [string]: Color3 } = table.freeze({
    Common    = Color3.fromRGB(180, 180, 180),
    Rare      = Color3.fromRGB(85, 126, 239),
    Epic      = Color3.fromRGB(163, 53, 238),
    Legendary = Color3.fromRGB(255, 215, 0),
})

local RARITY_ORDER: { Rarity } = table.freeze({
    "Common", "Rare", "Epic", "Legendary"
})

-- Instancia dedicada para mejor aleatoriedad
local RNG = Random.new()

----- Funciones del Módulo -----

--[[
    Realiza un roll basado en las chances del box config.
    Soporta porcentajes decimales (ej. 0.5%).
    @param boxConfig — Configuración de la caja (tipo BoxConfig)
    @param useLucky  — true si se usa Lucky Spin
    @return skinName: string, rarity: Rarity
]]
function LootRoller.roll(boxConfig: BoxConfig, useLucky: boolean): (string, Rarity)
    local chances = if useLucky and boxConfig.LuckyChances then boxConfig.LuckyChances else boxConfig.Chances
    local pools = boxConfig.Pools

    -- 1. Determinar rareza ganadora por peso acumulado (Soporta decimales de 0.0 a 100.0)
    -- NextNumber genera un float, permitiendo chances como 0.1%
    local randomValue = RNG:NextNumber(0, 100)
    local accumulated = 0
    local wonRarity: Rarity = "Common" -- fallback

    for _, rarity in ipairs(RARITY_ORDER) do
        -- Forzamos a tipar la rareza para acceder al diccionario
        local chance = chances[rarity :: string] or 0

        if chance > 0 then
            accumulated += chance
            if randomValue <= accumulated then
                wonRarity = rarity
                break
            end
        end
    end

    -- 2. Escoger una skin aleatoria del pool de esa rareza
    local pool = pools[wonRarity]

    if not pool or #pool == 0 then
        -- Fallback seguro: si el pool está vacío, subir al Common
        pool = pools["Common"]
        wonRarity = "Common"

        -- Si incluso Common está vacío, devolvemos un string vacío para evitar errores
        if not pool or #pool == 0 then
            warn("[LootRoller] Error: La caja no tiene items en la pool 'Common'.")
            return "", "Common"
        end
    end

    -- RNG:NextInteger es inclusivo en ambos extremos
    local skinName = pool[RNG:NextInteger(1, #pool)]

    return skinName, wonRarity
end

--[[
    Devuelve el Color3 asociado a una rareza.
]]
function LootRoller.getRarityColor(rarity: string): Color3
    return RARITY_COLORS[rarity] or RARITY_COLORS.Common
end

return LootRoller
