--!strict
--[[
	Los borders (ItemsConfig.Borders) no se compran ni se guardan en Inventory: se
	poseen en cuanto el nivel llega a su LevelRequired. Lo usan el server
	(InventoryRepository, tarjeta de muerte) y el Locker.
]]

local constants = script.Parent.Parent.constants
local ItemsConfig = require(constants.ItemsConfig)

local BorderLevels = {}

function BorderLevels.isUnlocked(borderId: string, level: number): boolean
	local definition = ItemsConfig.Borders[borderId]
	return definition ~= nil and level >= (definition.LevelRequired or 0)
end

-- El de mayor LevelRequired que ya se tiene; para los bots, que no equipan.
function BorderLevels.highestUnlocked(level: number): string?
	local bestId: string? = nil
	local bestLevel = -1
	for borderId, definition in ItemsConfig.Borders do
		local required = definition.LevelRequired or 0
		if level >= required and required > bestLevel then
			bestId = borderId
			bestLevel = required
		end
	end
	return bestId
end

return BorderLevels
