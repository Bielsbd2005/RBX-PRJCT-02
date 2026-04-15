local ReplicatedStorage = game:GetService("ReplicatedStorage")

local playerChildAddedConnection
local replicatedStorageChildAddedConnection
local clientWeaponsScript
local weaponsSystemFolder

local function setupWeaponsSystem()
	local WeaponsSystem = require(weaponsSystemFolder.WeaponsSystem)
	if not WeaponsSystem.doingSetup and not WeaponsSystem.didSetup then
		WeaponsSystem.setup()
	end
end

local function onReplicatedStorageChildAdded(child)
	if child.Name == "WeaponsSystem" then
		setupWeaponsSystem()
		replicatedStorageChildAddedConnection:Disconnect()
	end
end

local function onPlayerChildAdded(child)
	if child.Name == "PlayerScripts" then
		clientWeaponsScript.Parent = child
		playerChildAddedConnection:Disconnect()
	end
end

if script.Parent.Name ~= "PlayerScripts" then
	clientWeaponsScript = script:Clone()
	local PlayerScripts = script.Parent.Parent:FindFirstChild("PlayerScripts")

	if PlayerScripts ~= nil then
		clientWeaponsScript.Parent = PlayerScripts
	else
		playerChildAddedConnection = script.Parent.Parent.ChildAdded:Connect(onPlayerChildAdded)
	end
else
	-- Initialize LevelUp Listener
	task.spawn(function()
		-- Wait for the module provided by user
		local success, LevelUpFX = pcall(function()
			return require(ReplicatedStorage:WaitForChild("LevelUpFX", 10))
		end)

		if success and LevelUpFX then
			local MenuFolder = ReplicatedStorage:WaitForChild("MenuFolder", 10)
			if MenuFolder then
				local Remotes = MenuFolder:WaitForChild("Remotes", 10)
				if Remotes then
					local Currency = Remotes:WaitForChild("Currency", 10)
					if Currency then
						local LevelUp = Currency:WaitForChild("LevelUp", 10)
						if LevelUp then
							LevelUp.OnClientEvent:Connect(function(newLevel)
								LevelUpFX.Show(newLevel)
							end)
						end
					end
				end
			end
		end
	end)

	weaponsSystemFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")

	-- Add WeaponData Listener for EliminatedPlayer
	if weaponsSystemFolder then
		local WeaponData = weaponsSystemFolder:WaitForChild("WeaponData", 5)
		if WeaponData and WeaponData:IsA("RemoteEvent") then
			WeaponData.OnClientEvent:Connect(function(action, ...)
				if action == "EliminatedPlayer" then
					local soundService = game:GetService("SoundService")
					local gameplayFolder = soundService:FindFirstChild("Audio") and soundService.Audio:FindFirstChild("Gameplay")
					if gameplayFolder then
						local elimSound = gameplayFolder:FindFirstChild("EliminatedPlayer")
						if elimSound and elimSound:IsA("Sound") then
							local soundClone = elimSound:Clone()
							soundClone.Parent = soundService
							soundClone:Play()
							game:GetService("Debris"):AddItem(soundClone, soundClone.TimeLength + 1)
						end
					end
				end
			end)
		end
	end

	if weaponsSystemFolder ~= nil then
		setupWeaponsSystem()
	else
		replicatedStorageChildAddedConnection = ReplicatedStorage.ChildAdded:Connect(onReplicatedStorageChildAdded)
	end
end
