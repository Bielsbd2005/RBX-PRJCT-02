--!strict

--[[
@desc IA de un bot individual (servidor): patrulla, persecución, selección de objetivo
@desc y disparo, sobre Navigator/StuckDetector/RoamGraph y el WeaponsSystem.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)
local BotConfig = require(Shared.constants.BotConfig)
local WeaponsConfig = require(Shared.constants.WeaponsConfig)
local BotPersonalities = require(Shared.constants.BotPersonalities)
local AssetIds = require(Shared.constants.AssetIds)
local CollisionGroups = require(Shared:WaitForChild("CollisionGroups"))
local LastAttackerStore = require(ReplicatedStorage:WaitForChild("WeaponsSystem"):WaitForChild("Libraries"):WaitForChild("LastAttackerStore"))

local Navigator = require(script.Parent:WaitForChild("nav"):WaitForChild("Navigator"))
local StuckDetector = require(script.Parent:WaitForChild("nav"):WaitForChild("StuckDetector"))
local RoamGraph = require(script.Parent:WaitForChild("nav"):WaitForChild("RoamGraph"))
local BotAppearance = require(script.Parent:WaitForChild("BotAppearance"))

type AliveTarget = {
	model: Model,
	hum: Humanoid?,
	root: BasePart?,
}
local RaycastViz = require(script.Parent:WaitForChild("debug"):WaitForChild("RaycastViz"))
local DetectRangeViz = require(script.Parent:WaitForChild("debug"):WaitForChild("DetectRangeViz"))

local WEAPON_TAG = "WeaponsSystemWeapon"

-- Diagnóstico sin prints: en Studio cada bot publica su fase de navegación en el
-- attribute NavPhase (Explorer → Properties → Attributes), útil para ver qué hace un bot
-- parado sin llenar el Output. Fuera de Studio no se escribe nada.
local IS_STUDIO = RunService:IsStudio()
local NAV_PHASE_ATTR = "NavPhase"

-- Tope del gate de aterrizaje al spawnear. Si el bot cae al vacío o queda
-- suspendido, el FSM arranca igual pasado este tiempo en vez de colgarse.
local SPAWN_GROUND_TIMEOUT = 1.5

local _weaponDataRemote: RemoteEvent? = nil
local _weaponFiredRemote: RemoteEvent? = nil

--[[
@desc Resolves and caches the WeaponData RemoteEvent lazily: it may not exist yet at
@desc module load, and hit-direction indicators would be lost for the whole server.
]]
local function _getWeaponDataRemote(): RemoteEvent?
	if _weaponDataRemote and _weaponDataRemote.Parent then
		return _weaponDataRemote
	end
	local wsFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
	local remote = wsFolder and wsFolder:FindFirstChild("WeaponData")
	if remote and remote:IsA("RemoteEvent") then
		_weaponDataRemote = remote
		return remote
	end
	return nil
end

-- Broadcast de disparos con LOD por distancia observador↔tirador (ver
-- BotConfig.Combat.ShotBroadcast*). Cuadrados precalculados: el loop de
-- broadcast corre por jugador por disparo.
local SHOT_RANGE2 = BotConfig.Combat.ShotBroadcastRange ^ 2
local SHOT_LOD2 = BotConfig.Combat.ShotBroadcastLodDistance ^ 2
local SHOT_LOD_DIVISOR = math.max(1, math.floor(BotConfig.Combat.ShotBroadcastLodDivisor))

local function _getWeaponFiredRemote(): RemoteEvent?
	if _weaponFiredRemote and _weaponFiredRemote.Parent then
		return _weaponFiredRemote
	end
	local wsFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
	local network = wsFolder and wsFolder:FindFirstChild("Network")
	local fired = network and network:FindFirstChild("WeaponFired")
	if fired and fired:IsA("RemoteEvent") then
		_weaponFiredRemote = fired
		return fired
	end
	return nil
end

local AGENT_PARAMS = {
	AgentRadius = BotConfig.Pathfinding.AgentRadius,
	AgentHeight = BotConfig.Pathfinding.AgentHeight,
	AgentCanJump = BotConfig.Pathfinding.AgentCanJump,
	AgentJumpHeight = BotConfig.Movement.JumpHeight,
	AgentMaxSlope = BotConfig.Pathfinding.AgentMaxSlope,
	WaypointSpacing = BotConfig.Pathfinding.WaypointSpacing,
}

local ANIM_IDS = {
	Idle = AssetIds.Animations.CharacterIdle,
	Run = AssetIds.Animations.CharacterRun,
	Jump = AssetIds.Animations.CharacterJump,
	ToolHold = AssetIds.Animations.BotToolHold,
}

local _animationCache: { [string]: Animation } = {}

local function _getCachedAnimation(id: string): Animation
	local existing = _animationCache[id]
	if existing then return existing end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	_animationCache[id] = anim
	return anim
end

local FOV_COS = math.cos(math.rad(BotConfig.Combat.FOVDegrees / 2))
local DETECT_RANGE2 = BotConfig.Combat.DetectRange ^ 2
local RETALIATION_RANGE2 = BotConfig.Combat.RetaliationRange ^ 2
local PLAYER_PRIORITY_BIAS = BotConfig.Combat.PlayerPriorityBias
-- Gate del apuntado: AlignOrientation.CFrame replica a todos los clientes en cada
-- escritura; solo se reescribe si el look vector gira más de 2°.
local AIM_GATE_COS = math.cos(math.rad(2))

local EYE_OFFSET = Vector3.new(0, 1.5, 0)

-- Cache Player -> HumanoidRootPart del Character actual, para filtrar el broadcast de disparos por rango.
local _playerRootByPlayer: { [Player]: BasePart } = {}

local function _updateCachedPlayerRoot(player: Player, char: Model)
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		_playerRootByPlayer[player] = root
		return
	end
	local conn: RBXScriptConnection?
	conn = char.ChildAdded:Connect(function(child)
		if child.Name == "HumanoidRootPart" and child:IsA("BasePart") then
			if player.Character == char then
				_playerRootByPlayer[player] = child :: BasePart
			end
			if conn then conn:Disconnect(); conn = nil end
		end
	end)
	char.AncestryChanged:Connect(function(_, parent)
		if parent == nil and conn then
			conn:Disconnect()
			conn = nil
		end
	end)
end

-- Dedupe guard: a player joining between PlayerAdded:Connect and the initial GetPlayers()
-- loop would be wired twice (same race AI/init.luau guards with _wiredPlayers).
local _rootCacheWiredPlayers: { [Player]: true } = {}

local function _wirePlayerRootCache(player: Player)
	if _rootCacheWiredPlayers[player] then
		return
	end
	_rootCacheWiredPlayers[player] = true
	if player.Character then
		_updateCachedPlayerRoot(player, player.Character)
	end
	player.CharacterAdded:Connect(function(char)
		_updateCachedPlayerRoot(player, char)
	end)
	player.CharacterRemoving:Connect(function()
		_playerRootByPlayer[player] = nil
	end)
end

Players.PlayerAdded:Connect(_wirePlayerRootCache)
for _, _existingPlayer in Players:GetPlayers() do
	_wirePlayerRootCache(_existingPlayer)
end
Players.PlayerRemoving:Connect(function(p)
	_rootCacheWiredPlayers[p] = nil
	_playerRootByPlayer[p] = nil
end)

local STATES = {
	PATROL = "PATROL",
	CHASE = "CHASE",
	ATTACK = "ATTACK",
}

local BotAI = {}
BotAI.__index = BotAI

export type BotAIInstance = typeof(setmetatable({} :: {
	_dummy: Model,
	_humanoid: Humanoid,
	_rootPart: BasePart,
	_team: string,
	_myTeam: string?,
	_fakeUserId: number,
	_isAlive: boolean,
	_alignOrientation: AlignOrientation?,
	_uprightConstraint: AlignOrientation?,
	_mapRoot: Instance?,
	_connections: { RBXScriptConnection },
	_nextShotId: number,
	_aliveTargets: { AliveTarget },
	_botModelByFakeUserId: { [number]: Model }?,
	_raycastParams: RaycastParams?,
	_currentTarget: Model?,
	_currentTargetRoot: BasePart?,
	_currentTargetHum: Humanoid?,
	_currentTargetPos: Vector3,
	_currentTargetPlayer: Player?,
	_isCurrentTargetVisible: boolean,
	_targetGraceUntil: number,
	_forcedTarget: Model?,
	_forcedTargetHum: Humanoid?,
	_forcedTargetRoot: BasePart?,
	_forcedUntil: number,
	_fireReadyAt: number,
	_combatCycleEndAt: number,
	_combatMoveDir: Vector3,
	_targetCandidates: { { char: Model, d: number, score: number, root: BasePart } },
	_tool: Tool?,
	_tipAttachment: Attachment?,
	_wrapId: string?,
	_weaponId: string?,
	_fireRate: number,
	_lastAimPos: Vector3,
	_navigator: Navigator.Navigator?,
	_stuckDetector: StuckDetector.StuckDetector?,
	_navPhase: string,
	_roamGraph: RoamGraph.RoamGraph?,
	_animTracks: { [string]: AnimationTrack }?,
	_combat: ResolvedCombatProfile,
}, BotAI))

-- Per-bot combat skill, resolved ONCE at construction (personality
-- overrides over the global BotConfig.Combat baseline) so the 10–20Hz combat
-- loops read a flat table instead of paying an `override or global` chain
-- per field per tick.
export type ResolvedCombatProfile = {
	Precision: number,
	ReactionDelayMin: number,
	ReactionDelayMax: number,
	CombatPauseChance: number,
	CombatPauseMin: number,
	CombatPauseMax: number,
	CombatStepMin: number,
	CombatStepMax: number,
	JumpChanceMult: number,
	StationaryPrecisionBonus: number,
	StationarySpeedThreshold: number,
}

local function _resolveCombatProfile(overrides: BotPersonalities.CombatOverrides?): ResolvedCombatProfile
	local base = BotConfig.Combat
	local o: BotPersonalities.CombatOverrides = overrides or {}
	return {
		Precision = o.Precision or base.Precision,
		ReactionDelayMin = o.ReactionDelayMin or base.ReactionDelayMin,
		ReactionDelayMax = o.ReactionDelayMax or base.ReactionDelayMax,
		CombatPauseChance = o.CombatPauseChance or base.CombatPauseChance,
		CombatPauseMin = o.CombatPauseMin or base.CombatPauseMin,
		CombatPauseMax = o.CombatPauseMax or base.CombatPauseMax,
		CombatStepMin = o.CombatStepMin or base.CombatStepMin,
		CombatStepMax = o.CombatStepMax or base.CombatStepMax,
		JumpChanceMult = o.JumpChanceMult or 1,
		-- Sin override por personalidad: el bonus contra objetivo quieto es una
		-- regla del juego, no un rasgo de skill tier.
		StationaryPrecisionBonus = base.StationaryPrecisionBonus,
		StationarySpeedThreshold = base.StationarySpeedThreshold,
	}
end

--[[
@param fakeUserId number? Id de bot (<0) para kill attribution; combatOverrides nil = perfil global.
]]
function BotAI.new(botModel: Model, team: "A" | "B", fakeUserId: number?, wrapId: string?, combatOverrides: BotPersonalities.CombatOverrides?, weaponId: string?): BotAIInstance
	local humanoid = botModel:FindFirstChildOfClass("Humanoid") :: Humanoid
	local rootPart = botModel:FindFirstChild("HumanoidRootPart") :: BasePart

	local self = setmetatable({
		_dummy = botModel,
		_humanoid = humanoid,
		_rootPart = rootPart,
		_team = team,
		-- Normalizado una vez: _getBestTarget lo compara a 10Hz por candidato.
		_myTeam = TeamUtils.normalize(team),
		_fakeUserId = fakeUserId or 0,
		_isAlive = true,
		_alignOrientation = nil,
		_uprightConstraint = nil,
		_mapRoot = nil :: Instance?,
		_connections = {} :: { RBXScriptConnection },
		_nextShotId = 1,
		_aliveTargets = {},
		_botModelByFakeUserId = nil,
		_raycastParams = nil,
		_currentTarget = nil,
		_currentTargetPlayer = nil,
		_currentTargetRoot = nil,
		_currentTargetHum = nil,
		_currentTargetPos = Vector3.zero,
		_isCurrentTargetVisible = false,
		_targetGraceUntil = 0,
		_forcedTarget = nil,
		_forcedTargetHum = nil,
		_forcedTargetRoot = nil,
		_forcedUntil = 0,
		_fireReadyAt = 0,
		_combatCycleEndAt = 0,
		_combatMoveDir = Vector3.zero,
		_targetCandidates = {},
		_tool = nil,
		_tipAttachment = nil,
		_wrapId = wrapId,
		_weaponId = weaponId,
		_fireRate = BotConfig.Combat.FireRate,
		_lastAimPos = Vector3.zero,
		_navigator = nil,
		_stuckDetector = nil,
		_navPhase = "",
		_roamGraph = nil,
		_animTracks = nil,
		_combat = _resolveCombatProfile(combatOverrides),
	}, BotAI) :: BotAIInstance

	return self
end

--[[
@desc Network ownership al servidor: movimiento y disparo autoritativos.
]]
function BotAI:_setupNetworkOwnership()
	local ok = pcall(function()
		(self._rootPart :: any):SetNetworkOwner(nil)
	end)
	if not ok then
		warn("[BotAI] SetNetworkOwner falló en " .. self._dummy.Name)
	end
end

--[[
@desc Prefiere la Tool REAL del weaponId (mismos templates que los jugadores → tracers,
@desc sonidos y wrap correctos por arma vía el WeaponsSystem del cliente).
]]
function BotAI:_setupTool()
	-- El clon hereda del template los atributos de identidad (WeaponCategory) y
	-- el tag, así que el WeaponsSystem lo resuelve igual que el arma de un
	-- jugador, sin estampar nada aquí.
	local toolTemplate = BotAppearance.findWeaponTemplate(self._weaponId)
	if not toolTemplate then
		warn(string.format(
			"[BotAI] %s sin arma: no existe ServerStorage.WeaponTools.Main.%s. El bot no disparará.",
			self._dummy.Name,
			tostring(self._weaponId)
		))
		return
	end
	local tool = toolTemplate:Clone()
	BotAppearance.applyWrapToTool(tool, self._wrapId)
	tool.Parent = self._dummy
	if not CollectionService:HasTag(tool, WEAPON_TAG) then
		CollectionService:AddTag(tool, WEAPON_TAG)
	end
	self._humanoid:EquipTool(tool)
	self._nextShotId = 1
	self._tool = tool
	local tipAttach = tool:FindFirstChild("TipAttachment", true)
	if tipAttach and tipAttach:IsA("Attachment") then
		self._tipAttachment = tipAttach
	end

	-- Cadencia del arma real (si no, un Sniper dispararía a la cadencia del AR). El daño NO
	-- escala con el arma: sigue el perfil RNG del bot (VsPlayer/VsBot). Clamp defensivo.
	local shotCooldown = tonumber(WeaponsConfig.GetValueForTool(tool, "ShotCooldown"))
	if shotCooldown and shotCooldown > 0 then
		self._fireRate = math.clamp(shotCooldown, 0.08, 1.5)
	end
end

--[[
@desc Async para no bloquear picos de spawn al iniciar ronda.
]]
function BotAI:_setupAnimations(): { [string]: AnimationTrack }
	local tracks = {} :: { [string]: AnimationTrack }
	self._animTracks = tracks

	task.spawn(function()
		if not self._isAlive then return end
		local animator = self._humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = self._humanoid
		end

		for name, id in ANIM_IDS do
			if not self._isAlive then return end
			local anim = _getCachedAnimation(id)
			local ok, track = pcall(function()
				return (animator :: Animator):LoadAnimation(anim)
			end)
			if ok then
				tracks[name] = track :: AnimationTrack
			end
		end

		if tracks.ToolHold and self._isAlive then
			tracks.ToolHold.Priority = Enum.AnimationPriority.Action
			tracks.ToolHold.Looped = true
			tracks.ToolHold:Play()
		end
	end)

	return tracks
end

--[[
@desc Constraint físico en vez de rotación instantánea, por suavidad visual.
]]
function BotAI:_setupRotationConstraint(): AlignOrientation?
	local existing = self._rootPart:FindFirstChild("RotationAttachment")
	local attachment: Attachment
	if existing and existing:IsA("Attachment") then
		attachment = existing
	else
		attachment = Instance.new("Attachment")
		attachment.Name = "RotationAttachment"
		attachment.Parent = self._rootPart
	end

	-- Constraint de APUNTADO: gira el HRP entero hacia el objetivo en combate.
	-- El FSM lo togglea (Enabled + CFrame por tick). Controla los 3 ejes, pero su
	-- CFrame objetivo siempre es vertical (lookAt horizontal), así que coincide
	-- con el constraint de verticalidad de abajo — no se pelean.
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.MaxTorque = 1e6
	align.MaxAngularVelocity = 20
	align.Responsiveness = 30
	align.Enabled = false
	align.Parent = self._dummy

	-- Constraint de VERTICALIDAD: los NPC vivos tienen FallingDown/Ragdoll/GettingUp
	-- deshabilitados (ver AIService), así que un vuelco físico (choque entre bots,
	-- aterrizaje del spawn, giro brusco) los dejaría tumbados sin recuperación. Fija SOLO el
	-- eje "arriba" del HRP (PrimaryAxisOnly), dejando el yaw libre; siempre Enabled.
	-- Ejes: con PrimaryAxisOnly, AlignOrientation alinea el eje X del attachment
	-- (Attachment.Axis) con el RightVector del CFrame objetivo. Rotamos el
	-- attachment 90° en Z para que su X local apunte al +Y del HRP (arriba), y
	-- damos como objetivo un CFrame cuyo RightVector es el +Y del mundo. Ambos son
	-- CFrame.Angles(0, 0, π/2) → RightVector (0, 1, 0).
	local existingUpright = self._rootPart:FindFirstChild("UprightAttachment")
	local uprightAttachment: Attachment
	if existingUpright and existingUpright:IsA("Attachment") then
		uprightAttachment = existingUpright
	else
		uprightAttachment = Instance.new("Attachment")
		uprightAttachment.Name = "UprightAttachment"
		uprightAttachment.CFrame = CFrame.Angles(0, 0, math.pi / 2)
		uprightAttachment.Parent = self._rootPart
	end

	local upright = Instance.new("AlignOrientation")
	upright.Name = "UprightConstraint"
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upright.Attachment0 = uprightAttachment
	upright.PrimaryAxisOnly = true
	upright.CFrame = CFrame.Angles(0, 0, math.pi / 2)
	upright.RigidityEnabled = false
	upright.MaxTorque = 1e6
	upright.MaxAngularVelocity = 20
	upright.Responsiveness = 25
	upright.Enabled = true
	upright.Parent = self._dummy

	-- Guardados para apagarlos síncronamente en Stop() (ver allí).
	self._alignOrientation = align
	self._uprightConstraint = upright

	return align
end

function BotAI:_playAnimation(name: string, tracks: { [string]: AnimationTrack }, currentTrack: AnimationTrack?): AnimationTrack?
	local track = tracks[name]
	if track and currentTrack ~= track then
		if currentTrack then
			currentTrack:Stop(0.2)
		end
		track:Play(0.2)
		return track
	end
	return currentTrack
end

--[[
@param maxRange number? Alcance del rayo (default DetectRange); la represalia pasa
@param RetaliationRange para poder devolver fuego de lejos.
]]
function BotAI:_canSeeTarget(target: Model, preResolvedRoot: BasePart?, maxRange: number?): boolean
	local targetRoot = preResolvedRoot or target:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return false
	end

	local origin = self._rootPart.Position + EYE_OFFSET
	local targetPos = (targetRoot :: BasePart).Position + EYE_OFFSET
	local direction = targetPos - origin

	if direction.Magnitude > (maxRange or BotConfig.Combat.DetectRange) then
		return false
	end

	local params = self._raycastParams

	local result = workspace:Raycast(origin, direction, params)
	local seesTarget = result ~= nil and result.Instance:IsDescendantOf(target)

	if RaycastViz.isEnabled() then
		local rayResult: RaycastViz.RayResult
		local endPos: Vector3
		if seesTarget then
			rayResult = "hit"
			endPos = targetPos
		elseif result then
			rayResult = "blocked"
			endPos = result.Position
		else
			rayResult = "void"
			endPos = targetPos
		end
		RaycastViz.draw(origin, endPos, rayResult)
	end

	return seesTarget
end

function BotAI:_getBestTarget(): (Model?, boolean, BasePart?)
	local rootPos = self._rootPart.Position
	local myTeam = self._myTeam
	local facing = self._rootPart.CFrame.LookVector
	local now = time()

	local candidates = self._targetCandidates
	local candidateCount = 0

	-- Filtros ordenados por coste: distancia y FOV son matemática pura sobre
	-- el root cacheado y descartan a casi todos; el equipo (GetPlayerFromCharacter
	-- + attributes + leaderstats) y la protección de spawn (attribute) solo se
	-- consultan para lo que sobrevive al rango.
	for _, entry in self._aliveTargets do
		local char = entry.model
		if char == self._dummy then continue end

		local root = entry.root
		if not root or not root.Parent then
			root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			entry.root = root
		end
		if not root then continue end

		local delta = (root :: BasePart).Position - rootPos
		local d2 = delta:Dot(delta)
		if d2 > DETECT_RANGE2 then continue end

		local d = math.sqrt(d2)
		if d > 0.001 and facing:Dot(delta) / d < FOV_COS then continue end

		local hum = entry.hum
		if not hum or not hum.Parent then
			hum = char:FindFirstChildOfClass("Humanoid")
			entry.hum = hum
		end
		if not hum or hum.Health <= 0 then continue end

		-- Teamless characters (lobby, mid-teleport, just-joined) are never valid targets —
		-- same rule as TeamUtils.areEnemies.
		local charTeam = TeamUtils.getSide(char)
		if not charTeam or charTeam == myTeam then continue end

		local protectedUntil = char:GetAttribute("SpawnProtectedUntil")
		if type(protectedUntil) == "number" and protectedUntil > now then continue end

		-- Prioridad a humanos: un jugador ordena como si estuviera PlayerPriorityBias studs
		-- más cerca, así los MaxLosChecksPerEval raycasts se gastan primero en él.
		local score = d
		if char:GetAttribute("FakeUserId") == nil then
			score -= PLAYER_PRIORITY_BIAS
		end

		candidateCount += 1
		local c = candidates[candidateCount]
		if c then
			c.char = char
			c.d = d
			c.score = score
			c.root = root :: BasePart
		else
			candidates[candidateCount] = { char = char, d = d, score = score, root = root :: BasePart }
		end
	end

	for i = candidateCount + 1, #candidates do
		candidates[i] = nil
	end

	if candidateCount == 0 then
		return nil, false, nil
	end

	table.sort(candidates, function(a, b) return a.score < b.score end)

	local maxChecks = math.min(candidateCount, BotConfig.Combat.MaxLosChecksPerEval)
	for i = 1, maxChecks do
		local c = candidates[i]
		if self:_canSeeTarget(c.char, c.root) then
			return c.char, true, c.root
		end
	end

	return nil, false, nil
end

--[[
@desc attackerUserId: UserId real (>0) o fake id de bot (<0).
]]
local function _findAttackerModel(
	attackerUserId: number,
	aliveTargets: { AliveTarget },
	selfDummy: Model,
	botModelByFakeUserId: { [number]: Model }?
): Model?
	if attackerUserId > 0 then
		local p = Players:GetPlayerByUserId(attackerUserId)
		if p and p.Character then
			return p.Character
		end
		return nil
	end
	if botModelByFakeUserId then
		local m = botModelByFakeUserId[attackerUserId]
		if m and m ~= selfDummy then
			return m
		end
		return nil
	end
	for _, entry in aliveTargets do
		local m = entry.model
		if m == selfDummy then
			continue
		end
		if m:GetAttribute("FakeUserId") == attackerUserId then
			return m
		end
	end
	return nil
end

function BotAI:_getForcedTarget(): Model?
	local target = self._forcedTarget
	if not target then
		return nil
	end
	if os.clock() >= self._forcedUntil or not target.Parent then
		self._forcedTarget = nil
		return nil
	end
	-- Reuse hum/root cached when the forced target was set (this runs at
	-- 10Hz during retaliation); refresh lazily if the refs went stale.
	local hum = self._forcedTargetHum
	if not hum or not hum.Parent then
		hum = target:FindFirstChildOfClass("Humanoid")
		self._forcedTargetHum = hum
	end
	local root = self._forcedTargetRoot
	if not root or not root.Parent then
		root = target:FindFirstChild("HumanoidRootPart") :: BasePart?
		self._forcedTargetRoot = root
	end
	if not hum or (hum :: Humanoid).Health <= 0 or not root then
		self._forcedTarget = nil
		return nil
	end
	local myTeam = self._myTeam
	local theirTeam = TeamUtils.getSide(target)
	-- Drop the forced target if it's a teammate OR teamless (left the match /
	-- back to lobby mid-retaliation) — same rule as _getBestTarget.
	if not theirTeam or theirTeam == myTeam then
		self._forcedTarget = nil
		return nil
	end
	-- Rango absoluto de represalia (no DetectRange+bonus): quien te dispara
	-- desde lejos sigue siendo objetivo mientras esté en el mapa a tiro.
	local fd = self._rootPart.Position - (root :: BasePart).Position
	if fd:Dot(fd) > RETALIATION_RANGE2 then
		self._forcedTarget = nil
		return nil
	end
	return target
