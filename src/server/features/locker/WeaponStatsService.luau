--!strict
--[[
	WeaponStatsService.luau (Server)
	Responde a Network.WeaponStats.Request con los stats de combate del arma
	pedida. Esos valores viven en la Configuration del Tool real en
	ServerStorage.WeaponTools.<categoría>.<weaponId> — que NO se replica al
	cliente — por eso el locker los pide y este service los lee y devuelve.

	Qué se devuelve (valores BASE, nivel 1):
	  • damage       — daño efectivo: BlastDamage si el arma explota al impacto
	                   (RPG), si no HitDamage.
	  • fireRate     — balas por minuto = 60 / ShotCooldown.
	  • reloadTime   — segundos de recarga (ReloadTime).
	  • ammoCapacity — tamaño del cargador (AmmoCapacity).
	Más rangos del arsenal entero (damageMax / fireRateMax / reloadMin) para que
	el cliente normalice las barras 0..1 sin números mágicos.

	El escalado por nivel (WeaponLevelConfig) lo aplica el CLIENTE: es config
	pública compartida y el cliente ya tiene sus WeaponKills, así no hace falta
	un round-trip por cada subida de nivel.

	Seguridad: handler read-only e idempotente (sólo lee config y hace echo de
	números). Payload tipado/cap-eado vía NetGuards. Rate-limit ligero como
	defensa anti-spam del SendTo; el cliente cachea por arma + debounce, así que
	el tráfico legítimo es ~1 request por arma y nunca lo toca.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network   = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local ItemsConfig = require(Shared.constants.ItemsConfig)
local WeaponCategory = require(Shared.constants.WeaponCategory)

local M = NetGuards.MAX

local WEAPON_TOOLS_ROOT_NAME = "WeaponTools"
local RATE_LIMIT_SECONDS = 0.05

-- Defaults espejo de los de BaseWeapon:getConfigValue, por si un Tool no trae
-- alguna Value en su Configuration (o no existe el Tool).
local DEFAULTS = {
	HitDamage = 10,
	BlastDamage = 100,
	ShotCooldown = 0.1,
	ReloadTime = 2,
	AmmoCapacity = 30,
	ExplodeOnImpact = false,
}

type WeaponStats = {
	damage: number,
	fireRate: number,
	reloadTime: number,
	ammoCapacity: number,
}

type Ranges = {
	damageMax: number,
	fireRateMax: number,
	reloadMin: number,
}

local WeaponStatsService = {}

-- Estado del módulo
local _started = false
local _lastRequestAt: { [number]: number } = {}
-- Cache construido perezosamente: [category][weaponId] = WeaponStats.
local _statsCache: { [string]: { [string]: WeaponStats } } = {}
local _ranges: Ranges? = nil

-- ── Lectura de Tools ─────────────────────────────────────────

local function _getWeaponToolsRoot(): Folder?
	local root = ServerStorage:FindFirstChild(WEAPON_TOOLS_ROOT_NAME)
	if root and root:IsA("Folder") then
		return root
	end
	return nil
end

-- Resuelve el Tool: ruta canónica WeaponTools.<categoría>.<weaponId> y, como en
-- el README/LoadoutService, fallback a WeaponTools.<weaponId> directo.
local function _findWeaponTool(category: string, weaponId: string): Tool?
	if weaponId == "" then
		return nil
	end

	local root = _getWeaponToolsRoot()
	if not root then
		return nil
	end

	local byCategory = root:FindFirstChild(category)
	if byCategory then
		local direct = byCategory:FindFirstChild(weaponId)
		if direct and direct:IsA("Tool") then
			return direct
		end
	end

	local fallback = root:FindFirstChild(weaponId)
	if fallback and fallback:IsA("Tool") then
		return fallback
	end

	return nil
end

-- Lee los Value de la Configuration del Tool a una tabla nombre→valor.
local function _readConfigValues(tool: Tool): { [string]: any }
	local values: { [string]: any } = {}
	local config = tool:FindFirstChildOfClass("Configuration")
	if config then
		for _, child in config:GetChildren() do
			if child:IsA("ValueBase") then
				values[child.Name] = (child :: any).Value
			end
		end
	end
	return values
end

local function _num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- Convierte la Configuration de un Tool (o defaults) a los 4 stats mostrados.
local function _computeStats(tool: Tool?): WeaponStats
	local cfg = if tool then _readConfigValues(tool) else {}

	local explodes = cfg.ExplodeOnImpact == true
	local damage = if explodes
		then _num(cfg.BlastDamage, DEFAULTS.BlastDamage)
		else _num(cfg.HitDamage, DEFAULTS.HitDamage)

	-- ShotCooldown 0/negativo no tiene sentido físico; clamp para no dividir por
	-- cero al pasar a balas/min.
	local shotCooldown = math.max(_num(cfg.ShotCooldown, DEFAULTS.ShotCooldown), 1 / 10000)
	local fireRate = math.floor(60 / shotCooldown + 0.5)

	local reloadTime = math.max(_num(cfg.ReloadTime, DEFAULTS.ReloadTime), 0)
	local ammoCapacity = math.max(math.floor(_num(cfg.AmmoCapacity, DEFAULTS.AmmoCapacity) + 0.5), 0)

	return {
		damage = damage,
		fireRate = fireRate,
		reloadTime = reloadTime,
		ammoCapacity = ammoCapacity,
	}
end

-- Construye el cache de stats por arma + los rangos del arsenal. Se hace una
-- sola vez (perezoso): para entonces los Tools de ServerStorage ya cargaron.
local function _ensureBuilt()
	if _ranges ~= nil then
		return
	end

	local damageMax, fireRateMax, reloadMin = 1, 1, math.huge

	for _, category in WeaponCategory.ALL do
		local categoryItems = (ItemsConfig :: any)[category]
		if type(categoryItems) ~= "table" then
			continue
		end
		local categoryCache: { [string]: WeaponStats } = {}
		_statsCache[category] = categoryCache

		for weaponId in categoryItems do
			local stats = _computeStats(_findWeaponTool(category, weaponId))
			categoryCache[weaponId] = stats
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

	_ranges = {
		damageMax = damageMax,
		fireRateMax = fireRateMax,
		reloadMin = reloadMin,
	}
end

-- Stats de un arma concreta: del cache si está, si no se calcula al vuelo
-- (resuelve el Tool ahora) para tolerar armas no listadas en ItemsConfig.
local function _getStats(category: string, weaponId: string): WeaponStats
	local categoryCache = _statsCache[category]
	local cached = categoryCache and categoryCache[weaponId]
	if cached then
		return cached
	end

	local stats = _computeStats(_findWeaponTool(category, weaponId))
	if categoryCache then
		categoryCache[weaponId] = stats
	end
	return stats
end

-- ── Handler ──────────────────────────────────────────────────

local function _onRequest(data: { weaponCategory: string, weaponId: string }, player: Player): ()
	if not NetGuards.validate(data, {
		weaponCategory = M.Category,
		weaponId       = M.Id,
	}) or not WeaponCategory.isValid(data.weaponCategory) or data.weaponId == "" then
		Network.WeaponStats.Response.SendTo({
			weaponCategory = if type(data) == "table" and type(data.weaponCategory) == "string" then data.weaponCategory else "",
			weaponId = if type(data) == "table" and type(data.weaponId) == "string" then data.weaponId else "",
			success = false,
			damage = 0, fireRate = 0, reloadTime = 0, ammoCapacity = 0,
			damageMax = 1, fireRateMax = 1, reloadMin = 1,
		}, player)
		return
	end

	-- Rate-limit defensivo (anti-spam del SendTo). El cliente cachea + debounce,
	-- así que el tráfico legítimo (≥0.06s entre selecciones) nunca cae aquí.
	local last = _lastRequestAt[player.UserId] or 0
	if time() - last < RATE_LIMIT_SECONDS then
		return
	end
	_lastRequestAt[player.UserId] = time()

	_ensureBuilt()
	local ranges = _ranges :: Ranges
	local stats = _getStats(data.weaponCategory, data.weaponId)

	Network.WeaponStats.Response.SendTo({
		weaponCategory = data.weaponCategory,
		weaponId = data.weaponId,
		success = true,
		damage = stats.damage,
		fireRate = stats.fireRate,
		reloadTime = stats.reloadTime,
		ammoCapacity = stats.ammoCapacity,
		damageMax = ranges.damageMax,
		fireRateMax = ranges.fireRateMax,
		reloadMin = ranges.reloadMin,
	}, player)
end

-- ── Módulo ───────────────────────────────────────────────────

function WeaponStatsService:Start(): ()
	if _started then
		return
	end
	_started = true

	Players.PlayerRemoving:Connect(function(player: Player)
		_lastRequestAt[player.UserId] = nil
	end)

	Network.WeaponStats.Request.Listen(_onRequest)
end

return WeaponStatsService
