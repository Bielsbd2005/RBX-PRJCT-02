--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MatchWeapons = {}

local _cachedModule: any = nil
local _attemptedResolve = false

local function _getWeaponsSystemModule(): any
	if _attemptedResolve then
		return _cachedModule
	end

	_attemptedResolve = true

	local weaponsSystemFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
	if not weaponsSystemFolder then
		return nil
	end

	local weaponsSystemModule = weaponsSystemFolder:FindFirstChild("WeaponsSystem")
	if not weaponsSystemModule or not weaponsSystemModule:IsA("ModuleScript") then
		return nil
	end

	local ok, moduleOrError = pcall(function()
		return require(weaponsSystemModule)
	end)
	if ok then
		_cachedModule = moduleOrError
		return _cachedModule
	end

	warn("[MatchWeapons] No se pudo cargar WeaponsSystem module: " .. tostring(moduleOrError))
	return nil
end

local function _deactivateRuntime()
	local weaponsSystem = _getWeaponsSystemModule()
	if not weaponsSystem then
		return
	end

	weaponsSystem.resetClientRuntimeState()
end

function MatchWeapons.clearGui(playerGui: PlayerGui)
	for _, node in playerGui:GetChildren() do
		if not node:IsA("ScreenGui") then
			continue
		end

		local isWeaponsGui = node.Name == "WeaponsSystemGui"
			or node.Name == "WeaponSystemInsets"
			or node.Name == "WeaponGUI"
			or node.Name == "WeaponGui"

		if not isWeaponsGui then
			local scalingElements = node:FindFirstChild("ScalingElements")
			local hasCrosshair = node:FindFirstChild("Crosshair", true) ~= nil
			isWeaponsGui = scalingElements ~= nil and hasCrosshair
		end

		if isWeaponsGui then
			node.Enabled = false
		end
	end
end

function MatchWeapons.cleanAll(playerGui: PlayerGui)
	local localPlayer = Players.LocalPlayer
	local character = localPlayer.Character

	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:UnequipTools()
			for _, track in humanoid:GetPlayingAnimationTracks() do
				local priority = track.Priority
				if
					priority == Enum.AnimationPriority.Action
					or priority == Enum.AnimationPriority.Action2
					or priority == Enum.AnimationPriority.Action3
					or priority == Enum.AnimationPriority.Action4
				then
					track:Stop(0)
				end
			end
		end
	end

	_deactivateRuntime()

	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, tool in backpack:GetChildren() do
			if tool:IsA("Tool") then
				tool:Destroy()
			end
		end
	end

	if character then
		for _, tool in character:GetChildren() do
			if tool:IsA("Tool") then
				tool:Destroy()
			end
		end
	end

	MatchWeapons.clearGui(playerGui)
end

--- Limpieza con reintentos en delays para ganar a scripts que re-equipan.
--- guardFn debe devolver true mientras los reintentos sigan siendo válidos.
function MatchWeapons.cleanAllWithRetries(playerGui: PlayerGui, guardFn: (() -> boolean)?)
	MatchWeapons.cleanAll(playerGui)

	for _, delaySec in { 0.05, 0.2, 0.5 } do
		task.delay(delaySec, function()
			if guardFn and not guardFn() then
				return
			end
			MatchWeapons.cleanAll(playerGui)
		end)
	end
end

return MatchWeapons
