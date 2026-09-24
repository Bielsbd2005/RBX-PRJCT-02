--!strict

-- Kill effect "Noobified": al morir el cuerpo se convierte en el noob clásico (cabeza y
-- brazos amarillos, torso azul, piernas verdes, cara sonriente de siempre y sin ropa
-- ni accesorios) y cae en ragdoll de Default.
--
-- Todo son propiedades replicadas y sin animar, así que va entero aquí (servidor en
-- partida, cliente en los previews), sin parte de cliente.
-- Sonido: ReplicatedStorage.Templates.Noobify (Sound) si existe; sin él, en silencio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefaultKillEffect = require(script.Parent.Default)

local YELLOW = Color3.fromRGB(245, 205, 48)
local BLUE = Color3.fromRGB(13, 105, 172)
local GREEN = Color3.fromRGB(164, 189, 71)

local CONFIG = {
	FACE_TEXTURE = "rbxasset://textures/face.png", -- la sonrisa clásica que trae el motor
	TEMPLATES_FOLDER = "Templates",
	SOUND_TEMPLATE_NAME = "Noobify",
	-- Nombres R15 y R6 juntos: en cada rig solo existen los suyos.
	COLORS = {
		Head = YELLOW,
		LeftUpperArm = YELLOW, LeftLowerArm = YELLOW, LeftHand = YELLOW,
		RightUpperArm = YELLOW, RightLowerArm = YELLOW, RightHand = YELLOW,
		["Left Arm"] = YELLOW, ["Right Arm"] = YELLOW,
		UpperTorso = BLUE, LowerTorso = BLUE, Torso = BLUE,
		LeftUpperLeg = GREEN, LeftLowerLeg = GREEN, LeftFoot = GREEN,
		RightUpperLeg = GREEN, RightLowerLeg = GREEN, RightFoot = GREEN,
		["Left Leg"] = GREEN, ["Right Leg"] = GREEN,
	} :: { [string]: Color3 },
}

local Noobify = {}

local function playSound(char: Model)
	local templates = ReplicatedStorage:FindFirstChild(CONFIG.TEMPLATES_FOLDER)
	local template = if templates then templates:FindFirstChild(CONFIG.SOUND_TEMPLATE_NAME) else nil
	local head = char:FindFirstChild("Head")
	if template and template:IsA("Sound") and template.SoundId ~= "" and head then
		-- Dentro del cadáver: se limpia con él.
		local sound = template:Clone()
		sound.Parent = head
		sound:Play()
	end
end

local function paintBodyPart(part: BasePart, color: Color3)
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Reflectance = 0
	if part:IsA("MeshPart") then
		part.TextureID = ""
	end
	for _, child in part:GetChildren() do
		-- SurfaceAppearance tapa el Color; la cara se rehace aparte.
		if child:IsA("SurfaceAppearance") or child:IsA("Decal") then
			child:Destroy()
		end
	end
end

local function setClassicFace(head: BasePart)
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Face = Enum.NormalId.Front
	face.Texture = CONFIG.FACE_TEXTURE
	face.Parent = head
end

function Noobify.apply(char: Model): boolean
	local bodyParts: { [BasePart]: boolean } = {}
	for _, child in char:GetChildren() do
		local color = CONFIG.COLORS[child.Name]
		if color and child:IsA("BasePart") then
			paintBodyPart(child, color)
			bodyParts[child] = true
		end
	end

	-- Fuera ropa y accesorios: Accessory, Shirt/Pants clásicos, BodyColors (repintaría
	-- encima) y cualquier prenda suelta del outfit. El HRP y lo que cuelga dentro de las
	-- partes del cuerpo se quedan.
	for _, child in char:GetChildren() do
		if
			child:IsA("Accessory")
			or child:IsA("Clothing")
			or child:IsA("ShirtGraphic")
			or child:IsA("BodyColors")
			or (child:IsA("BasePart") and not bodyParts[child] and child.Name ~= "HumanoidRootPart")
			or ((child:IsA("Model") or child:IsA("Folder")) and child:FindFirstChildWhichIsA("BasePart", true))
		then
			child:Destroy()
		end
	end

	local head = char:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		setClassicFace(head)
	end

	DefaultKillEffect.apply(char)
	playSound(char)
	return true
end

return Noobify
