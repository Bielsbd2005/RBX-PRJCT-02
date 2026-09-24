--!strict
--[[
	Partes de un arma que reciben el wrap: el PrimaryPart y las piezas móviles separadas
	de él (Studio: BasePart con el nombre exacto de EXTRA_PART_NAMES, en cualquier nivel).
	Lo usa WeaponWrapPainter.
]]

local EXTRA_PART_NAMES: { [string]: true } = {
	Barrel = true,
	Pump = true,
}

local WeaponWrapParts = {}

function WeaponWrapParts.get(root: Instance, primaryPart: BasePart): { BasePart }
	local parts = { primaryPart }
	for _, descendant in root:GetDescendants() do
		if EXTRA_PART_NAMES[descendant.Name] and descendant:IsA("BasePart") and descendant ~= primaryPart then
			table.insert(parts, descendant)
		end
	end
	return parts
end

return WeaponWrapParts
