--!strict

--[[
    LootConfig
    Configuración de cajas de loot con chances por rareza y pools de skins.
]]

----- Tipos Exportados -----
export type Chances = {
    Common: number?,
    Rare: number?,
    Epic: number?,
    Legendary: number?,
}

export type Pools = {
    Common: { string },
    Rare: { string },
    Epic: { string },
    Legendary: { string },
}

export type BoxConfig = {
    Order: number,
    Name: string,
    Price: number,
    Currency: string?, -- Opcional, por defecto asumiremos "Coins" en tu lógica
    Thumb: string,
    LuckySpin: boolean,
    Chances: Chances,
    LuckyChances: Chances?,
    Pools: Pools,
}

export type LootConfigDatabase = {
    [string]: BoxConfig
}

----- Helpers -----
local function asset(id: number | string): string
    return "rbxassetid://" .. tostring(id)
end

-- Congela las tablas anidadas para evitar alteraciones en tiempo de ejecución
local function deepFreeze(tbl: any): any
    for _, v in tbl do
        if type(v) == "table" then
            deepFreeze(v)
        end
    end
    return table.freeze(tbl)
end

----- Base de Datos -----
local LootConfig: LootConfigDatabase = {
    ["Wood"] = {
        Order = 1,
        Name = "Wood",
        Price = 100,
        Thumb = asset(137764490762168),
        LuckySpin = true,

        -- Chances normales (deben sumar 100)
        Chances = {
            Common    = 68,
            Rare      = 22,
            Epic      = 9,
            Legendary = 1,
        },
        -- Chances con Lucky Spin (deben sumar 100)
        LuckyChances = {
            Common    = 46,
            Rare      = 22,
            Epic      = 17,
            Legendary = 15,
        },

        -- Pool de skins por rareza (nombres de ItemsData.WeaponSkins)
        Pools = {
            Common    = {"SK_0001","SK_0002","SK_0003","SK_0004","SK_0005","SK_0006","SK_0007","SK_0008","SK_0009","SK_0010","SK_0011","SK_0012"},
            Rare      = {"SK_0013","SK_0014","SK_0015","SK_0016","SK_0017","SK_0018"},
            Epic      = {"SK_0013","SK_0014","SK_0015"},
            Legendary = {"SK_0016"},
        },
    },
    ["Metal"] = {
        Order = 2,
        Name = "Metal",
        Price = 100,
        Thumb = asset(117272503833559),
        LuckySpin = true,

        Chances = {
            Common    = 68,
            Rare      = 22,
            Epic      = 9,
            Legendary = 1,
        },
        LuckyChances = {
            Common    = 46,
            Rare      = 22,
            Epic      = 17,
            Legendary = 15,
        },

        Pools = {
            Common    = {"SK_0001","SK_0002","SK_0003","SK_0004","SK_0005","SK_0006","SK_0007","SK_0008","SK_0009","SK_0010","SK_0011","SK_0012"},
            Rare      = {"SK_0013","SK_0014","SK_0015","SK_0016","SK_0017","SK_0018"},
            Epic      = {"SK_0013","SK_0014","SK_0015"},
            Legendary = {"SK_0016"},
        },
    },
    ["Magma"] = {
        Order = 3,
        Name = "Magma",
        Price = 100,
        Currency = "Robux",
        Thumb = asset(125156836268515),
        LuckySpin = false,

        Chances = {
            Common    = 68,
            Rare      = 22,
            Epic      = 9,
            Legendary = 1,
        },
        -- No LuckyChances porque LuckySpin = false

        Pools = {
            Common    = {"SK_0001","SK_0002","SK_0003","SK_0004","SK_0005","SK_0006"},
            Rare      = {"SK_0002"},
            Epic      = {},
            Legendary = {},
        },
    },
}

deepFreeze(LootConfig)

return LootConfig 