end

--[[
@desc Grace, fast-path estable y reaction delay para el primer disparo.
]]
function BotAI:_evaluateTarget(now: number)
	if not self._isAlive then
		return
	end
	local potentialTarget: Model?
	local isVisible: boolean
	local resolvedRoot: BasePart? = nil
	local resolvedHum: Humanoid? = nil
	local forced = self:_getForcedTarget()
	if forced then
		potentialTarget = forced
		-- _getForcedTarget acaba de validar (y refrescar si hacía falta) el
		-- hum/root cacheados: reusarlos aquí y al final de la evaluación en
		-- lugar de pagar FindFirstChild por tick durante la retaliación.
		resolvedRoot = self._forcedTargetRoot
		resolvedHum = self._forcedTargetHum
		-- LoS a rango de represalia: si me disparan desde 100 studs, devuelvo
		-- fuego desde 100 studs en vez de ir a CHASE hasta entrar en DetectRange.
		isVisible = self:_canSeeTarget(forced, resolvedRoot, BotConfig.Combat.RetaliationRange)
	else
		local current = self._currentTarget
		local fastPath = false
		if current and current.Parent then
			local hum = self._currentTargetHum
			local root = self._currentTargetRoot
			if hum and hum.Parent and (hum :: Humanoid).Health > 0 and root and root.Parent then
				local toRoot = (root :: BasePart).Position - self._rootPart.Position
				local d2 = toRoot:Dot(toRoot)
				local detectRange = BotConfig.Combat.DetectRange
				if d2 <= detectRange * detectRange then
					local d = math.sqrt(d2)
					local facing = self._rootPart.CFrame.LookVector
					if d > 0.001 and facing:Dot(toRoot) / d >= FOV_COS then
						if self:_canSeeTarget(current, root :: BasePart) then
							potentialTarget = current
							isVisible = true
							fastPath = true
							resolvedRoot = root
							resolvedHum = hum
						end
					end
				end
			end
		end
		if not fastPath then
			potentialTarget, isVisible, resolvedRoot = self:_getBestTarget()
			-- Stickiness: si el objetivo que acabo de perder de vista es un
			-- JUGADOR todavía en memoria, no lo cambio por un bot NPC que
			-- pase por delante — sigo en CHASE hacia el humano. Solo otro
			-- jugador visible (o la represalia, arriba) puede desplazarlo.
			if potentialTarget
				and current
				and potentialTarget ~= current
				and now < self._targetGraceUntil
				and self._currentTargetPlayer ~= nil
				and potentialTarget:GetAttribute("FakeUserId") ~= nil then
				potentialTarget = nil
				isVisible = false
				resolvedRoot = nil
			end
		end
	end

	if potentialTarget and isVisible then
		self._targetGraceUntil = now + BotConfig.Combat.TargetMemoryGrace
	elseif not potentialTarget and self._currentTarget and now < self._targetGraceUntil then
		local prev = self._currentTarget
		local prevHum = self._currentTargetHum
		if not prevHum or not prevHum.Parent then
			prevHum = prev:FindFirstChildOfClass("Humanoid")
		end
		local prevRoot = self._currentTargetRoot
		if not prevRoot or not prevRoot.Parent then
			prevRoot = prev:FindFirstChild("HumanoidRootPart") :: BasePart?
		end
		if prev.Parent
			and prevHum and (prevHum :: Humanoid).Health > 0
			and prevRoot then
			local graceRange = BotConfig.Combat.DetectRange + BotConfig.Combat.GraceRangeBonus
			local gd = self._rootPart.Position - (prevRoot :: BasePart).Position
			if gd:Dot(gd) <= graceRange * graceRange then
				potentialTarget = prev
				isVisible = false
				resolvedRoot = prevRoot
				resolvedHum = prevHum
			end
		end
	end

	local prevVisible = self._isCurrentTargetVisible
	-- El delay también se arma al CAMBIAR de objetivo visible (el anterior murió y hay otro
	-- con LoS en la misma evaluación); si no, dispararía al nuevo con delay cero.
	local switchedTarget = potentialTarget ~= self._currentTarget
	if isVisible and (not prevVisible or switchedTarget) then
		local lo = self._combat.ReactionDelayMin
		local hi = self._combat.ReactionDelayMax
		self._fireReadyAt = now + lo + math.random() * (hi - lo)
	end

	self._currentTarget = potentialTarget
	self._isCurrentTargetVisible = isVisible
	if potentialTarget then
		local targetRoot: BasePart? = resolvedRoot
		if not targetRoot or not targetRoot.Parent then
			local r = potentialTarget:FindFirstChild("HumanoidRootPart")
			targetRoot = if r and r:IsA("BasePart") then r :: BasePart else nil
		end
		if targetRoot then
			self._currentTargetRoot = targetRoot
			self._currentTargetPos = targetRoot.Position
		else
			self._currentTargetRoot = nil
		end
		local targetHum: Humanoid? = resolvedHum
		if not targetHum or not targetHum.Parent then
			targetHum = potentialTarget:FindFirstChildOfClass("Humanoid")
		end
		self._currentTargetHum = targetHum
		if potentialTarget:GetAttribute("FakeUserId") == nil then
			self._currentTargetPlayer = Players:GetPlayerFromCharacter(potentialTarget)
		else
			self._currentTargetPlayer = nil
		end
	else
		self._currentTargetRoot = nil
		self._currentTargetHum = nil
		self._currentTargetPlayer = nil
	end
