--!strict
--[[
	Cadena de wraps de maestría. Los de `Challenge` se ganan con los contadores del arma
	(bajas, precisión, rachas), adaptados a su clase (constants.WeaponMasteryClasses);
	los de MasteryScope, por tener los del eslabón anterior:
	  "Weapon"   → esa arma tiene todos los wraps de Challenge sin `Requires`.
	  "Category" → todas las armas del catálogo de su categoría tienen los "Weapon".
	  "All"      → todas las armas de todas las categorías tienen los "Category".
	Los "Category" y "All" se conceden a todas las armas que abarcan.
	Un Challenge con `Requires` pide además ese wrap en el arma y no es eslabón de nadie.
	El servidor (KillRewardsService) concede con esto y el Locker muestra el progreso.
]]

local constants = script.Parent.Parent.constants
local ItemsConfig = require(constants.ItemsConfig) :: any
local WeaponCategory = require(constants.WeaponCategory)
local WeaponMasteryClasses = require(constants.WeaponMasteryClasses)

export type Scope = "Weapon" | "Category" | "All"
-- "Kills" vive en WeaponKills del perfil; el resto, en WeaponChallenges.
export type Stat = "Kills" | "Precision" | "Streaks"
export type Challenge = { stat: Stat, goal: number, requires: string? }
export type Owns = (category: string, weaponId: string, wrapId: string) -> boolean
export type Grant = { category: string, weaponId: string, wrapId: string }

local SCOPE_ORDER: { Scope } = { "Weapon", "Category", "All" }
local STATS: { Stat } = { "Kills", "Precision", "Streaks" }
-- El orden en que se listan: los retos de Kills, luego Precision y Streaks, y al
-- final los de ámbito. Son claves de ItemsConfig.WeaponWraps; un wrap de maestría
-- que falte aquí va al final.
local DIFFICULTY_ORDER = {
	"Mastery_Graphite",
	"Mastery_Copper",
	"Mastery_Jade",
	"Mastery_Cobalt",
	"Mastery_Amethyst",
	"Mastery_Garnet",
	"Mastery_Gold",
	"Mastery_Damascus",
	"Mastery_Galaxy",
}

local WrapMastery = {}

-- Objetivos sin escalar por clase.
local baseChallenges: { [string]: Challenge } = {}
local challengeWraps: { string } = {}
local gatedWraps: { string } = {}
local wrapsByScope: { [Scope]: { string } } = { Weapon = {}, Category = {}, All = {} }
local scopeByWrap: { [string]: Scope } = {}

for wrapId, def in ItemsConfig.WeaponWraps do
	if type(def) ~= "table" then
		continue
	end
	local challenge = def.Challenge
	local goal = if type(challenge) == "table" then tonumber(challenge.Goal) else nil
	if goal and goal > 0 and table.find(STATS, challenge.Stat) then
		local requires: string? = if type(def.Requires) == "string" then def.Requires else nil
		baseChallenges[wrapId] = { stat = challenge.Stat, goal = goal, requires = requires }
		table.insert(if requires then gatedWraps else challengeWraps, wrapId)
	elseif wrapsByScope[def.MasteryScope] then
		table.insert(wrapsByScope[def.MasteryScope], wrapId)
		scopeByWrap[wrapId] = def.MasteryScope
	end
end

local function difficultyOf(wrapId: string): number
	return table.find(DIFFICULTY_ORDER, wrapId) or #DIFFICULTY_ORDER + 1
end

local function byDifficulty(a: string, b: string): boolean
	local difficultyA, difficultyB = difficultyOf(a), difficultyOf(b)
	if difficultyA ~= difficultyB then
		return difficultyA < difficultyB
	end
	return a < b
end
table.sort(challengeWraps, byDifficulty)
table.sort(gatedWraps, byDifficulty)
for _, scope in SCOPE_ORDER do
	table.sort(wrapsByScope[scope], byDifficulty)
end

local function sortedKeys(map: any): { string }
	local keys = {}
	if type(map) == "table" then
		for key in map do
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys
end

local weaponsByCategory: { [string]: { string } } = {}
for _, category in WeaponCategory.ALL do
	weaponsByCategory[category] = sortedKeys(ItemsConfig[category])
end

local function prerequisitesOf(scope: Scope): { string }
	if scope == "Weapon" then
		return challengeWraps
	elseif scope == "Category" then
		return wrapsByScope.Weapon
	end
	return wrapsByScope.Category
end

-- Sin prerequisitos configurados no se concede nada (evita regalar el wrap).
local function hasAll(owns: Owns, category: string, weaponId: string, wrapIds: { string }): boolean
	if #wrapIds == 0 then
		return false
	end
	for _, wrapId in wrapIds do
		if not owns(category, weaponId, wrapId) then
			return false
		end
	end
	return true
end

-- Pares (categoría, arma) que abarca un wrap de ese scope concedido desde `category`/`weaponId`.
local function targetsOf(scope: Scope, category: string, weaponId: string): { { string } }
	if scope == "Weapon" then
		return { { category, weaponId } }
	end
	local categories = if scope == "Category" then { category } else WeaponCategory.ALL
	local targets = {}
	for _, cat in categories do
		for _, id in weaponsByCategory[cat] or {} do
			table.insert(targets, { cat, id })
		end
	end
	return targets
end

function WrapMastery.isMasteryWrap(wrapId: string): boolean
	return baseChallenges[wrapId] ~= nil or scopeByWrap[wrapId] ~= nil
end

-- Posición del wrap por dificultad, para ordenarlos; nil si no es de maestría.
function WrapMastery.orderOf(wrapId: string): number?
	return if WrapMastery.isMasteryWrap(wrapId) then difficultyOf(wrapId) else nil
