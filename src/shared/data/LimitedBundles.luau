--!strict
--[[
	Reglas de los bundles limitados (StoreProducts.Bundles) que comparten cliente y
	servidor: posesión, stock y número de serie.

	El servidor (LimitedBundleService) publica las unidades vendidas de cada bundle como
	atributo de ReplicatedStorage; la tienda lo lee para pintar el stock y el servidor
	vuelve a decidir con él antes de lanzar el prompt.
	El número de serie vive en InventoryMeta.WeaponWraps[wrapId].Serial.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local constants = script.Parent.Parent.constants
local StoreProducts = require(constants.StoreProducts)
local WeaponCategory = require(constants.WeaponCategory)
local InventoryRepository = require(script.Parent.InventoryRepository)

type BundleDefinition = StoreProducts.BundleDefinition

local SOLD_ATTRIBUTE_PREFIX = "LimitedSold_"

local LimitedBundles = {}

LimitedBundles.SERIAL_FORMAT = "#%d"

function LimitedBundles.soldAttributeName(bundle: BundleDefinition): string
	return SOLD_ATTRIBUTE_PREFIX .. bundle.Name
end

-- nil mientras el servidor no haya leído el contador: entonces no se vende.
function LimitedBundles.getSold(bundle: BundleDefinition): number?
	local value = ReplicatedStorage:GetAttribute(LimitedBundles.soldAttributeName(bundle))
	return if type(value) == "number" then value else nil
end

function LimitedBundles.isSaleOpen(bundle: BundleDefinition, sold: number?): boolean
	return bundle.ProductId > 0 and sold ~= nil and sold < bundle.SellableUnits
end

-- Basta con uno de sus wraps: solo se consiguen con el bundle. Sin el flag UnlockAll,
-- que haría creer al servidor que todos lo tienen ya.
function LimitedBundles.ownsBundle(profileData: any, bundle: BundleDefinition): boolean
	for _, wrap in bundle.Wraps do
		local category = wrap.Category :: WeaponCategory.WeaponCategory
		if InventoryRepository.rawOwnsWeaponWrap(profileData, category, wrap.WeaponId, wrap.WrapId) then
			return true
		end
	end
	return false
end

function LimitedBundles.serialOf(inventoryMeta: any, wrapId: string): number?
	local wrapsMeta = if type(inventoryMeta) == "table" then inventoryMeta.WeaponWraps else nil
	local meta = if type(wrapsMeta) == "table" then wrapsMeta[wrapId] else nil
	local serial = if type(meta) == "table" then tonumber(meta.Serial) else nil
	return if serial and serial > 0 then serial else nil
end

return table.freeze(LimitedBundles)
