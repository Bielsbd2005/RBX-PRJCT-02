--!strict
--[[
	Stats de combate de cara al jugador para el panel del locker, calculados en
	el cliente desde WeaponsConfig. fireRate en balas/min; damage es BlastDamage
	si el arma explota al impactar. Los rangos del arsenal normalizan barras 0..1.
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
	ammoMax: number,
}

export type WeaponDisplayStats = BaseStats & Ranges

local DisplayStats = {}

-- Un arma sin definición se pinta con los defaults de BulletWeapon, que es lo
-- que usará en partida.
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

	local damageMax, fireRateMax, reloadMin, ammoMax = 1, 1, math.huge, 1
	for category, weapons in WeaponsConfig.GetAll() do
		for weaponId in weapons do
			local stats = DisplayStats.GetBase(category, weaponId)
			damageMax = math.max(damageMax, stats.damage)
			fireRateMax = math.max(fireRateMax, stats.fireRate)
			ammoMax = math.max(ammoMax, stats.ammoCapacity)
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
		ammoMax = ammoMax,
	})
	_ranges = ranges
	return ranges
end

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
		ammoMax = ranges.ammoMax,
	}
end

return table.freeze(DisplayStats)
