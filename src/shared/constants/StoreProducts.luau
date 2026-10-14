--!strict

--[[
	Catálogo de todo lo que se compra con Robux: los developer products de la
	tienda (packs de Cash y de Gems, bundles limitados) y los gamepasses.

	Cash y Gems declaran listas de datos puros y `buildCatalog` deriva los índices
	que consumen cliente y servidor, para que no diverjan por copy-paste. El orden de
	la lista es el orden en la UI; `PriceText` se deriva de `RobuxPrice`.

	Son catálogos separados porque cada uno se cablea sobre una fila distinta de la
	GUI (Store…Content.CoinsRow / GemsRow; el mapeo vive en el cliente, store/init.luau).

	`PageName` y `Row` ya no se usan para localizar botones; `Rows` se conserva como
	orden estable para recorrer el catálogo.

	ProductId = 0 significa "sin configurar" (mismo convenio que
	`BattlePassConfig.PremiumProductId`): queda fuera de `ByProductId`, ProcessReceipt
	lo ignora y el binder desactiva el botón.
]]

local ItemsConfig = require(script.Parent.ItemsConfig) :: any

local DEFAULT_ROW = "Row1"

-- U+E002 es un codepoint privado que las fuentes de Roblox pintan como el icono de Robux.
local PRICE_TEXT_FORMAT = "\u{E002} %d"

-- Campos comunes a todo pack, sea de la moneda que sea: es lo único que
-- necesita el binder del cliente para cablear un slot.
export type ProductBase = {
	-- Sku en analíticas y logs; la GUI ya no lo usa (el slot se busca por posición en InOrder).
	ButtonName: string,
	-- Sin uso: el cliente localiza las filas por nombre fijo (store/init.luau).
	Row: string,
	ProductId: number,
	-- Precio ya formateado para el label (derivado de RobuxPrice).
	PriceText: string,
	RobuxPrice: number,
}

export type StoreProductDefinition = ProductBase & { CashAmount: number }
export type GemProductDefinition = ProductBase & { GemAmount: number }

-- Agrupación por `Row`; sin consumidores (ver cabecera).
export type ProductRow<T> = {
	RowName: string,
	Products: { T },
}

--[[
	Gamepass: va aparte de los catálogos de packs a propósito. NO es un developer
	product: no pasa por ProcessReceipt, su posesión se consulta con
	`UserOwnsGamePassAsync` y es permanente. Dentro de `ByProductId` el dispatcher
	de receipts concedería un pack de moneda por un receipt que nunca llega.

	PassId = 0 significa "sin configurar": nadie lo posee y el beneficio no se concede.

	`RobuxPrice` solo pinta el label (con PassId = 0 no hay `GetProductInfo`); el
	precio que se cobra es el del panel de Roblox y deben coincidir.

	Roblox no deja comprar un pass para otro jugador: regalarlo es comprar el developer
	product `GiftProductId` (mismo precio), que GiftingService convierte en una entrada
	de `GiftedPasses` en el perfil del receptor. GiftProductId = 0 ⇒ no se regala.
]]
export type GamePassDefinition = {
	-- Nombre legible; se usa como sku en analíticas y como key de `GiftedPasses`
	-- (renombrarlo deja sin pass a quien lo recibió regalado).
	Name: string,
	-- Texto para el jugador (nombre en la tienda, alerta y notificación de regalo).
	DisplayName: string,
	-- Slot de la GUI donde vive el pass (Store…PassesRow.<ButtonName>).
	ButtonName: string,
	PassId: number,
	GiftProductId: number,
	RobuxPrice: number,
	-- Precio ya formateado para el label (derivado de RobuxPrice).
	PriceText: string,
	-- Gems que se conceden una sola vez al poseerlo (VIPItemsService); un refund no las retira.
	WelcomeGems: number?,
}

