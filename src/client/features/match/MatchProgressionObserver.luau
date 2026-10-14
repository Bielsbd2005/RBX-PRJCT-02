--!strict
--[[
	Observers de DataController que disparan las animaciones in-match de level up,
	maestría de armas y desafíos diarios.
	Todos siembran el estado inicial sin notificar.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Fusion = require(Packages.fusion)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local DailyTasks = require(Shared.constants.DailyTasks)
local ActionRewards = require(Shared.constants.ActionRewards)
local WrapMastery = require(Shared.data.WrapMastery)

local DataController = require(script.Parent.Parent.Parent.core.data.DataController)

-- Hitos intermedios (25/50/75%) solo para tiers con objetivo >= esto; los pequeños
-- solo notifican al completarse.
local MASTERY_MILESTONE_MIN_TARGET = 50
local MASTERY_STATS: { WrapMastery.Stat } = { "Kills", "Precision", "Streaks" }

local MatchProgressionObserver = {}

-- Siguiente wrap del arma para ese contador; los objetivos dependen de su clase.
local function _nextMasteryTier(category: string, weaponId: string, stat: WrapMastery.Stat, n: number): { wrapId: string, goal: number }?
	for _, tier in WrapMastery.tiersOf(category, weaponId, stat) do
		if tier.goal > n then
			return tier
		end
	end
	return nil
end

-- Marca que avisa al subir: el cuarto del objetivo (0..3; el 100% es completar) o, en
-- las rachas, cada una, porque nada más le dice al jugador que la racha ha contado.
local function _milestoneMark(stat: WrapMastery.Stat, n: number, target: number): number
	if stat == "Streaks" then
		return n
	elseif target < MASTERY_MILESTONE_MIN_TARGET then
		return 0
	end
	return math.clamp(math.floor((n / target) / 0.25), 0, 3)
end

-- Precision solo llega aquí por headshots: en rachas WrapMastery lo da como "Streaks".
local function _statLabel(stat: WrapMastery.Stat): string
	return if stat == "Precision" then "Headshots" else stat
end

local function _eachWeaponKill(weaponKills: any, fn: (category: string, weaponId: string, kills: number) -> ())
	if type(weaponKills) ~= "table" then
		return
	end
	for _, category in { "Main", "Special" } do
		local catMap = weaponKills[category]
		if type(catMap) == "table" then
			for weaponId, kills in catMap do
				if type(kills) == "number" then
					fn(category, weaponId, kills)
				end
			end
		end
	end
end

local function _masteryRewardFields(wrapKey: string): any
	local def = ItemsConfig.WeaponWraps[wrapKey]
	return {
		name = if type(def) == "table" and type(def.Name) == "string" and def.Name ~= "" then def.Name else wrapKey,
		wrapId = wrapKey,
	}
end

type AttachDeps = {
	hud: any,
	matchHudGui: ScreenGui?,
	fusionScope: any,
	janitor: any,
}

local function _snapshotWrapsOwned(inventory: any): { [string]: { [string]: { [string]: boolean } } }
	local snapshot: { [string]: { [string]: { [string]: boolean } } } = {}
	local byWeapon = if type(inventory) == "table" then inventory.WeaponWrapsByWeapon else nil
	if type(byWeapon) ~= "table" then
		return snapshot
	end
	for category, weaponMap in byWeapon do
		if type(weaponMap) == "table" then
			local catSnap: { [string]: { [string]: boolean } } = {}
			for weaponId, wrapMap in weaponMap do
				if type(wrapMap) == "table" then
					local wrapSnap: { [string]: boolean } = {}
					for wrapKey, owned in wrapMap do
						if owned == true or (type(owned) == "number" and owned > 0) then
							wrapSnap[wrapKey] = true
						end
					end
					catSnap[weaponId] = wrapSnap
				end
			end
			snapshot[category] = catSnap
		end
	end
	return snapshot
end

function MatchProgressionObserver.attach(deps: AttachDeps)
	local hud = deps.hud
	local matchHudGui = deps.matchHudGui
	local fusionScope = deps.fusionScope
	local janitor = deps.janitor

	DataController:WhenReady():andThen(function()
		local lastSeenLevel: number? = nil
		local function updateCashAndLevel()
			local stats = Fusion.peek(DataController.Stats) :: any
			hud:updateCashLevel(stats)

			local currentLevel = if stats and type(stats.Level) == "number" then math.max(0, math.floor(stats.Level)) else 0
			-- Con el HUD apagado (fin de ronda, lobby) sonaría y lanzaría confeti sin verse.
			if lastSeenLevel ~= nil and currentLevel > lastSeenLevel and matchHudGui and matchHudGui.Enabled then
				hud:playLevelUpAnimation(currentLevel)
			end
			lastSeenLevel = currentLevel
		end
		local statsObserver = fusionScope:Observer(DataController.Stats)
		janitor:Add(statsObserver:onBind(updateCashAndLevel), true)
		updateCashAndLevel()

		local previousByWeapon: { [string]: { [string]: { [string]: boolean } } } = {}
		local wrapsSeeded = false

		local function updateWrapsAndDetectUnlocks()
			local inventory = Fusion.peek(DataController.Inventory) :: any
			local current = _snapshotWrapsOwned(inventory)

			if wrapsSeeded then
				-- Damascus/Galaxy llegan a varias armas a la vez: una tarjeta por wrap.
				local celebrated: { [string]: boolean } = {}
				for category, weaponMap in current do
					local prevCat = previousByWeapon[category] or {}
					for weaponId, wrapMap in weaponMap do
						local prevWraps = prevCat[weaponId] or {}
						for wrapKey, _ in wrapMap do
							if not prevWraps[wrapKey] and not celebrated[wrapKey] and WrapMastery.isMasteryWrap(wrapKey) then
								celebrated[wrapKey] = true
								local fields = _masteryRewardFields(wrapKey)
								fields.current = 1
								fields.target = 1
								fields.isComplete = true
								hud:playMasteryAnimation(fields)
							end
						end
					end
				end
			end

			previousByWeapon = current
			wrapsSeeded = true
		end

		local inventoryObserver = fusionScope:Observer(DataController.Inventory)
		janitor:Add(inventoryObserver:onBind(updateWrapsAndDetectUnlocks), true)

		-- Hitos hacia el siguiente tier de cada contador (_milestoneMark); el 100% lo dispara
		-- la detección de wrap de arriba. Al entrar en un tier nuevo se siembra sin notificar.
		-- Un arma con contadores de desafío siempre tiene bajas: basta recorrer WeaponKills.
		local lastMarkByTier: { [string]: { target: number, mark: number } } = {}
		local milestoneSeeded = false
		local function onMasteryStatsChanged()
			local weaponChallenges = Fusion.peek(DataController.WeaponChallenges) :: any
			_eachWeaponKill(Fusion.peek(DataController.WeaponKills), function(category, weaponId, kills)
				local categoryChallenges = if type(weaponChallenges) == "table" then weaponChallenges[category] else nil
				local challengeStats = if type(categoryChallenges) == "table" then categoryChallenges[weaponId] else nil
				for _, stat in MASTERY_STATS do
					local value = if stat == "Kills"
						then kills
						else (if type(challengeStats) == "table" then tonumber(challengeStats[stat]) else nil) or 0
					local key = category .. "|" .. weaponId .. "|" .. stat
					local tier = _nextMasteryTier(category, weaponId, stat, value)
					if not tier then
						lastMarkByTier[key] = nil
						continue
					end
					local mark = _milestoneMark(stat, value, tier.goal)
					local prev = lastMarkByTier[key]
					if not prev or prev.target ~= tier.goal then
						lastMarkByTier[key] = { target = tier.goal, mark = mark }
						continue
					end
					if milestoneSeeded and mark > prev.mark and matchHudGui and matchHudGui.Enabled then
						local fields = _masteryRewardFields(tier.wrapId)
						fields.name ..= ": " .. _statLabel(stat)
						fields.current = value
						fields.target = tier.goal
						fields.isComplete = false
						hud:playMasteryAnimation(fields)
					end
					prev.mark = math.max(prev.mark, mark)
				end
			end)
			milestoneSeeded = true
		end
		for _, masteryStats in { DataController.WeaponKills, DataController.WeaponChallenges } do
			janitor:Add(fusionScope:Observer(masteryStats):onBind(onMasteryStatsChanged), true)
		end
		onMasteryStatsChanged()

		-- La rotación se siembra con el DateKey del estado, el mismo con el que paga el
		-- server. Se reserva el cash (hud:reserveChallengeCash) porque el server manda
		-- cash y estado en la MISMA tanda: sin la reserva, el popup de ganancias
		-- animaría esa subida por su cuenta además de la tarjeta.
		local dailySeeded = false
		local lastDailyClaimed: { [string]: boolean } = {}
		local function onDailyTasksChanged()
			local state = Fusion.peek(DataController.DailyTasks) :: any
			if type(state) ~= "table" then
				return
			end
			local claimedById = if type(state.Claimed) == "table" then state.Claimed else {}
			local canNotify = dailySeeded and matchHudGui ~= nil and matchHudGui.Enabled

			local dateKey = if type(state.DateKey) == "string" then state.DateKey else nil
			for _, active in DailyTasks.GetRotation(dateKey) do
				local def = active.Definition
				local slotId = active.SlotId
				local objective = math.max(1, math.floor(def.Objective))
				local claimed = (claimedById :: any)[slotId] == true
				local wasClaimed = lastDailyClaimed[slotId] == true
				local rewardCash = ActionRewards.GetCash(DailyTasks.RewardKey(def))

				if canNotify and claimed and not wasClaimed then
					hud:reserveChallengeCash(rewardCash)
					hud:playDailyTaskAnimation({
						current = objective,
						target = objective,
						name = def.Title,
						isComplete = true,
						rewardCash = rewardCash,
					})
				end

				lastDailyClaimed[slotId] = claimed
			end
			dailySeeded = true
		end
		local dailyTasksObserver = fusionScope:Observer(DataController.DailyTasks)
		janitor:Add(dailyTasksObserver:onBind(onDailyTasksChanged), true)
		onDailyTasksChanged()
	end)
end

return MatchProgressionObserver
