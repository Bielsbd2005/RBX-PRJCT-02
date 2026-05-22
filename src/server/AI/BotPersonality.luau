--!strict
--[[
	BotPersonality.luau
	Helpers de sampling de personalidades de bots.

	- rollPersonality(): pick weighted del módulo de config.
	- rollStats(p): nivel + kills históricas uniformes en el rango del tier.
	- filterByRarity(ids, category, p): intersecta una lista de ids con
	  los que tienen Rarity ∈ p.allowedRarities.

	El módulo es server-only (lo llama AIService al asignar identidad). La
	config (BotPersonalities) está en shared para futuro consumo de UI.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotPersonalities = require(Shared.constants.BotPersonalities)
local ItemsConfig = require(Shared.constants.ItemsConfig)

export type Personality = BotPersonalities.Personality

local BotPersonality = {}

-- ── Tabla de pesos cumulativa (calculada al load) ───────────────
-- Estructura: { { id = "...", cumulative = number }, ... }; total al final.
-- Pick: math.random(1, total) → binary scan no necesario con ≤4 entries,
-- iteramos lineal.

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

-- ── API ─────────────────────────────────────────────────────────

function BotPersonality.rollPersonality(): (string, Personality)
	-- Defensiva: si la config está vacía (no debería), devolvemos un
	-- tier neutro. Sin allowedRarities, los filtros más abajo dejarían
	-- pools intactos.
	if _totalWeight <= 0 or #_weightedList == 0 then
		local fallback: Personality = {
			id = "Default",
			weight = 1,
			levelRange = { min = 1, max = 1 },
			historicalKillsRange = { min = 0, max = 0 },
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
	-- Fallback teórico (no debería alcanzarse con _totalWeight bien sumado).
	local last = _weightedList[#_weightedList]
	return last.id, last.personality
end

function BotPersonality.rollStats(personality: Personality): (number, number)
	local lvl = personality.levelRange
	local kills = personality.historicalKillsRange
	local level = math.random(math.max(1, lvl.min), math.max(lvl.min, lvl.max))
	local historicalKills = math.random(math.max(0, kills.min), math.max(kills.min, kills.max))
	return level, historicalKills
end

--- Filtra una lista de ids dejando sólo los cuyo Rarity está en
--- personality.allowedRarities. Si allowedRarities está vacío,
--- devuelve la lista original (= sin filtro).
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
