--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemDefaults = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemDefaults"))

local DefaultKillEffect = require(script.Parent.Default)
local GravityKillEffect = require(script.Parent.Gravity)

type KillEffectModule = {
	apply: (target: Model) -> boolean,
}

local killEffectsById = {
	Default = DefaultKillEffect,
	Gravity = GravityKillEffect,
} :: { [string]: KillEffectModule }

local KillEffectsRegistry = {}

function KillEffectsRegistry.apply(effectId: string?, target: Model): boolean
	local resolvedId = if type(effectId) == "string" and effectId ~= "" then effectId else ItemDefaults.ITEM_ID
	local killEffectModule = killEffectsById[resolvedId] or killEffectsById[ItemDefaults.ITEM_ID]
	return killEffectModule.apply(target)
end

return KillEffectsRegistry
