--!strict

local DefaultKillEffect = require(script.Parent.Default)
local GravityKillEffect = require(script.Parent.Gravity)

type KillEffectModule = {
	apply: (target: Model) -> boolean,
}

local DEFAULT_KILL_EFFECT_ID = "Default"

local killEffectsById = {
	Default = DefaultKillEffect,
	Gravity = GravityKillEffect,
} :: { [string]: KillEffectModule }

local KillEffectsRegistry = {}

function KillEffectsRegistry.apply(effectId: string?, target: Model): boolean
	local resolvedId = if type(effectId) == "string" and effectId ~= "" then effectId else DEFAULT_KILL_EFFECT_ID
	local killEffectModule = killEffectsById[resolvedId] or killEffectsById[DEFAULT_KILL_EFFECT_ID]
	return killEffectModule.apply(target)
end

return KillEffectsRegistry
