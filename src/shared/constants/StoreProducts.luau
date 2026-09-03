--!strict

--[[
	Catálogo de todo lo que se compra con Robux: los developer products de la
	tienda (packs de Cash y de Gems) y los gamepasses.

	Los packs son dos monedas con exactamente la misma forma: packs de Cash y packs
	de Gems. Cada una declara una lista de datos puros y `buildCatalog` deriva de
	ahí los índices que consumen cliente y servidor, así que ambas monedas no
	pueden divergir por copy-paste.

	Para editar el catálogo solo se tocan las listas de packs de más abajo:
	  · el orden de la lista es el orden de aparición en la UI;
	  · `PriceText` NO se escribe a mano: se deriva de `RobuxPrice` para que no
	    puedan quedar desincronizados.

	Cash y Gems son catálogos separados (y no una sola lista con un campo de
	moneda) porque cada uno se cablea sobre una fila distinta de la GUI: los packs
	de Cash en Store…Content.CoinsRow y los de Gems en GemsRow (el mapeo fila↔
	catálogo vive en el cliente, store/init.luau). Mezclarlos haría buscar los
	packs de Gems en la fila del cash y no aparecerían.

	`PageName` y `Row` son HERENCIA de la GUI anterior (páginas con filas Row1/
	Row2…). Hoy no los usa nadie para localizar botones; se conservan porque
	`Rows` sigue siendo el orden estable con el que recorrer el catálogo.

	ProductId = 0 significa "sin configurar" (mismo convenio que
	`BattlePassConfig.PremiumProductId`): el pack queda fuera de `ByProductId`,
	así que ProcessReceipt lo ignora, y el binder desactiva el botón. Hay que
	crear los developer products reales en el panel de Roblox y pegar aquí
	los IDs.
]]

-- Fila usada por los packs que no declaran `Row`.
local DEFAULT_ROW = "Row1"

-- El espacio inicial es la separación con el icono de Robux que la GUI dibuja
-- a la izquierda del label.
local PRICE_TEXT_FORMAT = " %d"

-- ────────────────────────────────────────────────────────────
-- TIPOS
-- ────────────────────────────────────────────────────────────

-- Campos comunes a todo pack, sea de la moneda que sea: es lo único que
-- necesita el binder del cliente para localizar y cablear un botón.
export type ProductBase = {
	ButtonName: string,
	-- Fila de la página donde vive el botón (Store.<PageName>.<Row>.<ButtonName>).
	Row: string,
	ProductId: number,
	-- Precio ya formateado para el label (derivado de RobuxPrice).
	PriceText: string,
	RobuxPrice: number,
}

export type StoreProductDefinition = ProductBase & { CashAmount: number }
export type GemProductDefinition = ProductBase & { GemAmount: number }

-- Fila lógica de una página: nombre del contenedor (Store.<PageName>.<RowName>)
-- y los productos que contiene, en orden de aparición.
export type ProductRow<T> = {
	RowName: string,
	Products: { T },
}

--[[
	Gamepass de Roblox. Va aparte de los catálogos de packs a propósito: NO es un
	developer product. No pasa por ProcessReceipt (no hay receipt ni PurchaseId
	que idempotentizar), su posesión se consulta con `UserOwnsGamePassAsync` y es
	permanente. Meterlo en un `Catalog` lo dejaría dentro de `ByProductId`, que es
	justo el mapa con el que el dispatcher de receipts decide qué conceder: un id
	de gamepass ahí concedería un pack de moneda por un receipt que nunca llega.

	PassId = 0 significa "sin configurar" (mismo convenio que ProductId): nadie lo
	posee, así que el beneficio se muestra bloqueado y no se concede.

	`RobuxPrice` es solo para pintar el label: el precio que se cobra es el del
	panel de Roblox. Se declara aquí igual que en los packs para que la fila se
	vea completa antes de que el pass exista (con PassId = 0 no hay
	`GetProductInfo` que consultar); al crear el pass hay que pegar el id real y
	dejar este número en el mismo precio que se puso en el panel.
]]
export type GamePassDefinition = {
	-- Nombre legible; se usa como sku en analíticas.
	Name: string,
	-- Botón de la GUI donde vive el pass (Store…PassesRow.<ButtonName>).
	ButtonName: string,
	PassId: number,
	RobuxPrice: number,
	-- Precio ya formateado para el label (derivado de RobuxPrice).
	PriceText: string,
}

