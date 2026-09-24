--!strict

-- Kill effect "Oof": la muerte clásica de Roblox. Se rompen los joints y el cuerpo se
-- desmonta en sus 6 piezas de R6 (cabeza, torso, brazos y piernas; en R15 las partes de
-- cada una se sueldan entre sí), que caen sueltas con un pequeño empujón.
--
-- Los accesorios (ropa y sombreros) conservan su soldadura y caen con su pieza.
-- El HumanoidRootPart se queda anclado en el punto de muerte: KillCam lo lee.
-- Sonido: ReplicatedStorage.Templates.Oof (Sound) si existe; si no, CONFIG.SOUND_ID.
-- Se reproduce donde corre apply (servidor en partida, cliente en los previews).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Utils = require(script.Parent.Utils)

local CONFIG = {
	SPREAD_XZ = 5, -- studs/s máx de empujón horizontal por pieza
	SPEED_UP_MIN = 2, -- studs/s
	SPEED_UP_MAX = 10,
	SPIN = 4, -- rad/s máx de giro inicial por eje
	TEMPLATES_FOLDER = "Templates",
	SOUND_TEMPLATE_NAME = "Oof",
	SOUND_ID = "rbxasset://sounds/uuhhh.mp3", -- el de muerte que trae el motor
	SOUND_VOLUME = 1,
	PITCH_MIN = 1,
	PITCH_MAX = 1.1,
	SOUND_PARTS = { "Head", "UpperTorso", "Torso" },
}

-- Nombres R15 y R6 juntos: en cada rig solo existen los suyos. La primera parte de
-- cada pieza es la que recibe las soldaduras.
local PIECES = {
	{ "Head" },
	{ "UpperTorso", "LowerTorso", "Torso" },
	{ "LeftUpperArm", "LeftLowerArm", "LeftHand", "Left Arm" },
	{ "RightUpperArm", "RightLowerArm", "RightHand", "Right Arm" },
	{ "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "Left Leg" },
	{ "RightUpperLeg", "RightLowerLeg", "RightFoot", "Right Leg" },
}

local rng = Random.new()

local Oof = {}

local function makeSound(): Sound
	local templates = ReplicatedStorage:FindFirstChild(CONFIG.TEMPLATES_FOLDER)
	local template = if templates then templates:FindFirstChild(CONFIG.SOUND_TEMPLATE_NAME) else nil
	if template and template:IsA("Sound") and template.SoundId ~= "" then
		return template:Clone()
	end
	local sound = Instance.new("Sound")
	sound.SoundId = CONFIG.SOUND_ID
	sound.Volume = CONFIG.SOUND_VOLUME
	return sound
end

local function playSound(parts: { [string]: BasePart })
	for _, name in CONFIG.SOUND_PARTS do
		local part = parts[name]
		if part then
			-- Dentro del cadáver: se limpia con él.
			local sound = makeSound()
			sound.PlaybackSpeed = rng:NextNumber(CONFIG.PITCH_MIN, CONFIG.PITCH_MAX)
			sound.Parent = part
			sound:Play()
			return
		end
	end
end

-- El HRP se queda anclado: cualquier cosa soldada a él (aunque la soldadura viva en
-- otra parte, que Utils.destroyJoints no ve) se quedaría flotando en el sitio.
local function detachFromRoot(char: Model, root: BasePart)
	for _, desc in char:GetDescendants() do
		if desc:IsA("JointInstance") or desc:IsA("WeldConstraint") then
			local joint = desc :: any
			if joint.Part0 == root or joint.Part1 == root then
				desc:Destroy()
			end
		elseif desc:IsA("Constraint") then
			local att0 = desc.Attachment0
			local att1 = desc.Attachment1
			if (att0 and att0.Parent == root) or (att1 and att1.Parent == root) then
				desc:Destroy()
			end
		end
	end
end

-- Parte principal de cada pieza, con el resto soldado a ella.
local function weldPieces(parts: { [string]: BasePart }): { BasePart }
	local mains: { BasePart } = {}
	for _, names in PIECES do
		local main: BasePart? = nil
		for _, name in names do
			local part = parts[name]
			if part then
				if main then
					Utils.createWeld(main, part)
				else
					main = part
				end
			end
		end
		if main then
			table.insert(mains, main)
		end
	end
	return mains
end

function Oof.apply(char: Model): boolean
	-- Anclado mientras se desmonta: sin joints, la gravedad se lo llevaría a medias.
	local allBaseParts: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			table.insert(allBaseParts, desc)
		elseif Utils.isRigJoint(desc) then
			desc:Destroy()
		end
	end

	local parts = Utils.buildPartLookup(char)
	local root = parts.HumanoidRootPart
	if root then
		detachFromRoot(char, root)
		root.CanCollide = false
		root.Massless = true
		local i = table.find(allBaseParts, root)
		if i then
			table.remove(allBaseParts, i)
		end
	end

	local hum = char:FindFirstChildWhichIsA("Humanoid", true)
	if hum then
		Utils.releaseHumanoid(hum)
	end

	local mains = weldPieces(parts)
	Utils.makeCorpseInert(char)

	for name, part in parts do
		if name ~= "HumanoidRootPart" then
			part.CanCollide = true
		end
	end
	for _, part in allBaseParts do
		part.Anchored = false
	end
	Utils.setServerOwnership(allBaseParts)

	-- Un step después, como Utils.applyImpulse: en el mismo frame que desanclar y
	-- cambiar de dueño la velocidad a veces se descarta.
	RunService.Heartbeat:Once(function()
		-- El Humanoid puede volver a encender CanCollide del HRP; que ninguna pieza caiga
		-- encima de él.
		if root and root.Parent then
			root.CanCollide = false
		end
		for _, main in mains do
			if main.Parent and not main.Anchored then
				main.AssemblyLinearVelocity = Vector3.new(
					rng:NextNumber(-CONFIG.SPREAD_XZ, CONFIG.SPREAD_XZ),
					rng:NextNumber(CONFIG.SPEED_UP_MIN, CONFIG.SPEED_UP_MAX),
					rng:NextNumber(-CONFIG.SPREAD_XZ, CONFIG.SPREAD_XZ)
				)
				main.AssemblyAngularVelocity = Vector3.new(
					rng:NextNumber(-CONFIG.SPIN, CONFIG.SPIN),
					rng:NextNumber(-CONFIG.SPIN, CONFIG.SPIN),
					rng:NextNumber(-CONFIG.SPIN, CONFIG.SPIN)
				)
			end
		end
	end)

	playSound(parts)
	return true
end

return Oof
