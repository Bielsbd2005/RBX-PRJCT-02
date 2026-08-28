--!strict
--[[
	Currency.luau
	Las dos monedas blandas del juego y el stat de perfil donde vive el saldo de
	cada una. Vive en shared porque cliente y servidor tienen que coincidir: el
	Locker decide qué icono/saldo pinta y qué pack ofrece si no llega, y
	ShopService cobra de ese mismo stat. Si divergen, la UI ofrece comprar Cash
	para un ítem que se paga en Gems.

	  · Cash — moneda blanda: se gana jugando y también se compra con Robux.
	  · Gems — moneda premium: SOLO Battle Pass o packs de Robux (ver
	    DataTemplate.Stats.Gems). Un ítem con `Currency = "Gems"` en ItemsConfig
	    es, de facto, contenido de pago.

	El precio de un ítem (ItemsConfig.Price) está SIEMPRE expresado en su
	`Currency`: no hay conversión entre monedas en ningún punto del código.
]]

export type Currency = "Cash" | "Gems"

local CASH = "Cash"
local GEMS = "Gems"

-- Moneda → clave dentro de profile.Data.Stats con el saldo. Hoy coinciden con
-- el nombre de la moneda, pero el mapa es explícito para que un rename del stat
-- no obligue a buscar concatenaciones por todo el código.
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

--[[
	Normaliza el campo `Currency` de un ItemConfig. Es opcional y puede venir con
	cualquier basura de una edición a mano: todo lo que no sea "Gems" cae a Cash,
	que es el default histórico (fail-safe: nunca cobra la moneda premium por
	accidente).
]]
function Currency.resolve(value: any): Currency
	return (if value == GEMS then GEMS else CASH) :: Currency
end

-- Ruta de DataService al saldo de la moneda (para GetValue/BatchUpdate).
function Currency.balancePath(currency: Currency): { string }
	return { "Stats", BALANCE_STAT[currency] or CASH }
end

return table.freeze(Currency)
