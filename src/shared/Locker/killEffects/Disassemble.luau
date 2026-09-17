--!strict

-- Kill effect "Piece by Piece": ragdoll de Default y se quitan por grupos (brazos,
-- piernas, torso, cabeza) con sus accesorios.
--
-- El TORSO no se destruye, se oculta y ancla: RagdollCleanup usa LowerTorso/Torso para
-- saber cuándo se asentó el cadáver de un bot, y sin él el modelo quedaría para siempre.
-- El HumanoidRootPart no se toca: KillCam lo lee.
--
-- Debe caber en DEFAULT_PREVIEW_TIME de KillEffectsRegistry.
-- Sonido: ReplicatedStorage.Templates.Disassemble (Sound) si existe; si no, CONFIG.SOUND_ID.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local DefaultKillEffect = require(script.Parent.Default)

local CONFIG = {
	START_DELAY = 0.35, -- s de ragdoll antes de quitar el primer grupo
	GROUP_GAP = 0.35, -- s entre grupos
	TEMPLATES_FOLDER = "Templates",
	SOUND_TEMPLATE_NAME = "Disassemble",
	SOUND_ID = "rbxasset://sounds/electronicpingshort.wav", -- PROVISIONAL: sustituir por el definitivo
	SOUND_VOLUME = 0.8,
	PITCH_START = 1,
	PITCH_STEP = 0.12, -- cuánto sube la PlaybackSpeed por grupo
	SOUND_LIFETIME = 3, -- s hasta limpiar el emisor
}

type Group = {
	parts: { string },
	hide: boolean?, -- ocultar y anclar en vez de destruir (ver cabecera)
}

-- Nombres R15 y R6 juntos: en cada rig sólo existen los suyos.
local GROUPS: { Group } = {
	{ parts = { "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand", "Left Arm", "Right Arm" } },
	{ parts = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot", "Left Leg", "Right Leg" } },
	{ parts = { "UpperTorso", "LowerTorso", "Torso" }, hide = true },
	{ parts = { "Head" } },
}

-- Acepta AccessoryWeld o RigidConstraint.
local function accessoryBodyPart(accessory: Accessory): BasePart?
	local handle = accessory:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		return nil
	end
	for _, child in handle:GetChildren() do
		if child:IsA("JointInstance") then
			local other = if child.Part0 == handle then child.Part1 else child.Part0
			if other then
				return other
			end
		elseif child:IsA("RigidConstraint") then
			local att = if child.Attachment0 and child.Attachment0.Parent ~= handle then child.Attachment0 else child.Attachment1
			local other = if att then att.Parent else nil
			if other and other:IsA("BasePart") and other ~= handle then
				return other
			end
		end
	end
	return nil
end

-- Se resuelve antes de que nada se destruya; un accesorio sin soldadura reconocible
-- se va con el último grupo.
local function collectGroups(char: Model): { { parts: { BasePart }, accessories: { Accessory } } }
	local groupOfPart: { [BasePart]: number } = {}
	local result = {}
	for i, group in GROUPS do
		local parts: { BasePart } = {}
		for _, name in group.parts do
			local part = char:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				table.insert(parts, part)
				groupOfPart[part] = i
			end
		end
		table.insert(result, { parts = parts, accessories = {} })
	end
	for _, child in char:GetChildren() do
		if child:IsA("Accessory") then
			local bodyPart = accessoryBodyPart(child)
			local index = if bodyPart then groupOfPart[bodyPart] else nil
			table.insert(result[index or #GROUPS].accessories, child)
		end
	end
	return result
end

local function hidePart(part: BasePart)
	part.Anchored = true
	for _, inst in part:GetDescendants() do
		if inst:IsA("BasePart") then
			-- Cajas internas de autocolisión del ragdoll, etc.
			inst.CanCollide = false
			inst.Transparency = 1
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			inst.Transparency = 1
		elseif inst:IsA("ParticleEmitter") or inst:IsA("Light") or inst:IsA("Beam") or inst:IsA("Trail") then
			inst.Enabled = false
		end
	end
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

local function centroid(parts: { BasePart }): Vector3?
	local sum = Vector3.zero
	local count = 0
	for _, part in parts do
		if part.Parent then
			sum += part.Position
			count += 1
		end
	end
	return if count > 0 then sum / count else nil
end

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

local function playSoundAt(position: Vector3, step: number)
	-- En Terrain: sigue sonando aunque el grupo ya no exista, y es 3D en server y preview.
	local emitter = Instance.new("Attachment")
	emitter.Name = "DisassembleSound"
	emitter.Parent = workspace.Terrain
	emitter.WorldPosition = position

	local sound = makeSound()
	sound.PlaybackSpeed *= CONFIG.PITCH_START + CONFIG.PITCH_STEP * (step - 1)
	sound.Parent = emitter
	sound:Play()
	Debris:AddItem(emitter, CONFIG.SOUND_LIFETIME)
end

local function removeGroup(parts: { BasePart }, accessories: { Accessory }, hide: boolean)
	for _, accessory in accessories do
		accessory:Destroy()
	end
	for _, part in parts do
		if part.Parent then
			if hide then
				hidePart(part)
			else
				part:Destroy()
			end
		end
	end
end

local function disassemble(char: Model, groups: { { parts: { BasePart }, accessories: { Accessory } } })
	task.wait(CONFIG.START_DELAY)
	local step = 0
	for i, group in groups do
		if char.Parent == nil then
			return
		end
		if #group.parts > 0 or #group.accessories > 0 then
			step += 1
			local position = centroid(group.parts)
			removeGroup(group.parts, group.accessories, GROUPS[i].hide == true)
			if position then
				playSoundAt(position, step)
			end
			task.wait(CONFIG.GROUP_GAP)
		end
	end
end

local Disassemble = {}

function Disassemble.apply(char: Model): boolean
	if not char:FindFirstChildWhichIsA("Humanoid", true) then
		return false
	end
	-- Default devuelve false en rigs no R15 (no los ragdollea); se desmontan igual.
	DefaultKillEffect.apply(char)

	-- En un thread: registry y MatchService esperan que apply vuelva al momento.
	task.spawn(disassemble, char, collectGroups(char))
	return true
end

return Disassemble
