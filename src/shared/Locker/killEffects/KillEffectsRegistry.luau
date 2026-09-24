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
local OofKillEffect = require(script.Parent.Oof)
local NoobifyKillEffect = require(script.Parent.Noobify)
local BobbleheadKillEffect = require(script.Parent.Bobblehead)
local FlattenedKillEffect = require(script.Parent.Flattened)
local GumDropKillEffect = require(script.Parent.GumDrop)
local ElectrocutionKillEffect = require(script.Parent.Electrocution)

-- La parte de servidor de un kill effect (en los previews corre en el cliente). La
-- parte visual de cada cliente, si la hay, va en client/core/visuals/killEffects/<id>
-- y la arranca KillEffectVisuals con el tag y los atributos de abajo.
type KillEffectModule = {
	apply: (target: Model) -> boolean,
	-- s que el preview (Locker, pase) mantiene el cadáver en escena. Sin él, DEFAULT_PREVIEW_TIME.
	previewTime: number?,
}

local DEFAULT_PREVIEW_TIME = 2

-- Un id que no esté aquí (ítem del catálogo sin implementar) cae al Default en `apply`.
-- Los que solo son ragdoll de Default + visual de cliente reusan DefaultKillEffect.
local killEffectsById = {
	Default = DefaultKillEffect,
	Gravity = GravityKillEffect,
	Tombstone = TombstoneKillEffect,
	Balloons = BalloonsKillEffect,
	Burning = BurningKillEffect,
	Abduction = AbductionKillEffect,
	Disassemble = DisassembleKillEffect,
	XpOrbs = XpOrbsKillEffect,
	Confetti = { apply = DefaultKillEffect.apply, previewTime = 2.5 },
	Oof = OofKillEffect,
	Noobify = NoobifyKillEffect,
	Bobblehead = BobbleheadKillEffect,
	Flattened = FlattenedKillEffect,
	BlockBlast = {
		apply = function(char: Model): boolean
			Utils.freezeCorpse(char)
			return true
		end,
		previewTime = 2.5,
	},
	Electrocution = ElectrocutionKillEffect,
	GumDrop = GumDropKillEffect,
} :: { [string]: KillEffectModule }

local KillEffectsRegistry = {}

-- Contrato con el cliente (KillEffectVisuals): todo cadáver procesado lleva el tag y
-- estos atributos, puestos DESPUÉS de `apply` para que los del propio efecto lleguen antes.
KillEffectsRegistry.TAG = "KillEffect"
KillEffectsRegistry.ATTR = table.freeze({
	ID = "KillEffectId", -- id del efecto aplicado (ya resuelto: nunca uno sin implementar)
	STARTED_AT = "KillEffectStartedAt", -- GetServerTimeNow() al morir: sincroniza a quien llega tarde
})

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
	if not killEffectsById[resolvedId] then
		resolvedId = ItemDefaults.ITEM_ID
	end
	-- Desarmar aquí (punto único para players, bots y todos los efectos), antes de que
	-- el módulo procese el cuerpo.
	Utils.stripWeapons(target)
	local applied = killEffectsById[resolvedId].apply(target)
	target:SetAttribute(KillEffectsRegistry.ATTR.ID, resolvedId)
	target:SetAttribute(KillEffectsRegistry.ATTR.STARTED_AT, workspace:GetServerTimeNow())
	target:AddTag(KillEffectsRegistry.TAG)
	return applied
end

return KillEffectsRegistry
