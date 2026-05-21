--!strict
--[[
	MatchProgressionObserver.luau
	Observers de DataController para disparar las animaciones in-match de level up,
	BattlePass tier-up, wrap challenge unlock, y daily task claim. Extraído de
	`features/match/init.luau` para no acumular orquestación de progresión ahí.

	API:
		MatchProgressionObserver.attach({
			hud, matchHudGui, fusionScope, janitor
		})

	Internamente espera DataController:WhenReady() y wirea los 4 observers.
	Cada uno usa el janitor pasado para registrar su cleanup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Fusion = require(Packages.fusion)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local DailyTasksConfig = require(Shared.constants.DailyTasks)
local ActionRewards = require(Shared.constants.ActionRewards)
local LockerCategory = require(Shared.constants.LockerCategory)

local DataController = require(script.Parent.Parent.Parent.core.data.DataController)

local DAILY_TASK_COMPLETED_ICON = "rbxassetid://113694528712529"

local MatchProgressionObserver = {}

type AttachDeps = {
	hud: any,
	matchHudGui: ScreenGui?,
	fusionScope: any,
	janitor: any,
}

local function _findLevelUpUnlock(level: number): any
	for category, items in ItemsConfig do
		if type(items) == "table" then
			for itemId, definition in items do
				if type(definition) == "table" and tonumber(definition.LevelRequired) == level then
					local name = if type(definition.Name) == "string" and definition.Name ~= ""
						then definition.Name
						else tostring(itemId)
					local image = if type(definition.Image) == "string" then definition.Image else nil
					return {
						name = name,
						category = tostring(category),
						image = image,
					}
				end
			end
		end
	end
	return nil
end

local function _isKillChallengeWrap(wrapKey: string): (boolean, any)
	local weaponWraps = ItemsConfig.WeaponWraps
	if type(weaponWraps) ~= "table" then
		return false, nil
	end
	local def = weaponWraps[wrapKey]
	if type(def) ~= "table" then
		return false, nil
	end
	local challenge = def.KillChallenge
	if type(challenge) == "table" and tonumber(challenge.Kills) and challenge.Kills > 0 then
		return true, def
	end
	return false, nil
end

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
		-- ── Level up de character ───────────────────────────────
		local lastSeenLevel: number? = nil
		local function updateCashAndLevel()
			local stats = Fusion.peek(DataController.Stats) :: any
			hud:updateCashLevel(stats)

			local currentLevel = if stats and type(stats.Level) == "number" then math.max(0, math.floor(stats.Level)) else 0
			if lastSeenLevel ~= nil and currentLevel > lastSeenLevel then
				local unlock = _findLevelUpUnlock(currentLevel)
				hud:playLevelUpAnimation(currentLevel, unlock)
			end
			lastSeenLevel = currentLevel
		end
		local statsObserver = fusionScope:Observer(DataController.Stats)
		janitor:Add(statsObserver:onBind(updateCashAndLevel), true)
		updateCashAndLevel()

		-- ── BattlePass tier-up ──────────────────────────────────
		-- Convención: el jugador percibe "Lvl. N" como el último tier completado,
		-- así que mostramos `currentTier - 1` (CurrentTier internamente es "el
		-- tier hacia el que progreso"). Si ocurre cascading tier-up (subir 3
		-- niveles en una sola kill), disparamos un único toast con el tier final,
		-- igual que hace el level up de character.
		local lastSeenBPTier: number? = nil
		local function checkBattlePassLevelUp()
			local bp = Fusion.peek(DataController.BattlePass) :: any
			if type(bp) ~= "table" then return end
			local currentTier = if type(bp.CurrentTier) == "number" then math.max(1, math.floor(bp.CurrentTier)) else 1
			if lastSeenBPTier ~= nil and currentTier > lastSeenBPTier then
				local displayLevel = math.max(0, currentTier - 1)
				hud:playBattlePassLevelUpAnimation(displayLevel)
			end
			lastSeenBPTier = currentTier
		end
		local bpObserver = fusionScope:Observer(DataController.BattlePass)
		janitor:Add(bpObserver:onBind(checkBattlePassLevelUp), true)
		checkBattlePassLevelUp()

		-- ── Wrap challenge unlock ───────────────────────────────
		-- Snapshot inicial de wraps owned por arma para detectar desbloqueos.
		local previousByWeapon: { [string]: { [string]: { [string]: boolean } } } = {}
		local wrapsSeeded = false

		local function updateWrapsAndDetectUnlocks()
			local inventory = Fusion.peek(DataController.Inventory) :: any
			local current = _snapshotWrapsOwned(inventory)

			if wrapsSeeded then
				for category, weaponMap in current do
					local prevCat = previousByWeapon[category] or {}
					for weaponId, wrapMap in weaponMap do
						local prevWraps = prevCat[weaponId] or {}
						for wrapKey, _ in wrapMap do
							if not prevWraps[wrapKey] then
								local isChallenge, def = _isKillChallengeWrap(wrapKey)
								if isChallenge then
									hud:playChallengeCompletedAnimation({
										name = if type(def.Name) == "string" and def.Name ~= "" then def.Name else wrapKey,
										image = if type(def.Image) == "string" and def.Image ~= "" then def.Image else nil,
										previewWeaponCategory = category,
										previewWeaponId = weaponId,
										itemId = wrapKey,
										category = LockerCategory.WEAPON_WRAPS,
										textureID = if type(def.TextureID) == "string" then def.TextureID else nil,
										baseColor = if typeof(def.BaseColor) == "Color3" then def.BaseColor else nil,
										animated = def.isAnimated == true,
										studsPerTile = tonumber(def.StudsPerTile),
									})
								end
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

		-- ── Daily tasks: detectar transición Claimed false→true ─
		-- Solo dispara la animación de "Completed" cuando el HUD de partida
		-- está activo (matchHudGui.Enabled). En menú no se muestra; el frame
		-- del lobby ya pinta el fill verde como feedback.
		local prevClaimed: { [string]: boolean } = {}
		local claimedSeeded = false
		local function onDailyTasksChanged()
			local state = Fusion.peek(DataController.DailyTasks) :: any
			local claimed = if state and type(state.Claimed) == "table" then state.Claimed else {}

			if claimedSeeded and matchHudGui and matchHudGui.Enabled then
				for _, def in DailyTasksConfig.Tasks do
					local now = (claimed :: any)[def.Id] == true
					local before = prevClaimed[def.Id] == true
					if now and not before then
						-- Description leerá "You earned Cash"; Reward.Value
						-- mostrará el monto otorgado por la tarea. Cash vive en
						-- ActionRewards (clave "Daily"..Id), no en DailyTasks.luau.
						hud:playChallengeCompletedAnimation({
							name = "Cash",
							image = DAILY_TASK_COMPLETED_ICON,
							cashAmount = ActionRewards.GetCash("Daily" .. def.Id),
						})
					end
				end
			end

			local snapshot: { [string]: boolean } = {}
			for _, def in DailyTasksConfig.Tasks do
				snapshot[def.Id] = (claimed :: any)[def.Id] == true
			end
			prevClaimed = snapshot
			claimedSeeded = true
		end
		local dailyTasksObserver = fusionScope:Observer(DataController.DailyTasks)
		janitor:Add(dailyTasksObserver:onBind(onDailyTasksChanged), true)
	end)
end

return MatchProgressionObserver