-- Orden estable explícito: `ByName` es un diccionario y recorrerlo pintaría la fila
-- en un orden distinto cada sesión.
export type GamePassCatalog = {
	InOrder: { GamePassDefinition },
	ByName: { [string]: GamePassDefinition },
	ByPassId: { [number]: GamePassDefinition },
	-- Solo passes regalables de verdad (GiftProductId y PassId > 0).
	ByGiftProductId: { [number]: GamePassDefinition },
}

--[[
	Bundle limitado: developer product que concede unos wraps, cada uno para un arma
	concreta, con un número de serie global (LimitedBundleService). Se regala con el
	mismo ProductId. ProductId = 0 ⇒ sin configurar: no se vende ni se regala.
]]
export type BundleWrap = {
	WrapId: string,
	-- WeaponCategory ("Main" | "Special") del arma que recibe el wrap.
	Category: string,
	WeaponId: string,
}

export type BundleDefinition = {
	-- Clave del contador global en el DataStore y sku en analíticas: renombrarlo
	-- reinicia la numeración.
	Name: string,
	-- Texto para el jugador (aviso de regalo). El título del slot es de la GUI.
	DisplayName: string,
	-- Slot de la GUI donde vive el bundle (Store…BundlesRow.<ButtonName>).
	ButtonName: string,
	ProductId: number,
	RobuxPrice: number,
	PriceText: string,
	-- Unidades anunciadas. La venta se cierra en `SellableUnits`: el hueco absorbe las
	-- compras simultáneas de varios servidores, que no se pueden devolver.
	MaxUnits: number,
	SellableUnits: number,
	Wraps: { BundleWrap },
}

export type BundleCatalog = {
	InOrder: { BundleDefinition },
	ByName: { [string]: BundleDefinition },
	-- Solo bundles configurados (ProductId > 0).
	ByProductId: { [number]: BundleDefinition },
	-- Wrap → bundle que lo concede: un wrap así solo se consigue con su bundle.
	ByWrapId: { [string]: BundleDefinition },
}

export type Catalog<T> = {
	-- Frame de la GUI que contiene las filas (Store.<PageName>).
	PageName: string,
	InOrder: { T },
	ByButtonName: { [string]: T },
	-- Solo packs configurados (ProductId > 0), para que un receipt jamás pueda
	-- resolverse a un pack a medio crear.
	ByProductId: { [number]: T },
	-- Sin consumidores: el orden de la UI sale de `InOrder`.
	Rows: { ProductRow<T> },
}

local CASH_PACKS = {
	{ ButtonName = "Cash1", ProductId = 3567132597, RobuxPrice = 49, CashAmount = 800 },
	{ ButtonName = "Cash2", ProductId = 3567132599, RobuxPrice = 99, CashAmount = 2000 },
	{ ButtonName = "Cash3", ProductId = 3567132598, RobuxPrice = 199, CashAmount = 5000 },
	{ ButtonName = "Cash4", ProductId = 3567132596, RobuxPrice = 399, CashAmount = 11000 },
	{ ButtonName = "Cash5", ProductId = 3567132595, RobuxPrice = 799, CashAmount = 24000 },
}

-- ProductId = 0 → pendientes de crear en el panel de Roblox.
local GEM_PACKS = {
	{ ButtonName = "Gems1", ProductId = 3713310604, RobuxPrice = 49, GemAmount = 100 },
	{ ButtonName = "Gems2", ProductId = 3713310633, RobuxPrice = 99, GemAmount = 250 },
	{ ButtonName = "Gems3", ProductId = 3713310658, RobuxPrice = 199, GemAmount = 600 },
	{ ButtonName = "Gems4", ProductId = 3713310686, RobuxPrice = 399, GemAmount = 1400 },
	{ ButtonName = "Gems5", ProductId = 3713310707, RobuxPrice = 799, GemAmount = 3000 },
}

