--!strict

-- Kill effect "Gum Drop!": el cuerpo queda al instante atrapado en una gominola gigante,
-- congelado en una pose flácida, como un insecto en ámbar. Sin física: la pose se
-- calcula aquí (cinemática directa desde el HRP con los C0/C1 del rig más el giro de
-- POSE) y se ESCRIBE en el CFrame de cada pieza con todo anclado. Tiene que ser así:
-- anclar un personaje que aún simulaba su cliente no replica posiciones, y cada cliente
-- se quedaría con la suya (el que corría, más adelante que la gominola). La gominola se
-- ajusta a la caja del cuerpo ya posado (centrada, base en el suelo y escalada si no
-- cabe), así que nada asoma. Corre donde corre apply (servidor en partida, cliente en
-- los previews).
--
-- Arte en ReplicatedStorage.Templates.GumDrop (Model autorado de pie): se coloca por su
-- caja, no por su pivot, y cuelga del cadáver, así que se funde y limpia con él. Sin
-- plantilla, cae al Default. Aquí queda a tamaño final; el crecimiento lo anima cada
-- cliente (visuals/killEffects/GumDrop).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefaultKillEffect = require(script.Parent.Default)
local Utils = require(script.Parent.Utils)

local CONFIG = {
	TEMPLATE_NAME = "GumDrop",
	MARGIN = 0.75, -- studs de aire entre el cuerpo y la pared de la gominola
}

-- Giro extra de cada joint (nombres R15; valen para Motor6D y AnimationConstraint) en
-- los ejes del hueso padre. X: lo que sube (tronco, cabeza) se inclina hacia delante
-- con negativo y lo que cuelga (brazos) se adelanta con positivo. Z: balanceo lateral.
local POSE: { [string]: CFrame } = {
	Root = CFrame.Angles(-0.12, 0, 0.08),
	Waist = CFrame.Angles(-0.3, 0.15, 0.08),
	Neck = CFrame.Angles(-0.55, 0.25, 0.2),
	LeftShoulder = CFrame.Angles(0.35, 0, -0.25),
	RightShoulder = CFrame.Angles(0.25, 0, 0.35),
	LeftElbow = CFrame.Angles(0.45, 0, 0),
	RightElbow = CFrame.Angles(0.6, 0, 0),
	LeftWrist = CFrame.Angles(0.3, 0, 0),
	RightWrist = CFrame.Angles(0.25, 0, 0),
	LeftHip = CFrame.Angles(-0.2, 0, -0.12),
	RightHip = CFrame.Angles(0.15, 0, 0.1),
	LeftKnee = CFrame.Angles(-0.5, 0, 0),
	RightKnee = CFrame.Angles(-0.35, 0, 0),
	LeftAnkle = CFrame.Angles(-0.3, 0, 0),
	RightAnkle = CFrame.Angles(-0.35, 0, 0),
}

type Box = { min: Vector3, max: Vector3 }
-- child.CFrame = parent.CFrame * c0 * POSE[name] * c1:Inverse()
type Bone = { name: string, child: BasePart, c0: CFrame, c1: CFrame }

local GumDrop = {}

GumDrop.previewTime = 3
-- Contrato con visuals/killEffects/GumDrop: nombre de la gominola dentro del cadáver y
-- atributo con su número de piezas (el cliente espera a tenerlas todas para animarla).
GumDrop.DROP_NAME = "GumDrop"
GumDrop.ATTR_PARTS = "GumDropParts"

-- Caja alineada al mundo de las piezas visibles. Sin el HRP: invisible.
local function boundsOf(root: Instance): Box?
	local box: Box? = nil
	for _, desc in root:GetDescendants() do
		if not desc:IsA("BasePart") or desc.Name == "HumanoidRootPart" or desc.Transparency >= 1 then
			continue
		end
		local cf, half = desc.CFrame, desc.Size / 2
		local extent = Vector3.new(
			math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z,
			math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z,
			math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
		)
		local lo, hi = cf.Position - extent, cf.Position + extent
		if box then
			box.min = box.min:Min(lo)
			box.max = box.max:Max(hi)
		else
			box = { min = lo, max = hi }
		end
	end
	return box
end

local function findTemplate(): Model?
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	local template = if templates then templates:FindFirstChild(CONFIG.TEMPLATE_NAME) else nil
	return if template and template:IsA("Model") and boundsOf(template) then template else nil
end

-- Huesos por parte padre. Motor6D (personajes de partida) y AnimationConstraint
-- (Shared.Bodies, previews). Se lee la pose de reposo del rig, no la animación en curso.
local function collectBones(char: Model): { [BasePart]: { Bone } }
	local bones: { [BasePart]: { Bone } } = {}
	local function add(parent: Instance?, child: Instance?, name: string, c0: CFrame, c1: CFrame)
		if not parent or not child or not parent:IsA("BasePart") or not child:IsA("BasePart") then
			return
		end
		local list = bones[parent]
		if not list then
			list = {}
			bones[parent] = list
		end
		table.insert(list, { name = name, child = child, c0 = c0, c1 = c1 })
	end
	for _, desc in char:GetDescendants() do
		if desc:IsA("Motor6D") then
			add(desc.Part0, desc.Part1, desc.Name, desc.C0, desc.C1)
		elseif desc:IsA("AnimationConstraint") then
			local att0, att1 = desc.Attachment0, desc.Attachment1
			if att0 and att1 then
				add(att0.Parent, att1.Parent, desc.Name, att0.CFrame, att1.CFrame)
			end
		end
	end
	return bones
