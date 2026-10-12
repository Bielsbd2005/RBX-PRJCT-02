--!strict
--[[
	Zona de fuego que deja un proyectil con FireZoneOnImpact (flare gun). Solo servidor:
	la Part se crea en Workspace y replica sola, sin remotes.

	Studio: ReplicatedStorage.WeaponsSystem.Assets.Effects.FireZone. Si es un Folder o un
	Model se clonan sus hijos dentro del disco de la zona; si no, se clona él mismo. Los
	emitters en modo Box/Cylinder cubren el disco a cualquier radio. Sin el asset la zona
	quema pero no se ve. Assets.Effects.FireZoneBody (opcional) es el efecto del cuerpo
	ardiendo; sin él se usa un Fire básico.
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
-- El cuerpo sigue ardiendo este rato tras salir de la zona.
local BURN_LINGER = 2
local BODY_FIRE_NAME = "FireZoneBodyFire"
local GROUND_SEARCH_DISTANCE = 30
local FADE_OUT_TIME = 1.5

local templateFolder: Instance? = nil
-- Opcional: efecto que se cuelga del torso mientras el cuerpo arde.
local bodyTemplate: Instance? = nil
do
	local assets = script.Parent.Parent:FindFirstChild("Assets")
	local effects = assets and assets:FindFirstChild("Effects")
	templateFolder = effects and effects:FindFirstChild("FireZone")
	if not templateFolder then
		warn("[FireZone] falta Assets.Effects.FireZone: las zonas queman pero no se ven")
	end
	bodyTemplate = effects and effects:FindFirstChild("FireZoneBody")
end

type Zone = {
	part: BasePart,
	center: Vector3,
	up: Vector3,
	radius: number,
	damagePerTick: number,
	endsAt: number,
	dealer: Player,
	dealerCharacter: Model?,
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

-- Las piezas del asset conservan su CFrame de Studio al clonarse: hay que llevarlas al
-- disco, anclarlas y quitarles colisión, o se quedan donde se autoraron (o caen). Se
-- traslada sin tocar la rotación: la orientación es la que tenga el asset en Studio.
local function _placeGeometry(instance: Instance, at: Vector3)
	if instance:IsA("Model") then
		local pivot = instance:GetPivot()
		instance:PivotTo(CFrame.new(at) * pivot.Rotation)
	elseif instance:IsA("BasePart") then
		instance.CFrame = CFrame.new(at) * instance.CFrame.Rotation
	else
		return
	end
	for _, d in instance:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanQuery = false
		instance.CanTouch = false
	end
end

local function _attachTemplate(disc: BasePart, placeAt: Vector3)
	local template = templateFolder
	if not template then
		return
	end

	local children = if template:IsA("Folder") then template:GetChildren() else { template }
	for _, child in children do
		local clone = child:Clone()
		_placeGeometry(clone, placeAt)
		clone.Parent = disc
	end

	if #disc:GetDescendants() == 0 then
		warn("[FireZone] Assets.Effects.FireZone está vacío: la zona quema pero no se ve")
	end
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
	-- El disco solo da volumen a los emitters del asset y sitio donde colgarlos.
	part.Transparency = 1
	CollectionService:AddTag(part, "WeaponsSystemIgnore")

	_attachTemplate(part, center + up * 0.1)
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

-- `dealerCharacter`: el cuerpo que lanzó el fuego. Volver al menú da un cuerpo de lobby
-- vivo, y sin esto su fuego seguiría quemando (y matando sin atacante que acreditar).
local function _dealerAlive(dealer: Player, dealerCharacter: Model?): boolean
	if not dealer.Parent or dealer.Character ~= dealerCharacter then
		return false
	end
	local character = dealer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

--[[
	Quemadura viva de un humanoid. Se refresca mientras pisa una zona y sigue un rato tras
	salir, así que la clave es el humanoid y no la zona: dos zonas del mismo tirador no
	apilan daño.
]]
type Burn = {
	humanoid: Humanoid,
	character: Model,
	dealer: Player,
	dealerCharacter: Model?,
	damagePerTick: number,
	weaponName: string,
	weaponsSystem: any,
	expiresAt: number,
}

local burning: { [Humanoid]: Burn } = {}

local function _attachBodyFire(character: Model)
	local torso = character:FindFirstChild("HumanoidRootPart")
	if not (torso and torso:IsA("BasePart")) or torso:FindFirstChild(BODY_FIRE_NAME) then
		return
	end
	local effect: Instance
	if bodyTemplate then
		effect = bodyTemplate:Clone()
	else
		local fire = Instance.new("Fire")
		fire.Size = 5
		fire.Heat = 6
		effect = fire
	end
	effect.Name = BODY_FIRE_NAME
	effect.Parent = torso
end

local function _removeBodyFire(character: Model)
	local torso = character:FindFirstChild("HumanoidRootPart")
	local effect = torso and torso:FindFirstChild(BODY_FIRE_NAME)
	if effect then
		effect:Destroy()
	end
end

type BurnSource = {
	dealer: Player,
	dealerCharacter: Model?,
	damagePerTick: number,
	weaponName: string,
	weaponsSystem: any,
}

local function _refreshBurn(source: BurnSource, humanoid: Humanoid, character: Model, now: number)
	local burn = burning[humanoid]
	if not burn then
		burn = {
			humanoid = humanoid,
			character = character,
			dealer = source.dealer,
			dealerCharacter = source.dealerCharacter,
			damagePerTick = source.damagePerTick,
			weaponName = source.weaponName,
			weaponsSystem = source.weaponsSystem,
			expiresAt = 0,
		}
		burning[humanoid] = burn
		_attachBodyFire(character)
	end
	burn.dealer = source.dealer
	burn.dealerCharacter = source.dealerCharacter
	burn.damagePerTick = source.damagePerTick
	burn.expiresAt = now + BURN_LINGER
end


local function _burnTick(now: number)
	for humanoid, burn in burning do
		local dealerOk = _dealerAlive(burn.dealer, burn.dealerCharacter)
		if now >= burn.expiresAt or humanoid.Health <= 0 or not humanoid:IsDescendantOf(workspace) or not dealerOk then
			_removeBodyFire(burn.character)
			burning[humanoid] = nil
			continue
		end

		-- Protección de spawn: TakeDamage no haría nada y el tirador vería números falsos.
		if burn.character:FindFirstChildOfClass("ForceField") then
			continue
		end

		burn.weaponsSystem.doDamage(humanoid, burn.damagePerTick, nil, burn.dealer, nil, { Name = burn.weaponName })

		-- El cliente del tirador solo predice el feedback de sus disparos: el de la
		-- quemadura hay que mandárselo.
		local vfx = burn.weaponsSystem.remoteEvents["DamageOverTimeVFX"]
		if vfx then
			vfx:FireClient(burn.dealer, humanoid, burn.damagePerTick)
		end
	end
end

local function _tick()
	local now = os.clock()
	local overlap = OverlapParams.new()

	for i = #zones, 1, -1 do
		local zone = zones[i]
		-- Sin dealer vivo doDamage no aplica el daño (_defaultDamageCallback lo exige):
		-- mejor apagar la zona que dejar un fuego que no quema.
		if now >= zone.endsAt or not zone.part.Parent or not _dealerAlive(zone.dealer, zone.dealerCharacter) then
			_extinguish(zone)
			table.remove(zones, i)
			continue
		end

		local dealerCharacter = zone.dealer.Character :: Model

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
			if not humanoid or not character or humanoid.Health <= 0 then
				continue
			end
			if character == dealerCharacter or not TeamUtils.areEnemies(dealerCharacter, character) then
				continue
			end
			_refreshBurn(zone, humanoid, character, now)
		end
	end

	_burnTick(now)

	if #zones == 0 and next(burning) == nil and tickConn then
		tickConn:Disconnect()
		tickConn = nil
	end
end

local function _ensureTickLoop()
	if tickConn then
		return
	end
	tickAccumulator = 0
	tickConn = RunService.Heartbeat:Connect(function(dt)
		tickAccumulator += dt
		if tickAccumulator >= TICK_INTERVAL then
			tickAccumulator -= TICK_INTERVAL
			_tick()
		end
	end)
end

local FireZone = {}

export type IgniteParams = {
	weaponsSystem: any,
	dealer: Player,
	weaponName: string,
	humanoid: Humanoid,
	damagePerSecond: number,
}

-- Impacto directo: prende al jugador al instante, sin esperar a que pise la zona.
-- Sin comprobar equipo: quien llama ya validó que es enemigo. El primer tick de daño
-- llega en el siguiente ciclo (hasta TICK_INTERVAL).
function FireZone.ignite(params: IgniteParams)
	assert(RunService:IsServer(), "FireZone.ignite es solo servidor")
	local humanoid = params.humanoid
	local character = humanoid.Parent
	if not (character and character:IsA("Model")) or humanoid.Health <= 0 then
		return
	end
	_refreshBurn({
		dealer = params.dealer,
		dealerCharacter = params.dealer.Character,
		damagePerTick = params.damagePerSecond * TICK_INTERVAL,
		weaponName = params.weaponName,
		weaponsSystem = params.weaponsSystem,
	}, humanoid, character, os.clock())
	_ensureTickLoop()
end

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
		warn(`[FireZone] sin suelo a menos de {GROUND_SEARCH_DISTANCE} studs bajo el impacto: no se crea la zona`)
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
		dealerCharacter = params.dealer.Character,
		weaponName = params.weaponName,
		weaponsSystem = params.weaponsSystem,
	})

	_ensureTickLoop()
end

return FireZone