-- En el orden en que se pintan. `RobuxPrice` debe coincidir con el precio del panel
-- de Roblox (el del pass y el de su developer product de regalo) o el botón mentirá.
-- TODO: crear los developer products de regalo en el panel de Roblox y poner su id.
local GAME_PASS_LIST = {
	-- Bonus "VIP" de ResultsRewards, ítems isVIPExclusive, Gems de bienvenida y tag VIP (VIPItemsService).
	{
		Name = "VIP",
		DisplayName = "VIP",
		ButtonName = "VIP",
		PassId = 1962133164,
		GiftProductId = 0,
		RobuxPrice = 299,
		WelcomeGems = 100,
	},
	-- Cuelga de la espalda el arma que no llevas en la mano (BackWeaponService).
	{
		Name = "BackWeapon",
		DisplayName = "Back Weapon",
		ButtonName = "BackWeapon",
		PassId = 1964587184,
		GiftProductId = 0,
		RobuxPrice = 200,
	},
}

local BUNDLE_LIST = {
	{
		Name = "Founders",
		DisplayName = "Founders Bundle",
		ButtonName = "Bundle01",
		ProductId = 3718585698,
		RobuxPrice = 1200,
		MaxUnits = 500,
		SellableUnits = 490,
		Wraps = {
			{ WrapId = "Wrap_Founders_Groza", Category = "Main", WeaponId = "Groza" },
			{ WrapId = "Wrap_Founders_UZI", Category = "Special", WeaponId = "UZI" },
		},
	},
}

--[[
	Rellena los campos derivados (Row por defecto, PriceText), congela cada producto
	y construye los índices. Los errores de configuración (botón o developer product
	duplicado) revientan al requerir el módulo, antes de que un receipt entregue el
	pack equivocado.
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
	Como `buildCatalog` para gamepasses. Un `PassId` duplicado daría por comprado un
	beneficio que nadie pagó; solo se comprueba en los configurados (PassId > 0).
	Un pass sin PassId tampoco se regala: nadie podría poseerlo.
]]
local function buildGamePasses(passes: { any }): GamePassCatalog
	local inOrder = {} :: { GamePassDefinition }
	local byName = {} :: { [string]: GamePassDefinition }
	local byPassId = {} :: { [number]: GamePassDefinition }
	local byGiftProductId = {} :: { [number]: GamePassDefinition }

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

			if pass.GiftProductId > 0 then
				local giftClash = byGiftProductId[pass.GiftProductId]
				if giftClash then
					error(
						`[StoreProducts] GamePasses: GiftProductId {pass.GiftProductId} repetido en "{giftClash.Name}" y "{pass.Name}"`
					)
				end
				byGiftProductId[pass.GiftProductId] = pass
			end
		end

		table.insert(inOrder, pass)
	end

	return table.freeze({
		InOrder = table.freeze(inOrder),
		ByName = table.freeze(byName),
		-- `PromptGamePassPurchaseFinished` solo entrega el passId.
		ByPassId = table.freeze(byPassId),
		ByGiftProductId = table.freeze(byGiftProductId),
	})
end

