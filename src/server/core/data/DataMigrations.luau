--!strict
--[[
	Migraciones forward-only del PlayerProfile. Añadir un campo nuevo NO necesita
	migración (Reconcile() lo rellena); renombrar, cambiar forma o mover datos sí.

	Para añadir una: función en MIGRATIONS indexada por la versión de DESTINO que muta
	`data` in-place y es idempotente, y subir `Metadata.Version` de DataTemplate.

	Si una falla, Version no avanza y se reintenta en el siguiente login. Corren antes
	de crear la Replica, así que mutar in-place es seguro.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataTemplate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("DataTemplate"))

local DataMigrations = {}

DataMigrations.CURRENT_VERSION = DataTemplate.Metadata.Version

-- Ids de wraps de maestría anteriores a v4 → id actual (Mastery_<Name>); false = retirado.
local MASTERY_WRAP_RENAMES_V4: { [string]: string | false } = {
	Mastery_Carbon = "Mastery_Graphite",
	Mastery_Bronze = "Mastery_Copper",
	Mastery_Silver = "Mastery_Jade",
	Mastery_Obsidian = "Mastery_Cobalt",
	Mastery_Titanium = "Mastery_Amethyst",
	Mastery_Ruby = "Mastery_Garnet",
	Mastery_Inferno = false,
	Mastery_Void = false,
}

-- Wraps que solo daba el Battle Pass: se retiran (los equipados vuelven a Default).
local BATTLE_PASS_WRAPS_RETIRED_V5: { [string]: string | false } = {
	Wrap_Pink = false,
	Wrap_RPG_Blue = false,
	Wrap_S1_Ember = false,
	Wrap_S1_Tide = false,
	Wrap_S1_Magma = false,
	Wrap_S1_Volt = false,
	Wrap_S1_Frost = false,
	Wrap_S1_Shadow = false,
	Wrap_S1_Prism = false,
}

-- Copia nueva y no in-place: añadir claves a una tabla mientras se recorre no es seguro.
local function renamedKeys(map: any, renames: { [string]: string | false }): any
	if type(map) ~= "table" then
		return map
	end
	local result = {}
	for key, value in map do
		local renamed = renames[key]
		if renamed ~= false then
			result[renamed or key] = value
		end
	end
	return result
end

-- Aplica `renames` a los wraps poseídos, a su metadata y a los equipados.
local function renameWraps(data: any, renames: { [string]: string | false })
	local wrapsByWeapon = if type(data.Inventory) == "table" then data.Inventory.WeaponWrapsByWeapon else nil
	if type(wrapsByWeapon) == "table" then
		for _, weapons in wrapsByWeapon do
			if type(weapons) == "table" then
				for weaponId, owned in weapons do
					weapons[weaponId] = renamedKeys(owned, renames)
				end
			end
		end
	end
	if type(data.InventoryMeta) == "table" then
		data.InventoryMeta.WeaponWraps = renamedKeys(data.InventoryMeta.WeaponWraps, renames)
	end
	if type(data.Loadout) == "table" then
		for _, slotsKey in { "MainWeaponWraps", "SpecialWeaponWraps" } do
			local equippedByWeapon = data.Loadout[slotsKey]
			if type(equippedByWeapon) == "table" then
				for weaponId, wrapId in equippedByWeapon do
					local renamed = renames[wrapId]
					-- Un wrap retirado equipado vuelve al de por defecto.
					equippedByWeapon[weaponId] = if renamed == false then "Default" else renamed or wrapId
				end
			end
		end
	end
end

local MIGRATIONS: { [number]: (any) -> () } = {
	-- v2 es la baseline.
	[3] = function(data)
		data.NewItemFlags = nil
		if type(data.Settings) == "table" then
			data.Settings.ColorblindMode = nil
			data.Settings.Language = nil
			data.Settings.CrosshairColor = nil
		end
		if type(data.Rewards) == "table" then
			data.Rewards.NotificationsClaimed = nil
		end
	end,
	[4] = function(data)
		renameWraps(data, MASTERY_WRAP_RENAMES_V4)
	end,
	[5] = function(data)
		data.BattlePass = nil
		renameWraps(data, BATTLE_PASS_WRAPS_RETIRED_V5)
	end,
}

DataMigrations.migrations = MIGRATIONS

-- Devuelve (applied, errored).
function DataMigrations.migrate(data: any): (boolean, boolean)
	if type(data) ~= "table" or type(data.Metadata) ~= "table" then
		return false, false
	end

	local from = if type(data.Metadata.Version) == "number" then data.Metadata.Version else 0
	if from >= DataMigrations.CURRENT_VERSION then
		return false, false
	end

	local applied = false
	for v = from + 1, DataMigrations.CURRENT_VERSION do
		local fn = MIGRATIONS[v]
		if fn ~= nil then
			local ok, err = pcall(fn, data)
			if not ok then
				warn(("[DataMigrations] migración v%d falló para perfil v%d: %s"):format(v, from, tostring(err)))
				return applied, true
			end
			applied = true
		end
		-- También avanza en los huecos de MIGRATIONS.
		data.Metadata.Version = v
	end

	return applied, false
end

return DataMigrations
