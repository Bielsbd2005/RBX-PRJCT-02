--!strict
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local AudioRuntime = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("AudioRuntime")
)
local IsServer = RunService:IsServer()
local LocalPlayer = (not IsServer) and Players.LocalPlayer or nil

local HealthBarController = nil
local StreakDisplay = nil

if not IsServer then
	HealthBarController = require(script.Parent:WaitForChild("Libraries"):WaitForChild("HealthBarController"))
	StreakDisplay = require(script.Parent:WaitForChild("Libraries"):WaitForChild("StreakDisplay"))

	-- Al morir, sin esperar al respawn.
	local function _hookCharacterForStreak(character: Model)
		task.spawn(function()
			local humanoid = character:FindFirstChildOfClass("Humanoid")
				or character:WaitForChild("Humanoid", 10) :: Humanoid?
			if humanoid then
				humanoid.Died:Connect(function()
					StreakDisplay.reset()
				end)
			end
		end)
	end

	LocalPlayer.CharacterAdded:Connect(function(character)
		HealthBarController.onCharacterAdded(character)
		StreakDisplay.reset()
		_hookCharacterForStreak(character)
	end)

	if LocalPlayer.Character then
		task.spawn(HealthBarController.onCharacterAdded, LocalPlayer.Character)
		_hookCharacterForStreak(LocalPlayer.Character)
	end
end

local WeaponSecurity = nil
if IsServer then
	WeaponSecurity = require(script.Parent:WaitForChild("Libraries"):WaitForChild("WeaponSecurity"))
end

-- Template en Studio: SoundService.Audio.Gameplay.Elimination (docs/AUDIO.md).
local _elimSoundPool: { Sound } = {}
local _ELIM_POOL_SIZE = 3
local _warnedMissingElim = false

local function _playEliminationSound()
	local audio = SoundService:FindFirstChild("Audio")
	local gameplay = audio and audio:FindFirstChild("Gameplay")
	local template = AudioRuntime.findSound(gameplay, "Elimination")
	if not template then
		if not _warnedMissingElim then
			_warnedMissingElim = true
			warn("WeaponsSystem: falta SoundService.Audio.Gameplay.Elimination — ejecuta tools/audio/SetupSoundService.luau")
		end
		return
	end

	for _, s in _elimSoundPool do
		if not s.IsPlaying then
			s:Play()
			return
		end
	end

	if #_elimSoundPool < _ELIM_POOL_SIZE then
		local s = AudioRuntime.clone(template)
		table.insert(_elimSoundPool, s)
		s:Play()
	end
end

local _personalKillFeed = nil
local _pickupDropEffect = nil

local function _getPersonalKillFeed()
	if not _personalKillFeed then
		local lib = script.Parent:FindFirstChild("Libraries")
		local mod = lib and lib:FindFirstChild("PersonalKillFeed")
		if mod then _personalKillFeed = require(mod) end
	end
	return _personalKillFeed
end

local function _getPickupDropEffect()
	if not _pickupDropEffect then
		local lib = script.Parent:FindFirstChild("Libraries")
		local mod = lib and lib:FindFirstChild("PickupDropEffect")
		if mod then _pickupDropEffect = require(mod) end
	end
	return _pickupDropEffect
end

-- Desfase tolerado entre el fin de recarga del cliente y el del servidor: jitter y un
-- par de frames (la latencia de subida se cancela, ambos cuentan ReloadTime).
local RELOAD_EARLY_TOLERANCE = 0.15
local RELOAD_REQUEST_MIN_INTERVAL = 0.25

local NetworkingCallbacks = {}
NetworkingCallbacks.WeaponsSystem = nil