-- Los gamepasses no tienen filas ni páginas que derivar (van todos en la misma
-- fila de la tienda), pero sí necesitan un orden estable: `ByName` es un
-- diccionario y recorrerlo pintaría la fila en un orden distinto cada sesión.
export type GamePassCatalog = {
	InOrder: { GamePassDefinition },
	ByName: { [string]: GamePassDefinition },
}

export type Catalog<T> = {
	-- Frame de la GUI que contiene las filas (Store.<PageName>).
	PageName: string,
	InOrder: { T },
	ByButtonName: { [string]: T },
	-- Solo packs configurados (ProductId > 0), para que un receipt jamás pueda
	-- resolverse a un pack a medio crear.
	ByProductId: { [number]: T },
	-- Filas en el orden de primera aparición de cada `Row` en `InOrder`. Así el
	-- binder recorre filas en un orden estable y reordenar la lista de packs
	-- reordena la UI sin tocar código.
	Rows: { ProductRow<T> },
}

-- ────────────────────────────────────────────────────────────
-- PACKS
-- ────────────────────────────────────────────────────────────

local CASH_PACKS = {
	{ ButtonName = "Cash1", ProductId = 3567132597, RobuxPrice = 49, CashAmount = 500 },
	{ ButtonName = "Cash2", ProductId = 3567132599, RobuxPrice = 99, CashAmount = 1250 },
	{ ButtonName = "Cash3", ProductId = 3567132598, RobuxPrice = 199, CashAmount = 3000 },
	{ ButtonName = "Cash4", ProductId = 3567132596, RobuxPrice = 399, CashAmount = 7000 },
	{ ButtonName = "Cash5", ProductId = 3567132595, RobuxPrice = 799, CashAmount = 15000 },
}

-- Moneda premium. ProductId = 0 → pendientes de crear en el panel de Roblox.
local GEM_PACKS = {
	{ ButtonName = "Gems1", ProductId = 0, RobuxPrice = 49, GemAmount = 100 },
	{ ButtonName = "Gems2", ProductId = 0, RobuxPrice = 99, GemAmount = 250 },
	{ ButtonName = "Gems3", ProductId = 0, RobuxPrice = 199, GemAmount = 600 },
	{ ButtonName = "Gems4", ProductId = 0, RobuxPrice = 399, GemAmount = 1400 },
	{ ButtonName = "Gems5", ProductId = 0, RobuxPrice = 799, GemAmount = 3000 },
}

-- Gamepasses, en el orden en el que se pintan en la fila de la tienda.
-- `RobuxPrice` está puesto al precio real de cada pass en el panel de Roblox
-- (ver arriba: aquí sólo pinta el label, cobra el panel). Si se cambia el precio
-- allí hay que reflejarlo aquí o el botón mentirá.
local GAME_PASS_LIST = {
	-- Bonus de cash de fin de partida: el bonus "VIP" de ResultsRewards.
	{ Name = "VIP", ButtonName = "VIP", PassId = 1962133164, RobuxPrice = 100 },
	-- Cuelga de la espalda el arma que no llevas en la mano (BackWeaponService).
	{ Name = "BackWeapon", ButtonName = "BackWeapon", PassId = 1964587184, RobuxPrice = 200 },
}

-- ────────────────────────────────────────────────────────────
-- ÍNDICES DERIVADOS
-- ────────────────────────────────────────────────────────────

