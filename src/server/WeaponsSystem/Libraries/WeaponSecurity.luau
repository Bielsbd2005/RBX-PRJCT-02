--!strict
-- WeaponSecurity: validación server-side de hits y propiedad de armas.
-- Diseñado para móvil — todas las operaciones son O(1) o O(N) con N pequeño;
-- no hace raycasts extra ni iteraciones masivas.
--
-- Flujo:
--   server recibe WeaponFired → registerShot(player, weapon, fireInfo)
--   server recibe WeaponHit   → validateHit(player, weapon, hitInfo)
--                                 (true, _) → aplicar daño
--                                 (false, reason) → descartar
--
-- Validación: cone (dot del dir esperado vs el del hit) + range (distancia
-- desde origin hasta hitInfo.p ≤ MaxDistance + tolerancia). Esto bloquea
-- exploits triviales (auto-aim genérico, hits a >maxRange, hits con sid no
-- registrado) que cubren la gran mayoría de cheaters casuales.
--
-- DELIBERADAMENTE NO incluye:
--   • Server-side raycast canónico (anti-wallhack/headshot bypass).
--   • Rate-limit de ROF server-side.
--   • Lag compensation.
-- Esos refactors están planificados en docs/REFACTORS.md "Anti-cheat AAA".
-- Se implementarán cuando aparezcan reportes de exploit en producción —
-- añadirlos antes de tener un threat model real introduce friction de
-- gameplay (ver Sprint 1 commit + revert) sin beneficio comprobado.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local WeaponSecurity = {}

local SHOT_TTL = 3
local MAX_PENDING_PER_PLAYER = 50
local DEFAULT_MAX_RANGE = 1500
local RANGE_TOLERANCE = 50
local MIN_DIR_DOT = 0.5
local MIN_DIR_CHECK_DIST = 5
local ROF_TOLERANCE = 0.8

type ShotData = {
	origin: Vector3,
	dir: Vector3,
	time: number,
	weaponInst: Instance,
	hitsRemaining: number,
	maxRange: number,
}

-- userId → sid → ShotData
local pendingShots: { [number]: { [number]: ShotData } } = {}
local pendingCounts: { [number]: number } = {}
local lastShotTime: { [number]: number } = {}
local lastShotCooldown: { [number]: number } = {}

local function getOrCreateBucket(userId: number): { [number]: ShotData }
	local bucket = pendingShots[userId]
	if not bucket then
		bucket = {}
		pendingShots[userId] = bucket
		pendingCounts[userId] = 0
	end
	return bucket
end

local function getBucketCount(userId: number): number
	return pendingCounts[userId] or 0
end

local function purgeBucket(bucket: { [number]: ShotData }, userId: number, now: number): number
	local count = 0
	for sid, data in bucket do
		if now - data.time > SHOT_TTL then
			bucket[sid] = nil
		else
			count += 1
		end
	end
	pendingCounts[userId] = count
	return count
end

local function dropOldest(bucket: { [number]: ShotData }, userId: number)
	local oldestSid, oldestTime = nil, math.huge
	for sid, data in bucket do
		if data.time < oldestTime then
			oldestSid = sid
			oldestTime = data.time
		end
	end
	if oldestSid ~= nil then
		bucket[oldestSid] = nil
		pendingCounts[userId] = math.max(0, (pendingCounts[userId] or 1) - 1)
	end
end

-- Verifica que el arma está en el Character del jugador.
function WeaponSecurity.ownsWeapon(player: Player, weaponInst: Instance): boolean
	local character = player.Character
	if not character then
		return false
	end
	return weaponInst:IsDescendantOf(character)
end

