--!strict
--[[
	Server-only (lo usa AIService al asignar identidad). La config
	BotPersonalities vive en shared para poder consumirla desde UI.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotPersonalities = require(Shared.constants.BotPersonalities)
local ItemsConfig = require(Shared.constants.ItemsConfig)

export type Personality = BotPersonalities.Personality

local BotPersonality = {}

local _weightedList: { { id: string, cumulative: number, personality: Personality } } = {}
local _totalWeight = 0

local function _buildWeightedList()
	local cumulative = 0
	for id, personality in BotPersonalities do
		local w = math.max(0, personality.weight)
		if w > 0 then
			cumulative += w
			table.insert(_weightedList, { id = id, cumulative = cumulative, personality = personality })
		end
	end
	_totalWeight = cumulative
end

_buildWeightedList()

function BotPersonality.rollPersonality(): (string, Personality)
	-- Config vacía: tier neutro; con allowedRarities vacío los filtros no recortan pools.
	if _totalWeight <= 0 or #_weightedList == 0 then
		local fallback: Personality = {
			id = "Default",
			weight = 1,
			levelRange = { min = 1, max = 1 },
			allowedRarities = {},
			hatProbability = 0,
		}
		return "Default", fallback
	end
	local roll = math.random(1, _totalWeight)
	for _, entry in _weightedList do
		if roll <= entry.cumulative then
			return entry.id, entry.personality
		end
	end
	local last = _weightedList[#_weightedList]
	return last.id, last.personality
end

-- AIService lo usa para recuperar el bloque `combat` al spawnear el BotAI.
function BotPersonality.getById(id: string): Personality?
	return BotPersonalities[id]
end

-- Nivel fingido del bot: la única estadística inventada que se le enseña al
-- jugador (en la tarjeta de la pantalla de muerte).
function BotPersonality.rollLevel(personality: Personality): number
	local lvl = personality.levelRange
	return math.random(math.max(1, lvl.min), math.max(lvl.min, lvl.max))
end

--- allowedRarities vacío = sin filtro (devuelve la lista original).
function BotPersonality.filterByRarity(ids: { string }, category: string, personality: Personality): { string }
	local allowed = personality.allowedRarities
	local hasAnyAllowed = next(allowed) ~= nil
	if not hasAnyAllowed then
		return ids
	end

	local categoryConfig = (ItemsConfig :: any)[category]
	if type(categoryConfig) ~= "table" then
		return ids
	end

	local result: { string } = {}
	for _, id in ids do
		local def = categoryConfig[id]
		if type(def) == "table" then
			local rarity = def.Rarity
			if type(rarity) == "string" and allowed[rarity] then
				table.insert(result, id)
			end
		end
	end
	return result
end

return BotPersonality