function NetworkingCallbacks.WeaponFired(player, instance, fireInfo)
	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem
	if not WeaponsSystem then
		return
	end

	local weapon = WeaponsSystem.getWeaponForInstance(instance)
	local weaponType = getmetatable(weapon)

	if weapon and weaponType then
		if weapon.instance == instance and weaponType.CanBeFired and weapon.player == player then
			if IsServer and WeaponSecurity then
				if not WeaponSecurity.ownsWeapon(player, instance) then
					return
				end
				-- Tras morir, la otra arma del loadout sigue en el Backpack y un cliente
				-- modificado puede meterla en el cadáver.
				if not WeaponSecurity.isShooterAlive(player) then
					return
				end
				-- El cliente honesto no dispara recargando (BaseWeapon:fire); al terminar la
				-- recarga el server rellenaría lo gastado durante ella.
				weapon:completeReloadIfDue(RELOAD_EARLY_TOLERANCE)
				if weapon.reloading then
					return
				end
				local currentAmmo = instance:GetAttribute("CurrentAmmo")
				if typeof(currentAmmo) == "number" and currentAmmo <= 0 then
					return
				end
				fireInfo = WeaponSecurity.sanitizeFireInfo(fireInfo)
				if not fireInfo or not WeaponSecurity.registerShot(player, weapon, fireInfo) then
					return
				end
				WeaponsSystem.accumulateStat(player, "ShotsFired", 1)
			end
			weapon:onFired(player, fireInfo, true)
		end
	end
end

function NetworkingCallbacks.WeaponReloadRequest(player, instance)
	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem
	if not WeaponsSystem then
		return
	end

	local weapon = WeaponsSystem.getWeaponForInstance(instance)
	local weaponType = getmetatable(weapon)
	if weapon and weaponType and weapon.instance == instance and weaponType.CanBeReloaded and weapon.player == player then
		weapon:reload(player, true)
	end
end

function NetworkingCallbacks.WeaponReloaded(player, instance)
	-- Broadcast servidor→cliente. Nunca como input en el server: saltaría los guards
	-- de reload() y refillaría CurrentAmmo (setup() tampoco conecta OnServerEvent).
	if IsServer then
		return
	end

	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem
	if not WeaponsSystem then
		return
	end

	local weapon = WeaponsSystem.getWeaponForInstance(instance)
	local weaponType = getmetatable(weapon)
	if weapon then
		if weapon.instance == instance and weaponType.CanBeReloaded and player ~= nil and player ~= LocalPlayer then
			weapon:onReloaded(player, true)
		end
	end
end

function NetworkingCallbacks.WeaponReloadCanceled(player, instance)
	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem
	if not WeaponsSystem then
		return
	end

	local weapon = WeaponsSystem.getWeaponForInstance(instance)
	local weaponType = getmetatable(weapon)
	if weapon and weaponType and weapon.instance == instance and weaponType.CanBeReloaded and weapon.player == player then
		weapon:cancelReload(player, true)
	end
end

function NetworkingCallbacks.WeaponHit(player, instance, hitInfo)
	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem
	if not WeaponsSystem then
		return
	end

	local weapon = WeaponsSystem.getWeaponForInstance(instance)
	local weaponType = getmetatable(weapon)
	if weapon then
		if weapon.instance == instance and weaponType.CanHit then
			if IsServer and WeaponSecurity then
				if not WeaponSecurity.ownsWeaponForHit(player, instance) then
					return
				end
				if weapon.player ~= player then
					return
				end
				local ok = WeaponSecurity.validateHit(player, weapon, hitInfo)
				if not ok then
					return
				end

				weapon:onHit(hitInfo)
			end
		end
	end
end

-- Solo se dispara al killer local.
function NetworkingCallbacks.PlayerEliminated(victimName, xpGained, wasHeadshot, victimPos)
	if IsServer then return end

	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem

	_playEliminationSound()

	local PersonalKillFeed = _getPersonalKillFeed()
	if PersonalKillFeed then
		PersonalKillFeed.showKill(victimName or "Unknown", xpGained or 100, wasHeadshot or false)
	end

	if StreakDisplay then
		StreakDisplay.onKill()
	end

	if WeaponsSystem then
		if WeaponsSystem.camera then
			WeaponsSystem.camera:playKillCameraShake(wasHeadshot or false)
		end
	end

	if HealthBarController then
		HealthBarController.onKill()
	end

	if victimPos then
		local PickupDropEffect = _getPickupDropEffect()
		if PickupDropEffect then
			PickupDropEffect.Play(victimPos)
		end
	end
end