end

--[[
@desc Rerollea el ciclo de movimiento de combate (pausa o paso) cuando el
@desc actual expira, aplicando la banda de distancia de BotConfig.Combat:
@desc   • dist < MinEngageDistance  → paso lateral + retroceso (nunca pausa:
@desc     quedarse quieto pegado al jugador es justo lo que queremos evitar).
@desc   • dist > MaxEngageDistance  → paso lateral + aproximación.
@desc   • en medio                  → lateral puro o pausa según personality.
@desc También lo usa CHASE a distancia de standoff para buscar ángulo sin
@desc hacer path hasta el cuerpo del objetivo.
]]
function BotAI:_updateCombatMove(now: number, targetPos: Vector3, dist: number)
	if now < self._combatCycleEndAt then
		return
	end
	local combat = self._combat
	local tooClose = dist < BotConfig.Combat.MinEngageDistance
	local tooFar = dist > BotConfig.Combat.MaxEngageDistance

	if not tooClose and not tooFar and math.random() < combat.CombatPauseChance then
		self._combatMoveDir = Vector3.zero
		local lo = combat.CombatPauseMin
		local hi = combat.CombatPauseMax
		self._combatCycleEndAt = now + lo + math.random() * (hi - lo)
		return
	end

	local toTarget = targetPos - self._rootPart.Position
	toTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
	local right = toTarget:Cross(Vector3.new(0, 1, 0))
	if right.Magnitude > 0.01 and toTarget.Magnitude > 0.01 then
		right = right.Unit
		local lateralSign = if math.random() < 0.5 then -1 else 1
		local lateral = lateralSign * (0.7 + math.random() * 0.3)
		local forward = 0
		if tooClose then
			-- Retroceder abre distancia; el lateral evita que sea una
			-- marcha atrás en línea recta contra la pared de detrás.
			forward = -(0.6 + math.random() * 0.3)
		elseif tooFar then
			forward = 0.5 + math.random() * 0.3
		end
		local dir = right * lateral + toTarget.Unit * forward
		if dir.Magnitude > 0.01 then
			self._combatMoveDir = dir.Unit
		else
			self._combatMoveDir = right
		end
	else
		self._combatMoveDir = Vector3.zero
	end
	local lo = combat.CombatStepMin
	local hi = combat.CombatStepMax
	self._combatCycleEndAt = now + lo + math.random() * (hi - lo)
