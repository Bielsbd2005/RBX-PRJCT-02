--!strict
--[[
	Zona de fuego que deja un proyectil con FireZoneOnImpact (flare gun). Solo servidor:
	la Part se crea en Workspace y replica sola, sin remotes.

	Studio (opcional): ReplicatedStorage.WeaponsSystem.Assets.Effects.FireZone, un Folder
	cuyos hijos (ParticleEmitters, PointLight, Sound…) se clonan dentro del disco de la zona.
	Los emitters en modo Box/Cylinder cubren el disco a cualquier radio. Sin él se usa un
	Fire básico.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local TICK_INTERVAL = 0.5
-- Tope por jugador: la más antigua se apaga al superarlo.
local MAX_ZONES_PER_PLAYER = 3
local ZONE_HEIGHT = 8
local GROUND_SEARCH_DISTANCE = 30
local FADE_OUT_TIME = 1.5

local templateFolder: Instance? = nil
do
	local assets = script.Parent.Parent:FindFirstChild("Assets")
	local effects = assets and assets:FindFirstChild("Effects")
	templateFolder = effects and effects:FindFirstChild("FireZone")
end

type Zone = {
	part: BasePart,
	center: Vector3,
	up: Vector3,
	radius: number,
	damagePerTick: number,
	endsAt: number,
	dealer: Player,
	weaponName: string,
	weaponsSystem: any,
}

local zones: { Zone } = {}
local tickConn: RBXScriptConnection? = nil
local tickAccumulator = 0

local function _humanoidOf(part: BasePart): Humanoid?
	local model = part:FindFirstAncestorOfClass("Model")
	return model and model:FindFirstChildOfClass("Humanoid")
end

-- Apoya la zona en el primer suelo bajo el impacto, saltándose personajes: un flare que
-- impacta en un jugador arde a sus pies.
local function _findGround(from: Vector3): (Vector3?, Vector3?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = {}
	for _ = 1, 4 do
		params.FilterDescendantsInstances = excluded
		local result = workspace:Raycast(from, Vector3.new(0, -GROUND_SEARCH_DISTANCE, 0), params)
		if not result then
			return nil, nil
		end
		local hit = result.Instance
		local model = hit:FindFirstAncestorOfClass("Model")
		if (model and model:FindFirstChildOfClass("Humanoid")) or CollectionService:HasTag(hit, "WeaponsSystemIgnore") then
			table.insert(excluded, model or hit)
		else
			return result.Position, result.Normal
		end
	end
	return nil, nil
end

local function _buildPart(center: Vector3, up: Vector3, radius: number): BasePart
	-- El eje de un Cylinder es X: se alinea con la normal del suelo.
	local side = if math.abs(up:Dot(Vector3.xAxis)) > 0.9 then Vector3.zAxis else Vector3.xAxis
	local part = Instance.new("Part")
	part.Name = "FireZone"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.2, radius * 2, radius * 2)
	part.CFrame = CFrame.fromMatrix(center + up * 0.1, up, up:Cross(side).Unit)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 110, 30)
	CollectionService:AddTag(part, "WeaponsSystemIgnore")

	if templateFolder then
		part.Transparency = 1
		for _, child in templateFolder:GetChildren() do
			child:Clone().Parent = part
		end
	else
		part.Transparency = 0.75
		local fire = Instance.new("Fire")
		fire.Size = math.min(radius * 1.5, 30)
		fire.Heat = 8
		fire.Parent = part
		local light = Instance.new("PointLight")
		light.Color = part.Color
		light.Range = radius * 2
		light.Brightness = 2
		light.Parent = part
	end

	part.Parent = workspace
	return part
end

local function _extinguish(zone: Zone)
	local part = zone.part
	for _, d in part:GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("Fire") or d:IsA("Light") or d:IsA("Smoke") then
			d.Enabled = false
		elseif d:IsA("Sound") then
			d:Stop()
		end
	end
	part.Transparency = 1
	Debris:AddItem(part, FADE_OUT_TIME)
end

local function _dealerAlive(dealer: Player): boolean
	if not dealer.Parent then
		return false
	end
	local character = dealer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function _tick()
	local now = os.clock()
	-- Un humanoid recibe como mucho un tick por dealer aunque pise varias zonas suyas.
	local hitThisTick: { [Player]: { [Humanoid]: true } } = {}
	local overlap = OverlapParams.new()

	for i = #zones, 1, -1 do
		local zone = zones[i]
		-- Sin dealer vivo doDamage no aplica el daño (_defaultDamageCallback lo exige):
		-- mejor apagar la zona que dejar un fuego que no quema.
		if now >= zone.endsAt or not zone.part.Parent or not _dealerAlive(zone.dealer) then
			_extinguish(zone)
			table.remove(zones, i)
			continue
		end

		local dealerCharacter = zone.dealer.Character :: Model
		local hitSet = hitThisTick[zone.dealer]
		if not hitSet then
			hitSet = {}
			hitThisTick[zone.dealer] = hitSet
		end

		local boxCFrame = zone.part.CFrame * CFrame.new(ZONE_HEIGHT / 2 - 1, 0, 0)
		local boxSize = Vector3.new(ZONE_HEIGHT, zone.radius * 2, zone.radius * 2)
		for _, part in workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlap) do
			if part.Name ~= "HumanoidRootPart" then
				continue
			end
			-- La caja es cuadrada: recorta al círculo en el plano del suelo.
			local offset = part.Position - zone.center
			local planar = offset - zone.up * offset:Dot(zone.up)
			if planar.Magnitude > zone.radius then
				continue
			end
			local humanoid = _humanoidOf(part)
			local character = humanoid and humanoid.Parent :: Model?
			if not humanoid or not character or humanoid.Health <= 0 or hitSet[humanoid] then
				continue
			end
			if character == dealerCharacter or not TeamUtils.areEnemies(dealerCharacter, character) then
				continue
			end
			hitSet[humanoid] = true
			zone.weaponsSystem.doDamage(humanoid, zone.damagePerTick, nil, zone.dealer, nil, { Name = zone.weaponName })
		end
	end

	if #zones == 0 and tickConn then
		tickConn:Disconnect()
		tickConn = nil
	end
end

local FireZone = {}

export type SpawnParams = {
	weaponsSystem: any,
	dealer: Player,
	weaponName: string,
	impact: Vector3,
	normal: Vector3,
	radius: number,
	duration: number,
	damagePerSecond: number,
}

function FireZone.spawn(params: SpawnParams)
	assert(RunService:IsServer(), "FireZone.spawn es solo servidor")

	local center, up = _findGround(params.impact + params.normal * 0.5)
	if not center or not up then
		return
	end

	local owned = 0
	for i = #zones, 1, -1 do
		if zones[i].dealer == params.dealer then
			owned += 1
			if owned >= MAX_ZONES_PER_PLAYER then
				_extinguish(zones[i])
				table.remove(zones, i)
			end
		end
	end

	table.insert(zones, {
		part = _buildPart(center, up, params.radius),
		center = center,
		up = up,
		radius = params.radius,
		damagePerTick = params.damagePerSecond * TICK_INTERVAL,
		endsAt = os.clock() + params.duration,
		dealer = params.dealer,
		weaponName = params.weaponName,
		weaponsSystem = params.weaponsSystem,
	})

	if not tickConn then
		tickAccumulator = 0
		tickConn = RunService.Heartbeat:Connect(function(dt)
			tickAccumulator += dt
			if tickAccumulator >= TICK_INTERVAL then
				tickAccumulator -= TICK_INTERVAL
				_tick()
			end
		end)
	end
end

return FireZone
