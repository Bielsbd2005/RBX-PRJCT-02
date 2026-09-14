--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemDefaults = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemDefaults"))
local ItemsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemsConfig")) :: any

local Utils = require(script.Parent.Utils)
local Parametric = require(script.Parent.Parametric)
local DefaultKillEffect = require(script.Parent.Default)
local GravityKillEffect = require(script.Parent.Gravity)
local ExplosionKillEffect = require(script.Parent.Explosion)
local TornadoKillEffect = require(script.Parent.Tornado)

type KillEffectModule = {
	apply: (target: Model) -> boolean,
}

local killEffectsById = {
	Default = DefaultKillEffect,
	Gravity = GravityKillEffect,
	Explosion = ExplosionKillEffect,
	Tornado = TornadoKillEffect,
} :: { [string]: KillEffectModule }

-- Efectos sin módulo propio pero con `Effect = { ... }` en ItemsConfig
-- (creados desde el dashboard): se construyen con Parametric una vez por id.
local parametricById: { [string]: KillEffectModule } = {}

local function resolveModule(effectId: string): KillEffectModule?
	local byModule = killEffectsById[effectId]
	if byModule then
		return byModule
	end
	local cached = parametricById[effectId]
	if cached then
		return cached
	end
	local catalog = ItemsConfig.KillEffects
	local def = if type(catalog) == "table" then catalog[effectId] else nil
	if type(def) == "table" and type(def.Effect) == "table" then
		local made = Parametric.make(def.Effect)
		parametricById[effectId] = made
		return made
	end
	return nil
end

local KillEffectsRegistry = {}

-- Ids con efecto resoluble: módulos registrados + entradas de ItemsConfig con
-- `Effect`. Lo consume el manifiesto de assets de TelemetryService.
function KillEffectsRegistry.ids(): { string }
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}
	for id in killEffectsById do
		if not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	local catalog = ItemsConfig.KillEffects
	if type(catalog) == "table" then
		for id, def in catalog do
			if type(def) == "table" and type(def.Effect) == "table" and not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
	end
	table.sort(ids)
	return ids
end

function KillEffectsRegistry.apply(effectId: string?, target: Model): boolean
	local resolvedId = if type(effectId) == "string" and effectId ~= "" then effectId else ItemDefaults.ITEM_ID
	local killEffectModule = resolveModule(resolvedId) or killEffectsById[ItemDefaults.ITEM_ID]
	-- Desarmar antes de ragdollear: el cadáver no debe quedar sujetando el arma.
	-- Choke point único → cubre players, bots y todos los kill effects, y ocurre
	-- antes de que el módulo procese las partes del cuerpo.
	Utils.stripWeapons(target)
	return killEffectModule.apply(target)
end

return KillEffectsRegistry
