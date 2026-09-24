--!strict
-- Hat de los previews (lobby, Locker, Resultados, pase). Busca y suelda con
-- CosmeticsTemplates, la misma regla que la partida.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticsTemplates = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("CosmeticsTemplates"))

local HatApplier = {}
HatApplier.__index = HatApplier

-- Marca los hats puestos por el applier, para quitarlos sin tocar accesorios del rig.
local COSMETIC_HAT_ATTRIBUTE = "CosmeticHat"

type HatApplier = {
	_model: Model,
	_itemsConfig: any,
	Clear: (self: HatApplier) -> (),
	Apply: (self: HatApplier, itemData: any) -> (),
	ApplyItemId: (self: HatApplier, itemId: string?) -> (),
	Reset: (self: HatApplier) -> (),
}

function HatApplier.new(model: Model, itemsConfig: any): HatApplier
	local self = setmetatable({}, HatApplier) :: any
	self._model = model
	self._itemsConfig = itemsConfig
	return self
end

function HatApplier:Clear()
	for _, child in self._model:GetChildren() do
		if child:IsA("Accessory") and child:GetAttribute(COSMETIC_HAT_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

-- itemData: entrada de catálogo con `id` (y `Name`, que findHatTemplate ya resuelve).
function HatApplier:Apply(itemData: any)
	self:Clear()
	if type(itemData) ~= "table" or type(itemData.id) ~= "string" or itemData.id == "" then
		return
	end

	local template = CosmeticsTemplates.findHatTemplate(itemData.id)
	if not template then
		warn("[HatApplier] No se encontró el sombrero:", itemData.Name or itemData.id)
		return
	end

	local hat = template:Clone()
	hat:SetAttribute(COSMETIC_HAT_ATTRIBUTE, true)
	CosmeticsTemplates.attachHatToCharacter(self._model, hat)
end

function HatApplier:ApplyItemId(itemId: string?)
	local hatsCategory = self._itemsConfig.Hats
	if type(itemId) ~= "string" or itemId == "" or type(hatsCategory) ~= "table" or type(hatsCategory[itemId]) ~= "table" then
		self:Reset()
		return
	end
	self:Apply({ id = itemId })
end

function HatApplier:Reset()
	self:Clear()
end

return HatApplier
