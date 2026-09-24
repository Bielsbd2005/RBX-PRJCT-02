--!strict
--[[
	Cadena de wraps de maestría. Los de KillChallenge se ganan por kills del arma;
	los de MasteryScope, por tener los del eslabón anterior:
	  "Weapon"   → esa arma tiene todos los wraps de KillChallenge.
	  "Category" → todas las armas del catálogo de su categoría tienen los "Weapon".
	  "All"      → todas las armas de todas las categorías tienen los "Category".
	Los "Category" y "All" se conceden a todas las armas que abarcan.
	El servidor (MatchService) concede con esto y el Locker muestra el progreso.
]]

local constants = script.Parent.Parent.constants
local ItemsConfig = require(constants.ItemsConfig) :: any
local WeaponCategory = require(constants.WeaponCategory)

export type Scope = "Weapon" | "Category" | "All"
export type Owns = (category: string, weaponId: string, wrapId: string) -> boolean
export type Grant = { category: string, weaponId: string, wrapId: string }

local SCOPE_ORDER: { Scope } = { "Weapon", "Category", "All" }

local WrapMastery = {}

WrapMastery.SCOPE_ORDER = SCOPE_ORDER

local killWraps: { string } = {}
local wrapsByScope: { [Scope]: { string } } = { Weapon = {}, Category = {}, All = {} }
local scopeByWrap: { [string]: Scope } = {}

for wrapId, def in ItemsConfig.WeaponWraps do
	if type(def) ~= "table" then
		continue
	end
	local challenge = def.KillChallenge
	local kills = if type(challenge) == "table" then tonumber(challenge.Kills) else nil
	if kills and kills > 0 then
		table.insert(killWraps, wrapId)
	elseif wrapsByScope[def.MasteryScope] then
		table.insert(wrapsByScope[def.MasteryScope], wrapId)
		scopeByWrap[wrapId] = def.MasteryScope
	end
end
table.sort(killWraps, function(a, b)
	return ItemsConfig.WeaponWraps[a].KillChallenge.Kills < ItemsConfig.WeaponWraps[b].KillChallenge.Kills
end)

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
		return killWraps
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

-- Wraps que hay que tener en cada arma que abarca un wrap de ese scope.
function WrapMastery.prerequisitesOf(scope: Scope): { string }
	return prerequisitesOf(scope)
end

function WrapMastery.scopeOf(wrapId: string): Scope?
	return scopeByWrap[wrapId]
end

-- Progreso hacia un wrap de ese scope para el arma: (hechos, total).
-- Weapon cuenta wraps de KillChallenge; Category y All cuentan armas.
function WrapMastery.progress(owns: Owns, scope: Scope, category: string, weaponId: string): (number, number)
	local prerequisites = prerequisitesOf(scope)
	if scope == "Weapon" then
		local done = 0
		for _, wrapId in prerequisites do
			if owns(category, weaponId, wrapId) then
				done += 1
			end
		end
		return done, #prerequisites
	end
	local targets = targetsOf(scope, category, weaponId)
	local done = 0
	for _, target in targets do
		if hasAll(owns, target[1], target[2], prerequisites) then
			done += 1
		end
	end
	return done, #targets
end

-- Wraps de MasteryScope que faltan por conceder tras progresar con esta arma.
-- Evalúa la cadena en orden contando como poseído lo que concede por el camino.
function WrapMastery.pendingGrants(owns: Owns, category: string, weaponId: string): { Grant }
	local grants: { Grant } = {}
	local granted: { [string]: boolean } = {}
	local function ownsNow(cat: string, id: string, wrapId: string): boolean
		return granted[cat .. "|" .. id .. "|" .. wrapId] == true or owns(cat, id, wrapId)
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
					granted[target[1] .. "|" .. target[2] .. "|" .. wrapId] = true
					table.insert(grants, { category = target[1], weaponId = target[2], wrapId = wrapId })
				end
			end
		end
	end

	return grants
end

return WrapMastery
