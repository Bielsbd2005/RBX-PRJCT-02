--!strict
--[[
	Lista de la vista Wraps del Locker para el arma objetivo: filtra por sub-vista,
	rellena el progreso de los desafíos de maestría y ordena.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local ItemDefaults = require(Shared.constants.ItemDefaults)
local WrapMastery = require(Shared.data.WrapMastery)
local LockerCatalog = require(script.Parent.LockerCatalog)
local LockerInventoryState = require(script.Parent.LockerInventoryState)

type LockerCatalogItem = LockerCatalog.LockerCatalogItem

local LockerWrapsView = {}

local function isMasteryWrapItem(item: LockerCatalogItem): boolean
	return (item.KillGoal ~= nil and item.KillGoal > 0) or item.MasteryScope ~= nil
end

-- Kills ascendente y, detrás, la cadena Gold → Damascus → Galaxy.
local MASTERY_SCOPE_ORDER_BASE = 1e12
local function masteryOrder(item: LockerCatalogItem): number
	if item.KillGoal then
		return item.KillGoal
	end
	local scopeIndex = if item.MasteryScope then table.find(WrapMastery.SCOPE_ORDER, item.MasteryScope :: any) else nil
	return if scopeIndex then MASTERY_SCOPE_ORDER_BASE + scopeIndex else math.huge
end

-- `view`: "owned" (wraps que posee el arma) o "maestry" (desafíos de maestría).
function LockerWrapsView.build(
	items: { LockerCatalogItem },
	inventory: LockerInventoryState.LockerInventoryState,
	view: string,
	getRarityRank: (rarity: string) -> number
): { LockerCatalogItem }
	local loadout = inventory:getLoadout()
	local targetWeaponId = inventory:getWrapsTargetWeaponId(loadout)
	local targetWeaponCategory = inventory:getWrapsTargetCategory()
	local targetCategoryConfig = ItemsConfig[targetWeaponCategory]
	local targetWeaponDefinition = if type(targetCategoryConfig) == "table"
		then targetCategoryConfig[targetWeaponId]
		else nil
	local targetWeaponDisplayName = if type(targetWeaponDefinition) == "table"
		and type(targetWeaponDefinition.Name) == "string"
		and targetWeaponDefinition.Name ~= ""
		then targetWeaponDefinition.Name
		else targetWeaponId
	local wrapItems = {} :: { LockerCatalogItem }

	for _, item in items do
		local isOwned = inventory:ownsWrap(targetWeaponCategory, targetWeaponId, item.id)
		local isChallenge = isMasteryWrapItem(item)
		local include: boolean
		if view == "maestry" then
			include = isChallenge
		else -- "owned"
			include = isOwned
		end
		if include then
			local wrapItem = table.clone(item)
			wrapItem.PreviewWeaponCategory = targetWeaponCategory
			wrapItem.PreviewWeaponId = targetWeaponId
			wrapItem.PreviewWeaponDisplayName = targetWeaponDisplayName
			if isChallenge and not isOwned then
				local scope = item.MasteryScope :: WrapMastery.Scope?
				if scope then
					wrapItem.ChallengeProgress, wrapItem.ChallengeGoal =
						WrapMastery.progress(function(category, weaponId, wrapId)
							return inventory:ownsWrap(category, weaponId, wrapId)
						end, scope, targetWeaponCategory, targetWeaponId)
				else
					wrapItem.ChallengeProgress = inventory:getWeaponKills(targetWeaponCategory, targetWeaponId)
					wrapItem.ChallengeGoal = item.KillGoal
				end
			elseif isChallenge and isOwned then
				wrapItem.ChallengeUnlocked = true
			end
			table.insert(wrapItems, wrapItem)
		end
	end

	-- Orden dentro de la vista Wraps:
	--   1) Default (siempre primero; sólo aparece en Owned)
	--   2) Desafíos de maestría no desbloqueados (Maestry) en orden de la cadena
	--   3) Resto (poseídos) por RAREZA descendente
	local function groupRank(it: LockerCatalogItem): number
		if it.id == ItemDefaults.ITEM_ID then
			return 1
		end
		local isOwned = inventory:ownsWrap(targetWeaponCategory, targetWeaponId, it.id)
		if isMasteryWrapItem(it) and not isOwned then
			return 2
		end
		return 3
	end

	table.sort(wrapItems, function(a, b)
		local groupA = groupRank(a)
		local groupB = groupRank(b)
		if groupA ~= groupB then
			return groupA < groupB
		end

		if groupA == 3 then
			local rarityA = getRarityRank(a.Rarity)
			local rarityB = getRarityRank(b.Rarity)
			if rarityA ~= rarityB then
				return rarityA > rarityB
			end
		end

		local orderA = masteryOrder(a)
		local orderB = masteryOrder(b)
		if orderA ~= orderB then
			return orderA < orderB
		end

		return a.Name < b.Name
	end)

	return wrapItems
end

return LockerWrapsView
