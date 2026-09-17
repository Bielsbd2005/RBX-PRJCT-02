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
				local currentAmmo = instance:GetAttribute("CurrentAmmo")
				if typeof(currentAmmo) == "number" and currentAmmo <= 0 then
					return
				end
				if not WeaponSecurity.registerShot(player, weapon, fireInfo) then
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
				if not WeaponSecurity.ownsWeapon(player, instance) then
					return
				end
				if weapon.player ~= player then
					return
				end
				local ok = WeaponSecurity.validateHit(player, weapon, hitInfo)
				if not ok then
					return
				end

				WeaponsSystem.accumulateStat(player, "ShotsHit", 1)
				weapon:onHit(hitInfo)
			end
		end
	end
end

function NetworkingCallbacks.WeaponActivated(player, instance, activated)
	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem
	if not WeaponsSystem then
		return
	end

	local weapon = WeaponsSystem.getWeaponForInstance(instance)
	local weaponType = getmetatable(weapon)

	if weapon and weaponType then
		if weapon.instance == instance and weapon.player == player then
			weapon:setActivated(activated, true)
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

function NetworkingCallbacks.PlayerAssist()
	if IsServer then return end

	_playEliminationSound()

	local PersonalKillFeed = _getPersonalKillFeed()
	if PersonalKillFeed then
		PersonalKillFeed.showAssist()
	end
end

-- Explosiones: el server solo broadcastea la posición; cada cliente clona y emite.
-- Estructura esperada del template:
--   ReplicatedStorage.WeaponsSystem.Assets.Effects.ExplosionParticles (Folder)
--       ├── ParticleA (ParticleEmitter)  -- atributo "EmitCount" (number, default 10)
--       ├── ParticleB (ParticleEmitter)  -- atributo "EmitCount"
--       └── ...

local _explosionTemplates: { ParticleEmitter }? = nil
local _explosionMaxLifetime = 0

local function _getExplosionTemplates(): ({ ParticleEmitter }, number)
	if _explosionTemplates then
		return _explosionTemplates, _explosionMaxLifetime
	end

	local wsFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
	local assets = wsFolder and wsFolder:FindFirstChild("Assets")
	local effects = assets and assets:FindFirstChild("Effects")
	local folder = effects and effects:FindFirstChild("ExplosionParticles")

	local templates = {} :: { ParticleEmitter }
	local maxLifetime = 0
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("ParticleEmitter") then
				table.insert(templates, child)
				local lifetime = child.Lifetime.Max
				if lifetime > maxLifetime then
					maxLifetime = lifetime
				end
			end
		end
	end

	_explosionTemplates = templates
	_explosionMaxLifetime = maxLifetime
	return templates, maxLifetime
end

-- Preload: si no, la primera explosión se ve sin textura mientras carga.
if not IsServer then
	task.spawn(function()
		local ContentProvider = game:GetService("ContentProvider")
		local templates, _ = _getExplosionTemplates()
		if #templates > 0 then
			pcall(function()
				ContentProvider:PreloadAsync(templates)
			end)
		end
	end)
end

function NetworkingCallbacks.PlayExplosionVFX(position: Vector3)
	if IsServer then return end
	if typeof(position) ~= "Vector3" then return end

	local templates, maxLifetime = _getExplosionTemplates()
	if #templates == 0 then
		return
	end

	-- ParticleEmitters necesitan un BasePart como ancestro.
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Massless = true
	holder.Transparency = 1
	holder.Size = Vector3.new(0.1, 0.1, 0.1)
	holder.Position = position

	for _, template in templates do
		local emitter = template:Clone()
		-- One-shot: Enabled=false corta el flujo continuo pero :Emit(N) sigue funcionando.
		emitter.Enabled = false
		emitter.Parent = holder
		local count = template:GetAttribute("EmitCount")
		if type(count) ~= "number" or count <= 0 then
			count = 10
		end
		emitter:Emit(count)
	end

	holder.Parent = workspace
	-- Margen: al destruir el holder desaparecen también las partículas vivas.
	Debris:AddItem(holder, maxLifetime + 0.5)
end

return NetworkingCallbacks
