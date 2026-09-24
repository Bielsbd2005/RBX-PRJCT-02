--!strict
--[[
	Kill effect Flattened, parte de cliente (el servidor solo ancla el cuerpo y lo
	vuelve inerte). Secuencia, en segundos desde la muerte:
	  0 → golpe    cae un yunque; su sombra crece en el suelo; justo antes del golpe el
	               cuerpo se estira (anticipación)
	  golpe        el cuerpo se aplasta y ensancha pegado a la base del yunque
	  suelo        el cuerpo pasa a ser una pegatina (bamboleo), polvo, estrellitas
	               girando; el yunque rebota y se queda encima
	Yunque y pegatina duran lo que el cadáver: se funden con él (bots) y, si se borra
	de golpe (respawn, fin del preview), se desvanecen en VANISH_TIME en vez de cortarse.

	El cuerpo real se oculta al empezar y en su lugar va una copia local anclada (la
	"marioneta"): tal cual se veía, ropa incluida, y se deforma sin física ni red. Todo
	se anima por ctx.age(): fluido en cada cliente y quien llega tarde entra a mitad.

	La marioneta y la copia de la pegatina llevan Humanoid (sin él no se ve la ropa
	clásica). La marioneta va dentro de un Model y sin atributos: así
	HealthBillboardController y CharacterHighlightController no la toman por un
	personaje. La pegatina va en un SurfaceGui de PlayerGui con Adornee a la parte.

	Plantillas (ReplicatedStorage.Templates):
	  Flattened  BasePart plana con un SurfaceGui (en la cara donde se verá la pegatina)
	             y dentro un ViewportFrame. Sound y ParticleEmitter dentro, opcionales
	             (EmitCount como atributo del emisor): suenan/salen al tocar el suelo.
	  Anvil      MeshPart o Model. Sound dentro, opcional: suena al golpear. Sin él se
	             aplasta al momento.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Utils = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Locker"):WaitForChild("killEffects"):WaitForChild("Utils")
)
local Types = require(script.Parent.Parent.KillEffectTypes)

-- Tiempos en s y distancias en studs para un cuerpo normal (se escalan con él).
local CONFIG = {
	TEMPLATE_NAME = "Flattened",
	ANVIL_NAME = "Anvil",
	FOV = 30, -- grados de la cámara del ViewportFrame
	LIFT = 0.02, -- sobre el suelo para que no parpadee con él
	DEFAULT_EMIT = 10, -- partículas por emisor si no traen atributo EmitCount
	LATE_TOLERANCE = 0.5, -- retraso máximo con el que aún suena y salen partículas

	-- Yunque: cae acelerando desde DROP_HEIGHT sobre la cabeza hasta posarse en la pegatina.
	DROP_HEIGHT = 14,
	FALL_TIME = 0.5,
	BOUNCE_HEIGHT = 0.35,
	BOUNCE_TIME = 0.18,
	VANISH_TIME = 0.35, -- desvanecido de yunque y pegatina al borrarse el cadáver

	-- Marioneta.
	STRETCH_TIME = 0.14, -- antes del golpe, se estira hacia arriba
	STRETCH = 0.07, -- fracción que se estira
	SPREAD = 0.5, -- ensanche por cada unidad aplastada
	MIN_SQUASH = 0.08, -- altura mínima antes de pasar a pegatina

	-- Pegatina: crece desde POP_SCALE con bamboleo (Elastic).
	POP_TIME = 0.55,
	POP_SCALE = 0.55,

	-- Sombra del yunque, respecto a su huella.
	SHADOW_MIN = 0.3,
	SHADOW_MAX = 1.1,
	SHADOW_DARKNESS = 0.5, -- opacidad máxima

	-- Anillo de polvo al tocar el suelo, respecto a la huella del yunque.
	DUST_GROWTH = 3,
	DUST_TIME = 0.45,
	DUST_START_TRANSPARENCY = 0.3,

	-- Estrellitas del mareo sobre la pegatina.
	STAR_COUNT = 3,
	STAR_RADIUS = 1.1,
	STAR_HEIGHT = 0.9,
	STAR_SIZE = 0.35,
	STAR_SPIN = 7, -- rad/s
	STAR_BOB = 0.15,
	STAR_TIME = 1.6,
	STAR_FADE = 0.3,
	STAR_COLOR = Color3.fromRGB(255, 221, 64),
}

local DUST_FALLBACK = Color3.fromRGB(150, 130, 105)
local SHADOW_COLOR = Color3.new(0, 0, 0)
local FLAT = CFrame.Angles(0, 0, math.pi / 2) -- Cylinder tumbado: el disco mira arriba

type PuppetPart = {
	part: BasePart,
	cf: CFrame,
	size: Vector3,
	mesh: SpecialMesh?,
	meshScale: Vector3,
}

local Flattened = {}

local _folder: Folder? = nil
local _warnedMissing = false

local function debugWarn(message: string)
	if RunService:IsStudio() then
		warn("[Flattened] " .. message)
	end
end

local function getFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "FlattenedVisuals"
	folder.Parent = workspace
	_folder = folder
	return folder
end

local function findTemplate(name: string, warnIfMissing: boolean): Instance?
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	local template = if templates then templates:FindFirstChild(name) else nil
	if not template and warnIfMissing and not _warnedMissing then
		_warnedMissing = true
		debugWarn(`falta ReplicatedStorage.Templates.{name}`)
	end
	return template
end

-- Copia del personaje tal cual se ve ahora, sin nada que ejecute, suene o se marque.
local function cloneCharacter(char: Model): Model?
	local wasArchivable = char.Archivable
	char.Archivable = true
	local copy = char:Clone()
	char.Archivable = wasArchivable
	if not copy then
		return nil
	end

	local toDestroy: { Instance } = {}
	for _, desc in copy:GetDescendants() do
		if
			desc:IsA("BaseScript")
			or desc:IsA("ModuleScript")
			or desc:IsA("Sound")
			or desc:IsA("ParticleEmitter")
			or desc:IsA("Highlight")
			or desc:IsA("BillboardGui")
		then
			table.insert(toDestroy, desc)
		else
			-- Sin tags: el del propio efecto volvería a disparar el runner con la copia.
			for _, tag in desc:GetTags() do
				desc:RemoveTag(tag)
			end
		end
	end
	for _, inst in toDestroy do
		inst:Destroy()
	end
	for _, tag in copy:GetTags() do
		copy:RemoveTag(tag)
	end
	-- Sin atributos de equipo: CharacterHighlightController no la trackea.
	for name in copy:GetAttributes() do
		copy:SetAttribute(name, nil)
	end
	local hum = copy:FindFirstChildWhichIsA("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	return copy
end

-- Tumbado boca arriba en el origen del ViewportFrame: el torso en (0, 0, 0), la cara
-- mirando a +Y (hacia la cámara) y la cabeza hacia +Z.
local function layFlat(copy: Model)
	local center = copy:FindFirstChild("HumanoidRootPart") or copy:FindFirstChild("UpperTorso") or copy:FindFirstChild("Torso")
	if not (center and center:IsA("BasePart")) then
		return
	end
	-- Sin el giro del personaje: la pegatina ya se orienta con la parte.
	local _, yaw, _ = center.CFrame:ToEulerAnglesYXZ()
	local upright = CFrame.new(center.Position) * CFrame.Angles(0, yaw, 0)
	copy:PivotTo(CFrame.Angles(math.pi / 2, 0, 0) * upright:ToObjectSpace(copy:GetPivot()))
end

local function hideLocally(char: Model)
	for _, desc in char:GetDescendants() do
		if desc:IsA("BasePart") or desc:IsA("Decal") then -- Texture hereda de Decal
			desc.Transparency = 1
		end
	end
end

local function highestWorldY(root: Instance): number?
	local maxY: number? = nil
	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") and desc.Transparency < 1 then
			local cf = desc.CFrame
			local half = desc.Size / 2
			local extentY = math.abs(cf.RightVector.Y) * half.X
				+ math.abs(cf.UpVector.Y) * half.Y
				+ math.abs(cf.LookVector.Y) * half.Z
			local y = cf.Position.Y + extentY
			if maxY == nil or y > (maxY :: number) then
				maxY = y
			end
		end
	end
	return maxY
end

local function emitParticles(part: BasePart)
	for _, desc in part:GetDescendants() do
		if desc:IsA("ParticleEmitter") then
			local count = desc:GetAttribute("EmitCount")
			desc:Emit(if type(count) == "number" then count else CONFIG.DEFAULT_EMIT)
		end
	end
end

local function dustColor(hit: RaycastResult?): Color3
	local base = DUST_FALLBACK
	local inst = if hit then hit.Instance else nil
	if hit and inst and inst:IsA("Terrain") then
		local material = hit.Material
		-- pcall: GetMaterialColor lanza con materiales que no son de terreno.
		local ok, color = pcall(function()
			return (inst :: Terrain):GetMaterialColor(material)
		end)
		if ok then
			base = color
		end
	elseif inst and inst:IsA("BasePart") then
		base = inst.Color
	end
	return base:Lerp(Color3.new(1, 1, 1), 0.2)
end

local function makeFxPart(shape: Enum.PartType, color: Color3): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = color
	part.Transparency = 1
	part.Parent = getFolder()
	return part
end

-- Copia anclada del cuerpo que se deforma a mano: sin joints (cada pieza se mueve sola)
-- y dentro de un Model (ver cabecera).
local function makePuppet(char: Model): (Model?, { PuppetPart })
	local copy = cloneCharacter(char)
	if not copy then
		return nil, {}
	end
	Utils.makeCosmetic(copy)
	local joints: { Instance } = {}
	local parts: { PuppetPart } = {}
	for _, desc in copy:GetDescendants() do
		if desc:IsA("JointInstance") or desc:IsA("WeldConstraint") or desc:IsA("Constraint") then
			table.insert(joints, desc)
		elseif desc:IsA("BasePart") then
			local mesh = desc:FindFirstChildWhichIsA("SpecialMesh")
			local fileMesh = if mesh and mesh.MeshType == Enum.MeshType.FileMesh then mesh else nil
			table.insert(parts, {
				part = desc,
				cf = desc.CFrame,
				size = desc.Size,
				mesh = fileMesh,
				meshScale = if fileMesh then fileMesh.Scale else Vector3.one,
			})
		end
	end
	for _, joint in joints do
		joint:Destroy()
	end
	local hum = copy:FindFirstChildWhichIsA("Humanoid")
	if hum then
		pcall(Utils.releaseHumanoid, hum)
	end
	local wrapper = Instance.new("Model")
	wrapper.Name = "FlattenedPuppet"
	copy.Parent = wrapper
	wrapper.Parent = getFolder()
	return wrapper, parts
end

-- Escala alrededor de `origin`: `sxz` en horizontal y `sy` en vertical. Cada pieza
-- conserva su giro y su tamaño se escala por cuánto crece cada uno de sus ejes.
local function deform(puppet: { PuppetPart }, origin: Vector3, sy: number, sxz: number)
	local function axisScale(v: Vector3): number
		return Vector3.new(v.X * sxz, v.Y * sy, v.Z * sxz).Magnitude
	end
	for _, p in puppet do
		local cf = p.cf
		local rel = cf.Position - origin
		local k = Vector3.new(axisScale(cf.RightVector), axisScale(cf.UpVector), axisScale(cf.LookVector))
		p.part.Size = p.size * k
		p.part.CFrame = cf.Rotation + (origin + Vector3.new(rel.X * sxz, rel.Y * sy, rel.Z * sxz))
		if p.mesh then
			p.mesh.Scale = p.meshScale * k
		end
	end
end

local function basePartsOf(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	return parts
end

local function footprint(root: PVInstance): number
	local size = if root:IsA("Model") then root:GetExtentsSize() elseif root:IsA("BasePart") then root.Size else Vector3.one
	return math.max(size.X, size.Z, 1)
end

local function discSize(diameter: number): Vector3
	return Vector3.new(0.05, diameter, diameter)
end

function Flattened.play(char: Model, ctx: Types.Ctx)
	local stickerTemplate = findTemplate(CONFIG.TEMPLATE_NAME, true)
	local localPlayer = Players.LocalPlayer
	local playerGui = if localPlayer then localPlayer:FindFirstChildOfClass("PlayerGui") else nil
	if not (stickerTemplate and stickerTemplate:IsA("BasePart") and playerGui) then
		return
	end

	-- Todo lo que se lee del cuerpo, ANTES de ocultarlo.
	local scale = Utils.bodyScale(char)
	local deathPivot = Utils.deathCFrame(char)
	local hit = Utils.findGround(deathPivot.Position, char)
	local groundY = if hit then hit.Position.Y else (Utils.lowestWorldY(char) or deathPivot.Position.Y)
	local headTop = math.max(highestWorldY(char) or (deathPivot.Position.Y + 2 * scale), groundY + 0.5)
	local _, yaw, _ = deathPivot:ToEulerAnglesYXZ()
	local facing = CFrame.Angles(0, yaw, 0)
	local spot = Vector3.new(deathPivot.Position.X, groundY, deathPivot.Position.Z)

	-- Pegatina, lista pero sin mostrar.
	local sticker = stickerTemplate:Clone()
	local gui = sticker:FindFirstChildWhichIsA("SurfaceGui", true)
	local viewport = if gui then gui:FindFirstChildWhichIsA("ViewportFrame", true) else nil
	local stickerCopy = cloneCharacter(char)
	if not (gui and viewport and stickerCopy) then
		debugWarn(`la plantilla {CONFIG.TEMPLATE_NAME} no tiene SurfaceGui con ViewportFrame`)
		return
	end
	Utils.makeCosmetic(sticker)
	-- Apoyada por su punto más bajo: no se asume qué cara de la plantilla es la plana.
	sticker.CFrame = CFrame.new(spot) * facing * stickerTemplate.CFrame.Rotation
	local stickerBottom = Utils.lowestWorldY(sticker)
	if stickerBottom then
		sticker.CFrame += Vector3.new(0, groundY - stickerBottom + CONFIG.LIFT, 0)
	end
	local stickerSize = sticker.Size
	-- Las dos medidas mayores son la cara de la pegatina; la menor, su grosor.
	local dims = { stickerSize.X, stickerSize.Y, stickerSize.Z }
	table.sort(dims, function(a, b)
		return a > b
	end)
	local stickerTop = groundY + CONFIG.LIFT + dims[3]

	for _, child in viewport:GetChildren() do
		if child:IsA("Camera") or child:IsA("Model") then
			child:Destroy()
		end
	end
	layFlat(stickerCopy)
	stickerCopy.Parent = viewport
	-- Encuadre 1:1: la cámara ve en vertical lo que mide el lado corto de la cara.
	local distance = dims[2] / (2 * math.tan(math.rad(CONFIG.FOV) / 2))
	local camera = Instance.new("Camera")
	camera.FieldOfView = CONFIG.FOV
	camera.CFrame = CFrame.lookAt(Vector3.new(0, distance, 0), Vector3.zero, Vector3.zAxis)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	gui.Adornee = sticker
	-- Si no, desaparece al reaparecer el jugador local aunque el cadáver siga.
	gui.ResetOnSpawn = false

	-- Yunque (si hay) y pegatina se desvanecen juntos: con el fundido del cadáver o, si
	-- este se borra antes, en VANISH_TIME. Después se destruyen.
	local anvilFadeParts: { BasePart } = {}
	local function fadeAway(duration: number)
		local info = TweenInfo.new(duration, Enum.EasingStyle.Linear)
		TweenService:Create(viewport, info, { ImageTransparency = 1 }):Play()
		for _, part in anvilFadeParts do
			if part.Parent then
				TweenService:Create(part, info, { Transparency = 1 }):Play()
			end
		end
	end
	local anvilRef: Instance? = nil
	ctx.onFadeOut(fadeAway)
	ctx.add(function()
		fadeAway(CONFIG.VANISH_TIME)
		local toDestroy: { Instance? } = { sticker, gui, anvilRef }
		task.delay(CONFIG.VANISH_TIME, function()
			for _, inst in toDestroy do
				if inst then
					inst:Destroy()
				end
			end
		end)
	end)

	local function showSticker(fresh: boolean)
		sticker.Size = stickerSize * CONFIG.POP_SCALE
		sticker.Parent = getFolder()
		gui.Parent = playerGui
		TweenService:Create(
			sticker,
			TweenInfo.new(CONFIG.POP_TIME, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
			{ Size = stickerSize }
		):Play()
		if fresh then
			emitParticles(sticker)
			local sound = sticker:FindFirstChildWhichIsA("Sound", true)
			if sound then
				sound:Play()
			end
		end
	end

	local anvilTemplate = findTemplate(CONFIG.ANVIL_NAME, false)
	if not (anvilTemplate and (anvilTemplate:IsA("BasePart") or anvilTemplate:IsA("Model"))) then
		hideLocally(char)
		showSticker(ctx.isFresh(CONFIG.LATE_TOLERANCE))
		return
	end
	local anvilSource = anvilTemplate :: PVInstance

	-- Línea de tiempo (s desde la muerte).
	local landAt = CONFIG.FALL_TIME
	local fromY = headTop + CONFIG.DROP_HEIGHT * scale
	local fall = fromY - stickerTop
	-- Cae con aceleración constante (t²): toca la cabeza en hitAt.
	local hitAt = landAt * math.sqrt(math.clamp((fromY - headTop) / math.max(fall, 1e-3), 0, 1))
	local endAt = landAt + math.max(CONFIG.BOUNCE_TIME, CONFIG.STAR_TIME, CONFIG.DUST_TIME)
	local age0 = ctx.age()

	-- Yunque.
	local anvil = anvilSource:Clone()
	anvilRef = anvil
	Utils.makeCosmetic(anvil)
	if anvil:IsA("Model") then
		anvil:ScaleTo(anvil:GetScale() * scale)
	elseif anvil:IsA("BasePart") then
		anvil.Size *= scale
	end
	local anvilRotation = facing * anvilSource:GetPivot().Rotation
	anvil:PivotTo(CFrame.new(spot) * anvilRotation)
	local pivotToBottom = spot.Y - (Utils.lowestWorldY(anvil) or spot.Y)
	local anvilWidth = footprint(anvil)
	anvilFadeParts = basePartsOf(anvil)
	local impactSound = anvil:FindFirstChildWhichIsA("Sound", true)

	local function anvilBottomAt(t: number): number
		if t < landAt then
			local a = t / landAt
			return fromY - fall * a * a
		end
		local u = (t - landAt) / CONFIG.BOUNCE_TIME
		if u < 1 then
			return stickerTop + CONFIG.BOUNCE_HEIGHT * scale * math.sin(math.pi * u)
		end
		return stickerTop
	end

	if age0 >= endAt then
		hideLocally(char)
		anvil:PivotTo(CFrame.new(spot.X, stickerTop + pivotToBottom, spot.Z) * anvilRotation)
		anvil.Parent = getFolder()
		showSticker(false)
		return
	end

	-- Marioneta (solo si aún no ha tocado el suelo).
	local puppet: Model? = nil
	local puppetParts: { PuppetPart } = {}
	if age0 < landAt then
		puppet, puppetParts = makePuppet(char)
		if puppet then
			ctx.add(puppet)
		end
	end
	hideLocally(char)

	local shadow = makeFxPart(Enum.PartType.Cylinder, SHADOW_COLOR)
	ctx.add(shadow)
	local dust = makeFxPart(Enum.PartType.Cylinder, dustColor(hit))
	ctx.add(dust)
	local stars: { Part } = {}
	for _ = 1, CONFIG.STAR_COUNT do
		local star = makeFxPart(Enum.PartType.Ball, CONFIG.STAR_COLOR)
		star.Material = Enum.Material.Neon
		star.Size = Vector3.one * CONFIG.STAR_SIZE * scale
		ctx.add(star)
		table.insert(stars, star)
	end
	local starCenter = spot + Vector3.new(0, stickerTop - groundY + CONFIG.STAR_HEIGHT * scale, 0)

	local impacted = false
	local landed = false
	local conn: RBXScriptConnection? = nil

	local function land(fresh: boolean)
		landed = true
		if puppet then
			puppet:Destroy()
			puppet = nil
		end
		table.clear(puppetParts)
		showSticker(fresh)
	end

	local function step()
		local t = ctx.age()
		if t >= endAt then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			-- Sin frames entre la caída y el final (app en segundo plano, hitch): el
			-- aterrizaje no llegó a correr y la marioneta seguiría junto a la pegatina.
			if not landed then
				land(false)
			end
			anvil:PivotTo(CFrame.new(spot.X, stickerTop + pivotToBottom, spot.Z) * anvilRotation)
			shadow:Destroy()
			dust:Destroy()
			for _, star in stars do
				star:Destroy()
			end
			return
		end

		local anvilBottom = anvilBottomAt(t)
		anvil:PivotTo(CFrame.new(spot.X, anvilBottom + pivotToBottom, spot.Z) * anvilRotation)

		-- Sombra: crece y oscurece mientras se acerca; se va al tocar el suelo.
		if t < landAt then
			local a = t / landAt
			a *= a
			shadow.Size = discSize(anvilWidth * (CONFIG.SHADOW_MIN + (CONFIG.SHADOW_MAX - CONFIG.SHADOW_MIN) * a))
			shadow.CFrame = CFrame.new(spot + Vector3.new(0, CONFIG.LIFT, 0)) * FLAT
			shadow.Transparency = 1 - CONFIG.SHADOW_DARKNESS * a
		else
			shadow.Transparency = 1
		end

		-- Marioneta: estirón antes del golpe y aplastada pegada a la base del yunque.
		if not landed and #puppetParts > 0 then
			if t >= hitAt - CONFIG.STRETCH_TIME and t < hitAt then
				local s = math.sin(math.pi * (t - (hitAt - CONFIG.STRETCH_TIME)) / CONFIG.STRETCH_TIME)
				deform(puppetParts, spot, 1 + CONFIG.STRETCH * s, 1 - CONFIG.STRETCH * 0.5 * s)
			elseif t >= hitAt then
				local sy = math.clamp((anvilBottom - groundY) / (headTop - groundY), CONFIG.MIN_SQUASH, 1)
				deform(puppetParts, spot, sy, 1 + (1 - sy) * CONFIG.SPREAD)
			end
		end

		if not impacted and t >= hitAt then
			impacted = true
			if impactSound and t - hitAt <= CONFIG.LATE_TOLERANCE then
				impactSound:Play()
			end
		end

		if not landed and t >= landAt then
			land(t - landAt <= CONFIG.LATE_TOLERANCE)
		end

		-- Polvo: anillo del color del suelo que se abre y se desvanece.
		local dustAge = t - landAt
		if dustAge >= 0 and dustAge < CONFIG.DUST_TIME then
			local u = TweenService:GetValue(dustAge / CONFIG.DUST_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
			dust.Size = discSize(anvilWidth * (1 + (CONFIG.DUST_GROWTH - 1) * u))
			dust.CFrame = CFrame.new(spot + Vector3.new(0, CONFIG.LIFT * 2, 0)) * FLAT
			dust.Transparency = CONFIG.DUST_START_TRANSPARENCY + (1 - CONFIG.DUST_START_TRANSPARENCY) * u
		else
			dust.Transparency = 1
		end

		-- Estrellitas girando sobre la pegatina.
		local starAge = t - landAt
		if starAge >= 0 and starAge < CONFIG.STAR_TIME then
			local fade = math.clamp((starAge - (CONFIG.STAR_TIME - CONFIG.STAR_FADE)) / CONFIG.STAR_FADE, 0, 1)
			for i, star in stars do
				local angle = starAge * CONFIG.STAR_SPIN + (i - 1) * 2 * math.pi / #stars
				local bob = math.sin(starAge * CONFIG.STAR_SPIN * 1.5 + i) * CONFIG.STAR_BOB * scale
				local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * CONFIG.STAR_RADIUS * scale
				star.CFrame = CFrame.new(starCenter + offset + Vector3.new(0, bob, 0))
				star.Transparency = fade
			end
		else
			for _, star in stars do
				star.Transparency = 1
			end
		end
	end

	anvil.Parent = getFolder()
	step()
	conn = RunService.PreRender:Connect(step)
	ctx.add(conn :: RBXScriptConnection)
end

function Flattened.stop()
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

return Flattened
