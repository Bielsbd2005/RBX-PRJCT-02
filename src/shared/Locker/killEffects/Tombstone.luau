--!strict

-- Kill effect: el cuerpo desaparece y una lápida (ReplicatedStorage.Templates.Lapida)
-- cae y se clava vertical en el suelo real bajo el punto de muerte (raycast hacia
-- abajo; solo hereda el yaw del personaje). Si la plantilla lleva un Sound dentro de
-- una parte, suena en el impacto.
--
-- Todo se anima en un único Heartbeat con TweenService:GetValue y no con tweens
-- encadenados, porque las fases (rebote, vaivén, cascotes) se solapan.
--
-- El cuerpo se OCULTA, no se destruye: sus dueños (MatchService, AIService, Locker,
-- ScenePreview) lo destruyen, y la cámara de muerte sigue mirando su HumanoidRootPart.
-- La lápida y sus efectos cuelgan DENTRO del cadáver para limpiarse con él sin
-- lifecycle propio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Utils = require(script.Parent.Utils)

local CONFIG = {
	TEMPLATES_FOLDER = "Templates",
	TEMPLATE_NAME = "Lapida",
	NAME_LABEL_PATH = { "TextPart", "Gui", "Name" },
	SINK = 0.15, -- studs que queda hundida en reposo para que no parezca flotar

	DROP_HEIGHT = 45, -- studs sobre el suelo desde los que empieza a caer
	FALL_TIME = 0.42, -- s de caída
	FALL_SPIN = 270, -- grados de giro vertical durante la caída (frena hasta 0)

	PUNCH_DEPTH = 0.9, -- studs que se clava de golpe antes de rebotar
	SETTLE_TIME = 0.35, -- s del rebote hasta su altura final
	WOBBLE_DEG = 8, -- grados del primer cabeceo
	WOBBLE_FREQ = 24, -- rad/s del vaivén
	WOBBLE_DECAY = 7, -- amortiguación del vaivén (más = para antes)
	WOBBLE_TIME = 0.7, -- s tras los que se fuerza recta

	SHADOW_MIN_SCALE = 0.3, -- tamaño inicial respecto a la huella de la lápida
	SHADOW_MAX_SCALE = 1.3, -- tamaño al impactar
	SHADOW_DARKNESS = 0.55, -- opacidad máxima (1 - Transparency)
	SHADOW_FADE = 0.5, -- s de fundido tras el impacto

	RING_GROWTH = 3.4, -- multiplicador final de la huella
	RING_TIME = 0.5,
	RING_START_TRANSPARENCY = 0.25,

	DEBRIS_COUNT = 8,
	DEBRIS_SIZE_MIN = 0.25,
	DEBRIS_SIZE_MAX = 0.6,
	DEBRIS_SPEED_XZ = { 10, 22 }, -- studs/s horizontales
	DEBRIS_SPEED_Y = { 14, 26 }, -- studs/s hacia arriba
	DEBRIS_GRAVITY = 90, -- studs/s² (más que la real: se ve más contundente)
	DEBRIS_LIFE = 0.8, -- s hasta desaparecer
	DEBRIS_FADE_FROM = 0.5, -- s desde los que empiezan a desvanecerse
}

-- Debe coincidir con RagdollCleanup/CharacterHighlightController: el server lo pone
-- en el cadáver al empezar a disolverlo, con la duración del fundido.
local FADE_OUT_ATTR = "KillEffectFadeOut"

local DUST_FALLBACK = Color3.fromRGB(150, 130, 105)
local SHADOW_COLOR = Color3.new(0, 0, 0)

local rng = Random.new()

local function ease(alpha: number, style: Enum.EasingStyle, direction: Enum.EasingDirection): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style, direction)
end

local function debugWarn(message: string)
	if RunService:IsStudio() then
		warn("[Tombstone] " .. message)
	end
end

