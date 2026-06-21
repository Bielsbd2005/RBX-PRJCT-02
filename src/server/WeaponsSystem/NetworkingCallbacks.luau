local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local IsServer = RunService:IsServer()
local LocalPlayer = (not IsServer) and Players.LocalPlayer or nil

-- =====================================================================
--  CLIENT-ONLY CONTROLLERS — reset / init on respawn
-- =====================================================================
local HealthBarController = nil

if not IsServer then
	HealthBarController = require(script.Parent:WaitForChild("Libraries"):WaitForChild("HealthBarController"))

	LocalPlayer.CharacterAdded:Connect(function(character)
		HealthBarController.onCharacterAdded(character)
	end)

	-- Handle already-spawned character
	if LocalPlayer.Character then
		task.spawn(HealthBarController.onCharacterAdded, LocalPlayer.Character)
	end
end
-- =====================================================================

local WeaponSecurity = nil
if IsServer then
	WeaponSecurity = require(script.Parent:WaitForChild("Libraries"):WaitForChild("WeaponSecurity"))
end

-- Pooled elimination sound — avoids Clone + Debris per kill/assist.
local _elimSoundPool: { Sound } = {}
local _ELIM_POOL_SIZE = 3

local function _playEliminationSound()
	local audio = SoundService:FindFirstChild("Audio")
	local gameplay = audio and audio:FindFirstChild("Gameplay")
	local template = gameplay and gameplay:FindFirstChild("EliminatedPlayer")
	if not template then
		warn("WeaponsSystem: Could not find SoundService.Audio.Gameplay.EliminatedPlayer")
		return
	end

	for _, s in _elimSoundPool do
		if not s.IsPlaying then
			s:Play()
			return
		end
	end

	if #_elimSoundPool < _ELIM_POOL_SIZE then
		local s = template:Clone()
		s.Parent = SoundService
		table.insert(_elimSoundPool, s)
		s:Play()
	end
end

-- Lazy-init caches for client libraries (avoid require/WaitForChild per kill)
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
	-- Broadcast servidor→cliente. Nunca debe ejecutarse como input en el server:
	-- onReloaded directo saltaría los guards de reload() y refillaría CurrentAmmo.
	-- (Defensa en profundidad: setup() ya no conecta OnServerEvent para este evento.)
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

-- Client-side: plays the elimination sound and shows kill feed for the killer
function NetworkingCallbacks.PlayerEliminated(victimName, xpGained, wasHeadshot, victimPos)
	if IsServer then return end

	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem

	_playEliminationSound()

	local PersonalKillFeed = _getPersonalKillFeed()
	if PersonalKillFeed then
		PersonalKillFeed.showKill(victimName or "Unknown", xpGained or 100, wasHeadshot or false)
	end

	if WeaponsSystem then
		if WeaponsSystem.camera then
			WeaponsSystem.camera:playKillCameraShake(wasHeadshot or false)
		end
	end

	if victimPos then
		local PickupDropEffect = _getPickupDropEffect()
		if PickupDropEffect then
			PickupDropEffect.Play(victimPos)
		end
	end
end

-- Client-side: shows assist notification in the kill feed
function NetworkingCallbacks.PlayerAssist()
	if IsServer then return end

	_playEliminationSound()

	local PersonalKillFeed = _getPersonalKillFeed()
	if PersonalKillFeed then
		PersonalKillFeed.showAssist()
	end
end

-- =====================================================================
--  EXPLOSION VFX — particulas de impacto para armas explosivas (rocket, etc)
-- =====================================================================
-- Diseño: el server clona NADA. Solo broadcastea la posición. Cada cliente
-- clona los ParticleEmitters del template y los emite localmente. Eso evita
-- replicación de instances + permite preload de texturas en cliente.
--
-- Estructura esperada del template:
--   ReplicatedStorage.WeaponsSystem.Assets.Effects.ExplosionParticles (Folder)
--       ├── ParticleA (ParticleEmitter)  -- atributo "EmitCount" (number, default 10)
--       ├── ParticleB (ParticleEmitter)  -- atributo "EmitCount"
--       └── ...
--
-- Cada ParticleEmitter es hijo directo del folder. Se clonan todos al holder
-- y emiten su EmitCount. El holder se destruye después del max Lifetime.

local _explosionTemplates: { ParticleEmitter }? = nil
local _explosionMaxLifetime = 0

local function _getExplosionTemplates(): ({ ParticleEmitter }, number)
	if _explosionTemplates then
		return _explosionTemplates, _explosionMaxLifetime
	end

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

-- Preload de texturas en cliente: evita que el primer disparo cargue async y
-- muestre partículas mal renderizadas hasta que la textura aparezca.
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

	-- Holder mínimo: Part anchored sin colisión ni query/touch para minimizar
	-- costo físico. ParticleEmitters necesitan un BasePart como ancestro.
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
		-- Forzar emisión one-shot: Enabled=false desactiva el flujo continuo
		-- (Rate * deltaTime), pero :Emit(N) sigue funcionando como burst manual.
		-- Si no, las partículas se reproducirían en bucle hasta destruir el holder.
		emitter.Enabled = false
		emitter.Parent = holder
		local count = template:GetAttribute("EmitCount")
		if type(count) ~= "number" or count <= 0 then
			count = 10
		end
		emitter:Emit(count)
	end

	holder.Parent = workspace
	-- +0.5s de margen para que las partículas terminen su ciclo antes de borrar
	-- el holder (al destruir el holder, las partículas vivas también desaparecen).
	Debris:AddItem(holder, maxLifetime + 0.5)
end

return NetworkingCallbacks