end

-- Gate por cambio: ATTACK y CHASE iteran a 20Hz y reescribirían el mismo valor.
function BotAI:_setNavPhase(phase: string)
	if not IS_STUDIO or self._navPhase == phase then
		return
	end
	self._navPhase = phase
	self._dummy:SetAttribute(NAV_PHASE_ATTR, phase)
end

-- Bloqueante (coordina PATROL sin carreras de ruta). Devuelve true si la navegación
-- falló (onFailed): PATROL lo usa para backoff.
function BotAI:_moveToLocation(location: Vector3, stopCondition: () -> boolean): boolean
	local navigator = self._navigator
	if not navigator then
		return false
	end

	local done = false
	local failed = false
	local walking = false
	navigator:goTo(location, {
		onArrived = function()
			done = true
		end,
		onFailed = function()
			done = true
			failed = true
		end,
	})

	-- "path-wait" cubre desde el enqueue hasta que el walk loop arranca: cola
	-- de ComputeAsync + el propio compute. Si un bot pasa aquí sus segundos
	-- de quietud, el cuello de botella es el pathfinding, no el movimiento.
	self:_setNavPhase("path-wait")

	-- 10Hz wait: the stop condition's inputs (target acquisition, death) come from the
	-- 10Hz eval loop, so polling faster gains no latency.
	while not done and not stopCondition() do
		if not walking and navigator:isMoving() then
			walking = true
			self:_setNavPhase("walking")
		end
		task.wait(0.1)
	end

	-- Cancelar SIEMPRE al salir por stopCondition, también en "path-wait" (compute encolado,
	-- isMoving aún false): si no, el compute pendiente arrancaría un walk con el bot ya en
	-- ATTACK. cancel() es idempotente y barato.
	if stopCondition() then
		navigator:cancel()
	end

	return failed