end

-- De pie y mirando hacia donde miraba, aunque muriera inclinado en un salto.
local function uprightRoot(root: BasePart): CFrame
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	if look.Magnitude < 1e-3 then
		return CFrame.new(root.Position)
	end
	return CFrame.lookAt(root.Position, root.Position + look)
end

local function pose(char: Model, root: BasePart)
	local bones = collectBones(char)

	-- Ropa y accesorios: su offset respecto a la parte del cuerpo de la que cuelgan,
	-- ANTES de mover nada (una Weld clásica entre partes ancladas no arrastra).
	local bodyParts: { BasePart } = {}
	local isBody: { [BasePart]: boolean } = {}
	for _, child in char:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(bodyParts, child)
			isBody[child] = true
		end
	end
	local hanging: { { part: BasePart, owner: BasePart, offset: CFrame } } = {}
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") and not isBody[desc] then
			local owner = Utils.ownerBodyPart(desc, isBody, bodyParts)
			if owner then
				table.insert(hanging, { part = desc, owner = owner, offset = owner.CFrame:Inverse() * desc.CFrame })
			end
		end
	end

	-- Todo anclado y sin joints de rig: cada CFrame que se escribe se queda, y ningún
	-- cliente los vuelve a resolver por su cuenta.
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
		elseif Utils.isRigJoint(desc) then
			desc:Destroy()
		end
	end

	root.CFrame = uprightRoot(root)
	local visited: { [BasePart]: boolean } = { [root] = true }
	local queue: { BasePart } = { root }
	local head = 1
	while head <= #queue do
		local parent = queue[head]
		head += 1
		for _, bone in bones[parent] or {} do
			if visited[bone.child] then
				continue
			end
			visited[bone.child] = true
			bone.child.CFrame = parent.CFrame * bone.c0 * (POSE[bone.name] or CFrame.identity) * bone.c1:Inverse()
			table.insert(queue, bone.child)
		end
	end

	for _, item in hanging do
		item.part.CFrame = item.owner.CFrame * item.offset
	end
end

local function ratio(need: number, have: number): number
	return if have > 1e-3 then need / have else 1
end

-- Escala (solo hacia arriba) y coloca la gominola para que la caja del cuerpo quede
-- dentro: centrada en XZ y con la base en baseY. Devuelve el pivot final.
local function fitAround(drop: Model, body: Box, baseY: number): CFrame
	local center = body.min:Lerp(body.max, 0.5)
	drop:PivotTo(CFrame.new(center))
	local gum = boundsOf(drop) :: Box
	local gumSize = gum.max - gum.min
	local bodySize = body.max - body.min
	local scale = math.max(
		1,
		ratio(bodySize.X + 2 * CONFIG.MARGIN, gumSize.X),
		ratio(body.max.Y - baseY + CONFIG.MARGIN, gumSize.Y),
		ratio(bodySize.Z + 2 * CONFIG.MARGIN, gumSize.Z)
	)
	if scale > 1 then
		drop:ScaleTo(drop:GetScale() * scale)
		gum = boundsOf(drop) :: Box
	end
	local gumCenter = gum.min:Lerp(gum.max, 0.5)
	return drop:GetPivot() + Vector3.new(center.X - gumCenter.X, baseY - gum.min.Y, center.Z - gumCenter.Z)
end

local function cover(char: Model, template: Model, root: BasePart)
	local body = boundsOf(char)
	if not body then
		return
	end
	local ground = Utils.findGround(root.Position, char)
	local baseY = if ground then math.min(ground.Position.Y, body.min.Y) else body.min.Y
	local drop = template:Clone()
	drop.Name = GumDrop.DROP_NAME
	Utils.makeCosmetic(drop)
	drop:PivotTo(fitAround(drop, body, baseY))
	local partCount = 0
	for _, desc in drop:GetDescendants() do
		if desc:IsA("BasePart") then
			partCount += 1
		end
	end
	drop:SetAttribute(GumDrop.ATTR_PARTS, partCount)
	drop.Parent = char
end

function GumDrop.apply(char: Model): boolean
	local template = findTemplate()
	local root = char:FindFirstChild("HumanoidRootPart")
	if not template or not root or not root:IsA("BasePart") then
		return DefaultKillEffect.apply(char)
	end

	local hum = char:FindFirstChildWhichIsA("Humanoid", true)
	if hum then
		Utils.releaseHumanoid(hum)
	end
	pose(char, root)
	Utils.makeCorpseInert(char)
	cover(char, template, root)
	return true
end

return GumDrop
