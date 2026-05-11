--!strict
--[[
	LightingPresetController
	Aplica presets de iluminación con tween. Los presets son PARCIALES — solo
	se tweanean las props declaradas en el preset; las demás se mantienen en
	el valor que tuvieran (lo deja el preset anterior).

	API:
	  apply(presetName, tweenInfo?)  — tweanea hacia el preset (default 0.8s).
	  applyImmediate(presetName)     — sin tween (útil al inicializar).

	Singleton: el state (tweens en vuelo, refs a effect children) vive a nivel
	de módulo. Llamar `apply` cancela los tweens previos.
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local LightingPresets = require(script.Parent.LightingPresets)

local DEFAULT_TWEEN_INFO = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local INSTANT_TWEEN_INFO = TweenInfo.new(0, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

local ATMOSPHERE_NAME = "PresetAtmosphere"
local CC_NAME = "PresetColorCorrection"
local BLOOM_NAME = "PresetBloom"
local SUN_RAYS_NAME = "PresetSunRays"
local SKY_NAME = "PresetSky"

-- Reusa cualquier instancia existente de la clase bajo Lighting (Studio puede
-- haber añadido una manualmente). Si no hay, crea una con un nombre conocido.
local function ensureChildOfClass(className: string, fallbackName: string): Instance
	local existing = Lighting:FindFirstChildOfClass(className)
	if existing then return existing end

	local instance = Instance.new(className)
	instance.Name = fallbackName
	instance.Parent = Lighting
	return instance
end

local activeTweens: { Tween } = {}

local function cancelActiveTweens()
	for _, tween in activeTweens do
		tween:Cancel()
	end
	table.clear(activeTweens)
end

local function tweenProps(target: Instance, props: { [string]: any }?, info: TweenInfo)
	if not props then return end

	-- Si el tween es instantáneo (info.Time == 0) podríamos asignar directo,
	-- pero TweenService:Create con time=0 también funciona y mantiene el path
	-- único; preferible para no duplicar lógica.
	local tween = TweenService:Create(target, info, props)
	table.insert(activeTweens, tween)
	tween:Play()
end

-- El Sky tiene props que son AssetIds (strings) y bools — no son tweenables.
-- Se asignan directamente, así que el cambio de skybox es siempre instantáneo
-- aunque el resto del preset esté en mitad de un fade.
local function applyPropsImmediate(target: Instance, props: { [string]: any }?)
	if not props then return end
	for key, value in props do
		(target :: any)[key] = value
	end
end

-- Kill-switch global: cuando es `false`, `apply`/`applyImmediate` son no-op
-- y se conserva la Lighting que esté configurada en Studio (incluyendo los
-- effects que haya añadido el dev manualmente). Los callsites en match/locker
-- features siguen invocándose sin cambios; flip a `true` para reactivar.
local ENABLED = false

local LightingPresetController = {}

function LightingPresetController.apply(presetName: string, tweenInfo: TweenInfo?)
	if not ENABLED then
		return
	end

	local preset = LightingPresets[presetName]
	if not preset then
		warn("[LightingPresetController] preset desconocido:", presetName)
		return
	end

	local info = tweenInfo or DEFAULT_TWEEN_INFO

	cancelActiveTweens()

	if preset.lighting then
		tweenProps(Lighting, preset.lighting, info)
	end
	if preset.atmosphere then
		tweenProps(ensureChildOfClass("Atmosphere", ATMOSPHERE_NAME), preset.atmosphere, info)
	end
	if preset.colorCorrection then
		tweenProps(ensureChildOfClass("ColorCorrectionEffect", CC_NAME), preset.colorCorrection, info)
	end
	if preset.bloom then
		tweenProps(ensureChildOfClass("BloomEffect", BLOOM_NAME), preset.bloom, info)
	end
	if preset.sunRays then
		tweenProps(ensureChildOfClass("SunRaysEffect", SUN_RAYS_NAME), preset.sunRays, info)
	end
	if preset.sky then
		applyPropsImmediate(ensureChildOfClass("Sky", SKY_NAME), preset.sky)
	end
end

function LightingPresetController.applyImmediate(presetName: string)
	LightingPresetController.apply(presetName, INSTANT_TWEEN_INFO)
end

return LightingPresetController