--[[
	Convierte una lista de packs en un catálogo listo para consumir: rellena los
	campos derivados (Row por defecto, PriceText), congela cada producto y
	construye los índices por botón, por productId y por fila.

	Los errores son de configuración (dos packs con el mismo botón o el mismo
	developer product), así que revientan al requerir el módulo: en Studio salta
	en cuanto se edita la lista, mucho antes de que un receipt entregue el pack
	equivocado.
]]
local function buildCatalog(pageName: string, packs: { any }): Catalog<any>
	local inOrder = {} :: { any }
	local byButtonName = {} :: { [string]: any }
	local byProductId = {} :: { [number]: any }
	local rows = {} :: { ProductRow<any> }
	local rowsByName = {} :: { [string]: ProductRow<any> }

	for _, pack in packs do
		local product = table.clone(pack)
		product.Row = pack.Row or DEFAULT_ROW
		product.PriceText = string.format(PRICE_TEXT_FORMAT, pack.RobuxPrice)
		table.freeze(product)

		if byButtonName[product.ButtonName] then
			error(`[StoreProducts] {pageName}: ButtonName duplicado "{product.ButtonName}"`)
		end
		byButtonName[product.ButtonName] = product

		if product.ProductId > 0 then
			local clash = byProductId[product.ProductId]
			if clash then
				error(
					`[StoreProducts] {pageName}: ProductId {product.ProductId} repetido en "{clash.ButtonName}" y "{product.ButtonName}"`
				)
			end
			byProductId[product.ProductId] = product
		end

		local row = rowsByName[product.Row]
		if not row then
			row = { RowName = product.Row, Products = {} }
			rowsByName[product.Row] = row
			table.insert(rows, row)
		end
		table.insert(row.Products, product)
		table.insert(inOrder, product)
	end

	for _, row in rows do
		table.freeze(row.Products)
		table.freeze(row)
	end

	return table.freeze({
		PageName = pageName,
		InOrder = table.freeze(inOrder),
		ByButtonName = table.freeze(byButtonName),
		ByProductId = table.freeze(byProductId),
		Rows = table.freeze(rows),
	})
end

--[[
	Misma idea que `buildCatalog` pero para los gamepasses: rellena `PriceText`,
	congela cada pass y devuelve la lista en orden + el índice por nombre (el que
	usan los consumidores del beneficio: `GamePasses.ByName.VIP`).

	Los duplicados también revientan al requerir el módulo. El de `PassId` es el
	que importa: dos passes con el mismo id darían por comprado un beneficio que
	nadie pagó, y sólo se comprueba en los configurados porque PassId = 0 es
	precisamente "todavía no tiene id".
]]
local function buildGamePasses(passes: { any }): GamePassCatalog
	local inOrder = {} :: { GamePassDefinition }
	local byName = {} :: { [string]: GamePassDefinition }
	local byPassId = {} :: { [number]: GamePassDefinition }

	for _, entry in passes do
		local pass = table.clone(entry)
		pass.PriceText = string.format(PRICE_TEXT_FORMAT, entry.RobuxPrice)
		table.freeze(pass)

		if byName[pass.Name] then
			error(`[StoreProducts] GamePasses: Name duplicado "{pass.Name}"`)
		end
		byName[pass.Name] = pass

		if pass.PassId > 0 then
			local clash = byPassId[pass.PassId]
			if clash then
				error(`[StoreProducts] GamePasses: PassId {pass.PassId} repetido en "{clash.Name}" y "{pass.Name}"`)
			end
			byPassId[pass.PassId] = pass
		end

		table.insert(inOrder, pass)
	end

	return table.freeze({
		InOrder = table.freeze(inOrder),
		ByName = table.freeze(byName),
	})
end

local Cash = buildCatalog("CashPage", CASH_PACKS) :: Catalog<StoreProductDefinition>
local Gems = buildCatalog("GemsPage", GEM_PACKS) :: Catalog<GemProductDefinition>
local GamePasses = buildGamePasses(GAME_PASS_LIST)

-- El dispatcher de receipts (ServerBootstrap) prueba un catálogo tras otro, así
-- que un mismo developer product en ambos entregaría la moneda equivocada según
-- el orden de las comprobaciones.
for productId, gemPack in Gems.ByProductId do
	local cashPack = Cash.ByProductId[productId]
	if cashPack then
		error(
			`[StoreProducts] ProductId {productId} usado por Cash "{cashPack.ButtonName}" y Gems "{gemPack.ButtonName}"`
		)
	end
end

return table.freeze({
	Cash = Cash,
	Gems = Gems,
	GamePasses = GamePasses,
})
