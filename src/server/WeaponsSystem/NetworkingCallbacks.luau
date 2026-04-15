local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local IsServer = RunService:IsServer()
local LocalPlayer = (not IsServer) and Players.LocalPlayer or nil

-- =====================================================================
--  KILL STREAK — client-only state
-- =====================================================================
local STREAK_TO_ACTION = {
	[1] = "Kill",
	[2] = "DoubleKill",
	[3] = "TripleKill",
	[4] = "Rampage",
	[5] = "Godlike",
}
local MAX_STREAK_BADGE = 5  -- clamps to "Godlike" for 5+ kills in a row

local killStreak = 0
local BadgeSystem = nil  -- lazy-required on first kill (client only)

-- Reset streak and clear badges whenever the local player respawns
if not IsServer then
	LocalPlayer.CharacterAdded:Connect(function()
		killStreak = 0
		if BadgeSystem then
			BadgeSystem.clear()
		end
	end)
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
function NetworkingCallbacks.PlayerEliminated(victimName, xpGained, wasHeadshot, victimPos)
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

	-- Badge system: only headshot kills count towards the streak
	if wasHeadshot then
		if not BadgeSystem then
			BadgeSystem = require(script.Parent:WaitForChild("Libraries"):WaitForChild("BadgeSystem"))
		end
		killStreak += 1
		local actionName = STREAK_TO_ACTION[math.min(killStreak, MAX_STREAK_BADGE)]
		if actionName then
			BadgeSystem.showBadge(actionName)
		end
	end

	if victimPos then
		coroutine.wrap(function()
			local MoneyEffectLocal = script.Parent:WaitForChild("Libraries"):FindFirstChild("MoneyEffectLocal")
			if MoneyEffectLocal then
				require(MoneyEffectLocal).Play(victimPos)
			end
		end)()
	end
end

return NetworkingCallbacks