--[[
	Como `buildCatalog` para bundles. Además de los duplicados revienta con un wrap que
	no existe, que se pueda comprar con moneda (dejaría de ser limitado) o que esté en
	dos bundles (el número de serie no sabría de cuál es).
]]
local function buildBundles(entries: { any }): BundleCatalog
	local inOrder = {} :: { BundleDefinition }
	local byName = {} :: { [string]: BundleDefinition }
	local byButtonName = {} :: { [string]: BundleDefinition }
	local byProductId = {} :: { [number]: BundleDefinition }
	local byWrapId = {} :: { [string]: BundleDefinition }

	for _, entry in entries do
		local bundle = table.clone(entry)
		bundle.PriceText = string.format(PRICE_TEXT_FORMAT, entry.RobuxPrice)
		local wraps = {}
		for _, wrap in entry.Wraps do
			table.insert(wraps, table.freeze(table.clone(wrap)))
		end
		bundle.Wraps = table.freeze(wraps)
		table.freeze(bundle)

		if byName[bundle.Name] then
			error(`[StoreProducts] Bundles: Name duplicado "{bundle.Name}"`)
		end
		byName[bundle.Name] = bundle

		if byButtonName[bundle.ButtonName] then
			error(`[StoreProducts] Bundles: ButtonName duplicado "{bundle.ButtonName}"`)
		end
		byButtonName[bundle.ButtonName] = bundle

		if bundle.SellableUnits <= 0 or bundle.SellableUnits > bundle.MaxUnits then
			error(`[StoreProducts] Bundles: "{bundle.Name}" necesita 0 < SellableUnits <= MaxUnits`)
		end

		for _, wrap in bundle.Wraps do
			local wrapDef = ItemsConfig.WeaponWraps[wrap.WrapId]
			if type(wrapDef) ~= "table" or wrapDef.CanPurchase == true then
				error(`[StoreProducts] Bundles: "{bundle.Name}" usa el wrap "{wrap.WrapId}", que no existe o se vende aparte`)
			end
			local weapons = ItemsConfig[wrap.Category]
			if type(weapons) ~= "table" or weapons[wrap.WeaponId] == nil then
				error(`[StoreProducts] Bundles: "{bundle.Name}" apunta al arma inexistente {wrap.Category}.{wrap.WeaponId}`)
			end
			local clash = byWrapId[wrap.WrapId]
			if clash then
				error(`[StoreProducts] Bundles: el wrap "{wrap.WrapId}" está en "{clash.Name}" y "{bundle.Name}"`)
			end
			byWrapId[wrap.WrapId] = bundle
		end

		if bundle.ProductId > 0 then
			local clash = byProductId[bundle.ProductId]
			if clash then
				error(`[StoreProducts] Bundles: ProductId {bundle.ProductId} repetido en "{clash.Name}" y "{bundle.Name}"`)
			end
			byProductId[bundle.ProductId] = bundle
		end

		table.insert(inOrder, bundle)
	end

	return table.freeze({
		InOrder = table.freeze(inOrder),
		ByName = table.freeze(byName),
		ByProductId = table.freeze(byProductId),
		ByWrapId = table.freeze(byWrapId),
	})
end

local Cash = buildCatalog("CashPage", CASH_PACKS) :: Catalog<StoreProductDefinition>
local Gems = buildCatalog("GemsPage", GEM_PACKS) :: Catalog<GemProductDefinition>
local GamePasses = buildGamePasses(GAME_PASS_LIST)
local Bundles = buildBundles(BUNDLE_LIST)

-- El dispatcher de receipts (ServerBootstrap) prueba un catálogo tras otro, así
-- que un mismo developer product en dos entregaría lo equivocado según el orden
-- de las comprobaciones.
for productId, gemPack in Gems.ByProductId do
	local cashPack = Cash.ByProductId[productId]
	if cashPack then
		error(
			`[StoreProducts] ProductId {productId} usado por Cash "{cashPack.ButtonName}" y Gems "{gemPack.ButtonName}"`
		)
	end
end
for productId, pass in GamePasses.ByGiftProductId do
	local pack = Cash.ByProductId[productId] or Gems.ByProductId[productId]
	if pack then
		error(`[StoreProducts] ProductId {productId} usado por el pack "{pack.ButtonName}" y el regalo de "{pass.Name}"`)
	end
end
for productId, bundle in Bundles.ByProductId do
	local pack = Cash.ByProductId[productId] or Gems.ByProductId[productId]
	local pass = GamePasses.ByGiftProductId[productId]
	if pack or pass then
		error(`[StoreProducts] ProductId {productId} usado por el bundle "{bundle.Name}" y por otro producto`)
	end
end

return table.freeze({
	Cash = Cash,
	Gems = Gems,
	GamePasses = GamePasses,
	Bundles = Bundles,
})
