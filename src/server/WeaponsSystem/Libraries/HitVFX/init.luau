--!strict
--[[
	VFX de impacto de balas (solo Body / Headshot). Plantillas en Studio:
	ReplicatedStorage.Templates.HitVFX con "Body" y "Headshot"; contrato en Config.luau.

	Solo partículas: el sonido de hit lo dispara DamageBillboardHandler desde
	SoundService.Audio.Gameplay, así que cualquier Sound en las plantillas se ignora.

	hitInfo = { p, n, h, wasHeadshot }
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script:WaitForChild("Config"))

local IS_SERVER = RunService:IsServer()
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local PARTICLE_SCALE = IS_MOBILE and Config.MobileScale or 1
local DEFAULT_EMIT_COUNT = 15

local HitVFX = {}

type Unit = {
	part: Part,
	emitters: { { e: ParticleEmitter, n: number } },
	busy: boolean,
}

local container: Folder? = nil
local prototypes: { [string]: Part } = {}
local pools: { [string]: { Unit } } = {}
local active = 0

-- Contenedor local bajo la cámara (no se replica). Perezoso: en el servidor no
-- hay CurrentCamera.
local function getContainer(): Folder?
	if container and container.Parent then
		return container
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = "HitVFXRuntime"
	folder.Parent = camera
	CollectionService:AddTag(folder, "WeaponsSystemIgnore")
	container = folder
	return folder
end

local function makeHost(): Part
	local part = Instance.new("Part")
	part.Name = "Impact"
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Locked = true
	CollectionService:AddTag(part, "WeaponsSystemIgnore")
	return part
end

-- Sin WaitForChild: se consulta en cada uso hasta que haya replicado.
local function getFolder(): Instance?
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	return templates and templates:FindFirstChild(Config.FolderName)
end

-- Se cachea al primer impacto de la categoría con la carpeta ya replicada.
local function getPrototype(name: string): Part?
	if prototypes[name] then
		return prototypes[name]
	end
	local folder = getFolder()
	local template = folder and folder:FindFirstChild(name)
	if not template then
		return nil
	end
	local host = makeHost()
	if template:IsA("Attachment") then
		template:Clone().Parent = host
	elseif template:IsA("BasePart") then
		for _, child in template:GetChildren() do
			child:Clone().Parent = host
		end
	end
	for _, d in host:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false -- siempre usamos :Emit()
		end
	end
	prototypes[name] = host
	return host
end

-- EmitCount: atributo opcional del ParticleEmitter en la plantilla.
local function indexUnit(part: Part): Unit
	local emitters = {}
	for _, d in part:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false
			table.insert(emitters, { e = d, n = (d:GetAttribute("EmitCount") :: number?) or DEFAULT_EMIT_COUNT })
		end
	end
	return { part = part, emitters = emitters, busy = false }
end

local function acquire(name: string): Unit?
	local pool = pools[name]
	if pool then
		for _, unit in pool do
			if not unit.busy then
				unit.busy = true
				active += 1
				return unit
			end
		end
	end
	if active >= Config.MaxConcurrent then
		return nil
	end
	local parent = getContainer()
	local proto = parent and getPrototype(name)
	if not proto then
		return nil
	end
	local clone = proto:Clone()
	clone.Parent = parent
	local unit = indexUnit(clone)
	unit.busy = true
	active += 1
	if not pool then
		pool = {}
		pools[name] = pool
	end
	table.insert(pool, unit)
	return unit
end

local function release(unit: Unit)
	if not unit.busy then
		return
	end
	unit.busy = false
	active -= 1
end

-- CFrame en `point` con UpVector = normal (las partículas emiten hacia Top = +Y).
local function cframeFromNormal(point: Vector3, normal: Vector3): CFrame
	local n = normal.Magnitude < 1e-4 and Vector3.yAxis or normal.Unit
	local arbitrary = math.abs(n.Y) < 0.99 and Vector3.yAxis or Vector3.xAxis
	local right = n:Cross(arbitrary).Unit
	return CFrame.fromMatrix(point, right, n, right:Cross(n).Unit)
end

-- "Headshot" / "Body", o nil si el impacto no es contra un jugador.
local function classify(hitInfo: any): string?
	if hitInfo.wasHeadshot then
		return Config.HeadshotCategory
	end
	local h = hitInfo.h
	if h and typeof(h) == "Instance" and h:IsA("Humanoid") then
		return Config.BodyCategory
	end
	return nil
end

function HitVFX.play(hitInfo: any, isLocalShot: boolean?)
	if IS_SERVER or not Config.Enabled or not hitInfo then
		return
	end
	if Config.LocalPlayerOnly and not isLocalShot then
		return
	end
	if typeof(hitInfo.p) ~= "Vector3" then
		return
	end
	local name = classify(hitInfo)
	if not name then
		return
	end
	local unit = acquire(name)
	if not unit then
		return
	end

	unit.part.CFrame = cframeFromNormal(hitInfo.p, (typeof(hitInfo.n) == "Vector3" and hitInfo.n) or Vector3.yAxis)

	local hold = 0.2
	for _, info in unit.emitters do
		local count = math.floor(info.n * PARTICLE_SCALE + 0.5)
		if count >= 1 then
			info.e:Emit(count)
			if info.e.Lifetime.Max > hold then
				hold = info.e.Lifetime.Max
			end
		end
	end

	task.delay(hold + 0.15, release, unit)
end

-- Opcional: evita el hitch del primer impacto.
function HitVFX.preload()
	if IS_SERVER then
		return
	end
	task.spawn(function()
		local folder = getFolder()
		if not folder then
			return
		end
		local assets = {}
		for _, d in folder:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				table.insert(assets, d)
			end
		end
		pcall(function()
			ContentProvider:PreloadAsync(assets)
		end)
	end)
end

return HitVFX
