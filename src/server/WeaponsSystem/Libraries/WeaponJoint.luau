--!strict
--[[
	Piezas móviles de un arma: encuentra las BasePart del Tool con un nombre dado y el
	joint que las une al resto, y les aplica un offset local. Lo usan WeaponBolt (traslación
	por disparo) y ReloadHinge (rotación al recargar).

	Solo cliente: el offset del joint es local y no replica.
]]

local LOCAL_WELD_NAME = "BoltClientWeld"

export type Entry = {
	part: BasePart,
	joint: JointInstance,
	prop: string,
	base: CFrame,
}

local WeaponJoint = {}

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

function WeaponJoint.collect(tool: Instance, partName: string): { Entry }
	local entries: { Entry } = {}
	local model = tool:FindFirstChildOfClass("Model")
	local root = model and model.PrimaryPart
	for _, part in tool:GetDescendants() do
		if part.Name ~= partName or not part:IsA("BasePart") then
			continue
		end
		-- Mover la raíz del ensamblaje arrastraría el arma entera.
		if part == root or part == tool:FindFirstChild("Handle") then
			warn(`[WeaponJoint] {part:GetFullName()}: no puede ser el PrimaryPart ni el Handle`)
			continue
		end
		local joint, prop = _resolveJoint(part, tool)
		if not joint then
			warn(`[WeaponJoint] {part:GetFullName()}: no está soldado a otra parte del arma`)
			continue
		end
		table.insert(entries, { part = part, joint = joint, prop = prop, base = (joint :: any)[prop] })
	end
	return entries
end

-- Eje local de la parte más alineado con `reference` (en mundo), o el atributo `override`
-- si la pieza está rotada respecto al modelo.
function WeaponJoint.resolveAxis(part: BasePart, reference: Vector3, override: string): Vector3
	local attribute = part:GetAttribute(override)
	if typeof(attribute) == "Vector3" and attribute.Magnitude > 1e-3 then
		return attribute.Unit
	end
	local v = part.CFrame:VectorToObjectSpace(reference)
	local ax, ay, az = math.abs(v.X), math.abs(v.Y), math.abs(v.Z)
	if ax >= ay and ax >= az then
		return Vector3.new(math.sign(v.X), 0, 0)
	elseif ay >= az then
		return Vector3.new(0, math.sign(v.Y), 0)
	end
	return Vector3.new(0, 0, math.sign(v.Z))
end

-- transform se aplica en el espacio local de la pieza: part_new = part_old * transform.
function WeaponJoint.setTransform(entry: Entry, transform: CFrame)
	if entry.joint.Parent then
		(entry.joint :: any)[entry.prop] = transform:Inverse() * entry.base
	end
end

function WeaponJoint.reset(entry: Entry)
	if entry.joint.Parent then
		(entry.joint :: any)[entry.prop] = entry.base
	end
end

return WeaponJoint
