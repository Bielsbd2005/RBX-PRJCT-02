--!strict
--[[
	DataMigrations.luau  (Server)

	Framework de migraciones forward-only para el schema del PlayerProfile.

	Cuándo necesitas una migración:
	  • Renombrar un campo (no auto-resuelto por Reconcile).
	  • Cambiar el tipo o forma de un campo (p. ej. boolean → number con count).
	  • Mover datos entre secciones (p. ej. reorganizar Stats).
	  • Computar un valor derivado a partir de campos existentes.

	Cuándo NO necesitas migración:
	  • Añadir un campo nuevo: Reconcile() de ProfileStore lo rellena con el
	    default del template automáticamente. Solo bumpea CURRENT_VERSION si
	    quieres usar el contador para telemetría/diagnostics.

	Cómo añadir una migración:
	  1. Define la función en el bloque MIGRATIONS abajo, indexada por la
	     versión de DESTINO. La función muta `data` in-place.
	  2. Bumpea CURRENT_VERSION al nuevo número.
	  3. Bumpea Metadata.Version en DataTemplate al mismo número.
	  4. La migración debe ser idempotente: re-ejecutarla no debe corromper.

	Garantías:
	  • Las migraciones corren en orden estricto (from+1 .. CURRENT_VERSION).
	  • Si una migración falla con error, NO avanzamos Version. Esto permite
	    re-intentar en el siguiente login sin perder datos.
	  • Migraciones corren ANTES de la creación de la Replica → mutaciones
	    in-place son seguras (mismo contrato que el resto de _loadPlayer).
]]

local DataMigrations = {}

-- Versión actual del schema. Bumpear al añadir una migración nueva, en sync
-- con `Metadata.Version` del DataTemplate.
DataMigrations.CURRENT_VERSION = 2

-- Registro de migraciones. Clave = versión de DESTINO. Valor = función
-- (data) -> () que muta data in-place.
--
-- Ejemplo (cuando exista una v3):
--   [3] = function(data)
--       -- Mover Stats.Headshots a una nueva sección CombatStats.
--       data.CombatStats = data.CombatStats or {}
--       data.CombatStats.Headshots = data.Stats.Headshots or 0
--       data.Stats.Headshots = nil
--   end,
local MIGRATIONS: { [number]: (any) -> () } = {
	-- v2 es la baseline actual; no hay migraciones aún.
}

DataMigrations.migrations = MIGRATIONS

--[[
	Aplica todas las migraciones necesarias para llevar `data` desde su versión
	actual hasta CURRENT_VERSION. Devuelve:
	  • applied  — true si se ejecutó al menos una migración con éxito.
	  • errored  — true si alguna migración lanzó error (Version no avanza).
]]
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
		-- Avanzar versión incluso para "no-op" migrations (gaps en MIGRATIONS).
		data.Metadata.Version = v
	end

	return applied, false
end

return DataMigrations
