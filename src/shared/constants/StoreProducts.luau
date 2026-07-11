--!strict

export type StoreProductDefinition = {
	ButtonName: string,
	-- Fila de la CashPage donde vive el botón (Store.CashPage.<Row>.<ButtonName>).
	-- Mover un pack de fila = cambiar este campo. Default "Row1" si se omite.
	Row: string,
	ProductId: number,
	PriceText: string,
	RobuxPrice: number,
	CashAmount: number,
}

-- Fila lógica de la CashPage: nombre del contenedor (Store.CashPage.<RowName>) y
-- los productos que contiene, en orden de aparición.
export type StoreRowLayout = {
	RowName: string,
	Products: { StoreProductDefinition },
}

local PRODUCTS_IN_ORDER = {
	{
		ButtonName = "Cash1",
		Row = "Row1",
		ProductId = 3567132597,
		RobuxPrice = 49,
		PriceText = " 49",
		CashAmount = 500,
	},
	{
		ButtonName = "Cash2",
		Row = "Row1",
		ProductId = 3567132599,
		RobuxPrice = 99,
		PriceText = " 99",
		CashAmount = 1250,
	},
	{
		ButtonName = "Cash3",
		Row = "Row1",
		ProductId = 3567132598,
		RobuxPrice = 199,
		PriceText = " 199",
		CashAmount = 3000,
	},
	{
		ButtonName = "Cash4",
		Row = "Row1",
		ProductId = 3567132596,
		RobuxPrice = 399,
		PriceText = " 399",
		CashAmount = 7000,
	},
	{
		ButtonName = "Cash5",
		Row = "Row1",
		ProductId = 3567132595,
		RobuxPrice = 799,
		PriceText = " 799",
		CashAmount = 15000,
	},
} :: { StoreProductDefinition }

local PRODUCTS_BY_BUTTON_NAME = {} :: { [string]: StoreProductDefinition }
local PRODUCTS_BY_PRODUCT_ID = {} :: { [number]: StoreProductDefinition }

-- Agrupación por fila, preservando el orden de primera aparición de cada Row en
-- PRODUCTS_IN_ORDER. Así el binder recorre filas en un orden estable y editar el
-- catálogo de arriba reordena la UI sin tocar código.
local ROW_LAYOUT = {} :: { StoreRowLayout }
local rowLayoutByName = {} :: { [string]: StoreRowLayout }

for _, product in PRODUCTS_IN_ORDER do
	PRODUCTS_BY_BUTTON_NAME[product.ButtonName] = product
	if product.ProductId > 0 then
		PRODUCTS_BY_PRODUCT_ID[product.ProductId] = product
	end

	local rowName = product.Row
	local row = rowLayoutByName[rowName]
	if not row then
		row = { RowName = rowName, Products = {} }
		rowLayoutByName[rowName] = row
		table.insert(ROW_LAYOUT, row)
	end
	table.insert(row.Products, product)
end

for _, row in ROW_LAYOUT do
	table.freeze(row.Products)
	table.freeze(row)
end

return table.freeze({
	ProductsInOrder = table.freeze(PRODUCTS_IN_ORDER),
	ProductsByButtonName = table.freeze(PRODUCTS_BY_BUTTON_NAME),
	ProductsByProductId = table.freeze(PRODUCTS_BY_PRODUCT_ID),
	-- Layout por filas para la CashPage (Row1, Row2, …), en orden.
	RowLayout = table.freeze(ROW_LAYOUT),
})