local function dustColor(result: RaycastResult): Color3
	local hit = result.Instance
	local base = DUST_FALLBACK
	if hit:IsA("Terrain") then
		local terrain = hit :: Terrain
		-- pcall: GetMaterialColor lanza con materiales que no son de terreno.
		local ok, color = pcall(function()
			return terrain:GetMaterialColor(result.Material)
		end)
		if ok then
			base = color
		end
	elseif hit:IsA("BasePart") then
		base = hit.Color
	end
	return base:Lerp(Color3.new(1, 1, 1), 0.2)
end

local function footprint(tombstone: PVInstance): number
	local size = if tombstone:IsA("Model")
		then tombstone:GetExtentsSize()
		elseif tombstone:IsA("BasePart") then tombstone.Size
		else Vector3.one * 2
	return math.max(size.X, size.Z, 2)
end

local function makeVfxPart(parent: Instance, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color
	part.Transparency = transparency
	part.Parent = parent
	return part
end

-- Disco plano sobre el suelo (Cylinder tumbado: el eje del cilindro es X).
local FLAT = CFrame.Angles(0, 0, math.pi / 2)
local function discSize(diameter: number): Vector3
	return Vector3.new(0.05, diameter, diameter)
end

type Chunk = {
	part: Part,
	origin: Vector3,
	velocity: Vector3,
	spinAxis: Vector3,
	spinRate: number, -- rad/s
	restY: number,
}

local function spawnDebris(parent: Instance, center: Vector3, radius: number, color: Color3): { Chunk }
	local chunks: { Chunk } = {}
	for i = 1, CONFIG.DEBRIS_COUNT do
		local angle = (i / CONFIG.DEBRIS_COUNT) * 2 * math.pi + rng:NextNumber(-0.3, 0.3)
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local size = rng:NextNumber(CONFIG.DEBRIS_SIZE_MIN, CONFIG.DEBRIS_SIZE_MAX)
		local part = makeVfxPart(parent, color:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.25)), 0)
		part.Size = Vector3.one * size
		local origin = center + dir * radius * 0.5 + Vector3.new(0, size / 2, 0)
		part.CFrame = CFrame.new(origin)
		table.insert(chunks, {
			part = part,
			origin = origin,
			velocity = dir * rng:NextNumber(CONFIG.DEBRIS_SPEED_XZ[1], CONFIG.DEBRIS_SPEED_XZ[2])
				+ Vector3.new(0, rng:NextNumber(CONFIG.DEBRIS_SPEED_Y[1], CONFIG.DEBRIS_SPEED_Y[2]), 0),
			spinAxis = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)).Unit,
			spinRate = rng:NextNumber(8, 16),
			restY = center.Y + size / 2,
		})
	end
	return chunks
end

local function stepDebris(chunks: { Chunk }, age: number)
	local fade = math.clamp(
		(age - CONFIG.DEBRIS_FADE_FROM) / (CONFIG.DEBRIS_LIFE - CONFIG.DEBRIS_FADE_FROM),
		0,
		1
	)
	for _, chunk in chunks do
		local part = chunk.part
		if part.Parent then
			local pos = chunk.origin + chunk.velocity * age - Vector3.new(0, 0.5 * CONFIG.DEBRIS_GRAVITY * age * age, 0)
			if pos.Y <= chunk.restY then
				pos = Vector3.new(pos.X, chunk.restY, pos.Z)
			end
			part.CFrame = CFrame.new(pos) * CFrame.fromAxisAngle(chunk.spinAxis, chunk.spinRate * age)
			part.Transparency = fade
			if age >= CONFIG.DEBRIS_LIFE then
				part:Destroy()
			end
		end
	end
end

