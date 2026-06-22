--!strict
--[[
	HitVFX/init.luau — VFX de impacto de balas (sólo Body / Headshot).

	Los efectos viven SIEMPRE en una carpeta de Studio (ReplicatedStorage.HitVFX),
	con una plantilla "Body" y otra "Headshot". Ver Config.luau para el contrato.

	SÓLO PARTÍCULAS. El sonido de hit/headshot NO se gestiona aquí — vive en
	SoundService.Audio.Gameplay.HitSound/Headshot y lo dispara DamageBillboardHandler
	(2D, pitch progresivo de combo). Mantener el sonido en un único sitio evita el
	doble audio; por eso el motor ignora cualquier Sound dentro de las plantillas.

	Eficiencia: pool por categoría (clones reusados, cero Instance.new en régimen),
	escalado de partículas en móvil y, por defecto, sólo se renderizan los impactos
	del jugador local (Config.LocalPlayerOnly).

	API:
	  HitVFX.play(hitInfo, isLocalShot)   -- hitInfo = { p, n, h, wasHeadshot }
	  HitVFX.preload()                    -- opcional, precarga assets en bootstrap
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

-- Punto invisible y anclado que aloja los emitters + sonidos de un impacto.
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

-- Prototipo de una categoría = host con la plantilla de la carpeta clonada
-- dentro. Se construye una vez (al primer impacto de esa categoría con la
-- carpeta ya replicada) y se cachea.
local function getPrototype(name: string): Part?
	if prototypes[name] then
		return prototypes[name]
	end
	local folder = ReplicatedStorage:FindFirstChild(Config.FolderName)
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

-- Indexa los emitters (con su EmitCount) de una clone recién creada. Los Sound
-- de la plantilla se ignoran a propósito (el audio vive en SoundService).
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

-- Reproduce el VFX de impacto. No-op en el servidor o si no es impacto a jugador.
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

-- Opcional: precarga las texturas de la carpeta para evitar el primer hitch.
function HitVFX.preload()
	if IS_SERVER then
		return
	end
	task.spawn(function()
		local folder = ReplicatedStorage:FindFirstChild(Config.FolderName)
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
