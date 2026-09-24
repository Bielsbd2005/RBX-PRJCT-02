--!strict
--[[
	Kill effect Electrocution, parte de cliente (la convulsión es física y la hace
	Shared.Locker.killEffects.Electrocution): mientras dura la descarga el cuerpo parpadea
	azul eléctrico y saltan arcos entre sus piezas.

	Arcos procedurales: Parts Neon anclados que se rehacen cada FLICKER_INTERVAL. Arte
	OPCIONAL en ReplicatedStorage.Templates.Electrocution: sus ParticleEmitter (o ella
	misma, si lo es) se clonan en el torso durante la descarga.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local killEffects = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects")
local Electrocution = require(killEffects:WaitForChild("Electrocution"))
local Utils = require(killEffects:WaitForChild("Utils"))
local GameSounds = require(script.Parent.Parent.Parent.ui.GameSounds)
local Types = require(script.Parent.Parent.KillEffectTypes)

-- Tamaños para un cuerpo normal; se multiplican por su escala.
local CONFIG = {
	FLICKER_INTERVAL = 0.05, -- s
	ARCS_MIN = 2, -- arcos por parpadeo
	ARCS_MAX = 4,
	ARC_SEGMENTS = 5,
	ARC_JITTER = 0.5, -- studs máx de desvío de los puntos intermedios
	ARC_THICKNESS = 0.08,
	ARC_COLORS = { Color3.fromRGB(120, 220, 255), Color3.fromRGB(230, 250, 255) },
	GLOW_COLOR = Color3.fromRGB(90, 190, 255),
	GLOW_FILL_MIN = 0.2, -- FillTransparency del Highlight en cada parpadeo
	GLOW_FILL_MAX = 0.8,
	GLOW_OUTLINE = 0.3,
	LIGHT_RANGE = 12,
	LIGHT_BRIGHTNESS_MIN = 1,
	LIGHT_BRIGHTNESS_MAX = 5,
	FADE_TIME = 0.3, -- s de apagado del brillo al acabar la descarga
	CULL_DISTANCE = 300, -- studs desde la cámara
	PITCH_MIN = 0.95,
	PITCH_MAX = 1.1,
	TORSO_PARTS = { "UpperTorso", "Torso", "HumanoidRootPart" },
	-- Extremos de los arcos: se une una al azar con otra distinta.
	ARC_PARTS = {
		"Head",
		"UpperTorso",
		"LowerTorso",
		"LeftUpperArm",
		"LeftLowerArm",
		"LeftHand",
		"RightUpperArm",
		"RightLowerArm",
		"RightHand",
		"LeftUpperLeg",
		"LeftLowerLeg",
		"LeftFoot",
		"RightUpperLeg",
		"RightLowerLeg",
		"RightFoot",
	},
	TEMPLATES_FOLDER = "Templates",
	TEMPLATE_NAME = "Electrocution",
}

local ElectrocutionVisuals = {}

local _rng = Random.new()
local _folder: Folder? = nil

local function getFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "ElectrocutionVisuals"
	folder.Parent = workspace
	_folder = folder
	return folder
end

local function findPart(char: Model, names: { string }): BasePart?
	for _, name in names do
		local part = char:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function randomPointIn(part: BasePart): Vector3
	local half = part.Size / 2
	return (part.CFrame * CFrame.new(
		_rng:NextNumber(-half.X, half.X),
		_rng:NextNumber(-half.Y, half.Y),
		_rng:NextNumber(-half.Z, half.Z)
	)).Position
end

local function segment(parent: Instance, from: Vector3, to: Vector3, thickness: number, color: Color3)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.new(thickness, thickness, (to - from).Magnitude)
	part.CFrame = CFrame.lookAt((from + to) / 2, to)
	part.Parent = parent
end

-- Zigzag entre dos puntos: los intermedios se desvían al azar, los extremos no.
local function arc(parent: Instance, from: Vector3, to: Vector3, scale: number)
	local color = CONFIG.ARC_COLORS[_rng:NextInteger(1, #CONFIG.ARC_COLORS)]
	local jitter = CONFIG.ARC_JITTER * scale
	local prev = from
	for i = 1, CONFIG.ARC_SEGMENTS do
		local point = from:Lerp(to, i / CONFIG.ARC_SEGMENTS)
		if i < CONFIG.ARC_SEGMENTS then
			point += Vector3.new(
				_rng:NextNumber(-jitter, jitter),
				_rng:NextNumber(-jitter, jitter),
				_rng:NextNumber(-jitter, jitter)
			)
		end
		segment(parent, prev, point, CONFIG.ARC_THICKNESS * scale, color)
		prev = point
	end
end

local function drawArcs(parent: Instance, bodyParts: { BasePart }, scale: number)
	parent:ClearAllChildren()
	for _ = 1, _rng:NextInteger(CONFIG.ARCS_MIN, CONFIG.ARCS_MAX) do
		local a = _rng:NextInteger(1, #bodyParts)
		local b = _rng:NextInteger(1, #bodyParts - 1)
		if b >= a then
			b += 1
		end
		arc(parent, randomPointIn(bodyParts[a]), randomPointIn(bodyParts[b]), scale)
	end
end

local function cloneTemplateEmitters(torso: BasePart, ctx: Types.Ctx): { ParticleEmitter }
	local emitters: { ParticleEmitter } = {}
	local templates = ReplicatedStorage:FindFirstChild(CONFIG.TEMPLATES_FOLDER)
	local template = if templates then templates:FindFirstChild(CONFIG.TEMPLATE_NAME) else nil
	if not template then
		return emitters
	end
	local sources: { Instance } = if template:IsA("ParticleEmitter") then { template } else template:GetDescendants()
	for _, source in sources do
		if source:IsA("ParticleEmitter") then
			local emitter = source:Clone()
			emitter.Enabled = true
			emitter.Parent = torso
			ctx.add(emitter)
			table.insert(emitters, emitter)
		end
	end
	return emitters
end

local function run(char: Model, ctx: Types.Ctx, bodyParts: { BasePart }, torso: BasePart)
	local scale = Utils.bodyScale(char)

	local arcs = Instance.new("Folder")
	arcs.Name = "Arcs"
	arcs.Parent = getFolder()
	ctx.add(arcs)

	-- Fuera del cadáver no abarcaría el cuerpo: apuntarlo explícitamente.
	local highlight = Instance.new("Highlight")
	highlight.FillColor = CONFIG.GLOW_COLOR
	highlight.OutlineColor = CONFIG.GLOW_COLOR
	highlight.OutlineTransparency = CONFIG.GLOW_OUTLINE
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = char
	highlight.Parent = arcs.Parent
	ctx.add(highlight)

	local light = Instance.new("PointLight")
	light.Color = CONFIG.GLOW_COLOR
	light.Range = CONFIG.LIGHT_RANGE * scale
	light.Shadows = false
	light.Parent = torso
	ctx.add(light)

	local emitters = cloneTemplateEmitters(torso, ctx)

	while ctx.age() < Electrocution.SHAKE_TIME do
		drawArcs(arcs, bodyParts, scale)
		highlight.FillTransparency = _rng:NextNumber(CONFIG.GLOW_FILL_MIN, CONFIG.GLOW_FILL_MAX)
		light.Brightness = _rng:NextNumber(CONFIG.LIGHT_BRIGHTNESS_MIN, CONFIG.LIGHT_BRIGHTNESS_MAX)
		task.wait(CONFIG.FLICKER_INTERVAL)
	end

	arcs:ClearAllChildren()
	for _, emitter in emitters do
		emitter.Enabled = false
	end
	local fade = TweenInfo.new(CONFIG.FADE_TIME)
	TweenService:Create(highlight, fade, { FillTransparency = 1, OutlineTransparency = 1 }):Play()
	TweenService:Create(light, fade, { Brightness = 0 }):Play()
	task.wait(CONFIG.FADE_TIME)
	ctx.finish()
end

function ElectrocutionVisuals.play(char: Model, ctx: Types.Ctx)
	if ctx.age() >= Electrocution.SHAKE_TIME then
		return
	end
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - Utils.bodyCenter(char)).Magnitude > CONFIG.CULL_DISTANCE then
		return
	end

	local torso = findPart(char, CONFIG.TORSO_PARTS)
	local bodyParts: { BasePart } = {}
	for _, name in CONFIG.ARC_PARTS do
		local part = char:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			table.insert(bodyParts, part)
		end
	end
	if not torso or #bodyParts < 2 then
		return
	end

	if ctx.isFresh() then
		-- Dentro del cadáver: se limpia con él.
		GameSounds.playAt(GameSounds.Electrocution, torso, _rng:NextNumber(CONFIG.PITCH_MIN, CONFIG.PITCH_MAX))
	end

	ctx.add(task.spawn(run, char, ctx, bodyParts, torso))
end

function ElectrocutionVisuals.stop()
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

return ElectrocutionVisuals
