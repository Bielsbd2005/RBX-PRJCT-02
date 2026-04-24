local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local IsServer = RunService:IsServer()
local LocalPlayer = (not IsServer) and Players.LocalPlayer or nil

-- =====================================================================
--  CLIENT-ONLY CONTROLLERS — reset / init on respawn
-- =====================================================================
local StreakController = nil
local HealthBarController = nil

if not IsServer then
	StreakController = require(script.Parent:WaitForChild("Libraries"):WaitForChild("StreakController"))
	HealthBarController = require(script.Parent:WaitForChild("Libraries"):WaitForChild("HealthBarController"))

	LocalPlayer.CharacterAdded:Connect(function(character)
		StreakController.reset()
		HealthBarController.onCharacterAdded(character)
	end)

	-- Handle already-spawned character
	if LocalPlayer.Character then
		task.spawn(HealthBarController.onCharacterAdded, LocalPlayer.Character)
	end
end
-- =====================================================================

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
	if weapon then
		if weapon.instance == instance and weaponType.CanBeReloaded then
			weapon:reload(player, true)
		end
	end
end

function NetworkingCallbacks.WeaponReloaded(player, instance)
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
	if weapon then
		if weapon.instance == instance and weaponType.CanBeReloaded and player ~= LocalPlayer then
			weapon:cancelReload(player, true)
		end
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
			if IsServer then
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
function NetworkingCallbacks.PlayerEliminated(victimName, xpGained, wasHeadshot, victimPos, coinAmount, streak)
	if IsServer then return end

	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem

	local audio = SoundService:FindFirstChild("Audio")
	local gameplay = audio and audio:FindFirstChild("Gameplay")
	local sound = gameplay and gameplay:FindFirstChild("EliminatedPlayer")

	if sound then
		local clone = sound:Clone()
		clone.Parent = SoundService
		clone:Play()
		Debris:AddItem(clone, clone.TimeLength + 1)
	else
		warn("WeaponsSystem: Could not find SoundService.Audio.Gameplay.EliminatedPlayer")
	end

	local PersonalKillFeed = require(script.Parent:WaitForChild("Libraries"):WaitForChild("PersonalKillFeed"))
	PersonalKillFeed.showKill(victimName or "Unknown", xpGained or 100, wasHeadshot or false)

	if WeaponsSystem then
		if WeaponsSystem.camera then
			WeaponsSystem.camera:playKillCameraShake(wasHeadshot or false)
		end
		if WeaponsSystem.gui then
			WeaponsSystem.gui:showKillContainer()
		end
	end

	if StreakController then
		StreakController.onKill()
	end

	-- Mostrar BonusEffect basado en la racha
	if victimPos then
		coroutine.wrap(function()
			local BonusEffect = script.Parent:WaitForChild("Libraries"):FindFirstChild("BonusEffect")
			if BonusEffect then
				require(BonusEffect).Play(victimPos, streak or 1)
			end
		end)()
	end
end

-- Client-side: shows assist notification in the kill feed
function NetworkingCallbacks.PlayerAssist()
	if IsServer then return end

	local WeaponsSystem = NetworkingCallbacks.WeaponsSystem

	local audio = SoundService:FindFirstChild("Audio")
	local gameplay = audio and audio:FindFirstChild("Gameplay")
	local sound = gameplay and gameplay:FindFirstChild("EliminatedPlayer")

	if sound then
		local clone = sound:Clone()
		clone.Parent = SoundService
		clone:Play()
		Debris:AddItem(clone, clone.TimeLength + 1)
	end

	local PersonalKillFeed = require(script.Parent:WaitForChild("Libraries"):WaitForChild("PersonalKillFeed"))
	PersonalKillFeed.showAssist()

	if WeaponsSystem then
		if WeaponsSystem.camera then
			WeaponsSystem.camera:playKillCameraShake(false)
		end
		if WeaponsSystem.gui then
			WeaponsSystem.gui:showKillContainer()
		end
	end
end

return NetworkingCallbacks
