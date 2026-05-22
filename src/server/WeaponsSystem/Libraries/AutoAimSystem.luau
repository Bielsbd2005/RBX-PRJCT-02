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

-- Raycast params for visibility check (reused to avoid GC pressure)
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true
-- Filter array reusado entre llamadas. Mutamos [1] in-place y asignamos
-- FilterDescendantsInstances al mismo array — evita el table literal por call.
local visibilityFilter: { Instance } = table.create(1)

-- W9: tablas reusadas para el sweep de targets. findBestTarget corre 20Hz por
-- arma equipada local. Antes cada call alocaba charactersToCheck = {} +
-- 2 closures (addNpcModelIfEnemy, scanBotsIn). Ahora reusamos el buffer y
-- las funciones son module-level con un upvalue mutable (_localCharacter).
local _charactersBuffer: { Model } = {}
local _localCharacter: Model? = nil

local function _addNpcModelIfEnemy(model: Instance)
	if not model:IsA("Model") then return end
	if model == _localCharacter then return end
	if Players:GetPlayerFromCharacter(model) then return end

	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end
	if _localCharacter and TeamUtils.isSameTeam(_localCharacter, model) then return end

	table.insert(_charactersBuffer, model)
end

local function _scanBotsIn(container: Instance)
	local botsFolder = if container.Name == "Bots" then container else container:FindFirstChild("Bots")
	if botsFolder and (botsFolder:IsA("Folder") or botsFolder:IsA("Model")) then
		for _, botModel in ipairs(botsFolder:GetChildren()) do
			_addNpcModelIfEnemy(botModel)
		end
	end
end

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

	-- Setup upvalue para los helpers + limpiar buffer reusado.
	_localCharacter = localPlayer.Character
	table.clear(_charactersBuffer)
	local charactersToCheck = _charactersBuffer

	-- Add enemy players
	for _, player in ipairs(Players:GetPlayers()) do
		if player == localPlayer then continue end
		if not player.Character then continue end
		if weaponsSystem.playersOnDifferentTeams(localPlayer, player) then
			table.insert(charactersToCheck, player.Character)
		end
	end

	-- Add NPCs: una sola pasada por workspace:GetChildren(); cada hijo cuenta
	-- como NPC potencial Y se inspecciona su carpeta "Bots" directa (sin
	-- FindFirstChild recursivo, que escanearía subárboles enteros).
	for _, child in ipairs(workspace:GetChildren()) do
		_addNpcModelIfEnemy(child)
		_scanBotsIn(child)
		-- Los bots reales viven en workspace.ActiveMap.<mapModel>.Bots (MatchService
		-- clona el mapa dentro del contenedor ActiveMap), así que necesitamos un
		-- nivel extra de profundidad solo dentro de ese contenedor — barato porque
		-- ActiveMap suele tener un único hijo (el mapModel cargado).
		if child.Name == "ActiveMap" then
			for _, sub in ipairs(child:GetChildren()) do
				_scanBotsIn(sub)
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

	-- Reuse module-level filter (mutate slot 1) en lugar de table literal por call.
	local localCharacter = LocalPlayer and LocalPlayer.Character
	visibilityFilter[1] = localCharacter
	raycastParams.FilterDescendantsInstances = visibilityFilter

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
