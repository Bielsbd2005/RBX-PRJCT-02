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
local LimitedBundles = require(Shared.data.LimitedBundles)
local LockerCatalog = require(script.Parent.LockerCatalog)
local LockerInventoryState = require(script.Parent.LockerInventoryState)

type LockerCatalogItem = LockerCatalog.LockerCatalogItem

local LockerWrapsView = {}

local function isMasteryWrapItem(item: LockerCatalogItem): boolean
	return item.IsMasteryWrap == true
end

local function masteryOrder(item: LockerCatalogItem): number
	return WrapMastery.orderOf(item.id) or math.huge
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
					local challenge = WrapMastery.challengeOf(item.id, targetWeaponCategory, targetWeaponId)
					if challenge then
						wrapItem.ChallengeProgress = inventory:getWeaponStat(targetWeaponCategory, targetWeaponId, challenge.stat)
						wrapItem.ChallengeGoal = challenge.goal
					end
				end
			elseif isChallenge and isOwned then
				wrapItem.ChallengeUnlocked = true
			end
			-- Reutiliza el badge de temporada: un wrap limitado nunca es de un pase.
			local serial = if isOwned then inventory:getWrapSerial(item.id) else nil
			if serial then
				wrapItem.SeasonLabel = string.format(LimitedBundles.SERIAL_FORMAT, serial)
			end
			table.insert(wrapItems, wrapItem)
		end
	end

	-- Orden dentro de la vista Wraps:
	--   1) Default (siempre primero; sólo aparece en Owned)
	--   2) Maestry: por dificultad, desbloqueados incluidos
	--   3) Owned: por RAREZA descendente
	local function groupRank(it: LockerCatalogItem): number
		if it.id == ItemDefaults.ITEM_ID then
			return 1
		end
		return if view == "maestry" then 2 else 3
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