-- Solo al que causó el daño: el feedback de un tick de quemadura es el mismo que el de
-- un disparo (marcador, contorno y número), que el cliente normalmente predice solo.
function NetworkingCallbacks.DamageOverTimeVFX(humanoid, damage)
	if IsServer then return end

	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem
	if not (WeaponsSystem and WeaponsSystem.gui) then return end
	if typeof(humanoid) ~= "Instance" or not humanoid:IsA("Humanoid") then return end

	WeaponsSystem.gui:OnHitOtherPlayer(damage or 0, humanoid, nil)
end

function NetworkingCallbacks.PlayerAssist()
	if IsServer then return end

	_playEliminationSound()

	local PersonalKillFeed = _getPersonalKillFeed()
	if PersonalKillFeed then
		PersonalKillFeed.showAssist()
	end
end

-- Explosiones: el server solo broadcastea la posición; cada cliente clona y emite.
-- Template (Studio): un Attachment con los ParticleEmitters dentro de
--   ReplicatedStorage.WeaponsSystem.Assets.Effects.ExplosionParticles
-- Los nombres deben coincidir con EXPLOSION_EMIT_COUNTS; un emitter que no esté en
-- la tabla usa su atributo "EmitCount" o 10.
local EXPLOSION_EMIT_COUNTS = {
	Backdrop = 45,
	Boom = 1,
	Fire2 = 20,
	Flames = 55,
	ShardsDark = 20,
	Smoke = 7,
	SmokeDark = 7,
	Specs = 35,
	Specs1 = 20,
	Specs2 = 18,
	Wind = 10,
	Wind1 = 1,
} :: { [string]: number }

local _explosionTemplate: Attachment? = nil
local _explosionResolved = false
local _explosionMaxLifetime = 0

local function _getExplosionTemplate(): (Attachment?, number)
	if _explosionResolved then
		return _explosionTemplate, _explosionMaxLifetime
	end
	_explosionResolved = true

	local wsFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
	local assets = wsFolder and wsFolder:FindFirstChild("Assets")
	local effects = assets and assets:FindFirstChild("Effects")
	local folder = effects and effects:FindFirstChild("ExplosionParticles")
	local attachment = folder and folder:FindFirstChildWhichIsA("Attachment")
	if not attachment then
		warn("[NetworkingCallbacks] Falta el Attachment de partículas en Effects.ExplosionParticles")
		return nil, 0
	end

	for _, child in attachment:GetChildren() do
		if child:IsA("ParticleEmitter") then
			_explosionMaxLifetime = math.max(_explosionMaxLifetime, child.Lifetime.Max)
		end
	end
	_explosionTemplate = attachment
	return attachment, _explosionMaxLifetime
end

-- Preload: si no, la primera explosión se ve sin textura mientras carga.
if not IsServer then
	task.spawn(function()
		local ContentProvider = game:GetService("ContentProvider")
		local template = _getExplosionTemplate()
		if template then
			pcall(function()
				ContentProvider:PreloadAsync(template:GetChildren())
			end)
		end
	end)
end

local _warnedMissingExplosionSound = false

-- Clon por explosión dentro del holder: suena en 3D desde el punto de impacto.
local function _playExplosionSound(holder: BasePart): number
	local audio = SoundService:FindFirstChild("Audio")
	local gameplay = audio and audio:FindFirstChild("Gameplay")
	local template = AudioRuntime.findSound(gameplay, "Explosion")
	if not template or template.SoundId == "" then
		if not _warnedMissingExplosionSound then
			_warnedMissingExplosionSound = true
			warn("WeaponsSystem: falta SoundService.Audio.Gameplay.Explosion (o su SoundId) — ejecuta tools/audio/SetupSoundService.luau")
		end
		return 0
	end

	local sound = template:Clone()
	sound.Parent = holder
	sound:Play()
	-- TimeLength es 0 hasta que el audio carga: margen fijo para no cortarlo.
	local length = if sound.TimeLength > 0 then sound.TimeLength else 4
	return length / math.max(sound.PlaybackSpeed, 0.01)
end

