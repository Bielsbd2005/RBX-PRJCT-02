--!strict
--[[
	ScenePresetController
	Aplica presets de iluminación AUTORADOS EN STUDIO desde una librería de
	carpetas, dirigidos por el atributo `LightingPreset`. Cero código por preset:
	el diseñador crea/tunea todo en Studio.

	── Librería (inerte hasta aplicar) ──────────────────────────
	  ReplicatedStorage/
	    LightingPresets/                (Folder)
	      <PresetName>/                 (Folder = nombre del preset)
	        Configuration               (Configuration; sus ATRIBUTOS son props del
	                                      servicio Lighting: Ambient, Brightness,
	                                      ClockTime, FogColor, FogStart, FogEnd,
	                                      ColorShift_Top, ColorShift_Bottom, …)
	        Atmosphere                  (instancias reales de effect/sky, aquí
	        BloomEffect                  inertes porque no cuelgan de Lighting)
	        ColorCorrectionEffect
	        Sky …

	── Consumidor ───────────────────────────────────────────────
	  Cualquier instancia con atributo `LightingPreset = "<PresetName>"`
	  (p. ej. Workspace.Cameras.lobby o una carpeta de mapa). `applyFrom(inst)`
	  lee el atributo; `apply(name)` aplica por nombre directo.

	── Semántica ─────────────────────────────────────────────────
	  * Escalares (Configuration): se SNAPSHOTEA el valor actual de Lighting ANTES
	    de sobrescribir, y se repone en restore(). Se itera sobre los atributos
	    (nada hardcodeado); los que no mapean a una prop asignable se ignoran con
	    warn. Los atributos soportan Color3/number nativos → sin parseo.
	  * Effects (PostEffect/Atmosphere/Sky): REEMPLAZO TOTAL. El preset define el set
	    COMPLETO de effects de la escena. Al aplicar se apartan (Parent=nil) TODOS
	    los effects existentes bajo Lighting (nada del look anterior sobrevive:
	    Atmosphere/Bloom/DoF/SunRays/Sky del place o de otro preset) y se CLONAN los
	    del preset (los de la librería son plantilla). Todo se repone en restore().
	    Excepción: los effects runtime-managed por otros controllers (el Blur de
	    paneles del BlurController) se eximen — son UI, no look de escena
	    (ver isReservedEffect).
	  * UN SOLO preset activo a la vez (Lighting es global): apply() de otro preset
	    restaura el anterior primero.

	Singleton cliente (Lighting es visual): el estado vive a nivel de módulo.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local LIBRARY_NAME = "LightingPresets"
local ATTRIBUTE_NAME = "LightingPreset"
-- Marca los clones que metemos bajo Lighting para no confundirlos con effects
-- del mapa base al apartar los existentes.
local CLONE_TAG_ATTRIBUTE = "__ScenePresetClone"

-- ── Estado del preset activo (singleton) ─────────────────────
local activePresetName: string? = nil
-- prop del servicio Lighting → su valor previo (para reponer en restore).
local savedScalars: { [string]: any } = {}
-- Clones de effects que metimos bajo Lighting.
local addedClones: { Instance } = {}
-- Effects del base que apartamos (Parent=nil) mientras el preset está activo.
local stashedOriginals: { Instance } = {}

-- ¿Es una instancia que va bajo Lighting y que un preset puede aportar/barrer?
local function isLightingChild(inst: Instance): boolean
	return inst:IsA("PostEffect") or inst:IsA("Atmosphere") or inst:IsA("Sky")
end

-- Effects runtime-managed por otros controllers que NO deben ser barridos por un
-- preset: viven bajo Lighting pero son UI, no "look de escena". Hoy: el Blur de
-- paneles del BlurController (BlurEffect llamado "Blur"). El DepthOfFieldEffect NO
-- se exime a propósito — si una escena quiere DoF, lo incluye en su preset, y
-- DepthOfFieldController togglea el que exista bajo Lighting (el del preset).
local function isReservedEffect(inst: Instance): boolean
	return inst:IsA("BlurEffect") and inst.Name == "Blur"
end

local function findLibrary(): Folder?
	local lib = ReplicatedStorage:FindFirstChild(LIBRARY_NAME)
	return if lib and lib:IsA("Folder") then lib :: Folder else nil
end

local ScenePresetController = {}

-- Aplica el preset `presetName` de la librería. No-op si ya está activo.
function ScenePresetController.apply(presetName: string)
	if activePresetName == presetName then
		return
	end
	-- Un solo preset a la vez: restaurar el anterior antes de aplicar el nuevo.
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

	-- 1) Escalares del servicio Lighting desde los atributos del Configuration.
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
				-- Snapshot solo de lo que de verdad sobrescribimos (clave única).
				savedScalars[key] = current
			else
				warn(("[ScenePresetController] '%s' (preset '%s') no es una prop asignable de Lighting."):format(key, presetName))
			end
		end
	end

	-- 2a) REEMPLAZO TOTAL: apartar TODOS los effects existentes bajo Lighting (no
	--     nuestros clones), salvo los runtime-managed exentos (ver isReservedEffect).
	--     El preset define el set COMPLETO de effects de la escena — nada del look
	--     anterior (Atmosphere/Bloom/DoF/SunRays/Sky del place o de otro preset)
	--     sobrevive. Se reponen en restore().
	for _, existing in Lighting:GetChildren() do
		if isLightingChild(existing)
			and not existing:GetAttribute(CLONE_TAG_ATTRIBUTE)
			and not isReservedEffect(existing) then
			table.insert(stashedOriginals, existing)
			existing.Parent = nil
		end
	end

	-- 2b) Clonar los effects del preset a Lighting.
	for _, child in presetFolder:GetChildren() do
		if isLightingChild(child) then
			local clone = child:Clone()
			clone:SetAttribute(CLONE_TAG_ATTRIBUTE, true)
			clone.Parent = Lighting
			table.insert(addedClones, clone)
		end
	end
end

-- Lee el atributo `LightingPreset` de `instance` y aplica ese preset. Devuelve
-- true si el atributo existía (y por tanto se intentó aplicar), false si no.
function ScenePresetController.applyFrom(instance: Instance): boolean
	local presetName = instance:GetAttribute(ATTRIBUTE_NAME)
	if type(presetName) ~= "string" or presetName == "" then
		return false
	end
	ScenePresetController.apply(presetName)
	return true
end

-- Restaura Lighting al estado previo al preset activo. No-op si no hay ninguno.
function ScenePresetController.restore()
	if activePresetName == nil then
		return
	end
	activePresetName = nil

	-- 1) Reponer los escalares snapshoteados.
	for key, value in savedScalars do
		pcall(function()
			(Lighting :: any)[key] = value
		end)
	end
	table.clear(savedScalars)

	-- 2) Destruir los clones y devolver los originales apartados.
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

-- Preset activo (o nil). Útil para debugging / tests.
function ScenePresetController.getActive(): string?
	return activePresetName
end

-- Precarga los assets de todos los presets (skyboxes, texturas de Sky/Decal, etc.)
-- para que la PRIMERA aplicación no sufra el streaming del CDN — el retraso más
-- visible al cambiar de escena. No bloqueante: espera la replicación de la librería
-- y precarga en su propia corrutina. Llamar una vez al arrancar. (No elimina el
-- micro-hitch de reparentar effects, solo el de carga de assets.)
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
