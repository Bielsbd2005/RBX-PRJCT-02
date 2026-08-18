--!strict
--[[
	MatchProgressionObserver.luau
	Observers de DataController para disparar las animaciones in-match de level up,
	BattlePass tier-up, y maestría de armas (completar un tier + hitos 25/50/75%
	de progreso). Extraído de `features/match/init.luau` para no acumular
	orquestación de progresión ahí.

	API:
		MatchProgressionObserver.attach({
			hud, matchHudGui, fusionScope, janitor
		})

	Internamente espera DataController:WhenReady() y wirea los observers (Stats,
	BattlePass, Inventory→maestría completada, WeaponKills→hitos).
	Cada uno usa el janitor pasado para registrar su cleanup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Fusion = require(Packages.fusion)
local ItemsConfig = require(Shared.constants.ItemsConfig) :: any
local LockerCategory = require(Shared.constants.LockerCategory)

local DataController = require(script.Parent.Parent.Parent.core.data.DataController)

-- Solo se muestran hitos intermedios (25/50/75%) para tiers con objetivo grande;
-- los tiers pequeños (p. ej. Bronze=4) solo notifican al completarse, sin spamear.
local MASTERY_MILESTONE_MIN_TARGET = 50

local MatchProgressionObserver = {}

-- Tiers de maestría = wraps con KillChallenge, ordenadas por kills ascendente.
local function _buildMasteryTiers(): { { kills: number, wrapKey: string, def: any } }
	local tiers = {}
	local weaponWraps = ItemsConfig.WeaponWraps
	if type(weaponWraps) == "table" then
		for wrapKey, def in weaponWraps do
			if type(def) == "table" and type(def.KillChallenge) == "table" then
				local kills = tonumber(def.KillChallenge.Kills)
				if kills and kills > 0 then
					table.insert(tiers, { kills = kills, wrapKey = wrapKey, def = def })
				end
			end
		end
	end
	table.sort(tiers, function(a, b)
		return a.kills < b.kills
	end)
	return tiers
end

-- Para `n` kills, el siguiente tier (el menor con kills > n) o nil si ya superó el máximo.
local function _nextMasteryTier(tiers: { { kills: number, wrapKey: string, def: any } }, n: number)
	for _, tier in tiers do
		if tier.kills > n then
			return tier
		end
	end
	return nil
end

-- Cuarto alcanzado (0..3) del ratio n/target; el 100% no cuenta (eso es completar).
local function _milestoneQuarter(n: number, target: number): number
	if target <= 0 then
		return 0
	end
	return math.clamp(math.floor((n / target) / 0.25), 0, 3)
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

-- Campos de preview/maestría para playMasteryAnimation desde un wrap def.
local function _masteryRewardFields(category: string, weaponId: string, wrapKey: string, def: any): any
	return {
		name = if type(def.Name) == "string" and def.Name ~= "" then def.Name else wrapKey,
		previewWeaponCategory = category,
		previewWeaponId = weaponId,
		itemId = wrapKey,
		category = LockerCategory.WEAPON_WRAPS,
		textureID = if type(def.TextureID) == "string" then def.TextureID else nil,
		baseColor = if typeof(def.BaseColor) == "Color3" then def.BaseColor else nil,
		material = if typeof(def.Material) == "EnumItem" and def.Material.EnumType == Enum.Material then def.Material else nil,
		animated = def.isAnimated == true,
		studsPerTile = tonumber(def.StudsPerTile),
	}
end

type AttachDeps = {
	hud: any,
	matchHudGui: ScreenGui?,
	fusionScope: any,
	janitor: any,
}

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
				hud:playLevelUpAnimation(currentLevel)
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
									-- Wrap de maestría recién ganado = tier completado (100%).
									local threshold = math.max(1, tonumber(def.KillChallenge.Kills) or 0)
									local fields = _masteryRewardFields(category, weaponId, wrapKey, def)
									fields.current = threshold
									fields.target = threshold
									fields.isComplete = true
									hud:playMasteryAnimation(fields)
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

		-- ── Maestría: hitos de progreso 25/50/75% ───────────────
		-- El kill-count por arma vive en DataController.WeaponKills (replicado, con
		-- ListenToChange). En cada incremento calculamos el % hacia el siguiente tier
		-- y, al cruzar un cuarto nuevo, mostramos el popup de Maestry. El 100%
		-- (completar) lo dispara la detección de wrap de arriba. Al entrar en una
		-- banda nueva sembramos el cuarto actual sin notificar (no spamear progreso
		-- ya hecho), y solo notificamos con el HUD de partida activo.
		local masteryTiers = _buildMasteryTiers()
		local lastMilestoneByWeapon: { [string]: { target: number, quarter: number } } = {}
		local milestoneSeeded = false
		local function onWeaponKillsChanged()
			local weaponKills = Fusion.peek(DataController.WeaponKills)
			_eachWeaponKill(weaponKills, function(category, weaponId, kills)
				local key = category .. "|" .. weaponId
				local tier = _nextMasteryTier(masteryTiers, kills)
				if not tier then
					lastMilestoneByWeapon[key] = nil
					return
				end
				local quarter = _milestoneQuarter(kills, tier.kills)
				local prev = lastMilestoneByWeapon[key]
				-- Banda nueva (o primer seed): registrar sin disparar.
				if not prev or prev.target ~= tier.kills then
					lastMilestoneByWeapon[key] = { target = tier.kills, quarter = quarter }
					return
				end
				if milestoneSeeded
					and quarter > prev.quarter
					and quarter >= 1
					and tier.kills >= MASTERY_MILESTONE_MIN_TARGET
					and matchHudGui and matchHudGui.Enabled
				then
					local fields = _masteryRewardFields(category, weaponId, tier.wrapKey, tier.def)
					fields.current = kills
					fields.target = tier.kills
					fields.isComplete = false
					hud:playMasteryAnimation(fields)
				end
				prev.quarter = math.max(prev.quarter, quarter)
			end)
			milestoneSeeded = true
		end
		local weaponKillsObserver = fusionScope:Observer(DataController.WeaponKills)
		janitor:Add(weaponKillsObserver:onBind(onWeaponKillsChanged), true)
		onWeaponKillsChanged()
	end)
end

return MatchProgressionObserver
