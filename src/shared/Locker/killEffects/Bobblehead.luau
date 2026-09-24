--!strict

-- Kill effect "Bobblehead": al morir el cuerpo encoge y la cabeza se infla al instante,
-- y cae en ragdoll de Default con esas proporciones.
--
-- Se transforma justo ANTES del ragdoll, en el mismo frame: Default construye joints y
-- cajas internas con los RigAttachments y tamaños ya escalados. Mientras, todo va
-- anclado y sin joints del rig: con Motor6D, mover la cabeza arrastraría al assembly.
-- Instantáneo a propósito: animarlo con el cuerpo congelado o ya en ragdoll se ve raro.
-- El cuerpo usa Model:ScaleTo (escala tamaños, attachments y mallas de accesorios); la
-- cabeza y lo que cuelga de ella se escalan a mano alrededor del cuello.
-- Sonido: ReplicatedStorage.Templates.Bobblehead (Sound) si existe; sin él, en silencio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefaultKillEffect = require(script.Parent.Default)
local Utils = require(script.Parent.Utils)

local CONFIG = {
	BODY_SCALE = 0.55, -- tamaño final del cuerpo respecto al original
	HEAD_SCALE = 1.6, -- tamaño final de la cabeza respecto a la original
	TEMPLATES_FOLDER = "Templates",
	SOUND_TEMPLATE_NAME = "Bobblehead",
}

local Bobblehead = {}

type Transform = {
	char: Model,
	head: BasePart,
	headGroup: { BasePart }, -- partes que cuelgan de la cabeza (accesorios, pelo...)
	baseModelScale: number,
	baseHeadHeight: number,
	anchor: Vector3, -- X/Z del HRP e Y de los pies al morir: el cuerpo encoge hacia ahí
}

local function playSound(head: BasePart)
	local templates = ReplicatedStorage:FindFirstChild(CONFIG.TEMPLATES_FOLDER)
	local template = if templates then templates:FindFirstChild(CONFIG.SOUND_TEMPLATE_NAME) else nil
	if template and template:IsA("Sound") and template.SoundId ~= "" then
		-- Dentro del cadáver: se limpia con él.
		local sound = template:Clone()
		sound.Parent = head
		sound:Play()
	end
end

-- Todo lo que cuelga de la cabeza. Se resuelve antes de tocar ningún joint.
local function collectHeadGroup(char: Model, head: BasePart): { BasePart }
	local bodyParts: { BasePart } = {}
	local isBody: { [BasePart]: boolean } = {}
	for _, child in char:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
			table.insert(bodyParts, child)
			isBody[child] = true
		end
	end
	local group: { BasePart } = {}
	for _, desc in char:GetDescendants() do
		if
			desc:IsA("BasePart")
			and not isBody[desc]
			and desc.Name ~= "HumanoidRootPart"
			and Utils.ownerBodyPart(desc, isBody, bodyParts) == head
		then
			table.insert(group, desc)
		end
	end
	return group
end

local function neckPoint(head: BasePart): Vector3
	local neck = head:FindFirstChild("NeckRigAttachment")
	if neck and neck:IsA("Attachment") then
		return neck.WorldPosition
	end
	return head.Position - head.CFrame.UpVector * (head.Size.Y / 2)
end

-- Escala uniforme de `part` alrededor de `pivot`: tamaño, posición, attachments y
-- mallas FileMesh (las demás SpecialMesh ya siguen al tamaño de la parte).
local function scalePartAbout(part: BasePart, pivot: Vector3, k: number)
	local cf = part.CFrame
	part.Size *= k
	part.CFrame = cf.Rotation + (pivot + (cf.Position - pivot) * k)
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") then
			child.Position *= k
		elseif child:IsA("SpecialMesh") and child.MeshType == Enum.MeshType.FileMesh then
			child.Scale *= k
		end
	end
end

local function rootPosition(char: Model): Vector3?
	local root = char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function applyScales(t: Transform, bodyScale: number, headScale: number)
	local char = t.char
	char:ScaleTo(t.baseModelScale * bodyScale)

	-- ScaleTo escala respecto al pivot del modelo, que en el doble del Locker ni siquiera
	-- está en el cuerpo: se devuelve el HRP a su X/Z y los pies a su altura.
	local rootPos = rootPosition(char)
	local bottom = Utils.lowestWorldY(char)
	if rootPos and bottom then
		local delta = Vector3.new(t.anchor.X - rootPos.X, t.anchor.Y - bottom, t.anchor.Z - rootPos.Z)
		char:PivotTo(char:GetPivot() + delta)
	end

	local wanted = t.baseHeadHeight * headScale
	local k = wanted / t.head.Size.Y
	local pivot = neckPoint(t.head)
	scalePartAbout(t.head, pivot, k)
	for _, part in t.headGroup do
		scalePartAbout(part, pivot, k)
	end
end

local function begin(char: Model): Transform?
	local head = char:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		return nil
	end
	local headGroup = collectHeadGroup(char, head)

	-- Anclado y sin joints del rig ni soldaduras de la cabeza: cada parte se mueve sola.
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
		elseif Utils.isRigJoint(desc) then
			desc:Destroy()
		end
	end
	for _, part in headGroup do
		for _, joint in part:GetJoints() do
			joint:Destroy()
		end
	end

	local rootPos = rootPosition(char)
	local bottom = Utils.lowestWorldY(char)
	return {
		char = char,
		head = head,
		headGroup = headGroup,
		baseModelScale = char:GetScale(),
		baseHeadHeight = head.Size.Y,
		anchor = Vector3.new(
			if rootPos then rootPos.X else head.Position.X,
			bottom or head.Position.Y,
			if rootPos then rootPos.Z else head.Position.Z
		),
	}
end

local function finish(t: Transform)
	-- Lo de la cabeza vuelve a ir soldado a ella para el ragdoll.
	for _, part in t.headGroup do
		if part.Parent then
			Utils.createWeld(t.head, part)
		end
	end
	DefaultKillEffect.apply(t.char)
end

function Bobblehead.apply(char: Model): boolean
	local t = begin(char)
	if not t then
		return DefaultKillEffect.apply(char)
	end
	local transform = t :: Transform
	playSound(transform.head)

	-- pcall: si ScaleTo falla con algún rig raro, que al menos caiga en ragdoll.
	local ok, err = pcall(applyScales, transform, CONFIG.BODY_SCALE, CONFIG.HEAD_SCALE)
	if not ok then
		warn("[Bobblehead] " .. tostring(err))
	end
	finish(transform)
	return true
end

return Bobblehead
