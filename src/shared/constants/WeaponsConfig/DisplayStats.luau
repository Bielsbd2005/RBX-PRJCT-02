--!strict
--[[
	WeaponsConfig/DisplayStats.luau
	Stats de combate "de cara al jugador" derivados de WeaponsConfig, para el
	panel de stats del locker. Sustituye al antiguo WeaponStatsService + el
	namespace Network.WeaponStats: al vivir la config en Shared, el cliente
	calcula esto en local sin round-trip.

	Valores BASE (nivel 1). El escalado por nivel (WeaponLevelConfig) lo aplica
	quien pinta, con las kills del jugador.

	  • damage       — BlastDamage si el arma explota al impactar, si no HitDamage.
	  • fireRate     — balas por minuto = 60 / ShotCooldown.
	  • reloadTime   — segundos de recarga.
	  • ammoCapacity — tamaño del cargador.
	Más los rangos del arsenal (damageMax / fireRateMax / reloadMin) para
	normalizar barras 0..1 sin números mágicos.
]]

local WeaponsConfig = require(script.Parent)

export type BaseStats = {
	damage: number,
	fireRate: number,
	reloadTime: number,
	ammoCapacity: number,
}

export type Ranges = {
	damageMax: number,
	fireRateMax: number,
	reloadMin: number,
}

export type WeaponDisplayStats = BaseStats & Ranges

local DisplayStats = {}

-- Un arma sin definición (Tool sin migrar, id inexistente) se pinta con los
-- defaults del esquema de BulletWeapon: mismo comportamiento que tendrá en
-- partida vía los defaults de BaseWeapon/BulletWeapon.
local FALLBACK_WEAPON_TYPE = "BulletWeapon"

local _statsCache: { [string]: BaseStats } = {}
local _ranges: Ranges? = nil

local function cacheKey(category: string, weaponId: string): string
	return category .. "|" .. weaponId
end

local function valueOrDefault(category: string, weaponId: string, keyName: string): any
	local value = WeaponsConfig.GetValue(category, weaponId, keyName)
	if value == nil then
		value = WeaponsConfig.Schema.GetDefault(FALLBACK_WEAPON_TYPE, keyName)
	end
	return value
end

local function num(value: any, fallback: number): number
	return if type(value) == "number" and value == value then value else fallback
end

local function computeStats(category: string, weaponId: string): BaseStats
	local explodes = valueOrDefault(category, weaponId, "ExplodeOnImpact") == true
	local damage = if explodes
		then num(valueOrDefault(category, weaponId, "BlastDamage"), 0)
		else num(valueOrDefault(category, weaponId, "HitDamage"), 0)

	-- ShotCooldown 0/negativo no tiene sentido físico; clamp para no dividir
	-- por cero al pasar a balas/min.
	local shotCooldown = math.max(num(valueOrDefault(category, weaponId, "ShotCooldown"), 0.1), 1 / 10000)
	local fireRate = math.floor(60 / shotCooldown + 0.5)

	local reloadTime = math.max(num(valueOrDefault(category, weaponId, "ReloadTime"), 0), 0)
	local ammoCapacity = math.max(math.floor(num(valueOrDefault(category, weaponId, "AmmoCapacity"), 0) + 0.5), 0)

	return {
		damage = damage,
		fireRate = fireRate,
		reloadTime = reloadTime,
		ammoCapacity = ammoCapacity,
	}
end

--- Stats base de un arma (cacheados: la config es estática).
function DisplayStats.GetBase(category: string, weaponId: string): BaseStats
	local key = cacheKey(category, weaponId)
	local cached = _statsCache[key]
	if cached then
		return cached
	end
	local stats = table.freeze(computeStats(category, weaponId))
	_statsCache[key] = stats
	return stats
end

--- Rangos del arsenal entero (todas las definiciones registradas). Cacheado.
function DisplayStats.GetRanges(): Ranges
	if _ranges then
		return _ranges
	end

	local damageMax, fireRateMax, reloadMin = 1, 1, math.huge
	for category, weapons in WeaponsConfig.GetAll() do
		for weaponId in weapons do
			local stats = DisplayStats.GetBase(category, weaponId)
			damageMax = math.max(damageMax, stats.damage)
			fireRateMax = math.max(fireRateMax, stats.fireRate)
			if stats.reloadTime > 0 then
				reloadMin = math.min(reloadMin, stats.reloadTime)
			end
		end
	end
	if reloadMin == math.huge then
		reloadMin = 1
	end

	local ranges: Ranges = table.freeze({
		damageMax = damageMax,
		fireRateMax = fireRateMax,
		reloadMin = reloadMin,
	})
	_ranges = ranges
	return ranges
end

--- Stats base + rangos, la forma que consume el panel del locker.
function DisplayStats.Get(category: string, weaponId: string): WeaponDisplayStats
	local base = DisplayStats.GetBase(category, weaponId)
	local ranges = DisplayStats.GetRanges()
	return {
		damage = base.damage,
		fireRate = base.fireRate,
		reloadTime = base.reloadTime,
		ammoCapacity = base.ammoCapacity,
		damageMax = ranges.damageMax,
		fireRateMax = ranges.fireRateMax,
		reloadMin = ranges.reloadMin,
	}
end

return table.freeze(DisplayStats)
