--!strict

local ItemDefaults = {}

-- Item-id fallback usado cuando el jugador no tiene nada equipado en una categoría.
-- Coincide con la key "Default" presente en cada categoría de ItemsConfig
-- (WeaponWraps, Hats, Faces, KillEffects, Outfits, Main, Special, etc.) y con el
-- nombre del Tool/Model fallback dentro de ReplicatedStorage.Shared.Locker.weapons.*.
ItemDefaults.ITEM_ID = "Default"

return ItemDefaults