end

function WrapMastery.classOf(category: string, weaponId: string): WeaponMasteryClasses.Class
	local catalog = ItemsConfig[category]
	local def = if type(catalog) == "table" then catalog[weaponId] else nil
	local classId = if type(def) == "table" then def.MasteryClass else nil
	return WeaponMasteryClasses.Classes[classId] or WeaponMasteryClasses.Classes[WeaponMasteryClasses.DEFAULT]
end

-- Desafío del wrap para esa arma, con el contador y el objetivo ya adaptados a su clase.
function WrapMastery.challengeOf(wrapId: string, category: string, weaponId: string): Challenge?
	local base = baseChallenges[wrapId]
	if not base then
		return nil
	end
	local class = WrapMastery.classOf(category, weaponId)
	if base.stat == "Precision" and class.Precision == "Streaks" then
		return { stat = "Streaks", goal = WeaponMasteryClasses.StreakGoal, requires = base.requires }
	end
	local goal = base.goal
	if base.stat ~= "Streaks" then
		goal = math.max(1, math.floor(goal * class.GoalScale + 0.5))
	end
	return { stat = base.stat, goal = goal, requires = base.requires }
end

-- Wraps del arma que se ganan con ese contador, por objetivo ascendente, incluidos los
-- que piden otro wrap.
function WrapMastery.tiersOf(category: string, weaponId: string, stat: Stat): { { wrapId: string, goal: number } }
	local tiers = {}
	for wrapId in baseChallenges do
		local challenge = WrapMastery.challengeOf(wrapId, category, weaponId) :: Challenge
		if challenge.stat == stat then
			table.insert(tiers, { wrapId = wrapId, goal = challenge.goal })
		end
	end
	table.sort(tiers, function(a, b)
		return a.goal < b.goal
	end)
	return tiers
end

-- Wraps que hay que tener en cada arma que abarca un wrap de ese scope.
function WrapMastery.prerequisitesOf(scope: Scope): { string }
	return prerequisitesOf(scope)
end

function WrapMastery.scopeOf(wrapId: string): Scope?
	return scopeByWrap[wrapId]
end

-- Wraps de Challenge que le faltan al arma para sus wraps de scope "Weapon".
function WrapMastery.missingWraps(owns: Owns, category: string, weaponId: string): { string }
	local missing = {}
	for _, wrapId in challengeWraps do
		if not owns(category, weaponId, wrapId) then
			table.insert(missing, wrapId)
		end
	end
	return missing
end

-- Pares (categoría, arma) a los que les faltan los prerequisitos de un wrap de scope
-- "Category" o "All".
function WrapMastery.missingWeapons(owns: Owns, scope: Scope, category: string, weaponId: string): { { string } }
	local prerequisites = prerequisitesOf(scope)
	local missing = {}
	for _, target in targetsOf(scope, category, weaponId) do
		if not hasAll(owns, target[1], target[2], prerequisites) then
			table.insert(missing, target)
		end
	end
	return missing
end

-- Progreso hacia un wrap de ese scope para el arma: (hechos, total).
-- Weapon cuenta wraps de Challenge; Category y All cuentan armas.
function WrapMastery.progress(owns: Owns, scope: Scope, category: string, weaponId: string): (number, number)
	if scope == "Weapon" then
		return #challengeWraps - #WrapMastery.missingWraps(owns, category, weaponId), #challengeWraps
	end
	local total = #targetsOf(scope, category, weaponId)
	return total - #WrapMastery.missingWeapons(owns, scope, category, weaponId), total
end

-- Wraps de maestría que faltan por conceder tras progresar con esta arma; `stats` son
-- sus contadores por Stat. Evalúa la cadena en orden contando como poseído lo que
-- concede por el camino.
function WrapMastery.pendingGrants(owns: Owns, stats: { [string]: number }, category: string, weaponId: string): { Grant }
	local grants: { Grant } = {}
	local granted: { [string]: boolean } = {}
	local function ownsNow(cat: string, id: string, wrapId: string): boolean
		return granted[cat .. "|" .. id .. "|" .. wrapId] == true or owns(cat, id, wrapId)
	end
	local function grant(cat: string, id: string, wrapId: string)
		granted[cat .. "|" .. id .. "|" .. wrapId] = true
		table.insert(grants, { category = cat, weaponId = id, wrapId = wrapId })
	end
	local function reached(wrapId: string): boolean
		local challenge = WrapMastery.challengeOf(wrapId, category, weaponId) :: Challenge
		return (stats[challenge.stat] or 0) >= challenge.goal
	end

	for _, wrapId in challengeWraps do
		if reached(wrapId) and not owns(category, weaponId, wrapId) then
			grant(category, weaponId, wrapId)
		end
	end

	for _, scope in SCOPE_ORDER do
		local prerequisites = prerequisitesOf(scope)
		local targets = targetsOf(scope, category, weaponId)
		local complete = #targets > 0
		for _, target in targets do
			if not hasAll(ownsNow, target[1], target[2], prerequisites) then
				complete = false
				break
			end
		end
		if not complete then
			break
		end
		for _, wrapId in wrapsByScope[scope] do
			for _, target in targets do
				if not ownsNow(target[1], target[2], wrapId) then
					grant(target[1], target[2], wrapId)
				end
			end
		end
	end

	for _, wrapId in gatedWraps do
		local requires = baseChallenges[wrapId].requires :: string
		if reached(wrapId) and ownsNow(category, weaponId, requires) and not owns(category, weaponId, wrapId) then
			grant(category, weaponId, wrapId)
		end
	end

	return grants
end

return WrapMastery
