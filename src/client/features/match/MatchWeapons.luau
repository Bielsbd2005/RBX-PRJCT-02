--!strict
--[[
	MatchWeapons.luau
	Limpieza centralizada de armas, herramientas y UI del WeaponsSystem.
]]

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

	if weaponsSystem.resetClientRuntimeState then
		weaponsSystem.resetClientRuntimeState()
		return
	end

	weaponsSystem.currentWeapon = nil

	if weaponsSystem.gui and weaponsSystem.gui.setEnabled then
		weaponsSystem.gui:setEnabled(false)
	end

	if weaponsSystem.camera then
		if weaponsSystem.camera.setEnabled then
			weaponsSystem.camera:setEnabled(false)
		end
		weaponsSystem.camera.rotateCharacterWithCamera = false
		if weaponsSystem.camera.resetZoomFactor then
			weaponsSystem.camera:resetZoomFactor()
		end
		if weaponsSystem.camera.setHasScope then
			weaponsSystem.camera:setHasScope(false)
		end
	end
end

--- Desactiva ScreenGuis del WeaponsSystem (crosshair, etc.).
function MatchWeapons.clearGui(playerGui: PlayerGui)
	for _, node in playerGui:GetChildren() do
		if not node:IsA("ScreenGui") then
			continue
		end

		local isWeaponsGui = node.Name == "WeaponsSystemGui"
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

--- Limpieza completa: desequipar tools, parar animaciones, destruir armas, ocultar GUI.
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
