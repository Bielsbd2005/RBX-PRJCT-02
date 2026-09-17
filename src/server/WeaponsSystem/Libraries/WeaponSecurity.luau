--!strict
-- Validación server-side barata (sin raycasts): WeaponFired → registerShot,
-- WeaponHit → validateHit (cono + rango + sid/pid registrados).
-- DELIBERADAMENTE sin raycast canónico ni lag compensation: añaden fricción de
-- gameplay sin un threat model real. Ver docs/REFACTORS.md "Anti-cheat de WeaponsSystem".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local WeaponsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("WeaponsConfig"))

local WeaponSecurity = {}

local SHOT_TTL = 3
local MAX_PENDING_PER_PLAYER = 50
-- Sale del esquema para que el chequeo NO sea más estricto que la simulación de BulletWeapon.
local DEFAULT_MAX_RANGE = tonumber(WeaponsConfig.Schema.GetDefault("BulletWeapon", "MaxDistance")) or 2000
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
	maxPid: number,
	usedPids: { [number]: boolean },
}

-- userId → sid → ShotData
local pendingShots: { [number]: { [number]: ShotData } } = {}
local pendingCounts: { [number]: number } = {}

-- ROF: userId → weaponInst → próximo instante permitido. Por arma y no por jugador
-- para que cambiar de arma rápida a lenta no rechace un disparo legítimo.
-- Keys débiles: las Tools de loadout se destruyen en cada respawn.
local WEAK_KEYS = { __mode = "k" }
local nextShotAllowedAt: { [number]: { [Instance]: number } } = {}

local function getOrCreateBucket(userId: number): { [number]: ShotData }
	local bucket = pendingShots[userId]
	if not bucket then
		bucket = {}
		pendingShots[userId] = bucket
		pendingCounts[userId] = 0
	end
	return bucket
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

function WeaponSecurity.ownsWeapon(player: Player, weaponInst: Instance): boolean
	local character = player.Character
	if not character then
		return false
	end
	return weaponInst:IsDescendantOf(character)
end

-- Llamar en WeaponFired tras validar propiedad. false = rechazado.
function WeaponSecurity.registerShot(player: Player, weapon: any, fireInfo: any): boolean
	if typeof(fireInfo) ~= "table" then return false end
	local sid = fireInfo.id
	if typeof(sid) ~= "number" then return false end
	if typeof(fireInfo.origin) ~= "Vector3" or typeof(fireInfo.dir) ~= "Vector3" then return false end
	if fireInfo.dir.Magnitude < 1e-4 then return false end

	local userId = player.UserId
	local now = os.clock()

	-- Origin = posición server-side del tirador, NO fireInfo.origin: un origin pegado a
	-- la víctima pasaría rango/cono y daría falloff máximo. Fallback solo sin HRP.
	local trustedOrigin = fireInfo.origin
	local shooterChar = player.Character
	local shooterRoot = shooterChar and shooterChar:FindFirstChild("HumanoidRootPart")
	if shooterRoot then
		trustedOrigin = (shooterRoot :: BasePart).Position
	end

	local cooldown = 0
	if typeof(weapon) == "table" and typeof(weapon.getConfigValue) == "function" then
		local cd = weapon:getConfigValue("ShotCooldown")
		if typeof(cd) == "number" and cd > 0 then
			cooldown = cd
		end
		-- Dentro de una ráfaga los disparos llegan cada BurstShotCooldown (< ShotCooldown).
		local burstCd = weapon:getConfigValue("BurstShotCooldown")
		if typeof(burstCd) == "number" and burstCd > 0 and burstCd < cooldown then
			cooldown = burstCd
		end
	end
	if cooldown > 0 and typeof(weapon.instance) == "Instance" then
		local byWeapon = nextShotAllowedAt[userId]
		if not byWeapon then
			byWeapon = setmetatable({}, WEAK_KEYS) :: any
			nextShotAllowedAt[userId] = byWeapon
		end
		-- Un disparo puede adelantarse jitterAllowance (red), pero nextAllowed avanza el
		-- cooldown completo, así que la cadencia SOSTENIDA no supera 1/cooldown.
		local jitterAllowance = cooldown * (1 - ROF_TOLERANCE)
		local nextAllowed = byWeapon[weapon.instance]
		if nextAllowed and now < nextAllowed - jitterAllowance then
			return false
		end
		-- Anchor en max(slot, now): llegar pronto no adelanta el schedule, llegar
		-- tarde lo reinicia desde now (sin "bancar" tiempo no usado).
		byWeapon[weapon.instance] = math.max(nextAllowed or 0, now) + cooldown
	end

	local bucket = getOrCreateBucket(userId)

	local count = purgeBucket(bucket, userId, now)
	while count >= MAX_PENDING_PER_PLAYER do
		dropOldest(bucket, userId)
		count -= 1
	end

	local numProjectiles = 1
	if typeof(weapon) == "table" and typeof(weapon.getConfigValue) == "function" then
		local n = weapon:getConfigValue("NumProjectiles")
		if typeof(n) == "number" and n > 0 then
			numProjectiles = math.floor(n)
		end
	end

	local maxRange = DEFAULT_MAX_RANGE
	if typeof(weapon) == "table" and typeof(weapon.getConfigValue) == "function" then
		local r = weapon:getConfigValue("MaxDistance")
		if typeof(r) == "number" and r > 0 then
			maxRange = r
		end
	end

	if not bucket[sid] then
		pendingCounts[userId] = (pendingCounts[userId] or 0) + 1
	end
	bucket[sid] = {
		origin = trustedOrigin,
		dir = fireInfo.dir.Unit,
		time = now,
		weaponInst = weapon.instance,
		hitsRemaining = numProjectiles,
		maxRange = maxRange,
		maxPid = numProjectiles,
		usedPids = {},
	}
	return true
end

-- Retorna (ok, reason).
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

	-- Cada proyectil (pid 1..NumProjectiles) reclama UN solo hit; se marca usado al
	-- final, solo si el hit pasa todas las validaciones.
	local pid = hitInfo.pid
	if typeof(pid) ~= "number" or pid % 1 ~= 0 or pid < 1 or pid > data.maxPid then
		return false, "bad pid"
	end
	if data.usedPids[pid] then
		return false, "pid reused"
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

	-- El punto debe estar cerca del part (bloquea headshots garantizados con un Head arbitrario).
	if typeof(hitInfo.part) ~= "Instance" or not hitInfo.part:IsA("BasePart") then
		return false, "bad part"
	end
	-- Margen por latencia escalado por la velocidad real del part (~250 ms de ping).
	local latencyTolerance = hitInfo.part.AssemblyLinearVelocity.Magnitude * 0.25 + 2
	if (hitInfo.part.Position - hitInfo.p).Magnitude > hitInfo.part.Size.Magnitude + latencyTolerance then
		return false, "part/point mismatch"
	end

	-- applyDamage usa serverOrigin para el falloff en vez de hitInfo.d (falseable por el cliente).
	hitInfo.serverOrigin = data.origin

	data.usedPids[pid] = true
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
		nextShotAllowedAt[uid] = nil
	end)
end

return WeaponSecurity
