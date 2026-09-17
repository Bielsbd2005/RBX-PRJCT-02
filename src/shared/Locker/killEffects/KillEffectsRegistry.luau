--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemDefaults = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants"):WaitForChild("ItemDefaults"))

local Utils = require(script.Parent.Utils)
local DefaultKillEffect = require(script.Parent.Default)
local GravityKillEffect = require(script.Parent.Gravity)
local TombstoneKillEffect = require(script.Parent.Tombstone)
local BalloonsKillEffect = require(script.Parent.Balloons)
local BurningKillEffect = require(script.Parent.Burning)
local AbductionKillEffect = require(script.Parent.Abduction)
local DisassembleKillEffect = require(script.Parent.Disassemble)
local XpOrbsKillEffect = require(script.Parent.XpOrbs)

type KillEffectModule = {
	apply: (target: Model) -> boolean,
	-- s que el preview (Locker, pase) mantiene el cadáver en escena. Sin él, DEFAULT_PREVIEW_TIME.
	previewTime: number?,
}

local DEFAULT_PREVIEW_TIME = 2

-- Un id que no esté aquí (ítem del catálogo sin implementar) cae al Default en `apply`.
local killEffectsById = {
	Default = DefaultKillEffect,
	Gravity = GravityKillEffect,
	Tombstone = TombstoneKillEffect,
	Balloons = BalloonsKillEffect,
	Burning = BurningKillEffect,
	Abduction = AbductionKillEffect,
	Disassemble = DisassembleKillEffect,
	XpOrbs = XpOrbsKillEffect,
} :: { [string]: KillEffectModule }

local KillEffectsRegistry = {}

-- Lo consume el manifiesto de assets de TelemetryService.
function KillEffectsRegistry.ids(): { string }
	local ids: { string } = {}
	for id in killEffectsById do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function KillEffectsRegistry.previewTime(effectId: string?): number
	local resolvedId = if type(effectId) == "string" and effectId ~= "" then effectId else ItemDefaults.ITEM_ID
	local killEffectModule = killEffectsById[resolvedId]
	local custom = if killEffectModule then killEffectModule.previewTime else nil
	return if type(custom) == "number" then custom else DEFAULT_PREVIEW_TIME
end

function KillEffectsRegistry.apply(effectId: string?, target: Model): boolean
	local resolvedId = if type(effectId) == "string" and effectId ~= "" then effectId else ItemDefaults.ITEM_ID
	local killEffectModule = killEffectsById[resolvedId] or killEffectsById[ItemDefaults.ITEM_ID]
	-- Desarmar aquí (punto único para players, bots y todos los efectos), antes de que
	-- el módulo procese el cuerpo.
	Utils.stripWeapons(target)
	return killEffectModule.apply(target)
end

return KillEffectsRegistry
