--!strict
--[[
	WeaponLevelConfig.luau
	Fuente única de verdad para el sistema de NIVELES DE ARMA (1..5).

	Modelo:
	  • El nivel de un arma NO se persiste como campo propio: se DERIVA de las
	    kills acumuladas con esa arma (`WeaponKills[category][weaponId]`), que ya
	    se guardan y replican. Así no hay migración de datos ni doble fuente de
	    verdad — sube el contador de kills, sube el nivel.
	  • Cada nivel escala stats de combate del arma (daño, cadencia, recarga,
	    cargador) mediante MULTIPLIERS. Sólo se escalan las claves whitelisted en
	    SCALED_STATS; el resto de configs del arma pasan sin tocar.

	Aplicación en runtime:
	  • El servidor escribe el nivel como atributo `WeaponLevel` en el Tool
	    (LoadoutService al spawnear; MatchService al subir de nivel en partida).
	  • `BaseWeapon:getConfigValue` lee ese atributo y aplica el multiplicador.
	    Como el atributo se replica, cliente y servidor calculan el MISMO valor
	    (la predicción de cadencia/recarga del cliente coincide con el daño
	    autoritativo del servidor).

	Para tunear el balance basta editar THRESHOLDS y MULTIPLIERS aquí.
]]

local WeaponLevelConfig = {}

-- Nombre del atributo que el servidor pone en el Tool y que BaseWeapon lee.
WeaponLevelConfig.ATTRIBUTE = "WeaponLevel"

-- Kills ACUMULADAS necesarias para HABER ALCANZADO cada nivel (índice = nivel).
-- THRESHOLDS[1] = 0 → todas las armas arrancan en nivel 1.
-- MAX_LEVEL se deriva del tamaño de la tabla (no hardcodear en otros sitios).
local THRESHOLDS = { 0, 20, 60, 140, 300 }

WeaponLevelConfig.MAX_LEVEL = #THRESHOLDS

--[[
	Multiplicadores de stat por nivel. MULTIPLIERS[stat][level].
	  • Nivel 1 SIEMPRE es 1.00 (baseline = valor configurado en el Tool).
	  • Stats "más es mejor" (daño, cargador) → factor creciente > 1.
	  • Stats "menos es mejor" (recoil) → factor decreciente < 1.

	Se escalan SÓLO tres aspectos: Daño, Recoil y Ammo. Mejora por nivel
	(L1→L5), todo relativo al stat base del Tool:

	  ┌────────┬──────┬──────┬──────┬──────┬──────┐
	  │ Campo  │  L1  │  L2  │  L3  │  L4  │  L5  │
	  ├────────┼──────┼──────┼──────┼──────┼──────┤
	  │ Daño   │  +0% │  +5% │ +10% │ +15% │ +20% │  (más daño por disparo)
	  │ Recoil │  -0% │  -5% │ -10% │ -15% │ -20% │  (menos retroceso = mejor)
	  │ Ammo   │  +0% │ +10% │ +20% │ +30% │ +40% │  (cargador más grande)
	  └────────┴──────┴──────┴──────┴──────┴──────┘

	Notas:
	  • Daño cubre HitDamage (balístico) y BlastDamage (explosivo, p. ej. RPG).
	  • Recoil cubre RecoilMin y RecoilMax (magnitud del kick).
	  • Ammo es AmmoCapacity (se redondea a entero, ver INTEGER_STATS).

	Estos buffs afectan el balance PvP: un arma a nivel 5 pega más, retrocede
	menos y lleva más balas que la misma arma a nivel 1. Tunear aquí.
]]
local MULTIPLIERS: { [string]: { number } } = {
	-- Daño: +5% por nivel → +20% a nivel 5.
	HitDamage = { 1.00, 1.05, 1.10, 1.15, 1.20 },
	BlastDamage = { 1.00, 1.05, 1.10, 1.15, 1.20 },
	-- Recoil: -5% por nivel → -20% a nivel 5 (menos retroceso).
	RecoilMin = { 1.00, 0.95, 0.90, 0.85, 0.80 },
	RecoilMax = { 1.00, 0.95, 0.90, 0.85, 0.80 },
	-- Ammo: +10% por nivel → +40% a nivel 5 (se redondea a entero).
	AmmoCapacity = { 1.00, 1.10, 1.20, 1.30, 1.40 },
}

