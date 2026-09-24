--!strict

-- Kill effect "Electrocution": ragdoll de Default sin lanzamiento que convulsiona durante
-- SHAKE_TIME: cada pieza lleva un AngularVelocity cuyo objetivo salta al azar cada
-- SHAKE_INTERVAL. Es física: corre donde corre apply (servidor en partida, cliente en los
-- previews). Chispazos, brillo y sonido: visuals/killEffects/Electrocution.

local DefaultKillEffect = require(script.Parent.Default)
local Utils = require(script.Parent.Utils)

local Electrocution = {}

-- Contrato con el cliente (visuals/killEffects/Electrocution): lo que dura la descarga.
Electrocution.SHAKE_TIME = 2
Electrocution.previewTime = Electrocution.SHAKE_TIME + 1

local CONFIG = {
	SHAKE_INTERVAL = 0.05, -- s entre cambios de giro
	MAX_SPIN = 40, -- rad/s máx por eje
	-- MaxTorque = masa del assembly × esto. Bajo: apenas se mueve; alto: las piezas
	-- chocan contra los límites de los joints y el solver las hace vibrar.
	TORQUE_PER_MASS = 400,
	-- Manos y pies van soldados al antebrazo y la espinilla: ya giran con ellos.
	SHAKE_PARTS = {
		"Head",
		"UpperTorso",
		"LowerTorso",
		"LeftUpperArm",
		"LeftLowerArm",
		"RightUpperArm",
		"RightLowerArm",
		"LeftUpperLeg",
		"LeftLowerLeg",
		"RightUpperLeg",
		"RightLowerLeg",
	},
}

local rng = Random.new()

local function randomSpin(): Vector3
	local m = CONFIG.MAX_SPIN
	return Vector3.new(rng:NextNumber(-m, m), rng:NextNumber(-m, m), rng:NextNumber(-m, m))
end

local function addMotors(parts: { [string]: BasePart }): { AngularVelocity }
	local motors: { AngularVelocity } = {}
	for _, name in CONFIG.SHAKE_PARTS do
		local part = parts[name]
		if not part then
			continue
		end
		local att = Instance.new("Attachment")
		att.Name = "ElectrocutionAtt"
		att.Parent = part
		local motor = Instance.new("AngularVelocity")
		motor.Attachment0 = att
		motor.RelativeTo = Enum.ActuatorRelativeTo.World
		motor.MaxTorque = part.AssemblyMass * CONFIG.TORQUE_PER_MASS
		motor.AngularVelocity = randomSpin()
		motor.Parent = part
		table.insert(motors, motor)
	end
	return motors
end

local function convulse(char: Model, parts: { [string]: BasePart }, motors: { AngularVelocity })
	local elapsed = 0
	while elapsed < Electrocution.SHAKE_TIME and char.Parent do
		elapsed += task.wait(CONFIG.SHAKE_INTERVAL)
		for _, motor in motors do
			motor.AngularVelocity = randomSpin()
		end
	end
	for _, motor in motors do
		local att = motor.Attachment0
		motor:Destroy()
		if att then
			att:Destroy()
		end
	end
	if char.Parent then
		Utils.calmRagdoll(parts, char)
	end
end

function Electrocution.apply(char: Model): boolean
	local parts = DefaultKillEffect.ragdoll(char)
	if not parts then
		return false
	end
	task.spawn(convulse, char, parts, addMotors(parts))
	return true
end

return Electrocution
