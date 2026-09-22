--!strict
--[[
	Ida y vuelta de las piezas móviles del arma en cada disparo. Una instancia por grupo:
	todas las BasePart del Tool con el nombre dado ("Bolt", "Pump", "SniperBolt"), unidas al resto del
	arma por un Weld, Motor6D o WeldConstraint. Ver docs/WEAPON-BOLT.md.

	Solo cliente: el offset del joint es local y no replica; simulateFire ya corre en cada
	cliente cuando alguien dispara, así que todos lo ven.
]]

local LOCAL_WELD_NAME = "BoltClientWeld"
-- Fracción del ciclo de ida (hacia atrás, o hacia delante en SniperBolt); el resto es el regreso.
local PULL_FRACTION = 0.3

type Bolt = {
	part: BasePart,
	joint: JointInstance,
	prop: string,
	base: CFrame,
	axis: Vector3, -- unitario, en el espacio local de la parte
}

local WeaponBolt = {}
WeaponBolt.__index = WeaponBolt

export type WeaponBolt = typeof(setmetatable(
	{} :: {
		tool: Instance,
		partName: string,
		bolts: { Bolt }?,
		lastShot: number,
		cycle: number,
		wasLocked: boolean,
		applied: number,
	},
	WeaponBolt
))

function WeaponBolt.new(tool: Instance, partName: string): WeaponBolt
	return setmetatable({
		tool = tool,
		partName = partName,
		bolts = nil,
		lastShot = -math.huge,
		cycle = 0.1,
		wasLocked = false,
		applied = 0,
	}, WeaponBolt)
end

-- Un WeldConstraint no admite offset: se desactiva en local y se sustituye por un Weld
-- equivalente (tampoco replica).
local function _resolveJoint(part: BasePart, tool: Instance): (JointInstance?, string)
	local existing = part:FindFirstChild(LOCAL_WELD_NAME)
	if existing and existing:IsA("Weld") then
		return existing, "C1"
	end

	for _, j in part:GetJoints() do
		if j:IsA("JointInstance") then
			local other = if j.Part0 == part then j.Part1 else j.Part0
			if other and other:IsDescendantOf(tool) then
				return j, if j.Part0 == part then "C0" else "C1"
			end
		elseif j:IsA("WeldConstraint") and j.Enabled then
			local other = if j.Part0 == part then j.Part1 else j.Part0
			if other and other:IsDescendantOf(tool) then
				local weld = Instance.new("Weld")
				weld.Name = LOCAL_WELD_NAME
				weld.Part0 = other
				weld.Part1 = part
				weld.C0 = other.CFrame:ToObjectSpace(part.CFrame)
				j.Enabled = false
				weld.Parent = part
				return weld, "C1"
			end
		end
	end
	return nil, "C1"
end

-- Eje local de la parte más alineado con la dirección de ida. El atributo BoltAxis
-- (Vector3, espacio local de la parte) lo fuerza si el modelo no está alineado.
local function _resolveAxis(part: BasePart, backWorld: Vector3): Vector3
	local override = part:GetAttribute("BoltAxis")
	if typeof(override) == "Vector3" and override.Magnitude > 1e-3 then
		return override.Unit
	end
	local v = part.CFrame:VectorToObjectSpace(backWorld)
	local ax, ay, az = math.abs(v.X), math.abs(v.Y), math.abs(v.Z)
	if ax >= ay and ax >= az then
		return Vector3.new(math.sign(v.X), 0, 0)
	elseif ay >= az then
		return Vector3.new(0, math.sign(v.Y), 0)
	end
	return Vector3.new(0, 0, math.sign(v.Z))
end

-- Una vez por arma: los descendientes del Tool replican juntos, así que no hace falta
-- reintentar. backWorld = dirección de ida en mundo (boca→culata, o al revés en SniperBolt).
function WeaponBolt.resolve(self: WeaponBolt, backWorld: Vector3)
	if self.bolts then
		return
	end
	local bolts: { Bolt } = {}
	self.bolts = bolts
	if backWorld.Magnitude < 1e-3 then
		return
	end

	local model = self.tool:FindFirstChildOfClass("Model")
	local root = model and model.PrimaryPart
	for _, part in self.tool:GetDescendants() do
		if part.Name ~= self.partName or not part:IsA("BasePart") then
			continue
		end
		-- Mover la raíz del ensamblaje arrastraría el arma entera.
		if part == root or part == self.tool:FindFirstChild("Handle") then
			warn(`[WeaponBolt] {part:GetFullName()}: no puede ser el PrimaryPart ni el Handle`)
			continue
		end
		local joint, prop = _resolveJoint(part, self.tool)
		if not joint then
			warn(`[WeaponBolt] {part:GetFullName()}: no está soldado a otra parte del arma`)
			continue
		end
		table.insert(bolts, {
			part = part,
			joint = joint,
			prop = prop,
			base = (joint :: any)[prop],
			axis = _resolveAxis(part, backWorld),
		})
	end
end

function WeaponBolt.isResolved(self: WeaponBolt): boolean
	return self.bolts ~= nil
end

-- delay: segundos tras el disparo antes de empezar a moverse (el "bombeo" del Pump).
function WeaponBolt.kick(self: WeaponBolt, now: number, cycle: number, delay: number)
	self.lastShot = now + delay
	self.cycle = cycle
end

local function _fraction(t: number): number
	if t <= 0 or t >= 1 then
		return 0
	elseif t < PULL_FRACTION then
		local u = t / PULL_FRACTION
		return 1 - (1 - u) * (1 - u)
	end
	local u = (t - PULL_FRACTION) / (1 - PULL_FRACTION)
	return 1 - u * u * (3 - 2 * u)
end

-- locked = cerrojo abierto (cargador vacío): se queda atrás al llegar al tope.
function WeaponBolt.step(self: WeaponBolt, now: number, travel: number, locked: boolean)
	local bolts = self.bolts
	if not bolts or #bolts == 0 then
		return
	end

	if self.wasLocked and not locked then
		-- Al soltarse, el regreso arranca desde el tope en vez de saltar.
		self.lastShot = now - PULL_FRACTION * self.cycle
	end
	self.wasLocked = locked

	local t = (now - self.lastShot) / self.cycle
	if locked then
		t = math.min(t, PULL_FRACTION)
	end
	local f = _fraction(t)
	if f == self.applied then
		return
	end
	self.applied = f

	for _, bolt in bolts do
		if bolt.joint.Parent then
			-- part_new = part_old * CFrame.new(offset) ⇒ prop = CFrame.new(-offset) * base
			(bolt.joint :: any)[bolt.prop] = CFrame.new(-bolt.axis * (f * travel)) * bolt.base
		end
	end
end

function WeaponBolt.reset(self: WeaponBolt)
	self.lastShot = -math.huge
	self.wasLocked = false
	self.applied = 0
	for _, bolt in self.bolts or {} do
		if bolt.joint.Parent then
			(bolt.joint :: any)[bolt.prop] = bolt.base
		end
	end
end

return WeaponBolt
