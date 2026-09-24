--!strict
--[[
	Apertura del arma al recargar: la pieza "Barrel" gira sobre su eje Z local al empezar
	la recarga, se queda abierta mientras dura y vuelve con un tween al terminar.
	Ver docs/WEAPON-BOLT.md.

	Studio: un Attachment "Hinge" hijo de la pieza marca la bisagra; sin él gira sobre su
	centro. Solo cliente, como WeaponBolt.
]]

local WeaponJoint = require(script.Parent:WaitForChild("WeaponJoint"))

local ReloadHinge = {}
ReloadHinge.__index = ReloadHinge

export type ReloadHinge = typeof(setmetatable(
	{} :: {
		tool: Instance,
		partName: string,
		entries: { { entry: WeaponJoint.Entry, axis: Vector3, pivot: Vector3 } }?,
		progress: number,
	},
	ReloadHinge
))

function ReloadHinge.new(tool: Instance, partName: string): ReloadHinge
	return setmetatable({
		tool = tool,
		partName = partName,
		entries = nil,
		progress = 0,
	}, ReloadHinge)
end

function ReloadHinge.isResolved(self: ReloadHinge): boolean
	return self.entries ~= nil
end

function ReloadHinge.resolve(self: ReloadHinge)
	if self.entries then
		return
	end
	local entries = {}
	self.entries = entries
	for _, entry in WeaponJoint.collect(self.tool, self.partName) do
		local hinge = entry.part:FindFirstChild("Hinge")
		local axis = entry.part:GetAttribute("HingeAxis")
		table.insert(entries, {
			entry = entry,
			-- Eje Z local: el modelo decide la orientación, no una heurística sobre el arma.
			axis = if typeof(axis) == "Vector3" and axis.Magnitude > 1e-3 then axis.Unit else Vector3.zAxis,
			pivot = if hinge and hinge:IsA("Attachment") then hinge.Position else Vector3.zero,
		})
	end
end

local function _smoothstep(u: number): number
	local t = math.clamp(u, 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
	openTime/closeTime: segundos de apertura y de vuelta. `progress` es lineal y se mueve
	hacia el estado actual, así que una recarga que acaba a mitad de la apertura cierra
	desde donde esté la pieza en vez de saltar.
]]
function ReloadHinge.step(self: ReloadHinge, dt: number, reloading: boolean, angle: number, openTime: number, closeTime: number)
	local entries = self.entries
	if not entries or #entries == 0 or angle == 0 then
		return
	end

	local target = if reloading then 1 else 0
	if self.progress == target then
		return
	end
	local rate = if reloading then dt / math.max(openTime, 1e-3) else -dt / math.max(closeTime, 1e-3)
	self.progress = math.clamp(self.progress + rate, 0, 1)

	local radians = math.rad(angle) * _smoothstep(self.progress)
	for _, item in entries do
		local rotation = CFrame.fromAxisAngle(item.axis, radians)
		WeaponJoint.setTransform(item.entry, CFrame.new(item.pivot) * rotation * CFrame.new(-item.pivot))
	end
end

function ReloadHinge.reset(self: ReloadHinge)
	self.progress = 0
	for _, item in self.entries or {} do
		WeaponJoint.reset(item.entry)
	end
end

return ReloadHinge
