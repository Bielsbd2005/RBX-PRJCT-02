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
local SHOT_BANK = 0.1
local MAX_BROADCAST_ORIGIN_OFFSET = 12

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

-- userId → weaponInst → sid → ShotData. Por arma porque cada arma numera sus sid
-- desde 1 (BaseWeapon): con clave solo sid, un disparo de otra arma pisaría el pendiente.
type ShotBucket = { [Instance]: { [number]: ShotData } }
local pendingShots: { [number]: ShotBucket } = {}
local pendingCounts: { [number]: number } = {}

-- ROF: userId → weaponInst → próximo instante permitido. Por arma y no por jugador
-- para que cambiar de arma rápida a lenta no rechace un disparo legítimo.
-- Keys débiles: las Tools de loadout se destruyen en cada respawn.
local WEAK_KEYS = { __mode = "k" }
-- jitter: margen del cooldown con el que se programó nextAt. burstCount/lastAt: balas de
-- la ráfaga en curso (solo FireMode "Burst").
type ShotSchedule = { nextAt: number, jitter: number, burstCount: number, lastAt: number }
local nextShotAllowedAt: { [number]: { [Instance]: ShotSchedule } } = {}

local function getOrCreateBucket(userId: number): ShotBucket
	local bucket = pendingShots[userId]
	if not bucket then
		bucket = {}
		pendingShots[userId] = bucket
		pendingCounts[userId] = 0
	end
	return bucket
end

local function removeShot(bucket: ShotBucket, userId: number, weaponInst: Instance, sid: number)
	local shots = bucket[weaponInst]
	if not shots or not shots[sid] then
		return
	end
	shots[sid] = nil
	if next(shots) == nil then
		bucket[weaponInst] = nil
	end
	pendingCounts[userId] = math.max(0, (pendingCounts[userId] or 1) - 1)
end

local function purgeBucket(bucket: ShotBucket, userId: number, now: number): number
	local count = 0
	for weaponInst, shots in bucket do
		for sid, data in shots do
			if now - data.time > SHOT_TTL then
				shots[sid] = nil
			else
				count += 1
			end
		end
		if next(shots) == nil then
			bucket[weaponInst] = nil
		end
	end
	pendingCounts[userId] = count
	return count
end

local function dropOldest(bucket: ShotBucket, userId: number)
	local oldestInst, oldestSid, oldestTime = nil, nil, math.huge
	for weaponInst, shots in bucket do
		for sid, data in shots do
			if data.time < oldestTime then
				oldestInst = weaponInst
				oldestSid = sid
				oldestTime = data.time
			end
		end
	end
	if oldestInst ~= nil and oldestSid ~= nil then
		removeShot(bucket, userId, oldestInst, oldestSid)
	end
end

function WeaponSecurity.ownsWeapon(player: Player, weaponInst: Instance): boolean
	local character = player.Character
	if not character then
		return false
	end
	return weaponInst:IsDescendantOf(character)
end

-- Para WeaponHit: el proyectil sigue en vuelo tras cambiar de arma y la Tool ya está en
-- el Backpack. validateHit liga el sid a esta Tool, disparada equipada en WeaponFired.
function WeaponSecurity.ownsWeaponForHit(player: Player, weaponInst: Instance): boolean
	return weaponInst:IsDescendantOf(player) or WeaponSecurity.ownsWeapon(player, weaponInst)
end

-- Solo para WeaponFired: en WeaponHit rechazaría las balas legítimas disparadas justo
-- antes de morir (el sid ya prueba que el disparo se registró en vida).
function WeaponSecurity.isShooterAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil
		and humanoid.Health > 0
		and humanoid:GetState() ~= Enum.HumanoidStateType.Dead
end

