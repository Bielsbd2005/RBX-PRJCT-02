--[[
	AutoAimSystem.luau
	Client-side auto-aim and auto-fire system.
	Detects enemy players near the center of the screen and automatically fires.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local TeamUtils = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("TeamUtils"))

local AutoAimSystem = {}

-- Configuration
AutoAimSystem.SCREEN_RADIUS_THRESHOLD = 80		-- Pixels from screen center to consider a target
AutoAimSystem.MAX_DISTANCE = 300				-- Max studs distance to detect enemies
AutoAimSystem.FIRE_COOLDOWN = 0.15				-- Min seconds between auto-fire shots

-- Raycast params for visibility check (reused to avoid GC pressure)
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

-- Find the best enemy target near the screen center
function AutoAimSystem.findBestTarget(weaponsSystem)
	local camera = workspace.CurrentCamera
	if not camera then return nil, nil end

	local localPlayer = LocalPlayer
	if not localPlayer or not localPlayer.Character then return nil, nil end

	local localHumanoid = localPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not localHumanoid or localHumanoid.Health <= 0 then return nil, nil end

	local viewportSize = camera.ViewportSize
	local screenCenterX = viewportSize.X * 0.5
	local screenCenterY = viewportSize.Y * 0.5

	local bestTarget = nil
	local bestScreenDist = math.huge
	local bestWorldPos = nil

	local charactersToCheck = {}

	local function addNpcModelIfEnemy(model: Instance)
		if not model:IsA("Model") then return end
		if model == localPlayer.Character then return end
		if Players:GetPlayerFromCharacter(model) then return end

		local hum = model:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return end
		if TeamUtils.isSameTeam(localPlayer.Character, model) then return end

		table.insert(charactersToCheck, model)
	end

	-- Add enemy players
	for _, player in ipairs(Players:GetPlayers()) do
		if player == localPlayer then continue end

		-- Check teams — only target enemies
		local onDifferentTeams = true
		local success = pcall(function()
			onDifferentTeams = weaponsSystem.playersOnDifferentTeams(localPlayer, player)
		end)
		if not success then
			onDifferentTeams = true -- Default to treating as enemy if team check fails
		end
		if onDifferentTeams and player.Character then
			table.insert(charactersToCheck, player.Character)
		end
	end

	-- Add NPCs/Dummies from top-level Workspace models
	for _, child in ipairs(workspace:GetChildren()) do
		addNpcModelIfEnemy(child)
	end

	-- Add bots parented under map folders (e.g. Workspace.ActiveMap.<Map>.Bots)
	for _, child in ipairs(workspace:GetChildren()) do
		local botsFolder = child:FindFirstChild("Bots", true)
		if botsFolder and botsFolder:IsA("Folder") then
			for _, botModel in ipairs(botsFolder:GetChildren()) do
				addNpcModelIfEnemy(botModel)
			end
		end
	end

	for _, character in ipairs(charactersToCheck) do
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then continue end

		-- Target the center of mass first (UpperTorso/Torso) to avoid overpowered headshots
		local targetPart = character:FindFirstChild("UpperTorso") or
			character:FindFirstChild("Torso") or
			character:FindFirstChild("HumanoidRootPart")
		if not targetPart then continue end

		local worldPos = targetPart.Position
		local cameraPos = camera.CFrame.Position

		-- Distance check
		local worldDist = (worldPos - cameraPos).Magnitude
		if worldDist > AutoAimSystem.MAX_DISTANCE then continue end

		-- Screen position check
		local screenPos, onScreen = camera:WorldToViewportPoint(worldPos)
		if not onScreen then continue end

		local screenDist = math.sqrt(
			(screenPos.X - screenCenterX) ^ 2 +
				(screenPos.Y - screenCenterY) ^ 2
		)

		if screenDist > AutoAimSystem.SCREEN_RADIUS_THRESHOLD then continue end

		-- Pick the closest to screen center
		if screenDist < bestScreenDist then
			bestScreenDist = screenDist
			bestTarget = targetPart
			bestWorldPos = worldPos
		end
	end

	return bestTarget, bestWorldPos
end

-- Check if a target is visible (no walls blocking line of sight)
function AutoAimSystem.isTargetVisible(origin, targetPart)
	if not targetPart or not targetPart.Parent then return false end

	local targetPos = targetPart.Position
	local direction = targetPos - origin

	-- Build ignore list: local player's character + the target's character accessories
	local localCharacter = LocalPlayer and LocalPlayer.Character
	local filterInstances = {}

	if localCharacter then
		table.insert(filterInstances, localCharacter)
	end

	raycastParams.FilterDescendantsInstances = filterInstances

	local result = workspace:Raycast(origin, direction, raycastParams)

	if not result then
		-- No hit means clear line of sight (target is within range but nothing blocking)
		return true
	end

	-- Check if what we hit belongs to the target's character
	local hitPart = result.Instance
	if hitPart and targetPart.Parent and hitPart:IsDescendantOf(targetPart.Parent) then
		return true
	end

	return false
end

return AutoAimSystem
