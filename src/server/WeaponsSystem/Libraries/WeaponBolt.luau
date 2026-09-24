--!strict
--[[
	Ida y vuelta de las piezas móviles del arma en cada disparo. Una instancia por grupo:
	todas las BasePart del Tool con el nombre dado ("Bolt", "Pump", "SniperBolt"), unidas al resto del
	arma por un Weld, Motor6D o WeldConstraint. Ver docs/WEAPON-BOLT.md.

	Solo cliente: el offset del joint es local y no replica; simulateFire ya corre en cada
	cliente cuando alguien dispara, así que todos lo ven.
]]

local WeaponJoint = require(script.Parent:WaitForChild("WeaponJoint"))

-- Fracción del ciclo de ida (hacia atrás, o hacia delante en SniperBolt); el resto es el regreso.
local PULL_FRACTION = 0.3

type Bolt = {
	entry: WeaponJoint.Entry,
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

	for _, entry in WeaponJoint.collect(self.tool, self.partName) do
		table.insert(bolts, {
			entry = entry,
			axis = WeaponJoint.resolveAxis(entry.part, backWorld, "BoltAxis"),
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
		WeaponJoint.setTransform(bolt.entry, CFrame.new(bolt.axis * (f * travel)))
	end
end

function WeaponBolt.reset(self: WeaponBolt)
	self.lastShot = -math.huge
	self.wasLocked = false
	self.applied = 0
	for _, bolt in self.bolts or {} do
		WeaponJoint.reset(bolt.entry)
	end
end

return WeaponBolt
