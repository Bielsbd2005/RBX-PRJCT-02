--!strict

--[[
	Parametric — kill effect construido desde DATOS (`ItemsConfig.KillEffects[id].Effect`)
	en vez de desde un módulo propio. Es lo que hace funcionar un kill effect creado
	desde el dashboard de Telemetry sin escribir código nuevo: el registry llama a
	`make(effectDef)` y obtiene un módulo `{ apply(target) }` como Default/Gravity.

	Ragdoll idéntico al del resto de efectos (Utils comparte la construcción) y un
	empujón parametrizado sobre el torso:
	  · ImpulseXZ   studs/s máximos en horizontal (dirección aleatoria).
	  · ImpulseY    studs/s hacia arriba.
	  · Spin        rad/s de velocidad angular aleatoria (0 = sin giro).
	  · Jitter      studs/s de ruido añadido a cada componente.
	  · Flash       true = Explosion nativa PURAMENTE COSMÉTICA (BlastPressure = 0,
	                DestroyJointsRadius = 0), como hace Explosion.luau.
	  · FlashRadius tamaño del flash (BlastRadius) cuando Flash = true.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Utils = require(script.Parent.Utils)
local CollisionGroups = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CollisionGroups"))

export type EffectDef = {
	ImpulseXZ: number?,
	ImpulseY: number?,
	Spin: number?,
	Jitter: number?,
	Flash: boolean?,
	FlashRadius: number?,
}

export type KillEffectModule = {
	apply: (target: Model) -> boolean,
}

local DEFAULTS = {
	ImpulseXZ = 40,
	ImpulseY = 30,
	Spin = 0,
	Jitter = 0,
	Flash = false,
	FlashRadius = 6,
	JOINT_MAX_ANGLE = 55,
	RAGDOLL_HEAD_AS_JOINT = false,
	VISUAL_CLEANUP = 3, -- s tras los que limpiamos la Explosion por si el engine no la borra
}

local rng = Random.new()

local Parametric = {}

local function _num(value: any, fallback: number): number
	return if type(value) == "number" then value else fallback
end

local function spawnFlash(center: Vector3, radius: number)
	local explosion = Instance.new("Explosion")
	explosion.Position = center
	explosion.BlastPressure = 0
	explosion.BlastRadius = radius
	explosion.DestroyJointsRadius = 0
	explosion.Visible = true
	explosion.Parent = workspace
	Debris:AddItem(explosion, DEFAULTS.VISUAL_CLEANUP)
end

-- Como Utils.applyImpulse, pero para la velocidad angular: un step después para
-- que el desanclado y el ownership ya estén asentados.
local function applySpin(part: BasePart, angular: Vector3)
	RunService.Heartbeat:Once(function()
		if part.Parent then
			part.AssemblyAngularVelocity = angular
		end
	end)
end

local function applyRagdoll(char: Model, hum: Humanoid, def: EffectDef)
	-- Sólo reconstruimos joints de ragdoll para R15; para no-R15 dejamos el rig
	-- intacto (mismo criterio que Gravity/Explosion) y aun así aplicamos el empujón.
	local isR15 = hum.RigType == Enum.HumanoidRigType.R15

	local allBaseParts: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			table.insert(allBaseParts, desc)
		elseif isR15 and desc:IsA("Motor6D") then
			desc:Destroy()
		end
	end

	local parts = Utils.buildPartLookup(char)

	local root = parts.HumanoidRootPart
	if root then
		if isR15 then
			Utils.destroyJoints(root)
		end
		root.CanCollide = false
		root.Massless = true
	end

	hum:ChangeState(Enum.HumanoidStateType.Dead)
	hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	if isR15 then
		Utils.buildRagdoll(parts, DEFAULTS.JOINT_MAX_ANGLE, DEFAULTS.RAGDOLL_HEAD_AS_JOINT)
	end

	CollisionGroups.setGroupForParts(char, allBaseParts, CollisionGroups.RAGDOLL)

	for _, part in allBaseParts do
		part.Anchored = false
	end

	-- Servidor simula el ragdoll (evita el congelamiento por network-ownership;
	-- ver Utils.setServerOwnership). No-op en el preview del Locker (cliente).
	Utils.setServerOwnership(allBaseParts)

	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			part.CanCollide = true
		end
	end

	-- Roblox forces CanCollide=false on dead humanoid parts every frame.
	Utils.enforceCanCollide(allBaseParts, char)

	local impulseXZ = math.max(0, _num(def.ImpulseXZ, DEFAULTS.ImpulseXZ))
	local impulseY = _num(def.ImpulseY, DEFAULTS.ImpulseY)
	local spin = math.max(0, _num(def.Spin, DEFAULTS.Spin))
	local jitter = math.max(0, _num(def.Jitter, DEFAULTS.Jitter))

	local impulsePart = parts.LowerTorso or parts.Torso or parts.HumanoidRootPart
	if impulsePart then
		local angle = rng:NextNumber(0, 2 * math.pi)
		local vel = Vector3.new(math.cos(angle) * impulseXZ, impulseY, math.sin(angle) * impulseXZ)
		if jitter > 0 then
			vel += Vector3.new(
				rng:NextNumber(-jitter, jitter),
				rng:NextNumber(0, jitter),
				rng:NextNumber(-jitter, jitter)
			)
		end
		Utils.applyImpulse(impulsePart, vel)
		if spin > 0 then
			applySpin(impulsePart, Vector3.new(
				rng:NextNumber(-spin, spin),
				rng:NextNumber(-spin, spin),
				rng:NextNumber(-spin, spin)
			))
		end
	end

	if def.Flash == true then
		local center = if impulsePart then impulsePart.Position else char:GetPivot().Position
		spawnFlash(center, math.max(0, _num(def.FlashRadius, DEFAULTS.FlashRadius)))
	end
end

function Parametric.make(effectDef: any): KillEffectModule
	local def: EffectDef = if type(effectDef) == "table" then effectDef else {}
	local module = {}
	function module.apply(char: Model): boolean
		local hum = char:FindFirstChildWhichIsA("Humanoid", true)
		if not hum then
			return false
		end
		hum.BreakJointsOnDeath = false
		applyRagdoll(char, hum, def)
		return true
	end
	return module
end

return Parametric
