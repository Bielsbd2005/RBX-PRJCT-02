--!strict

local ItemDefaults = {}

-- Fallback cuando no hay nada equipado en una categoría. Debe coincidir con la key
-- "Default" de cada categoría de ItemsConfig y con el nombre del Tool/Model fallback
-- en ReplicatedStorage.Shared.Locker.weapons.*.
ItemDefaults.ITEM_ID = "Default"

return ItemDefaults
