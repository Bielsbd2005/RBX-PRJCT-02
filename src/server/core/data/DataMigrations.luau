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
