--!strict

export type StoreProductDefinition = {
	ButtonName: string,
	ProductId: number,
	PriceText: string,
	CashAmount: number,
}

local PRODUCTS_IN_ORDER = {
	{
		ButtonName = "Cash1",
		ProductId = 3567132597,
		PriceText = " 49",
		CashAmount = 500,
	},
	{
		ButtonName = "Cash2",
		ProductId = 3567132599,
		PriceText = " 99",
		CashAmount = 1250,
	},
	{
		ButtonName = "Cash3",
		ProductId = 3567132598,
		PriceText = " 199",
		CashAmount = 3000,
	},
	{
		ButtonName = "Cash4",
		ProductId = 3567132596,
		PriceText = " 399",
		CashAmount = 7000,
	},
	{
		ButtonName = "Cash5",
		ProductId = 3567132595,
		PriceText = " 799",
		CashAmount = 15000,
	},
} :: { StoreProductDefinition }

local PRODUCTS_BY_BUTTON_NAME = {} :: { [string]: StoreProductDefinition }
local PRODUCTS_BY_PRODUCT_ID = {} :: { [number]: StoreProductDefinition }

for _, product in PRODUCTS_IN_ORDER do
	PRODUCTS_BY_BUTTON_NAME[product.ButtonName] = product
	if product.ProductId > 0 then
		PRODUCTS_BY_PRODUCT_ID[product.ProductId] = product
	end
end

return table.freeze({
	ProductsInOrder = table.freeze(PRODUCTS_IN_ORDER),
	ProductsByButtonName = table.freeze(PRODUCTS_BY_BUTTON_NAME),
	ProductsByProductId = table.freeze(PRODUCTS_BY_PRODUCT_ID),
})
