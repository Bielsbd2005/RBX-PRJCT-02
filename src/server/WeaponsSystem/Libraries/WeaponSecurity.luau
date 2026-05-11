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

local function getOrCreateBucket(userId: number): { [number]: ShotData }
	local bucket = pendingShots[userId]
	if not bucket then
		bucket = {}
		pendingShots[userId] = bucket
	end
	return bucket
end

local function purgeBucket(bucket: { [number]: ShotData }, now: number): number
	local count = 0
	for sid, data in bucket do
		if now - data.time > SHOT_TTL then
			bucket[sid] = nil
		else
			count += 1
		end
	end
	return count
end

local function dropOldest(bucket: { [number]: ShotData })
	local oldestSid, oldestTime = nil, math.huge
	for sid, data in bucket do
		if data.time < oldestTime then
			oldestSid = sid
			oldestTime = data.time
		end
	end
	if oldestSid ~= nil then
		bucket[oldestSid] = nil
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
function WeaponSecurity.registerShot(player: Player, weapon: any, fireInfo: any)
	if typeof(fireInfo) ~= "table" then return end
	local sid = fireInfo.id
	if typeof(sid) ~= "number" then return end
	if typeof(fireInfo.origin) ~= "Vector3" or typeof(fireInfo.dir) ~= "Vector3" then return end
	if fireInfo.dir.Magnitude < 1e-4 then return end

	local bucket = getOrCreateBucket(player.UserId)
	local now = os.clock()

	-- Si el bucket está lleno, purgamos expirados; si sigue lleno, sacamos el más viejo.
	local count = 0
	for _ in bucket do count += 1 end
	if count >= MAX_PENDING_PER_PLAYER then
		count = purgeBucket(bucket, now)
		while count >= MAX_PENDING_PER_PLAYER do
			dropOldest(bucket)
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

	bucket[sid] = {
		origin = fireInfo.origin,
		dir = fireInfo.dir.Unit,
		time = now,
		weaponInst = weapon.instance,
		hitsRemaining = numProjectiles,
		maxRange = maxRange,
	}
end

-- Valida un hit reportado por el cliente. Retorna (ok, reason).
function WeaponSecurity.validateHit(player: Player, weapon: any, hitInfo: any): (boolean, string?)
	if typeof(hitInfo) ~= "table" then return false, "bad payload" end
	local sid = hitInfo.sid
	if typeof(sid) ~= "number" then return false, "no sid" end
	if typeof(hitInfo.p) ~= "Vector3" then return false, "no hit point" end

	local bucket = pendingShots[player.UserId]
	if not bucket then return false, "no shots" end

	local data = bucket[sid]
	if not data then return false, "unknown sid" end

	if os.clock() - data.time > SHOT_TTL then
		bucket[sid] = nil
		return false, "expired"
	end

	if data.weaponInst ~= weapon.instance then
		return false, "weapon mismatch"
	end

	if data.hitsRemaining <= 0 then
		bucket[sid] = nil
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
	end

	return true
end

-- Limpieza al salir el jugador.
if RunService:IsServer() then
	Players.PlayerRemoving:Connect(function(player)
		pendingShots[player.UserId] = nil
	end)
end

return WeaponSecurity