end

function BotAI:Start(
	mapRoot: Instance?,
	aliveTargets: { AliveTarget }?,
	roamGraph: RoamGraph.RoamGraph?,
	botModelByFakeUserId: { [number]: Model }?
)
	self._mapRoot = mapRoot
	self._aliveTargets = aliveTargets or {}
	self._roamGraph = roamGraph
	self._botModelByFakeUserId = botModelByFakeUserId
	self:_setupNetworkOwnership()
	self:_setupTool()

	local humanoid = self._humanoid
	local rootPart = self._rootPart

	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = { self._dummy }
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	-- LoS rays behave as a CHARACTERS member, so they ignore RAGDOLL parts: fresh corpses
	-- don't block line of sight. Walls (Default) and live characters still block.
	raycastParams.CollisionGroup = CollisionGroups.CHARACTERS
	self._raycastParams = raycastParams

	self._navigator = Navigator.new(humanoid, rootPart, AGENT_PARAMS)

	local _, connDetectViz = DetectRangeViz.attach(rootPart, BotConfig.Combat.DetectRange)
	if connDetectViz then
		table.insert(self._connections, connDetectViz)
	end

	self._stuckDetector = StuckDetector.new(
		rootPart,
		humanoid,
		self._navigator :: any,
		self._roamGraph :: any,
		self._dummy.Name
	)
	task.spawn(function()
		task.wait(math.random() * 0.1)
		while self._isAlive and humanoid.Health > 0 do
			if self._stuckDetector then
				self._stuckDetector:tick(os.clock())
			end
			task.wait(0.1)
		end
	end)

	task.spawn(function()
		task.wait(math.random() * 0.1)
		while self._isAlive and humanoid.Health > 0 do
			self:_evaluateTarget(os.clock())
			task.wait(0.1)
		end
	end)

	humanoid.UseJumpPower = false
	humanoid.JumpHeight = BotConfig.Movement.JumpHeight
	humanoid.WalkSpeed = BotConfig.Movement.WalkSpeed

	local tracks = self:_setupAnimations()
	local alignOrientation = self:_setupRotationConstraint()

	local currentTrack: AnimationTrack? = nil
	local lastShotTime = 0
	-- Próximo instante en que ATTACK evalúa si salta; el intervalo se rollea UNA vez por
	-- check (rollearlo cada tick haría que pasara en cuanto se cumple el mínimo).
	local nextJumpCheckAt = 0

	local connRun = humanoid.Running:Connect(function(speed)
		if speed > 0.5 then
			currentTrack = self:_playAnimation("Run", tracks, currentTrack)
			if tracks.Run then
				tracks.Run:AdjustSpeed(speed / 16)
			end
		else
			currentTrack = self:_playAnimation("Idle", tracks, currentTrack)
		end
	end)
	local connJump = humanoid.Jumping:Connect(function()
		currentTrack = self:_playAnimation("Jump", tracks, currentTrack)
	end)
	table.insert(self._connections, connRun)
	table.insert(self._connections, connJump)

	local connDamage = humanoid:GetAttributeChangedSignal("LastAttackerAt"):Connect(function()
		local lastAttacker = LastAttackerStore.get(humanoid)
		if not lastAttacker then return end
		local attackerUserId = lastAttacker.UserId
		if type(attackerUserId) ~= "number" then return end
		if attackerUserId == self._fakeUserId then return end -- self-damage
		local attackerModel = _findAttackerModel(attackerUserId, self._aliveTargets, self._dummy, self._botModelByFakeUserId)
		if attackerModel and attackerModel ~= self._dummy then
			-- Un bot NPC que me dispara NO me roba el objetivo si ya estoy enfrentando a un
			-- jugador (visible o en memoria). Un jugador atacante sí desplaza a otro.
			if attackerUserId < 0 and self._currentTargetPlayer ~= nil then
				return
			end
			self._forcedTarget = attackerModel
			-- Resolve once here so _getForcedTarget doesn't pay two child
			-- lookups per evaluation while the retaliation window is open.
			self._forcedTargetHum = attackerModel:FindFirstChildOfClass("Humanoid")
			self._forcedTargetRoot = attackerModel:FindFirstChild("HumanoidRootPart") :: BasePart?
			self._forcedUntil = os.clock() + BotConfig.Combat.RetaliationWindow
		end
	end)
	table.insert(self._connections, connDamage)

	task.spawn(function()
		local currentState = STATES.PATROL
		local lastAppliedMoveDir: Vector3 = Vector3.new(math.huge, 0, 0)
		-- Último look vector escrito en el AlignOrientation de apuntado.
		-- Vector3.zero como sentinel: dot(unit, zero)=0 < AIM_GATE_COS, así
		-- que la primera escritura tras (re)activar el apuntado siempre pasa.
		local lastAimDir: Vector3 = Vector3.zero
		local previousState: string = STATES.PATROL
		-- true mientras CHASE está en standoff (strafe sin path). Ver la rama CHASE.
		local chaseStandoff = false

		-- El rig entra por encima del pad de spawn y cae; pedir path desde el aire da NoPath
		-- (origen fuera del navmesh), que cuesta el backoff de PATROL y el StuckDetector no ve.
		-- Esperar al contacto con el suelo es más barato que fallar y reintentar.
		self:_setNavPhase("spawn-grounding")
		local groundDeadline = os.clock() + SPAWN_GROUND_TIMEOUT
		while self._isAlive
			and humanoid.Health > 0
			and humanoid.FloorMaterial == Enum.Material.Air
			and os.clock() < groundDeadline do
			task.wait(0.05)
		end

		while self._isAlive and humanoid.Health > 0 do
			local potentialTarget = self._currentTarget
			local isVisible = self._isCurrentTargetVisible
			local targetRoot = self._currentTargetRoot
			local targetPos = if targetRoot and targetRoot.Parent
				then targetRoot.Position
				else self._currentTargetPos

			if alignOrientation then
				if potentialTarget and targetRoot then
					-- Mirar SIEMPRE al objetivo desde la posición ACTUAL del bot (con strafe y objetivo
					-- quieto, una dirección vieja haría disparar "de lado"). Pero se ESCRIBE solo si gira
					-- >2°: AlignOrientation solo usa la rotación y cada escritura replica a los clientes.
					local rootPos = rootPart.Position
					local lookPos = Vector3.new(targetPos.X, rootPos.Y, targetPos.Z)
					local lookDelta = lookPos - rootPos
					-- Evita un lookAt degenerado (NaN) si el bot está justo encima.
					if lookDelta.Magnitude > 0.05 then
						local lookDir = lookDelta.Unit
						if lookDir:Dot(lastAimDir) < AIM_GATE_COS then
							alignOrientation.CFrame = CFrame.lookAt(rootPos, lookPos)
							lastAimDir = lookDir
						end
					end
					self._lastAimPos = targetPos
					alignOrientation.Enabled = true
					humanoid.AutoRotate = false
				else
					alignOrientation.Enabled = false
					humanoid.AutoRotate = true
					lastAimDir = Vector3.zero
				end
			end

			local currentTarget: Model? = potentialTarget
			if potentialTarget and targetRoot then
				if isVisible then
					currentState = STATES.ATTACK
				else
					currentState = STATES.CHASE
				end
			else
				currentState = STATES.PATROL
			end
			if currentState ~= STATES.CHASE then
				chaseStandoff = false
			end

			local isPlayer = false
			if currentTarget then
				isPlayer = currentTarget:GetAttribute("FakeUserId") == nil
			end
			local profile = if isPlayer then BotConfig.Combat.VsPlayer else BotConfig.Combat.VsBot

			if currentState == STATES.ATTACK and currentTarget and targetRoot then
				if self._navigator and self._navigator:isMoving() then
					self._navigator:cancel()
					-- cancel() deja Move(zero). Invalidar el último strafe
					-- aplicado para que el bloque de abajo lo reescriba en este
					-- mismo tick en vez de esperar al siguiente ciclo.
					lastAppliedMoveDir = Vector3.new(math.huge, 0, 0)
				end
				self:_setNavPhase("attack")

				local now = os.clock()
				local flatDelta = targetPos - rootPart.Position
				local targetDist = Vector3.new(flatDelta.X, 0, flatDelta.Z).Magnitude
				-- Si el ciclo actual es una pausa o un paso sin retroceso y el
				-- objetivo se nos ha echado encima, cortarlo ya: la banda de
				-- distancia solo se evalúa al rerollear.
				if targetDist < BotConfig.Combat.MinEngageDistance
					and self._combatMoveDir:Dot(flatDelta) >= 0 then
					self._combatCycleEndAt = 0
				end
				-- Strafe según personality + banda de distancia.
				self:_updateCombatMove(now, targetPos, targetDist)
				local enteredAttack = previousState ~= STATES.ATTACK
				if enteredAttack or self._combatMoveDir ~= lastAppliedMoveDir then
					humanoid:Move(self._combatMoveDir, false)
					lastAppliedMoveDir = self._combatMoveDir
				end

				if now >= nextJumpCheckAt then
					if math.random() < profile.JumpChance * self._combat.JumpChanceMult then
						humanoid.Jump = true
					end
					nextJumpCheckAt = now + math.random(20, 50) / 10
				end

				-- Cadencia del arma equipada (resuelta en _setupTool); precisión por personality.
				local fireRate = self._fireRate
				local precision = self._combat.Precision

				-- Un objetivo quieto es mucho más fácil de acertar: se suma un
				-- bonus de precisión que se desvanece según su velocidad, así
				-- campear no sale gratis. Se lee la velocidad del rig completo
				-- (AssemblyLinearVelocity) para que también cuente caer o ser
				-- empujado, no solo caminar.
				local bonus = self._combat.StationaryPrecisionBonus
				if bonus > 0 and targetRoot and targetRoot.Parent then
					local threshold = math.max(0.001, self._combat.StationarySpeedThreshold)
					local speed = targetRoot.AssemblyLinearVelocity.Magnitude
					local stillness = 1 - math.clamp(speed / threshold, 0, 1)
					precision = math.min(100, precision + bonus * stillness)
				end
				-- Más allá de DetectRange solo se llega por represalia: que
				-- devuelva fuego, pero con menos puntería.
				if targetDist > BotConfig.Combat.DetectRange then
					precision *= BotConfig.Combat.FarPrecisionMult
				end

				if os.clock() - lastShotTime > fireRate
					and isVisible
					and os.clock() >= self._fireReadyAt then
					lastShotTime = os.clock()

					local hit = math.random(1, 100) <= precision
					local weapon = self._tool
					local firedRemote = _getWeaponFiredRemote()

					if weapon and firedRemote then
						local tipAttach = self._tipAttachment
						local origin: Vector3
						if tipAttach and tipAttach.Parent then
							origin = tipAttach.WorldPosition
						else
							origin = rootPart.Position + EYE_OFFSET
						end
						local trueDir = (targetPos - origin).Unit
						local dir = trueDir
						if not hit then
							local spreadDeg = BotConfig.Combat.MissSpreadDegMin
								+ math.random() * (BotConfig.Combat.MissSpreadDegMax - BotConfig.Combat.MissSpreadDegMin)
							local axis = Vector3.new(
								math.random() - 0.5,
								math.random() - 0.5,
								math.random() - 0.5
							)
							if axis.Magnitude > 0.001 then
								axis = axis.Unit
								dir = (CFrame.fromAxisAngle(axis, math.rad(spreadDeg)) * trueDir).Unit
							end
						end
						local fireInfo = {
							origin = origin,
							dir = dir,
							charge = 1,
							id = self._nextShotId,
						}
						self._nextShotId += 1
						-- LOD por distancia (ver BotConfig.Combat.ShotBroadcast*):
						-- cada evento que llega al cliente es una simulación
						-- completa de bala. A los observadores lejanos no se les
						-- mandan los fallos, y de los aciertos solo 1 de cada
						-- SHOT_LOD_DIVISOR. El id sigue siendo único y creciente.
						local shotId = fireInfo.id
						local sendFarShot = hit and (shotId % SHOT_LOD_DIVISOR == 0)
						for p, pRoot in _playerRootByPlayer do
							if pRoot.Parent then
								local delta = origin - pRoot.Position
								local pd2 = delta:Dot(delta)
								if pd2 < SHOT_LOD2 or (pd2 < SHOT_RANGE2 and sendFarShot) then
									firedRemote:FireClient(p, nil, weapon, fireInfo)
								end
							end
						end
					end

					if hit then
						-- Reuse the hum cached by _evaluateTarget instead of a
						-- FindFirstChildOfClass per landed shot.
						local targetHum = self._currentTargetHum
						if not targetHum or not targetHum.Parent then
							targetHum = currentTarget:FindFirstChildOfClass("Humanoid")
						end
						if targetHum and (targetHum :: Humanoid).Health > 0 then
							local dmg = math.random(profile.DamageMin, profile.DamageMax)

							LastAttackerStore.set(targetHum :: Humanoid, self._fakeUserId, if weapon then weapon.Name else "NPC")

							;(targetHum :: Humanoid):TakeDamage(dmg)

							if isPlayer then
								local victimPlayer = self._currentTargetPlayer
								local dataRemote = _getWeaponDataRemote()
								if victimPlayer and dataRemote then
									dataRemote:FireClient(victimPlayer, "HitByOtherPlayer", rootPart.Position)
								end
							end
						end
					end
				end

				task.wait(0.05)

			elseif currentState == STATES.CHASE and currentTarget and targetRoot then
				-- CHASE solo existe SIN línea de visión (con LoS el FSM va a ATTACK), así que siempre
				-- es por path. El Navigator silencia goTo repetidos al mismo dest: llamarlo a 20Hz es barato.
				local flatDelta = targetPos - rootPart.Position
				local targetDist = Vector3.new(flatDelta.X, 0, flatDelta.Z).Magnitude
				-- Histéresis: entra en standoff por debajo de ChaseStandoffDistance
				-- y solo vuelve a hacer path por encima de ChaseResumeDistance.
				-- Sin ella alternaría path / retroceder cada ~1s, con un ComputeAsync por ciclo.
				local wantStandoff = targetDist < BotConfig.Combat.ChaseStandoffDistance
					or (chaseStandoff and targetDist < BotConfig.Combat.ChaseResumeDistance)
				if wantStandoff then
					-- Encima del objetivo y sin verlo (bot en medio, desnivel, prop): hacer path a su
					-- posición solo lo empuja y dispara el StuckDetector. Se busca ángulo con el strafe
					-- de combate (a esta distancia siempre lleva retroceso).
					self:_setNavPhase("chase-standoff")
					if not chaseStandoff then
						chaseStandoff = true
						-- Una sola vez: cancel() escribe Move(zero) y pisaría
						-- el strafe si se llamara a 20Hz. Cancela también un
						-- compute pendiente (isMoving aún false).
						if self._navigator then
							self._navigator:cancel()
						end
						lastAppliedMoveDir = Vector3.new(math.huge, 0, 0)
					end
					self:_updateCombatMove(os.clock(), targetPos, targetDist)
					if self._combatMoveDir ~= lastAppliedMoveDir then
						humanoid:Move(self._combatMoveDir, false)
						lastAppliedMoveDir = self._combatMoveDir
					end
				else
					self:_setNavPhase("chase-path")
					if chaseStandoff then
						-- Salida del standoff: Move es sticky y el walk loop
						-- del Navigator no escribe nada hasta que llega el path.
						chaseStandoff = false
						humanoid:Move(Vector3.zero, false)
						lastAppliedMoveDir = Vector3.new(math.huge, 0, 0)
					end
					if self._navigator then
						self._navigator:goTo(targetPos)
					end
				end

				task.wait(0.05)

			else
				local dest: Vector3?

				-- Salida de ATTACK: el strafe usa `humanoid:Move`, que es STICKY. Sin cortarlo el bot
				-- entra a PATROL trotando con el último rumbo durante `path-wait` y cada backoff, y
				-- como PATROL elige destino nuevo en cada reintento, se ve corriendo en círculos.
				if previousState ~= STATES.PATROL then
					humanoid:Move(Vector3.zero, false)
					lastAppliedMoveDir = Vector3.new(math.huge, 0, 0)
				end

				-- "roam-pick-fallback" delata un mapa sin AINav/RoamPoints
				-- usable: los destinos pasan a ser puntos aleatorios del
				-- WanderRadius, que caen fuera del navmesh a menudo y hacen
				-- fallar el compute una y otra vez.
				self:_setNavPhase("roam-pick")

				if self._roamGraph then
					dest = self._roamGraph:pickRandomNavigablePoint(
						rootPart.Position,
						BotConfig.Navigation.RoamMinDist,
						BotConfig.Navigation.RoamMaxDist
					)
				end

				if not dest then
					self:_setNavPhase("roam-pick-fallback")
					local randomVec = Vector3.new(
						math.random(-BotConfig.Movement.WanderRadius, BotConfig.Movement.WanderRadius),
						0,
						math.random(-BotConfig.Movement.WanderRadius, BotConfig.Movement.WanderRadius)
					)
					dest = rootPart.Position + randomVec
				end

				local jitter = BotConfig.Navigation.RoamDestJitter
				dest = (dest :: Vector3) + Vector3.new(
					(math.random() * 2 - 1) * jitter,
					0,
					(math.random() * 2 - 1) * jitter
				)

				local moveFailed = self:_moveToLocation(dest :: Vector3, function()
					return self._currentTarget ~= nil or not self._isAlive
				end)

				-- Backoff after a pathfinding failure: the Navigator defers onFailed almost immediately,
				-- so without this PATROL respins every ~2 frames paying an O(roam-points) pick.
				if moveFailed and self._isAlive and self._currentTarget == nil then
					self:_setNavPhase("path-failed-backoff")
					task.wait(0.3 + math.random() * 0.2)
				end

				task.wait()
			end

			previousState = currentState
		end

		if alignOrientation then
			alignOrientation.Enabled = false
		end
	end)
