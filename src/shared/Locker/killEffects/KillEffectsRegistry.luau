--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemDefaults = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemDefaults"))

local Utils = require(script.Parent.Utils)
local DefaultKillEffect = require(script.Parent.Default)
local GravityKillEffect = require(script.Parent.Gravity)
local ExplosionKillEffect = require(script.Parent.Explosion)

type KillEffectModule = {
	apply: (target: Model) -> boolean,
}

local killEffectsById = {
	Default = DefaultKillEffect,
	Gravity = GravityKillEffect,
	Explosion = ExplosionKillEffect,
} :: { [string]: KillEffectModule }

local KillEffectsRegistry = {}

function KillEffectsRegistry.apply(effectId: string?, target: Model): boolean
	local resolvedId = if type(effectId) == "string" and effectId ~= "" then effectId else ItemDefaults.ITEM_ID
	local killEffectModule = killEffectsById[resolvedId] or killEffectsById[ItemDefaults.ITEM_ID]
	-- Desarmar antes de ragdollear: el cadáver no debe quedar sujetando el arma.
	-- Choke point único → cubre players, bots y todos los kill effects, y ocurre
	-- antes de que el módulo procese las partes del cuerpo.
	Utils.stripWeapons(target)
	return killEffectModule.apply(target)
end

return KillEffectsRegistry