-- ByteNet transporta NaN e infinitos en Vector3, y NetGuards solo mira números
-- sueltos. Un NaN haría falsa cualquier comparación de rango o cono.
local function isFiniteVector(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	for _, c in { v.X, v.Y, v.Z } do
		if c ~= c or c == math.huge or c == -math.huge then
			return false
		end
	end
	return true
end

-- Copia con solo los campos que consumen onFired y los clientes del broadcast: el
-- payload original se reenvía a todos y no debe llevar nada que el server no haya mirado.
function WeaponSecurity.sanitizeFireInfo(fireInfo: any): { [string]: any }?
	if typeof(fireInfo) ~= "table" then return nil end
	local charge = fireInfo.charge
	return {
		id = fireInfo.id,
		origin = fireInfo.origin,
		dir = fireInfo.dir,
		charge = if typeof(charge) == "number" and charge == charge then math.clamp(charge, 0, 1) else nil,
	}
end

-- Llamar en WeaponFired tras validar propiedad. false = rechazado.
function WeaponSecurity.registerShot(player: Player, weapon: any, fireInfo: any): boolean
	if typeof(fireInfo) ~= "table" then return false end
	local sid = fireInfo.id
	if typeof(sid) ~= "number" then return false end
	if not isFiniteVector(fireInfo.origin) or not isFiniteVector(fireInfo.dir) then return false end
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
		-- fireInfo se reenvía tal cual a los demás clientes (trazador y sonido): un origin
		-- lejos del tirador pintaría balas saliendo de cualquier sitio. Se corrige en vez de
		-- rechazar para no castigar el desfase de red de un cliente que se mueve rápido.
		if (fireInfo.origin - trustedOrigin).Magnitude > MAX_BROADCAST_ORIGIN_OFFSET then
			fireInfo.origin = trustedOrigin
		end
	end

	local shotCooldown = 0
	local burstCooldown: number? = nil
	local burstSize = 1
	if typeof(weapon) == "table" and typeof(weapon.getConfigValue) == "function" then
		local cd = weapon:getConfigValue("ShotCooldown")
		if typeof(cd) == "number" and cd > 0 then
			shotCooldown = cd
		end
		if weapon:getConfigValue("FireMode") == "Burst" then
			local burstCd = weapon:getConfigValue("BurstShotCooldown")
			local size = weapon:getConfigValue("NumBurstShots")
			if typeof(burstCd) == "number" and burstCd > 0 and typeof(size) == "number" and size > 1 then
				burstCooldown = burstCd
				burstSize = math.floor(size)
			end
		end
	end
	if shotCooldown > 0 and typeof(weapon.instance) == "Instance" then
		local byWeapon = nextShotAllowedAt[userId]
		if not byWeapon then
			byWeapon = setmetatable({}, WEAK_KEYS) :: any
			nextShotAllowedAt[userId] = byWeapon
		end
		-- Un disparo puede adelantarse `jitter` (red), pero nextAt avanza el cooldown
		-- completo, así que la cadencia SOSTENIDA no supera 1/cooldown.
		local schedule = byWeapon[weapon.instance]
		if schedule and now < schedule.nextAt - schedule.jitter then
			return false
		end

		-- Ráfaga: las primeras NumBurstShots-1 balas esperan BurstShotCooldown y la última
		-- la pausa completa, como BulletWeapon:onFired. Un hueco de casi ShotCooldown abre
		-- ráfaga nueva: una cortada por munición o recarga no descuadra al cliente honesto.
		local burstCount = 0
		if schedule and now - schedule.lastAt < shotCooldown * ROF_TOLERANCE then
			burstCount = schedule.burstCount
		end
		burstCount += 1
		local cooldown = shotCooldown
		if burstCooldown and burstCount < burstSize then
			cooldown = burstCooldown
		else
			burstCount = 0
		end

		-- Anchor en max(slot, now - SHOT_BANK): anclar en now haría que un paquete tardío
		-- adelante el calendario y el siguiente, llegado a su hora, se rechace (con la UZI
		-- el margen es menor que un frame). SHOT_BANK acota lo que se puede "bancar".
		local base = if schedule then math.max(schedule.nextAt, now - SHOT_BANK) else now
		byWeapon[weapon.instance] = {
			nextAt = base + cooldown,
			jitter = cooldown * (1 - ROF_TOLERANCE),
			burstCount = burstCount,
			lastAt = now,
		}
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

	local shots = bucket[weapon.instance]
	if not shots then
		shots = {}
		bucket[weapon.instance] = shots
	end
	if not shots[sid] then
		pendingCounts[userId] = (pendingCounts[userId] or 0) + 1
	end
	shots[sid] = {
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
	if not isFiniteVector(hitInfo.p) then return false, "no hit point" end

	local uid = player.UserId
	local bucket = pendingShots[uid]
	if not bucket then return false, "no shots" end

	local weaponInst = weapon.instance
	local shots = bucket[weaponInst]
	local data = shots and shots[sid]
	if not data then return false, "unknown sid" end

	if os.clock() - data.time > SHOT_TTL then
		removeShot(bucket, uid, weaponInst, sid)
		return false, "expired"
	end

	if data.hitsRemaining <= 0 then
		removeShot(bucket, uid, weaponInst, sid)
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
	-- La normal no se puede comprobar sin raycast, pero sí acotar: la explosión y la
	-- FireZone se colocan con ella y una normal enorme las movería lejos del punto validado.
	local n = hitInfo.n
	hitInfo.n = if typeof(n) == "Vector3" and n.Magnitude > 0.5 and n.Magnitude < 1.5 then n.Unit else Vector3.yAxis

	data.usedPids[pid] = true
	data.hitsRemaining -= 1
	if data.hitsRemaining <= 0 then
		removeShot(bucket, uid, weaponInst, sid)
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