-- Registra un disparo válido. Llamar en WeaponFired tras validar propiedad.
-- Retorna false si el disparo es rechazado por ROF.
function WeaponSecurity.registerShot(player: Player, weapon: any, fireInfo: any): boolean
	if typeof(fireInfo) ~= "table" then return false end
	local sid = fireInfo.id
	if typeof(sid) ~= "number" then return false end
	if typeof(fireInfo.origin) ~= "Vector3" or typeof(fireInfo.dir) ~= "Vector3" then return false end
	if fireInfo.dir.Magnitude < 1e-4 then return false end

	local userId = player.UserId
	local now = os.clock()

	local cooldown = 0
	if typeof(weapon) == "table" and typeof(weapon.getConfigValue) == "function" then
		local cd = weapon:getConfigValue("ShotCooldown", 0.1)
		if typeof(cd) == "number" and cd > 0 then
			cooldown = cd
		end
	end
	local prev = lastShotTime[userId]
	if prev and cooldown > 0 and (now - prev) < cooldown * ROF_TOLERANCE then
		return false
	end
	lastShotTime[userId] = now
	lastShotCooldown[userId] = cooldown

	local bucket = getOrCreateBucket(userId)

	local count = getBucketCount(userId)
	if count >= MAX_PENDING_PER_PLAYER then
		count = purgeBucket(bucket, userId, now)
		while count >= MAX_PENDING_PER_PLAYER do
			dropOldest(bucket, userId)
			count -= 1
		end
	end

	local numProjectiles = 1
	if typeof(weapon) == "table" and typeof(weapon.getConfigValue) == "function" then
		local n = weapon:getConfigValue("NumProjectiles", 1)
		if typeof(n) == "number" and n > 0 then
			numProjectiles = math.floor(n)
		end
	end

	local maxRange = DEFAULT_MAX_RANGE
	if typeof(weapon) == "table" and typeof(weapon.getConfigValue) == "function" then
		local r = weapon:getConfigValue("MaxDistance", DEFAULT_MAX_RANGE)
		if typeof(r) == "number" and r > 0 then
			maxRange = r
		end
	end

	if not bucket[sid] then
		pendingCounts[userId] = (pendingCounts[userId] or 0) + 1
	end
	bucket[sid] = {
		origin = fireInfo.origin,
		dir = fireInfo.dir.Unit,
		time = now,
		weaponInst = weapon.instance,
		hitsRemaining = numProjectiles,
		maxRange = maxRange,
	}
	return true
end

-- Valida un hit reportado por el cliente. Retorna (ok, reason).
function WeaponSecurity.validateHit(player: Player, weapon: any, hitInfo: any): (boolean, string?)
	if typeof(hitInfo) ~= "table" then return false, "bad payload" end
	local sid = hitInfo.sid
	if typeof(sid) ~= "number" then return false, "no sid" end
	if typeof(hitInfo.p) ~= "Vector3" then return false, "no hit point" end

	local uid = player.UserId
	local bucket = pendingShots[uid]
	if not bucket then return false, "no shots" end

	local data = bucket[sid]
	if not data then return false, "unknown sid" end

	if os.clock() - data.time > SHOT_TTL then
		bucket[sid] = nil
		pendingCounts[uid] = math.max(0, (pendingCounts[uid] or 1) - 1)
		return false, "expired"
	end

	if data.weaponInst ~= weapon.instance then
		return false, "weapon mismatch"
	end

	if data.hitsRemaining <= 0 then
		bucket[sid] = nil
		pendingCounts[uid] = math.max(0, (pendingCounts[uid] or 1) - 1)
		return false, "no hits remaining"
	end

	local toHit = hitInfo.p - data.origin
	local dist = toHit.Magnitude
	if dist > data.maxRange + RANGE_TOLERANCE then
		return false, "out of range"
	end

	if dist > MIN_DIR_CHECK_DIST then
		local dot = data.dir:Dot(toHit / dist)
		if dot < MIN_DIR_DOT then
			return false, "off-axis"
		end
	end

	data.hitsRemaining -= 1
	if data.hitsRemaining <= 0 then
		bucket[sid] = nil
		pendingCounts[uid] = math.max(0, (pendingCounts[uid] or 1) - 1)
	end

	return true
end

if RunService:IsServer() then
	Players.PlayerRemoving:Connect(function(player)
		local uid = player.UserId
		pendingShots[uid] = nil
		pendingCounts[uid] = nil
		lastShotTime[uid] = nil
		lastShotCooldown[uid] = nil
	end)
end

return WeaponSecurity