-- Mismo criterio que HealthBillboardController. Bots: atributo "DisplayName" de
-- AIService (nunca el Name "Bot_N"). En los previews el doble no tiene dueño: jugador local.
local function victimName(char: Model): string
	local owner = Players:GetPlayerFromCharacter(char)
	if owner then
		return if owner.DisplayName ~= "" then owner.DisplayName else owner.Name
	end
	local attr = char:GetAttribute("DisplayName")
	if type(attr) == "string" and attr ~= "" then
		return attr
	end
	if RunService:IsClient() then
		local localPlayer = Players.LocalPlayer
		if localPlayer then
			return if localPlayer.DisplayName ~= "" then localPlayer.DisplayName else localPlayer.Name
		end
	end
	local humanoid = char:FindFirstChildWhichIsA("Humanoid", true)
	return if humanoid then humanoid.DisplayName else ""
end

-- Hijo a hijo con FindFirstChild: `Gui.Name` sería la PROPIEDAD Name, no el hijo.
local function applyName(tombstone: Instance, char: Model, name: string)
	local node: Instance? = tombstone
	for _, childName in CONFIG.NAME_LABEL_PATH do
		node = if node then node:FindFirstChild(childName) else nil
	end
	if not (node and (node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox"))) then
		debugWarn("falta el texto " .. table.concat(CONFIG.NAME_LABEL_PATH, ".") .. " en la plantilla")
		return
	end
	local label = node :: any
	label.Text = name

	-- RagdollCleanup solo funde partes y decals: el texto hay que fundirlo aquí.
	local function fadeText(fadeTime: number)
		local info = TweenInfo.new(fadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
		TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end
	local conn: RBXScriptConnection? = nil
	conn = char:GetAttributeChangedSignal(FADE_OUT_ATTR):Connect(function()
		local fadeTime = char:GetAttribute(FADE_OUT_ATTR)
		if type(fadeTime) == "number" and fadeTime > 0 then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			fadeText(fadeTime)
		end
	end)
end

local function playImpactSound(tombstone: Instance)
	local sound = tombstone:FindFirstChildWhichIsA("Sound", true)
	if sound then
		sound:Play()
	end
end

local function dropTombstone(char: Model, deathPivot: CFrame, name: string)
	-- Sin WaitForChild: el registry requiere este módulo en server y cliente y no
	-- debe colgarse si falta el arte.
	local templates = ReplicatedStorage:FindFirstChild(CONFIG.TEMPLATES_FOLDER)
	local template = if templates then templates:FindFirstChild(CONFIG.TEMPLATE_NAME) else nil
	if not (template and template:IsA("PVInstance")) then
		warn(
			"[Tombstone] Falta ReplicatedStorage."
				.. CONFIG.TEMPLATES_FOLDER
				.. "."
				.. CONFIG.TEMPLATE_NAME
				.. " (Model o BasePart)"
		)
		return
	end

	local hit = Utils.findGround(deathPivot.Position, char)
	if not hit then
		debugWarn("sin suelo bajo " .. tostring(deathPivot.Position) .. " (" .. char:GetFullName() .. ")")
		return
	end
	local ground = hit.Position

	local tombstone = template:Clone() :: PVInstance
	Utils.makeCosmetic(tombstone)
	applyName(tombstone, char, name)

	local look = deathPivot.LookVector * Vector3.new(1, 0, 1)
	local yaw = if look.Magnitude > 1e-3 then CFrame.lookAt(Vector3.zero, look.Unit) else CFrame.identity
	local upright = CFrame.new(ground) * yaw * template:GetPivot().Rotation

	tombstone:PivotTo(upright)
	local bottomY = Utils.lowestWorldY(tombstone) or ground.Y
	local landed = upright + Vector3.new(0, ground.Y - bottomY - CONFIG.SINK, 0)
	local width = footprint(tombstone)

	-- Pose relativa al punto de apoyo: el cabeceo rota sobre la base y no patina.
	local base = ground - Vector3.new(0, CONFIG.SINK, 0)
	local fromBase = CFrame.new(base):ToObjectSpace(landed)
	local tiltAxis = yaw.RightVector
	local function poseAt(height: number, spin: number, tilt: number): CFrame
		return CFrame.new(base + Vector3.new(0, height, 0))
			* CFrame.fromAxisAngle(tiltAxis, tilt)
			* CFrame.Angles(0, spin, 0)
			* fromBase
	end

	local fallSpin = math.rad(CONFIG.FALL_SPIN) * (if rng:NextNumber() < 0.5 then -1 else 1)
	tombstone:PivotTo(poseAt(CONFIG.DROP_HEIGHT, fallSpin, 0))
	tombstone.Parent = char

	local dust = dustColor(hit)
	local shadow = makeVfxPart(char, SHADOW_COLOR, 1)
	shadow.Shape = Enum.PartType.Cylinder
	shadow.Size = discSize(width * CONFIG.SHADOW_MIN_SCALE)
	shadow.CFrame = CFrame.new(ground + Vector3.new(0, 0.03, 0)) * FLAT

	local impacted = false
	local chunks: { Chunk } = {}
	local animEnd = CONFIG.FALL_TIME + math.max(CONFIG.SETTLE_TIME, CONFIG.WOBBLE_TIME, CONFIG.DEBRIS_LIFE)
	local startAt = os.clock()
	local conn: RBXScriptConnection? = nil

	local function impact()
		impacted = true
		playImpactSound(tombstone)

		TweenService:Create(shadow, TweenInfo.new(CONFIG.SHADOW_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
		}):Play()
		Debris:AddItem(shadow, CONFIG.SHADOW_FADE)

		local ring = makeVfxPart(char, dust, CONFIG.RING_START_TRANSPARENCY)
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = discSize(width)
		ring.CFrame = CFrame.new(ground + Vector3.new(0, 0.06, 0)) * FLAT
		TweenService:Create(ring, TweenInfo.new(CONFIG.RING_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = discSize(width * CONFIG.RING_GROWTH),
			Transparency = 1,
		}):Play()
		Debris:AddItem(ring, CONFIG.RING_TIME)

		chunks = spawnDebris(char, ground, width, dust)
	end

	conn = RunService.Heartbeat:Connect(function()
		local t = os.clock() - startAt
		if not tombstone.Parent or t >= animEnd then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			if tombstone.Parent then
				tombstone:PivotTo(landed)
			end
			for _, chunk in chunks do
				if chunk.part.Parent then
					chunk.part:Destroy()
				end
			end
			return
		end

		if t < CONFIG.FALL_TIME then
			local a = t / CONFIG.FALL_TIME
			local fall = ease(a, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local spinLeft = 1 - ease(a, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			tombstone:PivotTo(poseAt(CONFIG.DROP_HEIGHT * (1 - fall), fallSpin * spinLeft, 0))

			shadow.Size = discSize(width * (CONFIG.SHADOW_MIN_SCALE + (CONFIG.SHADOW_MAX_SCALE - CONFIG.SHADOW_MIN_SCALE) * fall))
			shadow.Transparency = 1 - CONFIG.SHADOW_DARKNESS * fall
			return
		end

		if not impacted then
			impact()
		end

		local u = t - CONFIG.FALL_TIME
		local height = if u < CONFIG.SETTLE_TIME
			then -CONFIG.PUNCH_DEPTH * (1 - ease(u / CONFIG.SETTLE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
			else 0
		local tilt = if u < CONFIG.WOBBLE_TIME
			then math.rad(CONFIG.WOBBLE_DEG) * math.exp(-CONFIG.WOBBLE_DECAY * u) * math.sin(CONFIG.WOBBLE_FREQ * u)
			else 0
		tombstone:PivotTo(poseAt(height, 0, tilt))

		stepDebris(chunks, u)
	end)
end

local Tombstone = {}

function Tombstone.apply(char: Model): boolean
	-- ANTES de ocultar.
	local deathPivot = Utils.deathCFrame(char)
	local name = victimName(char)
	Utils.hideCharacter(char)
	dropTombstone(char, deathPivot, name)
	return true
end

return Tombstone
