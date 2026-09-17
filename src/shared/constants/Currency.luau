--!strict
--[[
	En shared porque cliente (Locker: icono, saldo, pack a ofrecer) y servidor
	(ShopService cobra de este stat) deben coincidir.
	Gems solo se obtiene con Battle Pass o Robux: un ítem con Currency = "Gems"
	es contenido de pago. ItemsConfig.Price va siempre en su Currency, sin conversión.
]]

export type Currency = "Cash" | "Gems"

local CASH = "Cash"
local GEMS = "Gems"

-- Moneda → clave en profile.Data.Stats con el saldo.
local BALANCE_STAT: { [string]: string } = table.freeze({
	[CASH] = "Cash",
	[GEMS] = "Gems",
})

local Currency = {}

Currency.CASH = CASH :: Currency
Currency.GEMS = GEMS :: Currency
Currency.BalanceStat = BALANCE_STAT

function Currency.isValid(value: any): boolean
	return value == CASH or value == GEMS
end

-- Currency de ItemConfig es opcional: todo lo que no sea "Gems" cae a Cash
-- (fail-safe: nunca cobra la moneda premium por accidente).
function Currency.resolve(value: any): Currency
	return (if value == GEMS then GEMS else CASH) :: Currency
end

-- Ruta de DataService al saldo de la moneda (para GetValue/BatchUpdate).
function Currency.balancePath(currency: Currency): { string }
	return { "Stats", BALANCE_STAT[currency] or CASH }
end

return table.freeze(Currency)