-- Claves cuyo valor escalado debe ser ENTERO (cargador, nº de proyectiles...).
local INTEGER_STATS: { [string]: boolean } = {
	AmmoCapacity = true,
}

-- ────────────────────────────────────────────────────────────
-- API
-- ────────────────────────────────────────────────────────────

--- ¿Esta clave de config escala con el nivel del arma?
function WeaponLevelConfig.IsScaledStat(statKey: string): boolean
	return MULTIPLIERS[statKey] ~= nil
end

--- Clampa un nivel arbitrario al rango válido [1, MAX_LEVEL].
function WeaponLevelConfig.ClampLevel(level: number): number
	if type(level) ~= "number" or level ~= level then
		return 1
	end
	return math.clamp(math.floor(level), 1, WeaponLevelConfig.MAX_LEVEL)
end

--- Nivel (1..MAX_LEVEL) correspondiente a un total de kills con el arma.
function WeaponLevelConfig.GetLevelForKills(kills: number): number
	local k = if type(kills) == "number" and kills == kills then math.max(0, math.floor(kills)) else 0
	local level = 1
	for lvl = 1, WeaponLevelConfig.MAX_LEVEL do
		if k >= THRESHOLDS[lvl] then
			level = lvl
		else
			break
		end
	end
	return level
end

--- Kills ACUMULADAS necesarias para alcanzar `level`.
function WeaponLevelConfig.GetKillsForLevel(level: number): number
	return THRESHOLDS[WeaponLevelConfig.ClampLevel(level)]
end

--[[
	Aplica el escalado de nivel a un valor base de stat.
	  statKey   nombre de la config (p. ej. "HitDamage")
	  baseValue valor configurado en el Tool
	  level     nivel del arma (se clampa)
	Devuelve el valor escalado, o `baseValue` intacto si la clave no escala o el
	valor no es numérico. Las claves en INTEGER_STATS se redondean.
]]
function WeaponLevelConfig.ApplyScaling(statKey: string, baseValue: any, level: number): any
	local factors = MULTIPLIERS[statKey]
	if factors == nil or type(baseValue) ~= "number" then
		return baseValue
	end

	local lvl = WeaponLevelConfig.ClampLevel(level)
	local scaled = baseValue * factors[lvl]

	if INTEGER_STATS[statKey] then
		scaled = math.floor(scaled + 0.5)
	end
	return scaled
end

--[[
	Progreso de nivel para UI. Devuelve una tabla:
	  Level        nivel actual (1..MAX_LEVEL)
	  IsMax        true si ya está al máximo
	  Kills        kills acumuladas
	  KillsInLevel kills hechas dentro del nivel actual
	  KillsToNext  kills que faltan para el siguiente nivel (0 si IsMax)
	  NeededSpan   kills totales que abarca el nivel actual (para barras 0..1)
]]
function WeaponLevelConfig.GetProgress(kills: number): {
	Level: number,
	IsMax: boolean,
	Kills: number,
	KillsInLevel: number,
	KillsToNext: number,
	NeededSpan: number,
}
	local k = if type(kills) == "number" and kills == kills then math.max(0, math.floor(kills)) else 0
	local level = WeaponLevelConfig.GetLevelForKills(k)
	local isMax = level >= WeaponLevelConfig.MAX_LEVEL

	local floor = THRESHOLDS[level]
	if isMax then
		return {
			Level = level,
			IsMax = true,
			Kills = k,
			KillsInLevel = k - floor,
			KillsToNext = 0,
			NeededSpan = 0,
		}
	end

	local ceil = THRESHOLDS[level + 1]
	return {
		Level = level,
		IsMax = false,
		Kills = k,
		KillsInLevel = k - floor,
		KillsToNext = ceil - k,
		NeededSpan = ceil - floor,
	}
end

return table.freeze(WeaponLevelConfig)
