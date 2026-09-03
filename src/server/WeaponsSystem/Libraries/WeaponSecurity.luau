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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local WeaponsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("WeaponsConfig"))

local WeaponSecurity = {}

local SHOT_TTL = 3
local MAX_PENDING_PER_PLAYER = 50
-- Alcance asumido para un arma que no expone su config. Sale del esquema para
-- que el chequeo NO sea más estricto que la simulación: con 1500 a mano aquí y
-- 2000 en BulletWeapon, un disparo legítimo a esa distancia se descartaba.
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

-- ROF: userId → weaponInst → próximo instante permitido (leaky bucket).
-- Antes era un único timestamp por jugador comparado contra el cooldown del
-- arma ACTUAL: cambiar de un arma rápida a una lenta rechazaba el primer
-- disparo legítimo (ghost shot), y la tolerancia por-disparo permitía +25%
-- de DPS sostenido disparando siempre a 0.8×cooldown.
-- Keys débiles en la tabla interna: las Tools de loadout se destruyen en cada
-- respawn y no queremos pinnearlas hasta PlayerRemoving.
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

	-- S1: el origin del disparo es la posición server-side del tirador, NO
	-- fireInfo.origin (dato del cliente). Sin esto un cliente podía enviar un
	-- origin pegado a la víctima → en validateHit dist≈0 (pasa rango y cono) y
	-- en applyDamage travelDistance≈0 → falloff=1 (daño máximo) a rango
	-- ilimitado. Este origin alimenta tanto los checks de validateHit como
	-- hitInfo.serverOrigin. Fallback a fireInfo.origin solo si el tirador no
	-- tiene HRP server-side (char despawneando / armas montadas/NPC).
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
		-- Burst: dentro de una ráfaga los disparos legítimos llegan cada
		-- BurstShotCooldown (< ShotCooldown). Enforcear el intervalo mínimo
		-- real evita rechazar los disparos 2..N de la ráfaga.
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
		-- Un disparo puede adelantarse hasta jitterAllowance a su slot (jitter
		-- de red), pero nextAllowed avanza el cooldown completo por disparo,
		-- así que la cadencia SOSTENIDA no puede superar 1/cooldown — antes la
		-- tolerancia se regalaba entera en cada disparo.
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

	-- Purga por TTL en cada disparo (bucket acotado a MAX_PENDING, ~O(50)): antes
	-- las entradas vencidas solo se eliminaban al tocar el cap, así que un jugador
	-- que disparaba bajo el límite y nunca reportaba hits las retenía hasta el
	-- siguiente disparo que llenara el bucket.
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

	-- S2: cada proyectil (pid 1..NumProjectiles) puede reclamar UN solo hit.
	-- Sin esto un cliente podía repetir el mismo pid (o inventar pids) hasta
	-- agotar hitsRemaining con hits duplicados del mismo pellet. El pid se
	-- marca como usado al final, solo si el hit pasa todas las validaciones.
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

	-- S1: validar que el part reportado es real y que el punto de impacto
	-- está físicamente cerca del part (bloquea hitInfo.part arbitrario /
	-- guaranteed-headshot enviando un Head que no fue golpeado).
	if typeof(hitInfo.part) ~= "Instance" or not hitInfo.part:IsA("BasePart") then
		return false, "bad part"
	end
	-- Tolerancia part/punto: margen por latencia (el part puede haberse movido
	-- entre el hit del cliente y esta validación) escalado por la velocidad
	-- real del part, en vez del +5 fijo de antes — generoso para parts pequeños
	-- y estáticos (una Head admitía p a ~7 studs del centro). Un target a
	-- sprint (32 studs/s) con 250ms de ping conserva ~10 studs de margen.
	-- Nota: esto endurece la consistencia interna del payload; la verificación
	-- real de trayectoria (raycast/lag comp) sigue deferida — ver header.
	local latencyTolerance = hitInfo.part.AssemblyLinearVelocity.Magnitude * 0.25 + 2
	if (hitInfo.part.Position - hitInfo.p).Magnitude > hitInfo.part.Size.Magnitude + latencyTolerance then
		return false, "part/point mismatch"
	end

	-- S1: exponer el origin server-trusted del disparo registrado para que
	-- applyDamage recompute la distancia de falloff en vez de confiar en
	-- hitInfo.d (que el cliente puede falsear a 0 para max damage).
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
