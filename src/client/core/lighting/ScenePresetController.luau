--!strict
--[[
	Aplica presets de iluminación autorados en Studio. Estructura requerida:
	  ReplicatedStorage.LightingPresets.<PresetName> (Folder) con
	    · un Configuration cuyos ATRIBUTOS son props de Lighting (Ambient, ClockTime…)
	    · effects/Sky como hijos (inertes ahí; se clonan bajo Lighting).
	Consumidor: cualquier instancia con atributo `LightingPreset = "<PresetName>"`.

	Escalares: se guarda el valor previo y restore() lo repone. Effects: REEMPLAZO
	TOTAL — se apartan (Parent=nil) todos los effects de Lighting salvo los de
	isReservedEffect. Un solo preset activo a la vez (Lighting es global).
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local LIBRARY_NAME = "LightingPresets"
local ATTRIBUTE_NAME = "LightingPreset"
-- Marca nuestros clones para no apartarlos como si fueran effects del place.
local CLONE_TAG_ATTRIBUTE = "__ScenePresetClone"

local activePresetName: string? = nil
-- prop de Lighting → valor previo.
local savedScalars: { [string]: any } = {}
local addedClones: { Instance } = {}
local stashedOriginals: { Instance } = {}

local function isLightingChild(inst: Instance): boolean
	return inst:IsA("PostEffect") or inst:IsA("Atmosphere") or inst:IsA("Sky")
end

-- Effects de UI gestionados por otros controllers que un preset no debe barrer:
-- el Blur de BlurController. DepthOfField NO se exime: si una escena lo quiere, va
-- en su preset y DepthOfFieldController togglea el que haya bajo Lighting.
local function isReservedEffect(inst: Instance): boolean
	return inst:IsA("BlurEffect") and inst.Name == "Blur"
end

local function findLibrary(): Folder?
	local lib = ReplicatedStorage:FindFirstChild(LIBRARY_NAME)
	return if lib and lib:IsA("Folder") then lib :: Folder else nil
end

local ScenePresetController = {}

function ScenePresetController.apply(presetName: string)
	if activePresetName == presetName then
		return
	end
	if activePresetName ~= nil then
		ScenePresetController.restore()
	end

	local library = findLibrary()
	if not library then
		warn(("[ScenePresetController] Falta ReplicatedStorage.%s; no se aplica '%s'."):format(LIBRARY_NAME, presetName))
		return
	end
	local presetFolderNode = library:FindFirstChild(presetName)
	if not (presetFolderNode and presetFolderNode:IsA("Folder")) then
		warn(("[ScenePresetController] El preset '%s' no existe en ReplicatedStorage.%s."):format(presetName, LIBRARY_NAME))
		return
	end
	local presetFolder = presetFolderNode :: Folder

	activePresetName = presetName

	local config = presetFolder:FindFirstChildOfClass("Configuration")
	if config then
		for key, value in config:GetAttributes() do
			local okRead, current = pcall(function()
				return (Lighting :: any)[key]
			end)
			if not okRead then
				warn(("[ScenePresetController] '%s' (preset '%s') no es una prop de Lighting."):format(key, presetName))
				continue
			end
			local okWrite = pcall(function()
				(Lighting :: any)[key] = value
			end)
			if okWrite then
				savedScalars[key] = current
			else
				warn(("[ScenePresetController] '%s' (preset '%s') no es una prop asignable de Lighting."):format(key, presetName))
			end
		end
	end

	for _, existing in Lighting:GetChildren() do
		if isLightingChild(existing)
			and not existing:GetAttribute(CLONE_TAG_ATTRIBUTE)
			and not isReservedEffect(existing) then
			table.insert(stashedOriginals, existing)
			existing.Parent = nil
		end
	end

	for _, child in presetFolder:GetChildren() do
		if isLightingChild(child) then
			local clone = child:Clone()
			clone:SetAttribute(CLONE_TAG_ATTRIBUTE, true)
			clone.Parent = Lighting
			table.insert(addedClones, clone)
		end
	end
end

-- Devuelve true si `instance` tenía el atributo (y se intentó aplicar).
function ScenePresetController.applyFrom(instance: Instance): boolean
	local presetName = instance:GetAttribute(ATTRIBUTE_NAME)
	if type(presetName) ~= "string" or presetName == "" then
		return false
	end
	ScenePresetController.apply(presetName)
	return true
end

function ScenePresetController.restore()
	if activePresetName == nil then
		return
	end
	activePresetName = nil

	for key, value in savedScalars do
		pcall(function()
			(Lighting :: any)[key] = value
		end)
	end
	table.clear(savedScalars)

	for _, clone in addedClones do
		clone:Destroy()
	end
	table.clear(addedClones)
	for _, original in stashedOriginals do
		if original.Parent == nil then
			original.Parent = Lighting
		end
	end
	table.clear(stashedOriginals)
end

-- Para paneles con cámara propia al cerrar. Sin preset de lobby se restaura el
-- lighting base: quedarse con el del panel es peor que perder el look del lobby.
function ScenePresetController.applyLobbyOrRestore(warnPrefix: string?)
	local cameras = game:GetService("Workspace"):FindFirstChild("Cameras")
	local lobbyNode = if cameras then cameras:FindFirstChild("lobby") else nil
	if lobbyNode and ScenePresetController.applyFrom(lobbyNode) then
		return
	end
	warn(
		`{warnPrefix or "[ScenePresetController]"} No se pudo aplicar el preset del lobby (falta Workspace.Cameras.lobby o su atributo LightingPreset); se restaura el lighting base.`
	)
	ScenePresetController.restore()
end

-- No bloqueante; llamar una vez al arrancar. Quita el streaming de assets en la
-- primera aplicación, no el micro-hitch de reparentar effects.
function ScenePresetController.preload()
	task.spawn(function()
		local library = ReplicatedStorage:WaitForChild(LIBRARY_NAME, 30)
		if not (library and library:IsA("Folder")) then
			return
		end
		local assets = library:GetDescendants()
		if #assets == 0 then
			return
		end
		pcall(function()
			ContentProvider:PreloadAsync(assets)
		end)
	end)
end

return ScenePresetController