end

function BotAI:Stop()
	self._isAlive = false
	if self._navigator then
		self._navigator:Stop()
		self._navigator = nil
	end
	self._stuckDetector = nil
	-- Apagar los dos AlignOrientation AHORA, no en la siguiente iteración del FSM (con el
	-- ragdoll ya montado): viven bajo el Model, así que destroyJoints(root) del kill effect
	-- no los toca y el de verticalidad seguiría activo durante el cadáver.
	local align = self._alignOrientation
	if align then
		align.Enabled = false
		self._alignOrientation = nil
	end
	local upright = self._uprightConstraint
	if upright then
		upright.Enabled = false
		self._uprightConstraint = nil
	end
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)

	self._currentTarget = nil
	self._currentTargetRoot = nil
	self._currentTargetHum = nil
	self._currentTargetPlayer = nil
	self._forcedTarget = nil
	self._forcedTargetHum = nil
	self._forcedTargetRoot = nil
	table.clear(self._targetCandidates)

	local humanoid = self._humanoid
	if humanoid then
		humanoid:Move(Vector3.zero, false)
		humanoid.AutoRotate = true
		humanoid.Jump = false

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				track:Stop(0.1)
			end
		end
		local animTracks = self._animTracks
		if animTracks then
			for _, track in animTracks do
				pcall(function()
					track:Stop(0.1)
					track:Destroy()
				end)
			end
			table.clear(animTracks)
			self._animTracks = nil
		end
	end
end

return BotAI