function NetworkingCallbacks.PlayExplosionVFX(position: Vector3)
	if IsServer then return end
	if typeof(position) ~= "Vector3" then return end

	local template, maxLifetime = _getExplosionTemplate()

	-- ParticleEmitters necesitan un BasePart como ancestro.
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.1, 0.1, 0.1)
	holder.Position = position

	holder.Parent = workspace
	local soundLength = _playExplosionSound(holder)

	if template then
		local attachment = template:Clone()
		attachment.CFrame = CFrame.identity
		attachment.Parent = holder
		for _, emitter in attachment:GetChildren() do
			if emitter:IsA("ParticleEmitter") then
				-- One-shot: Enabled=false corta el flujo continuo pero :Emit(N) sigue funcionando.
				emitter.Enabled = false
				local count = EXPLOSION_EMIT_COUNTS[emitter.Name] or emitter:GetAttribute("EmitCount")
				emitter:Emit(if type(count) == "number" and count > 0 then count else 10)
			end
		end
	end

	-- Margen: al destruir el holder desaparecen también las partículas y el sonido vivos.
	Debris:AddItem(holder, math.max(maxLifetime, soundLength) + 0.5)
end

-- Entrada del cliente (Network.Weapons, ByteNet). NetGuards descarta números no
-- finitos; WeaponSecurity revalida propiedad, cadencia, cono y rango.
function NetworkingCallbacks.listenClientInput()
	local Network = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("networking"):WaitForChild("Network"))
	local NetGuards = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("networking"):WaitForChild("NetGuards"))
	local shotId = { kind = "number", integer = true, min = 0 } :: any

	Network.Weapons.WeaponFired.Listen(function(data: Network.WeaponFiredPayload, player: Player)
		if not data.weapon or not NetGuards.validate(data, {
			id = shotId,
			charge = { kind = "number", min = 0, max = 1 },
		}) then
			return
		end
		NetworkingCallbacks.WeaponFired(player, data.weapon, {
			id = data.id,
			origin = data.origin,
			dir = data.dir,
			charge = data.charge,
		})
	end)

	Network.Weapons.WeaponHit.Listen(function(data: Network.WeaponHitPayload, player: Player)
		if not data.weapon or not NetGuards.validate(data, {
			sid = shotId,
			pid = { kind = "number", integer = true, min = 1 },
			d = { kind = "number", min = 0 },
		}) then
			return
		end
		NetworkingCallbacks.WeaponHit(player, data.weapon, {
			sid = data.sid,
			pid = data.pid,
			part = data.part,
			p = data.p,
			n = data.n,
			d = data.d,
		})
	end)

	-- Cada par recarga+cancelación repone canReload y hace un broadcast a los jugadores
	-- cercanos: sin límite, un cliente modificado lo spamea en bucle. Solo se limita la
	-- recarga (el cancel exige una recarga previa) y por arma, para no descartar la de
	-- otra arma tras un cambio rápido. Muy por debajo de cualquier ReloadTime.
	-- Por jugador además de por arma: la Tool equipada replica a todos y, indexado solo
	-- por ella, otro cliente gastaba el cupo y la recarga real del dueño se descartaba.
	local lastReloadRequestAt: { [Player]: { [Instance]: number } } = setmetatable({}, { __mode = "k" }) :: any
	Network.Weapons.WeaponReloadRequest.Listen(function(data: Network.WeaponPayload, player: Player)
		local weapon = data.weapon
		if not weapon then
			return
		end
		local byWeapon = lastReloadRequestAt[player]
		if not byWeapon then
			byWeapon = setmetatable({}, { __mode = "k" }) :: any
			lastReloadRequestAt[player] = byWeapon
		end
		local now = os.clock()
		local last = byWeapon[weapon]
		if last and now - last < RELOAD_REQUEST_MIN_INTERVAL then
			return
		end
		byWeapon[weapon] = now
		NetworkingCallbacks.WeaponReloadRequest(player, weapon)
	end)

	Network.Weapons.WeaponReloadCanceled.Listen(function(data: Network.WeaponPayload, player: Player)
		if data.weapon then
			NetworkingCallbacks.WeaponReloadCanceled(player, data.weapon)
		end
	end)
end

return NetworkingCallbacks
