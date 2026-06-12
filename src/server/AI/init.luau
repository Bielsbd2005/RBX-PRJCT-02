--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local KillEffectsRegistry = require(Shared.Locker.killEffects.KillEffectsRegistry)
local CollisionGroups = require(Shared:WaitForChild("CollisionGroups"))
local BotNames = require(Shared.constants.BotNames)
local BotConfig = require(Shared.constants.BotConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)

local LastAttackerStore = require(ReplicatedStorage:WaitForChild("WeaponsSystem"):WaitForChild("Libraries"):WaitForChild("LastAttackerStore"))
local BotAI = require(script:WaitForChild("BotAI"))
local BotAppearance = require(script:WaitForChild("BotAppearance"))
local BotPersonality = require(script:WaitForChild("BotPersonality"))
local NavMetrics = require(script:WaitForChild("telemetry"):WaitForChild("NavMetrics"))
local RoamGraph = require(script:WaitForChild("nav"):WaitForChild("RoamGraph"))
local PathfindingQueue = require(script:WaitForChild("nav"):WaitForChild("PathfindingQueue"))

local DataServiceMod = require(script.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

type BotIdentity = {
	name: string,
	image: string,
	personalityId: string,
	level: number,
	historicalKills: number,
	appearance: BotAppearance.BotAppearance,
}

type RoundStartConfig = {
	spawnPoints: { BasePart },
	mapRoot: Instance?,
	onBotDied: ((string, string, Humanoid, number) -> ())?,
	-- Spawn-point selection routed through SpawnService/SpawnSelector (same
	-- scoring + reservation map as players). Injected by MatchService so the
	-- AI module doesn't depend on match modules. Optional: when absent or when
	-- it returns nil, _spawnOneBot falls back to a random point.
	selectSpawnPoint: ((team: "A" | "B") -> BasePart?)?,
	-- B2: notified when the staggered spawn pump finishes reconciling the
	-- roster (typically wired to MatchService's roster broadcast).
	onRosterChanged: (() -> ())?,
}

type BotRecord = {
	model: Model,
	humanoid: Humanoid,
	team: "A" | "B",
	deathConnection: RBXScriptConnection?,
	hasDeathBeenReported: boolean,
	-- Manejo de muerte (ragdoll + Destroy + cleanup). Se dispara desde Humanoid.Died
	-- y, como fallback, desde _refreshAliveLists si Died no llega a correr.
	handleDeath: (() -> ())?,
	ai: typeof(BotAI.new(({} :: any), "A")),
	descendantConn: RBXScriptConnection?,
}

local _dataServiceRef: DataService? = nil

local function _getKillEffectForBotAttacker(humanoid: Humanoid): string
	local lastAttacker = LastAttackerStore.get(humanoid)
	if not lastAttacker then
		return ItemDefaults.ITEM_ID
	end
	if lastAttacker.At > 0 and math.abs(time() - lastAttacker.At) > GameConfig.KillAttributionWindow then
		return ItemDefaults.ITEM_ID
	end
	local attackerUserId = lastAttacker.UserId
	if not attackerUserId then
		return ItemDefaults.ITEM_ID
	end
	local attackerPlayer = Players:GetPlayerByUserId(attackerUserId)
	if not attackerPlayer then
		return ItemDefaults.ITEM_ID
	end
	local profile = nil :: any
	local dataService = _dataServiceRef
	if dataService and dataService.GetProfile then
		profile = dataService:GetProfile(attackerPlayer)
	end
	if profile and profile.Data and profile.Data.Loadout then
		local killEffect = profile.Data.Loadout.KillEffect
		if type(killEffect) == "string" and killEffect ~= "" then
			return killEffect
		end
	end
	return ItemDefaults.ITEM_ID
end

local AIService = {}

local _isRoundActive = false
-- Bumped on every OnRoundEnd. Each bot captures the generation it was spawned
-- in; the death handler compares before touching round-scoped bookkeeping.
-- Without this, the deferred death fallback (_refreshAliveLists) can run AFTER
-- OnRoundEnd cleared the pools and re-insert a stale identity whose fakeUserId
-- collides once _fakeUserIdCounter resets for the next round.
local _roundGeneration = 0
local _mapRoot: Instance? = nil
local _roamGraph: RoamGraph.RoamGraph? = nil
local _spawnPoints: { BasePart } = {}
local _selectSpawnPoint: ((team: "A" | "B") -> BasePart?)? = nil
local _onBotDied: ((string, string, Humanoid, number) -> ())? = nil
-- B2: fired when the staggered spawn pump finishes filling the roster, so
-- MatchService can re-broadcast it (SetBotTargets returns before the pump
-- completes; the broadcast made at that point misses the pending spawns).
local _onRosterChanged: (() -> ())? = nil
local _botsByName: { [string]: BotRecord } = {}
local _activeBotCount = 0
-- D3: earliest os.clock() at which each team may spawn a REPLACEMENT for a
-- dead bot. Armed by the death handler when Lifecycle.RespawnDelay > 0
-- (default 0 = instant, historical behavior); the spawn pump skips a held
-- team without exiting. Round-start fills are never held (no death armed it).
local _spawnHoldUntil = { A = 0, B = 0 }
-- B6: index O(1) por FakeUserId para _findAttackerModel. Antes scan lineal
-- sobre aliveTargets por cada damage event (peor caso 16 events/100ms × 16
-- candidatos = 2560 comparaciones/seg).
local _botModelByFakeUserId: { [number]: Model } = {}
local _botNamesByTeam: { A: { string }, B: { string } } = {
	A = {},
	B = {},
}
local _nextBotId = 1
local _fakeUserIdCounter = 0
local _usedIdentityIndices: { [number]: boolean } = {}
local _botIdentityByName: { [string]: BotIdentity } = {}
local _recycledByTeam: { A: { { identity: BotIdentity, fakeUserId: number } }, B: { { identity: BotIdentity, fakeUserId: number } } } = { A = {}, B = {} }
local _identityByFakeUserId: { [number]: BotIdentity } = {}
local _teamByFakeUserId: { [number]: string } = {}
local _botFakeUserIdByName: { [string]: number } = {}

-- ────────────────────────────────────────────────────────────────
-- ALIVE TARGETS CACHE (compartido entre todos los BotAI)
--
-- Mantiene una lista de Models vivos (chars de jugadores reales + bots)
-- que pueden ser objetivos de los bots. Se actualiza vía signals
-- (PlayerAdded/CharacterAdded/Died/AncestryChanged) — sin polling.
--
-- Antes cada bot iteraba `workspace:GetChildren()` + `mapRoot/Bots:GetChildren()`
-- en cada tick (60Hz Heartbeat × 8 bots = ~5760 raycasts/seg en peor caso).
-- Esta cache global elimina la iteración masiva — el bot solo pasea sobre
-- los ~16 candidatos relevantes.
-- ────────────────────────────────────────────────────────────────

-- B4: tupla en lugar de Model. Antes _getBestTarget hacía
-- FindFirstChildOfClass + FindFirstChild por cada candidato cada tick
-- (16 bots × 24 chars × 2 × 10Hz ≈ 7680 lookups/seg en PATROL).
-- Resuelto al add-time + lazy refresh si el ref muere (respawn streaming).
export type AliveTarget = {
	model: Model,
	hum: Humanoid?,
	root: BasePart?,
}

local _aliveTargets: { AliveTarget } = {}
local _aliveTargetIndex: { [Model]: number } = {}

local function _addAliveTarget(model: Model)
	if _aliveTargetIndex[model] then return end
	local entry: AliveTarget = {
		model = model,
		hum = model:FindFirstChildOfClass("Humanoid"),
		root = model:FindFirstChild("HumanoidRootPart") :: BasePart?,
	}
	table.insert(_aliveTargets, entry)
	_aliveTargetIndex[model] = #_aliveTargets
end

local function _removeAliveTarget(model: Model)
	local idx = _aliveTargetIndex[model]
	if not idx then return end
	_aliveTargetIndex[model] = nil
	-- Swap-remove O(1): mover el último al hueco si no es el mismo.
	local last = #_aliveTargets
	if idx ~= last then
		local moved = _aliveTargets[last]
		_aliveTargets[idx] = moved
		_aliveTargetIndex[moved.model] = idx
	end
	_aliveTargets[last] = nil
end

-- Dedupe: protege contra la race del module-load donde un jugador que
-- aparece entre Players.PlayerAdded:Connect y el for-loop inicial era
-- wired DOS veces (CharacterAdded:Connect duplicado → 2× AncestryChanged
-- y Died listeners por char en cada respawn).
local _wiredPlayers: { [Player]: true } = {}

local function _wirePlayerAliveTracking(player: Player)
	if _wiredPlayers[player] then
		return
	end
	_wiredPlayers[player] = true

	local function onChar(char: Model)
		-- Audit mobile: remove defensivo del char anterior. _addAliveTarget
		-- ya dedupea por index, pero el char del respawn previo puede no
		-- haber salido todavía (AncestryChanged tarda un frame) → la nueva
		-- entry quedaría apuntando al char correcto pero la vieja seguiría
		-- referenciada por _aliveTargetIndex con el mismo Model si Roblox
		-- recicla la ref (raro pero posible al reusar rigs del LoadCharacter).
		_removeAliveTarget(char)
		_addAliveTarget(char)
		-- El char puede ser destruido sin Died (respawn instantáneo, kick, etc.).
		-- AncestryChanged lo cubre todos los casos sin duplicar lógica.
		char.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				_removeAliveTarget(char)
			end
		end)
		local hum = char:WaitForChild("Humanoid", 5)
		if hum and hum:IsA("Humanoid") then
			(hum :: Humanoid).Died:Connect(function()
				_removeAliveTarget(char)
			end)
		end
	end

	if player.Character then
		onChar(player.Character)
	end
	player.CharacterAdded:Connect(onChar)
end

Players.PlayerAdded:Connect(_wirePlayerAliveTracking)
for _, p in Players:GetPlayers() do
	_wirePlayerAliveTracking(p)
end

Players.PlayerRemoving:Connect(function(player)
	_wiredPlayers[player] = nil
	if player.Character then
		_removeAliveTarget(player.Character)
	end
end)

-- Graceful shutdown: cuando el servidor cierra, paramos los loops de todos los
-- bots para que no se queden ejecutando contra un DataModel a punto de morir.
-- Esto evita warnings/errores ruidosos durante el shutdown y permite que las
-- coroutines salgan limpiamente.
game:BindToClose(function()
	for _, record in pairs(_botsByName) do
		if record and record.ai then
			pcall(function()
				record.ai:Stop()
			end)
		end
	end
end)

local function _assignIdentity(): (BotIdentity, number)
	_fakeUserIdCounter -= 1
	local fakeUserId = _fakeUserIdCounter
	-- Pick an unused identity from the pool
	local available = {}
	for i, _ in BotNames do
		if not _usedIdentityIndices[i] then
			table.insert(available, i)
		end
	end
	local name: string
	local image: string
	if #available > 0 then
		local idx = available[math.random(1, #available)]
		_usedIdentityIndices[idx] = true
		local source = BotNames[idx]
		name = source.name
		image = source.image
	else
		-- Fallback: pool agotado (>20 bots/team). Prefijo "Bot_" en lugar de
		-- "Player" para evitar colisiones con usernames reales de Roblox que
		-- empiezan por "Player".
		name = "Bot_" .. tostring(math.abs(fakeUserId))
		image = "rbxassetid://0"
	end

	-- Personality drives apariencia + stats fingidas. Se rolea una vez por
	-- identidad: igual que appearance, sobrevive al recycle pool y se
	-- re-randomiza solo en OnRoundEnd cuando se limpian las identidades.
	local personalityId, personality = BotPersonality.rollPersonality()
	local level, historicalKills = BotPersonality.rollStats(personality)

	-- Construir identity fresca con apariencia cacheada. La apariencia
	-- vive en la identity para que el recycle pool tras la muerte del bot
	-- (init.luau:613) mantenga la misma hat/face/wrap durante todo el match.
	-- En OnRoundEnd se limpian _usedIdentityIndices y _recycledByTeam, así
	-- que la siguiente ronda re-rolea automáticamente.
	local identity: BotIdentity = {
		name = name,
		image = image,
		personalityId = personalityId,
		level = level,
		historicalKills = historicalKills,
		appearance = BotAppearance.roll(personality),
	}
	return identity, fakeUserId
end

local function _refreshAliveLists()
	local listA = _botNamesByTeam.A
	local listB = _botNamesByTeam.B
	table.clear(listA)
	table.clear(listB)

	local count = 0
	local deadUnreported: { BotRecord }? = nil
	for name, bot in _botsByName do
		if bot.model.Parent == nil then
			-- Modelo ya destruido: solo limpiar bookkeeping.
			if bot.deathConnection then
				bot.deathConnection:Disconnect()
				bot.deathConnection = nil
			end
			_botsByName[name] = nil
		elseif bot.humanoid.Health <= 0 then
			-- Muerto pero el modelo sigue presente. NO desconectamos su deathConnection
			-- (hacerlo orfanaba el cuerpo: sin ragdoll ni Destroy, congelado para
			-- siempre). Si su Died handler aún no corrió, lo disparamos como fallback
			-- (diferido, fuera del bucle, para no re-entrar esta iteración). No se
			-- cuenta como vivo.
			if not bot.hasDeathBeenReported then
				deadUnreported = deadUnreported or {}
				table.insert(deadUnreported, bot)
			end
		else
			count += 1
			if bot.team == "A" then
				table.insert(listA, name)
			else
				table.insert(listB, name)
			end
		end
	end
	_activeBotCount = count

	-- Fallback de limpieza: bots con Health<=0 cuyo Humanoid.Died no llegó a correr.
	-- El guard hasDeathBeenReported evita doble ejecución si Died sí dispara luego.
	if deadUnreported then
		for _, bot in deadUnreported do
			task.defer(function()
				if not bot.hasDeathBeenReported and bot.handleDeath then
					bot.handleDeath()
				end
			end)
		end
	end
end

-- Fallback when the injected selector is absent or returns nil (no map,
-- empty spawn list mid-teardown).
local function _getRandomSpawnPoint(): BasePart?
	if #_spawnPoints == 0 then
		return nil
	end

	return _spawnPoints[math.random(1, #_spawnPoints)]
end

local function _getSpawnPoint(team: "A" | "B"): BasePart?
	local selector = _selectSpawnPoint
	if selector then
		local point = selector(team)
		if point then
			return point
		end
	end

	return _getRandomSpawnPoint()
end

local function _buildFallbackBotModel(botName: string): Model
	local model = Instance.new("Model")
	model.Name = botName

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.CanCollide = false
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.CanCollide = true
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.CanCollide = true
	head.Parent = model

	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0 = root
	rootJoint.Part1 = torso
	rootJoint.Parent = root

	local neck = Instance.new("Motor6D")
	neck.Name = "Neck"
	neck.Part0 = torso
	neck.Part1 = head
	neck.C0 = CFrame.new(0, 1, 0)
	neck.C1 = CFrame.new(0, -0.5, 0)
	neck.Parent = torso

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = model

	model.PrimaryPart = root
	return model
end

local _hasWarnedMissingTemplate = false

-- B5: pool async de Models pre-clonados. Desacopla el coste de Model:Clone
-- (con sus 30+ parts/accessories) del path crítico de _spawnOneBot. El refill
-- corre en task.spawn — la siguiente vez que un bot muere y se necesita uno
-- nuevo, el pool ya tiene un rig caliente listo.
--
-- No se reutilizan rigs entre vidas (no es un pool de "ressurect"): la
-- Humanoid en estado Dead no se puede revivir limpiamente sin reemplazar el
-- Humanoid entero. Esta variante mata complejidad pero no la ganancia de
-- decouplear cloning del spawn moment.
--
-- Pool por outfit: con apariencia variable, cada outfit es un Model distinto
-- en ServerStorage.Bodies. Un único pool compartido implicaría todos los bots
-- con el mismo body. La key del pool es el outfitId.
local _botRigPoolByKey: { [string]: { Model } } = {}
local _botRigRefillingByKey: { [string]: boolean } = {}
local BOT_RIG_POOL_TARGET = 3
-- C1: cap on TOTAL parked rigs across all outfit pools, so memory no longer
-- grows linearly with the outfit catalog (~30 parts per rig). 2× the max
-- concurrent bot count keeps a full respawn wave warm; past the cap, refills
-- stop and a cold take pays one sync clone (rare).
local MAX_TOTAL_PARKED_RIGS = GameConfig.TeamSizeTarget * 4
-- C1: pools shrink to this size between rounds. Identities re-roll every
-- round, so keeping every pool hot has no cross-round hit-rate benefit; one
-- rig per outfit keeps the first take warm and the Voting-phase prewarm
-- rebuilds the rest before the next round-start burst.
local BOT_RIG_POOL_IDLE_TARGET = 1
local _botRigParkFolder: Folder? = nil

local function _ensureParkFolder(): Folder
	if _botRigParkFolder and _botRigParkFolder.Parent then
		return _botRigParkFolder
	end
	-- ServerStorage no replica al cliente — los rigs parked no se ven.
	local existing = ServerStorage:FindFirstChild("_BotRigPool")
	if existing and existing:IsA("Folder") then
		_botRigParkFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "_BotRigPool"
	folder.Parent = ServerStorage
	_botRigParkFolder = folder
	return folder
end

local function _clonePreparedRig(poolKey: string): Model?
	local template = BotAppearance.findBodyTemplate(poolKey)
	if not template then return nil end
	local clone = template:Clone()
	-- Parented a ServerStorage para que Roblox no intente streaming/replicación
	-- ni dispare ChildAdded en el workspace mientras está en el pool.
	clone.Parent = _ensureParkFolder()
	return clone
end

local function _countParkedRigs(): number
	local total = 0
	for _, pool in _botRigPoolByKey do
		total += #pool
	end
	return total
end

-- C1: shrink every pool down to `perPoolTarget`, destroying the extras.
local function _trimRigPools(perPoolTarget: number)
	for _, pool in _botRigPoolByKey do
		while #pool > perPoolTarget do
			local rig = table.remove(pool, #pool)
			if rig then
				rig:Destroy()
			end
		end
	end
end

local function _refillBotRigPoolAsync(poolKey: string)
	if _botRigRefillingByKey[poolKey] then return end
	_botRigRefillingByKey[poolKey] = true
	task.spawn(function()
		local pool = _botRigPoolByKey[poolKey]
		if not pool then
			pool = {}
			_botRigPoolByKey[poolKey] = pool
		end
		while #pool < BOT_RIG_POOL_TARGET and _countParkedRigs() < MAX_TOTAL_PARKED_RIGS do
			local rig = _clonePreparedRig(poolKey)
			if not rig then break end -- template missing → abandona refill
			table.insert(pool, rig)
			-- Yield between clones: without this the task.spawn body never
			-- yields, so every clone still landed in a single frame — the
			-- spike was moved, not amortized.
			task.wait()
		end
		_botRigRefillingByKey[poolKey] = false
	end)
end

local function _takeBotRigFromPool(poolKey: string): Model?
	local pool = _botRigPoolByKey[poolKey]
	if pool and #pool > 0 then
		local rig = pool[#pool]
		pool[#pool] = nil
		_refillBotRigPoolAsync(poolKey)
		return rig
	end
	-- Pool vacío (e.g., burst inicial de spawns, primer take para este outfit)
	-- → fallback sync.
	_refillBotRigPoolAsync(poolKey)
	return _clonePreparedRig(poolKey)
end

-- Resuelve qué pool usar para un outfitId dado. Prefiere el outfit pedido si
-- su body existe; cae a "Default" si está. Devuelve nil si no hay ningún
-- body disponible → _createBotModel cae al rig barebones.
local function _resolvePoolKeyForOutfit(outfitId: string?): string?
	if outfitId and BotAppearance.findBodyTemplate(outfitId) then
		return outfitId
	end
	if BotAppearance.findBodyTemplate("Default") then
		return "Default"
	end
	return nil
end

local function _createBotModel(botName: string, outfitId: string?): Model
	local poolKey = _resolvePoolKeyForOutfit(outfitId)
	if poolKey then
		local clone = _takeBotRigFromPool(poolKey)
		if clone then
			clone.Name = botName
			return clone
		end
	end

	-- Audit P2: warn una sola vez por proceso. Antes el fallback silencioso
	-- producía bots T-pose sin tool en producción y nadie se enteraba salvo
	-- viendo en vivo. Si el template falta, todos los bots del round caen
	-- al fallback — no necesitamos N warns iguales, solo uno con contexto.
	if not _hasWarnedMissingTemplate then
		_hasWarnedMissingTemplate = true
		warn("[AIService] BotTemplate no encontrado (esperado en ServerStorage.Bodies.<outfitId> o ServerStorage.Bodies.Default). Usando modelo barebones — los bots aparecerán en T-pose y sin arma hasta que se restaure el template.")
	end
	return _buildFallbackBotModel(botName)
end

-- Warm-up: pre-rellena los pools de rigs para que la primera oleada de spawns
-- no pague el coste de Clone en el path crítico. Si no hay bodies,
-- _createBotModel cae al rig barebones.
--
-- B2: serialized — one pool refills at a time (each refill already yields
-- between clones), so warming N outfits costs ~1 clone per frame instead of
-- N. Runs at module load and again when MatchService opens the Voting phase,
-- rebuilding what the round-end trim (C1) released before the next
-- round-start burst.
local _prewarmRunning = false
local function _prewarmRigPools()
	if _prewarmRunning then
		return
	end
	_prewarmRunning = true
	task.spawn(function()
		for _, outfitId in BotAppearance.getAvailableOutfitIds() do
			_refillBotRigPoolAsync(outfitId)
			while _botRigRefillingByKey[outfitId] do
				task.wait()
			end
		end
		_prewarmRunning = false
	end)
end

_prewarmRigPools()

local function _notifyActiveBotCount()
	NavMetrics.SetActiveBotCount(_activeBotCount)
end

local function _removeBotByName(botName: string, skipRefresh: boolean?)
	local bot = _botsByName[botName]
	if not bot then
		return
	end

	bot.ai:Stop()
	_removeAliveTarget(bot.model)

	if bot.deathConnection then
		bot.deathConnection:Disconnect()
		bot.deathConnection = nil
	end

	-- Clean identity tracking so GetBotRoster no longer includes this bot
	local fakeUserId = _botFakeUserIdByName[botName]
	if fakeUserId then
		_identityByFakeUserId[fakeUserId] = nil
		_teamByFakeUserId[fakeUserId] = nil
		_botModelByFakeUserId[fakeUserId] = nil
	end
	_botIdentityByName[botName] = nil
	_botFakeUserIdByName[botName] = nil

	if bot.model.Parent ~= nil then
		bot.model:Destroy()
	end

	_botsByName[botName] = nil
	_activeBotCount = math.max(0, _activeBotCount - 1)
	if not skipRefresh then
		_refreshAliveLists()
		_notifyActiveBotCount()
	end
end

local function _markBotTeam(model: Model, team: "A" | "B")
	model:SetAttribute("Team", team)
	model:SetAttribute("TeamSide", team)
	model:SetAttribute("BotTeam", team)

	local leaderstats = model:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = model
	end

	local teamValue = leaderstats:FindFirstChild("Team")
	if not teamValue or not teamValue:IsA("StringValue") then
		if teamValue then
			teamValue:Destroy()
		end
		teamValue = Instance.new("StringValue")
		teamValue.Name = "Team"
		teamValue.Parent = leaderstats
	end

	(teamValue :: StringValue).Value = team
end

local function _spawnOneBot(team: "A" | "B"): boolean
	if not _isRoundActive then
		return false
	end

	local mapRoot = _mapRoot
	if not mapRoot then
		return false
	end

	local spawnPoint = _getSpawnPoint(team)
	if not spawnPoint then
		return false
	end

	local botName = string.format("Bot_%s_%d", team, _nextBotId)
	_nextBotId += 1
	-- Captured by handleBotDeath: round-scoped bookkeeping (identity recycle,
	-- counters, _onBotDied) only runs if this round is still the active one.
	local spawnGeneration = _roundGeneration

	local identity: BotIdentity
	local fakeUserId: number
	local recycled = _recycledByTeam[team]
	if #recycled > 0 then
		local entry = table.remove(recycled, #recycled)
		identity = entry.identity
		fakeUserId = entry.fakeUserId
	else
		identity, fakeUserId = _assignIdentity()
	end
	_botIdentityByName[botName] = identity
	_botFakeUserIdByName[botName] = fakeUserId
	_identityByFakeUserId[fakeUserId] = identity
	_teamByFakeUserId[fakeUserId] = team

	local outfitId = if identity.appearance then identity.appearance.outfitId else nil
	local botModel = _createBotModel(botName, outfitId)
	local humanoid = botModel:FindFirstChildOfClass("Humanoid")
	local root = botModel:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		botModel:Destroy()
		warn(string.format("[AIService] Bot template inválido para %s (falta Humanoid/HumanoidRootPart)", botName))
		return false
	end

	_markBotTeam(botModel, team)

	-- Stamp identity on model
	botModel:SetAttribute("DisplayName", identity.name)
	botModel:SetAttribute("FakeUserId", fakeUserId)
	botModel:SetAttribute("ProfileImage", identity.image)
	_botModelByFakeUserId[fakeUserId] = botModel
	humanoid.DisplayName = identity.name

	-- Apariencia (hat + face). El wrap se aplica dentro de BotAI:_setupTool
	-- tras clonar el tool, vía el wrapId que pasamos al constructor.
	BotAppearance.apply(botModel, identity.appearance)

	local wrapId = if identity.appearance then identity.appearance.wrapId else nil
	-- D1: combat skill from the identity's personality tier; nil combat block
	-- (or unknown id) falls back to the global BotConfig.Combat profile.
	local personality = BotPersonality.getById(identity.personalityId)
	local botAIInstance = BotAI.new(botModel, team, fakeUserId, wrapId, if personality then personality.combat else nil)

	local botsFolder = mapRoot:FindFirstChild("Bots")
	if not botsFolder then
		botsFolder = Instance.new("Folder")
		botsFolder.Name = "Bots"
		botsFolder.Parent = mapRoot
	end

	-- Position BEFORE parenting: avoids one frame of physics/replication at
	-- the template's stored position. Setting the root CFrame moves the whole
	-- joined assembly, same as the old post-parent teleport.
	root.CFrame = spawnPoint.CFrame + Vector3.new(0, 4, 0)
	botModel.Parent = botsFolder
	humanoid.Health = humanoid.MaxHealth
	humanoid.BreakJointsOnDeath = false

	-- NPC humanoids never climb, swim, sit, or trip — disable the unused
	-- state-machine branches (per-humanoid simulation cost + avoids accidental
	-- transitions like FallingDown from collisions). Dead/Running/Jumping/
	-- Freefall/Landed stay enabled: movement, animations and the Died signal
	-- depend on them. Kill effects force ChangeState(Dead) themselves and do
	-- not use the Ragdoll/FallingDown states.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	-- Mismo tratamiento que los jugadores: CHARACTERS group para que players
	-- vivos no choquen con cadáveres. Al morir, el kill effect migra al grupo
	-- RAGDOLL. Watcher cubre tools/accesorios que se parenten después.
	CollisionGroups.setGroupForCharacter(botModel, CollisionGroups.CHARACTERS)
	-- Audit mobile: guardar la conexión para desconectarla en el Died handler
	-- antes del kill effect. El ragdoll/VFX parentea ~10 nuevos BaseParts y
	-- el listener se dispararía para cada uno (se ejecuta el switch
	-- CollisionGroup innecesario sobre un modelo en cleanup).
	local descendantConn = botModel.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = CollisionGroups.groupForNewPart(botModel)
		end
	end)

	-- Misma inmunidad al spawn que los jugadores (ver MatchService). ForceField
	-- nativo, no se rompe al disparar, expira por tiempo vía Debris.
	-- Audit mobile: Visible=false. El FF de los players sí se muestra
	-- (UX del propio jugador), pero las esferas azules de 16 bots
	-- recién spawneados clutterean móviles low-end sin valor de UX. El
	-- jugador que dispare a un bot recién spawneado ve "0 daño visible"
	-- durante 2s; el bot se mueve rápido y la situación se resuelve sola.
	-- Attribute SpawnProtectedUntil para que BotAI._getBestTarget skipee
	-- bots inmunes sin hacer FindFirstChildOfClass por candidato.
	if GameConfig.SpawnProtectionDuration > 0 then
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = botModel
		Debris:AddItem(forceField, GameConfig.SpawnProtectionDuration)
		botModel:SetAttribute("SpawnProtectedUntil", time() + GameConfig.SpawnProtectionDuration)
	end

	-- Registrar el bot en la cache global de targets para que otros bots
	-- puedan elegirlo sin iterar workspace.
	_addAliveTarget(botModel)

	local record: BotRecord = {
		model = botModel,
		humanoid = humanoid,
		team = team,
		deathConnection = nil,
		hasDeathBeenReported = false,
		handleDeath = nil,
		ai = botAIInstance,
		descendantConn = descendantConn,
	}

	botAIInstance:Start(mapRoot, _aliveTargets, _roamGraph, _botModelByFakeUserId)

	-- Manejo de muerte extraído a función para poder dispararlo también como FALLBACK
	-- desde _refreshAliveLists si el Humanoid.Died del servidor no llega a correr
	-- (p.ej. cuando otro bot muriendo a la vez desconectaba este handler antes de
	-- tiempo). El guard hasDeathBeenReported garantiza que corre UNA sola vez, venga
	-- del evento Died o del fallback.
	local function handleBotDeath()
		if record.hasDeathBeenReported then
			return
		end
		record.hasDeathBeenReported = true

		-- 0. Limpieza visual FIRST — orden crítico: estas operaciones tienen que
		-- correr aunque la lógica de juego de abajo falle. Si están más abajo y
		-- algo entre medias throws, el bot queda "corriendo tumbado" para
		-- siempre. Cada una en pcall por separado para que un fallo no cancele
		-- las demás.

		-- 0a-pre. Cortar el listener de CollisionGroup antes del kill effect:
		-- éste parentea N parts nuevos al ragdoll y dispararía el handler
		-- innecesariamente sobre un modelo en cleanup.
		if record.descendantConn then
			record.descendantConn:Disconnect()
			record.descendantConn = nil
		end

		-- 0a. Destrucción programada SIEMPRE. Aunque todo lo demás falle, el
		-- bot eventualmente desaparece.
		task.delay(BotConfig.Lifecycle.RagdollCleanupDelay, function()
			if botModel.Parent ~= nil then
				botModel:Destroy()
			end
		end)

		-- 0b. Parar IA + animaciones. Antes sin pcall: si throwea, las
		-- animaciones de correr siguen jugando aunque haya ragdoll.
		pcall(function()
			record.ai:Stop()
		end)

		-- 0c. Kill effect (ragdoll). Ya estaba en pcall.
		local effectId = _getKillEffectForBotAttacker(humanoid)
		pcall(KillEffectsRegistry.apply, effectId, botModel)

		-- 0d. Quitar del cache de targets vivos.
		pcall(_removeAliveTarget, botModel)

		if record.deathConnection then
			record.deathConnection:Disconnect()
			record.deathConnection = nil
		end

		-- Round-generation guard: if this handler runs late (deferred death
		-- fallback after OnRoundEnd, or after the next round already started),
		-- skip ALL round-scoped bookkeeping. Recycling into the cleared pools
		-- would leak a stale identity whose fakeUserId collides after the
		-- counter resets; decrementing _activeBotCount would corrupt the new
		-- round's count; _onBotDied would credit a kill in the wrong round.
		-- Visual cleanup above already ran regardless.
		if _roundGeneration ~= spawnGeneration then
			return
		end

		-- 1. Lógica de juego: recycle identity, refresh lists, notify. Cualquier
		-- error aquí ya no afecta la limpieza visual de arriba. En pcall
		-- envolvente para no romper el bucle de spawn de otros bots.
		pcall(function()
			-- D3: hold this team's next replacement spawn for the configured
			-- delay (0 = no-op). Players pay RespawnCooldown; this is the knob
			-- for pacing parity.
			if BotConfig.Lifecycle.RespawnDelay > 0 then
				_spawnHoldUntil[team] = os.clock() + BotConfig.Lifecycle.RespawnDelay
			end
			table.insert(_recycledByTeam[team], { identity = identity, fakeUserId = fakeUserId })
			-- B6: clear el index — el nuevo bot se asignará en _spawnOneBot.
			_botModelByFakeUserId[fakeUserId] = nil
			_botsByName[botName] = nil
			_activeBotCount = math.max(0, _activeBotCount - 1)
			_botIdentityByName[botName] = nil
			_botFakeUserIdByName[botName] = nil
			_refreshAliveLists()
			_notifyActiveBotCount()
			NavMetrics.RecordBotDied()
		end)

		-- 2. Callback externo de juego (persistencia, streak, remotes). Ya
		-- estaba en pcall.
		if _onBotDied then
			local ok, err = pcall(_onBotDied, team, botName, humanoid, fakeUserId)
			if not ok then
				warn(string.format("[AIService] _onBotDied error en %s: %s", botName, tostring(err)))
			end
		end
	end

	record.handleDeath = handleBotDeath
	record.deathConnection = humanoid.Died:Connect(handleBotDeath)

	_botsByName[botName] = record
	_activeBotCount += 1
	table.insert(_botNamesByTeam[team], botName)
	_notifyActiveBotCount()
	NavMetrics.RecordBotSpawned()
	return true
end

-- B2: spawns are staggered across Heartbeats instead of bursting in one
-- frame. SetBotTargets records the desired team sizes and wakes a single
-- pump coroutine that spawns at most MAX_SPAWNS_PER_STEP bots per step. The
-- pump re-reads desired targets and live counts on every iteration, so
-- rebalances landing mid-pump reconcile naturally — no double-spawns, no
-- spawns against a stale target. Removals stay synchronous: they're cheap,
-- and an over-target bot must not stay alive shooting people.
local _desiredBotTargets: { A: number, B: number } = { A = 0, B = 0 }
local _spawnPumpRunning = false
local MAX_SPAWNS_PER_STEP = 2

local function _notifyRosterChanged()
	local cb = _onRosterChanged
	if cb then
		pcall(cb)
	end
end

-- Synchronous half of the reconciliation: removals + recycled-identity trim.
local function _trimTeamToTarget(team: "A" | "B", target: number)
	local list = _botNamesByTeam[team]
	while #list > target do
		local botName = list[#list]
		if not botName then
			break
		end
		_removeBotByName(botName)
	end

	-- Trim excess recycled identities so roster matches the new target
	local recycledPool = _recycledByTeam[team]
	local maxRecycled = math.max(0, target - #list)
	while #recycledPool > maxRecycled do
		local removed = table.remove(recycledPool, #recycledPool)
		if removed then
			_identityByFakeUserId[removed.fakeUserId] = nil
			_teamByFakeUserId[removed.fakeUserId] = nil
		end
	end
end

local function _spawnDeficit(team: "A" | "B"): number
	return _desiredBotTargets[team] - #_botNamesByTeam[team]
end

local function _ensureSpawnPump()
	if _spawnPumpRunning then
		return
	end
	_spawnPumpRunning = true
	-- task.spawn resumes the body synchronously up to the first task.wait,
	-- so the common churn case (1 bot died → 1 respawn) still completes
	-- inside the SetBotTargets call, and a round-start burst gets its first
	-- MAX_SPAWNS_PER_STEP bots with no added latency.
	task.spawn(function()
		local spawnedAny = false
		while _isRoundActive do
			local budget = MAX_SPAWNS_PER_STEP
			while budget > 0 do
				-- D3: a held team (recent bot death + RespawnDelay) reports no
				-- spawnable deficit this step, but the OUTER exit check below
				-- uses the raw deficit, so the pump stays alive until the hold
				-- expires and then spawns.
				local now = os.clock()
				local deficitA = if now >= _spawnHoldUntil.A then _spawnDeficit("A") else 0
				local deficitB = if now >= _spawnHoldUntil.B then _spawnDeficit("B") else 0
				if deficitA <= 0 and deficitB <= 0 then
					break
				end
				-- Larger deficit first so neither team starves during bursts.
				local team: "A" | "B" = if deficitA >= deficitB then "A" else "B"
				if not _spawnOneBot(team) then
					-- Spawn failure (round ended / no map / no spawn point /
					-- bad template): give up like the old synchronous loop
					-- did. The next rebalance re-arms the pump.
					_spawnPumpRunning = false
					if spawnedAny then
						_notifyRosterChanged()
					end
					return
				end
				spawnedAny = true
				budget -= 1
			end
			if _spawnDeficit("A") <= 0 and _spawnDeficit("B") <= 0 then
				break
			end
			task.wait()
		end
		_spawnPumpRunning = false
		-- Clients got a roster broadcast when SetBotTargets returned (before
		-- the pump finished); re-broadcast now that the roster is complete.
		if spawnedAny then
			_notifyRosterChanged()
		end
	end)
end

function AIService:SetDataService(dataService: DataService)
	_dataServiceRef = dataService
end

function AIService:OnRoundStart(config: RoundStartConfig)
	self:OnRoundEnd()
	_isRoundActive = true
	_mapRoot = config.mapRoot
	_spawnPoints = table.clone(config.spawnPoints or {})
	_selectSpawnPoint = config.selectSpawnPoint
	_onBotDied = config.onBotDied
	_onRosterChanged = config.onRosterChanged
	_nextBotId = 1
	_fakeUserIdCounter = 0
	table.clear(_usedIdentityIndices)
	table.clear(_botIdentityByName)
	table.clear(_botFakeUserIdByName)
	table.clear(_recycledByTeam.A)
	table.clear(_recycledByTeam.B)
	table.clear(_identityByFakeUserId)
	table.clear(_teamByFakeUserId)
	NavMetrics.ResetCounts()
	NavMetrics.SetActiveBotCount(0)
	-- RoamGraph cacheado por mapRoot. Si el mapa es el mismo del round
	-- anterior, reusa el pool ya construido (cero coste). Si es distinto,
	-- construye uno nuevo en el primer pickRandomNavigablePoint.
	if _mapRoot then
		_roamGraph = RoamGraph.forMap(_mapRoot)
	else
		_roamGraph = nil
	end
end

function AIService:SetBotTargets(targetA: number, targetB: number)
	if not _isRoundActive then
		return
	end

	_refreshAliveLists()
	_desiredBotTargets.A = math.max(0, targetA)
	_desiredBotTargets.B = math.max(0, targetB)
	_trimTeamToTarget("A", _desiredBotTargets.A)
	_trimTeamToTarget("B", _desiredBotTargets.B)
	_ensureSpawnPump()
end

-- B2: MatchService calls this when the Voting phase opens — rebuilds the rig
-- pools the round-end trim released (amortized, ~1 clone per frame) so the
-- round-start burst takes warm rigs instead of paying synchronous clones.
function AIService:PrewarmRigPools()
	_prewarmRigPools()
end

function AIService:OnRoundEnd()
	-- OnRoundStart also calls OnRoundEnd as defensive cleanup; the rig-pool
	-- trim below must only run on a REAL round end (wasActive), or it would
	-- destroy the rigs the Voting-phase prewarm just built.
	local wasActive = _isRoundActive
	_isRoundActive = false
	_roundGeneration += 1
	_desiredBotTargets.A = 0
	_desiredBotTargets.B = 0
	_spawnHoldUntil.A = 0
	_spawnHoldUntil.B = 0

	local namesToRemove = {} :: { string }
	for botName in _botsByName do
		table.insert(namesToRemove, botName)
	end

	for _, botName in namesToRemove do
		_removeBotByName(botName, true)
	end

	table.clear(_botsByName)
	table.clear(_botNamesByTeam.A)
	table.clear(_botNamesByTeam.B)
	_spawnPoints = {}
	_selectSpawnPoint = nil
	_mapRoot = nil
	-- No destruir _roamGraph aquí: si la siguiente ronda usa el mismo mapRoot,
	-- queremos reusar la caché. AncestryChanged limpia automáticamente cuando
	-- el modelo del mapa se destruya.
	_roamGraph = nil
	_onBotDied = nil
	_onRosterChanged = nil
	-- C1: release parked rigs down to the idle target between rounds; the
	-- next Voting phase prewarm rebuilds them off the critical path.
	if wasActive then
		_trimRigPools(BOT_RIG_POOL_IDLE_TARGET)
	end
	-- Purgar la cola global. Las callbacks ya guardan _stopped, así que no
	-- es funcional — solo libera closures con refs a Path/Navigator viejos.
	PathfindingQueue.clear()
	table.clear(_usedIdentityIndices)
	table.clear(_botIdentityByName)
	table.clear(_botFakeUserIdByName)
	table.clear(_recycledByTeam.A)
	table.clear(_recycledByTeam.B)
	table.clear(_identityByFakeUserId)
	table.clear(_teamByFakeUserId)
end

function AIService:GetBotRoster(): { { fakeUserId: number, displayName: string, team: string, image: string, level: number, historicalKills: number, outfitId: string, faceId: string, hatId: string } }
	local roster = {}
	for fakeUserId, identity in _identityByFakeUserId do
		local team = _teamByFakeUserId[fakeUserId]
		if team then
			-- Apariencia (outfit/face/hat) para reconstruir la réplica del bot en la
			-- pantalla de Resultados con el mismo look que tuvo en partida.
			local appearance = identity.appearance
			table.insert(roster, {
				fakeUserId = fakeUserId,
				displayName = identity.name,
				team = team,
				image = identity.image,
				level = identity.level,
				historicalKills = identity.historicalKills,
				outfitId = if appearance and appearance.outfitId then appearance.outfitId else "",
				faceId = if appearance and appearance.faceId then appearance.faceId else "",
				hatId = if appearance and appearance.hatId then appearance.hatId else "",
			})
		end
	end
	return roster
end

function AIService:GetBotDisplayName(fakeUserId: number): string?
	local identity = _identityByFakeUserId[fakeUserId]
	return if identity then identity.name else nil
end

--- Devuelve la identity completa (con level + historicalKills + personalityId
--- + appearance) por fakeUserId. Usado por MatchService para sustituir stats
--- de killer cuando el atacante es un bot. Devuelve nil si no se conoce.
function AIService:GetBotIdentity(fakeUserId: number): BotIdentity?
	return _identityByFakeUserId[fakeUserId]
end

return AIService
