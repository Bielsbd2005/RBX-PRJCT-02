--!strict
-- BotAI: loop completo de comportamiento para un bot individual.
-- Se instancia por bot desde AIService. Portado del EJEMPLO/AI.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)
local BotConfig = require(Shared.constants.BotConfig)

local Navigator = require(script.Parent:WaitForChild("nav"):WaitForChild("Navigator"))
local StuckDetector = require(script.Parent:WaitForChild("nav"):WaitForChild("StuckDetector"))
local RoamGraph = require(script.Parent:WaitForChild("nav"):WaitForChild("RoamGraph"))
local BotAppearance = require(script.Parent:WaitForChild("BotAppearance"))

-- B4: tipo compartido con AIService. La tabla _aliveTargets es la misma
-- instancia (pasada por ref en Start), solo cambia su shape: { Model } →
-- { AliveTarget } con hum + root pre-resueltos.
type AliveTarget = {
	model: Model,
	hum: Humanoid?,
	root: BasePart?,
}
local NavMetrics = require(script.Parent:WaitForChild("telemetry"):WaitForChild("NavMetrics"))
local RaycastViz = require(script.Parent:WaitForChild("debug"):WaitForChild("RaycastViz"))
local DetectRangeViz = require(script.Parent:WaitForChild("debug"):WaitForChild("DetectRangeViz"))

local WEAPON_TAG = "WeaponsSystemWeapon"

local _weaponDataRemote: RemoteEvent? = nil
local _weaponFiredRemote: RemoteEvent? = nil
do
	local wsFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
	if wsFolder then
		local remote = wsFolder:FindFirstChild("WeaponData")
		if remote and remote:IsA("RemoteEvent") then
			_weaponDataRemote = remote
		end
	end
end

-- Cache del template AR-NPC. Antes ReplicatedStorage:FindFirstChild por
-- cada spawn (16 bots × respawn-rate). Lookup en root es barato pero el
-- cache deja el path de spawn limpio.
local _weaponTemplate: Tool? = nil
local function _getWeaponTemplate(): Tool?
	if _weaponTemplate and _weaponTemplate.Parent then
		return _weaponTemplate
	end
	local tpl = ReplicatedStorage:FindFirstChild("AR-NPC")
	if tpl and tpl:IsA("Tool") then
		_weaponTemplate = tpl
		return tpl
	end
	return nil
end

-- Audit: rango efectivo del visual de bala para clientes. Más allá, la
-- bala nunca se renderiza (sale del view o es demasiado pequeña). Filtra
-- el firedRemote por distancia para evitar broadcast inútil a móviles —
-- con 16 bots × 10Hz, FireAllClients enviaba ~160 events/seg × N clientes.
local BULLET_AUDIBLE_RANGE = 200
local BULLET_AUDIBLE_RANGE2 = BULLET_AUDIBLE_RANGE * BULLET_AUDIBLE_RANGE

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

-- ────────────────────────────────────────────────────────────────
-- Configuracion por instancia
-- ────────────────────────────────────────────────────────────────

local AGENT_PARAMS = {
	AgentRadius = BotConfig.Pathfinding.AgentRadius,
	AgentHeight = BotConfig.Pathfinding.AgentHeight,
	AgentCanJump = BotConfig.Pathfinding.AgentCanJump,
	AgentJumpHeight = BotConfig.Movement.JumpHeight,
	AgentMaxSlope = BotConfig.Pathfinding.AgentMaxSlope,
	WaypointSpacing = BotConfig.Pathfinding.WaypointSpacing,
}

local ANIM_IDS = {
	Idle = "rbxassetid://507766388",
	Run = "rbxassetid://507767714",
	Jump = "rbxassetid://507768704",
	ToolHold = "rbxassetid://80449761976468",
}

-- B5 (partial): Animation instances cacheadas a nivel módulo. Antes 4×
-- Instance.new("Animation") + Destroy por spawn (≈1.6 spawns/seg en steady
-- state → 6.4 alloc+free/seg). El asset queda warm-cacheado tras el primer
-- LoadAnimation, así que respawn subsiguientes resuelven sin yield de descarga.
-- Full rig pool (reutilizar Model/Tool entre vidas) queda fuera de scope:
-- requiere refactor del lifecycle de Stop()/Destroy()/death effects/network
-- ownership y reset robusto de estado por respawn — alto riesgo, ganancia
-- comparable solo a las micro-spikes ya cubiertas por esta cache.
local _animationCache: { [string]: Animation } = {}
local function _getCachedAnimation(id: string): Animation
	local existing = _animationCache[id]
	if existing then return existing end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	-- Parented a nil — vive en memoria, no necesita estar en el DataModel.
	_animationCache[id] = anim
	return anim
end

-- FOV cone cacheado a nivel de módulo. FOVDegrees es constante en runtime,
-- así que evitamos re-calcularlo por candidate evaluation.
local FOV_COS = math.cos(math.rad(BotConfig.Combat.FOVDegrees / 2))

local STATES = {
	PATROL = "PATROL",
	CHASE = "CHASE",
	ATTACK = "ATTACK",
}

-- ────────────────────────────────────────────────────────────────
-- BotAI
-- ────────────────────────────────────────────────────────────────

local BotAI = {}
BotAI.__index = BotAI

export type BotAIInstance = typeof(setmetatable({} :: {
	_dummy: Model,
	_humanoid: Humanoid,
	_rootPart: BasePart,
	_team: string,
	_fakeUserId: number,
	_isAlive: boolean,
	_mapRoot: Instance?,
	_connections: { RBXScriptConnection },
	_nextShotId: number,
	_aliveTargets: { AliveTarget },
	-- B6: dict compartido FakeUserId → Model (mantenido por AIService).
	_botModelByFakeUserId: { [number]: Model }?,
	_raycastParams: RaycastParams?,
	_currentTarget: Model?,
	_currentTargetRoot: BasePart?,
	_currentTargetPos: Vector3,
	-- B3: cache del Player real del current target (nil si es bot). Antes
	-- Players:GetPlayerFromCharacter por shot (4/seg/bot vs player) — ahora
	-- 1 lookup por re-target (10Hz).
	_currentTargetPlayer: Player?,
	_isCurrentTargetVisible: boolean,
	_targetGraceUntil: number,
	_forcedTarget: Model?,
	_forcedUntil: number,
	-- PR1.5: feel polish
	_fireReadyAt: number,
	_combatCycleEndAt: number,
	_combatMoveDir: Vector3,
	-- Buffer reusado por _getBestTarget. Sin esto, cada tick (10Hz × 16 bots)
	-- alloca una tabla nueva → 160 tablas/seg de basura para gc.
	_targetCandidates: { { char: Model, d: number } },
	-- Tool cacheado en _setupTool. Antes FindFirstChildOfClass + FindFirstChild
	-- recursivo por disparo (10/seg × 16 bots).
	_tool: Tool?,
	_tipAttachment: Attachment?,
	-- Wrap del arma asignado por AIService desde la BotIdentity. Aplicado
	-- una vez al clonar el tool en _setupTool. nil = textura por defecto del
	-- template AR-NPC (sin override).
	_wrapId: string?,
	-- Última CFrame aplicada a AlignOrientation. Permite skip de escritura si
	-- el target no se movió >0.5 stud (~480 escrituras/seg evitadas).
	_lastAimPos: Vector3,
	-- Sprint 4: pathfinding y walk loop encapsulados en Navigator.
	_navigator: Navigator.Navigator?,
	_stuckDetector: StuckDetector.StuckDetector?,
	_roamGraph: RoamGraph.RoamGraph?,
	-- Tracks cargados por _setupAnimations. Stop los Stop+Destroy para
	-- evitar zombis durante los 5s del ragdoll cleanup.
	_animTracks: { [string]: AnimationTrack }?,
}, BotAI))

function BotAI.new(botModel: Model, team: "A" | "B", fakeUserId: number?, wrapId: string?): BotAIInstance
	local humanoid = botModel:FindFirstChildOfClass("Humanoid") :: Humanoid
	local rootPart = botModel:FindFirstChild("HumanoidRootPart") :: BasePart

	local self = setmetatable({
		_dummy = botModel,
		_humanoid = humanoid,
		_rootPart = rootPart,
		_team = team,
		_fakeUserId = fakeUserId or 0,
		_isAlive = true,
		_mapRoot = nil :: Instance?,
		_connections = {} :: { RBXScriptConnection },
		_nextShotId = 1,
		_aliveTargets = {},
		_botModelByFakeUserId = nil,
		_raycastParams = nil,
		_currentTarget = nil,
		_currentTargetPlayer = nil,
		_currentTargetRoot = nil,
		_currentTargetPos = Vector3.zero,
		_isCurrentTargetVisible = false,
		_targetGraceUntil = 0,
		_forcedTarget = nil,
		_forcedUntil = 0,
		_fireReadyAt = 0,
		_combatCycleEndAt = 0,
		_combatMoveDir = Vector3.zero,
		_targetCandidates = {},
		_tool = nil,
		_tipAttachment = nil,
		_wrapId = wrapId,
		_lastAimPos = Vector3.zero,
		_navigator = nil,
		_stuckDetector = nil,
		_roamGraph = nil,
		_animTracks = nil,
	}, BotAI) :: BotAIInstance

	return self
end

function BotAI:_setupNetworkOwnership()
	local ok = pcall(function()
		(self._rootPart :: any):SetNetworkOwner(nil)
	end)
	if not ok then
		warn("[BotAI] SetNetworkOwner falló en " .. self._dummy.Name)
	end
end

function BotAI:_setupTool()
	local toolTemplate = _getWeaponTemplate()
	if not toolTemplate then
		-- Bug invisible que dejaba al bot vivo y caminando sin disparar nunca.
		-- Sin warn no había forma de notarlo salvo observando que ningún bot
		-- de un round tiraba balas. Falla ruidosamente.
		warn(string.format(
			"[BotAI] %s sin arma: ReplicatedStorage.AR-NPC no encontrado o no es Tool. El bot no disparará.",
			self._dummy.Name
		))
		return
	end
	local tool = toolTemplate:Clone()
	-- Apariencia visual: aplicar wrap antes de parentar el tool al rig.
	-- Silent-fails si AR-NPC.WeaponModel.PrimaryPart no existe — combat
	-- (TipAttachment + fallback) sigue funcionando.
	BotAppearance.applyWrapToTool(tool, self._wrapId)
	tool.Parent = self._dummy
	if not CollectionService:HasTag(tool, WEAPON_TAG) then
		CollectionService:AddTag(tool, WEAPON_TAG)
	end
	self._humanoid:EquipTool(tool)
	self._nextShotId = 1
	self._tool = tool
	-- Cachear TipAttachment una vez en lugar de FindFirstChild recursivo por
	-- shot (≈10/seg/bot × 16 bots = 160 lookups/seg).
	local tipAttach = tool:FindFirstChild("TipAttachment", true)
	if tipAttach and tipAttach:IsA("Attachment") then
		self._tipAttachment = tipAttach
	end
end

function BotAI:_setupAnimations(): { [string]: AnimationTrack }
	local tracks = {} :: { [string]: AnimationTrack }
	local animator = self._humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = self._humanoid
	end

	for name, id in ANIM_IDS do
		-- B5 (partial): instance compartida entre todos los bots. LoadAnimation
		-- crea un AnimationTrack nuevo por Animator (per-rig), pero el asset
		-- queda warm tras el primer load.
		local anim = _getCachedAnimation(id)
		local ok, track = pcall(function()
			return (animator :: Animator):LoadAnimation(anim)
		end)
		if ok then
			tracks[name] = track :: AnimationTrack
		end
	end

	if tracks.ToolHold then
		tracks.ToolHold.Priority = Enum.AnimationPriority.Action
		tracks.ToolHold.Looped = true
		tracks.ToolHold:Play()
	end

	-- Stop necesita la ref para Destroy explícito (GetPlayingAnimationTracks
	-- solo devuelve los en marcha; Run/Jump cuando el bot estaba en Idle se
	-- quedaban zombi en el Animator hasta destrucción del rig).
	self._animTracks = tracks

	return tracks
end

function BotAI:_setupRotationConstraint(): AlignOrientation?
	-- Reusar Attachment existente. Si refactorizás a model pool, evita
	-- duplicar RotationAttachment al respawnear sobre el mismo rootPart.
	local existing = self._rootPart:FindFirstChild("RotationAttachment")
	local attachment: Attachment
	if existing and existing:IsA("Attachment") then
		attachment = existing
	else
		attachment = Instance.new("Attachment")
		attachment.Name = "RotationAttachment"
		attachment.Parent = self._rootPart
	end

	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	-- Suave en lugar de rígido: cuando el target aparece o cambia de
	-- posición, el bot rota hacia él en ~0.3s en lugar de teleportar la
	-- orientación. Sprint 4 — antes RigidityEnabled=true hacía un giro
	-- brusco visible al detectar enemigo.
	align.RigidityEnabled = false
	align.MaxTorque = 1e6
	align.MaxAngularVelocity = 20
	align.Responsiveness = 30
	align.Enabled = false
	align.Parent = self._dummy

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

function BotAI:_canSeeTarget(target: Model): boolean
	local targetRoot = target:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return false
	end

	local origin = self._rootPart.Position + Vector3.new(0, 1.5, 0)
	local targetPos = (targetRoot :: BasePart).Position + Vector3.new(0, 1.5, 0)
	local direction = targetPos - origin

	if direction.Magnitude > BotConfig.Combat.DetectRange then
		return false
	end

	-- Audit fix P2: usa el RaycastParams cacheado en Start. Fallback defensive
	-- si _canSeeTarget se llamase antes de Start (no debería ocurrir).
	local params = self._raycastParams
	if not params then
		params = RaycastParams.new()
		params.FilterDescendantsInstances = { self._dummy }
		params.FilterType = Enum.RaycastFilterType.Exclude
	end

	local result = workspace:Raycast(origin, direction, params)
	local seesTarget = result ~= nil and result.Instance:IsDescendantOf(target)

	-- Visualización debug. No-op si workspace:GetAttribute("DebugBotRaycasts") no es true.
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

--[[
	Sprint 3: target selection en dos pasos.

	Antes: iterar workspace:GetChildren() + mapRoot/Bots por tick (60Hz × 8 bots
	= ~480 iteraciones/seg de cientos de instancias) y raycastear cada candidato
	cuya `d < minDist` (orden no determinista — múltiples raycasts en peleas
	clústerizadas).

	Ahora:
	  • La lista de candidatos viene pre-filtrada (`self._aliveTargets`,
	    actualizada por AIService vía signals).
	  • Pass 1: filtrar por equipo + distancia + salud, recolectando candidatos
	    válidos en un buffer junto con su distancia.
	  • Pass 2: ordenar por distancia ASC y raycastear desde el más cercano
	    con early-exit en cuanto haya LoS (típico = 1 raycast/llamada).
]]
function BotAI:_getBestTarget(): (Model?, boolean)
	local rootPos = self._rootPart.Position
	local myTeam = TeamUtils.normalize(self._team)
	local facing = self._rootPart.CFrame.LookVector

	-- Reusar buffer: clear es O(n) pero no alloca, y vacía la tabla para
	-- la próxima iter sin tirar la backing storage.
	local candidates = self._targetCandidates
	table.clear(candidates)

	-- Pass 1: filtrado liviano (sin raycast).
	-- PR1.5: incluye FOV check (dot product) antes de meter al candidate buffer.
	-- Retaliation NO pasa por aquí — _getForcedTarget tiene su propia ruta
	-- y bypassa el FOV (atacante por la espalda sigue triggereando).
	-- B4: hum/root pre-resueltos en la entry. Lazy-refresh si el ref murió
	-- (cubre el streaming de player chars: hum aparece después del Model).
	for _, entry in self._aliveTargets do
		local char = entry.model
		if char == self._dummy then continue end

		local hum = entry.hum
		if not hum or not hum.Parent then
			hum = char:FindFirstChildOfClass("Humanoid")
			entry.hum = hum
		end
		local root = entry.root
		if not root or not root.Parent then
			root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			entry.root = root
		end
		if not hum or not root or hum.Health <= 0 then continue end

		local charTeam = TeamUtils.getSide(char)
		if charTeam and myTeam and charTeam == myTeam then continue end

		-- Audit fix: skip targets en spawn protection. _canSeeTarget pasaría
		-- pero TakeDamage es no-op durante ForceField → bot dispara 2s a un
		-- target inmune. FindFirstChildOfClass es top-level (O(N) hijos del
		-- char, ~10-20).
		if char:FindFirstChildOfClass("ForceField") then continue end

		-- Reutilizamos delta para FOV (evita la alloc de .Unit). Magnitud y
		-- dirección comparten el mismo Vector3 → 1 alloc en lugar de 2.
		local delta = (root :: BasePart).Position - rootPos
		local d = delta.Magnitude
		if d > BotConfig.Combat.DetectRange then continue end

		-- FOV check: dot(facing, unit) = dot(facing, delta) / d. Si
		-- < cos(FOV/2), fuera de cono. Evita la alloc del Unit Vector.
		if d > 0.001 and facing:Dot(delta) / d < FOV_COS then continue end

		table.insert(candidates, { char = char, d = d })
	end

	if #candidates == 0 then
		return nil, false
	end

	-- Pass 2: ordenar por distancia, raycastear desde el más cercano con
	-- cap por iteración. Sin cap, un grupo de 5+ enemigos en cono con LOS
	-- bloqueada producía 5 raycasts × 16 bots × 10Hz = 800/seg en el peor
	-- caso. Los 3 más cercanos cubren el 99% de los engagements reales —
	-- si los 3 más cercanos no tienen LOS, ignorar a un 4º distante en
	-- este tick (volverá a evaluarse 100ms después con candidates frescos).
	table.sort(candidates, function(a, b) return a.d < b.d end)

	local maxChecks = math.min(#candidates, BotConfig.Combat.MaxLosChecksPerEval)
	for i = 1, maxChecks do
		local c = candidates[i]
		if self:_canSeeTarget(c.char) then
			return c.char, true
		end
	end

	return nil, false
end

-- Resolver el Model del atacante por su userId.
--   • userId > 0  → Player real → Player.Character
--   • userId < 0  → bot (fakeUserId) → lookup O(1) en el dict de AIService
--                   (mantenido por _spawnOneBot / Died handler).
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
	-- Fallback: scan lineal si el dict no está disponible (sin AIService).
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

-- Devuelve el forced target si todavía es válido (vivo, en rango ampliado,
-- timer no expirado, no es mi propio equipo). Si no, lo limpia y devuelve nil.
function BotAI:_getForcedTarget(): Model?
	local target = self._forcedTarget
	if not target then
		return nil
	end
	if os.clock() >= self._forcedUntil or not target.Parent then
		self._forcedTarget = nil
		return nil
	end
	local hum = target:FindFirstChildOfClass("Humanoid")
	local root = target:FindFirstChild("HumanoidRootPart")
	if not hum or (hum :: Humanoid).Health <= 0 or not root then
		self._forcedTarget = nil
		return nil
	end
	-- Filtro de equipo (defensive: friendly fire u otros mecanismos no
	-- deberían enganchar el forced target).
	local myTeam = TeamUtils.normalize(self._team)
	local theirTeam = TeamUtils.getSide(target)
	if theirTeam and myTeam and theirTeam == myTeam then
		self._forcedTarget = nil
		return nil
	end
	local d = (self._rootPart.Position - (root :: BasePart).Position).Magnitude
	if d > BotConfig.Combat.DetectRange + 20 then
		self._forcedTarget = nil
		return nil
	end
	return target
end

-- Sprint 4: evaluación de target desacoplada del bucle FSM. Antes el FSM
-- llamaba _getBestTarget al inicio de cada iteración, pero durante PATROL
-- el bucle estaba bloqueado en _moveToLocation hasta llegar al destino —
-- el bot tardaba hasta 3s en detectar un enemigo apareciendo en su esfera.
-- Ahora se llama desde un coroutine paralelo a 10Hz (BotAI:Start) que
-- actualiza self._currentTarget en background. La stopCondition del walk
-- loop ve el cambio al instante.
function BotAI:_evaluateTarget(now: number)
	-- Audit fix C1: guard contra ejecución post-Stop. Aunque el while del
	-- coroutine paralelo re-evalúa isAlive entre iteraciones, este guard
	-- elimina cualquier ventana posible si Stop se llama mientras la
	-- iteración del body ya ha comenzado (no debería ocurrir en runtime
	-- single-thread cooperativo, pero defensive).
	if not self._isAlive then
		return
	end
	local potentialTarget: Model?
	local isVisible: boolean
	local forced = self:_getForcedTarget()
	if forced then
		potentialTarget = forced
		isVisible = self:_canSeeTarget(forced)
	else
		-- Audit fix P5: fast path para engagement estable. Si el target
		-- actual sigue válido (vivo, en rango, en FOV) y mantiene LOS,
		-- saltamos Pass 1 + Pass 2 + sort. Evita iteración sobre
		-- _aliveTargets cuando el bot está concentrado en un enemigo.
		-- Behavior change deseable: el bot NO cambia de target a uno
		-- más cercano mid-combat (los players reales tampoco lo hacen).
		-- Si pierde LOS o el target sale de rango/FOV, fallback al
		-- _getBestTarget normal.
		local current = self._currentTarget
		local fastPath = false
		if current and current.Parent then
			local hum = current:FindFirstChildOfClass("Humanoid")
			local root = current:FindFirstChild("HumanoidRootPart")
			if hum and (hum :: Humanoid).Health > 0 and root then
				local toRoot = (root :: BasePart).Position - self._rootPart.Position
				local d = toRoot.Magnitude
				if d <= BotConfig.Combat.DetectRange then
					local facing = self._rootPart.CFrame.LookVector
					-- dot(facing, unit) = dot(facing, toRoot) / d. Evita
					-- alloc de toRoot.Unit (1 Vector3 por fast-path eval).
					if d > 0.001 and facing:Dot(toRoot) / d >= FOV_COS then
						if self:_canSeeTarget(current) then
							potentialTarget = current
							isVisible = true
							fastPath = true
						end
					end
				end
			end
		end
		if not fastPath then
			potentialTarget, isVisible = self:_getBestTarget()
		end
	end

	-- Target grace de 3s post-LOS: si vimos al enemigo hace <3s pero ahora
	-- no tiene LOS (jugador se metió detrás de cobertura), mantenemos el
	-- target y forzamos isVisible=false → el FSM cae a CHASE y persigue
	-- vía Navigator hasta recuperar LOS o expirar grace.
	if potentialTarget and isVisible then
		self._targetGraceUntil = now + 3
	elseif not potentialTarget and self._currentTarget and now < self._targetGraceUntil then
		local prev = self._currentTarget
		local prevHum = prev:FindFirstChildOfClass("Humanoid")
		local prevRoot = prev:FindFirstChild("HumanoidRootPart")
		if prev.Parent
			and prevHum and (prevHum :: Humanoid).Health > 0
			and prevRoot then
			local d = (self._rootPart.Position - (prevRoot :: BasePart).Position).Magnitude
			if d <= BotConfig.Combat.DetectRange + 15 then
				potentialTarget = prev
				isVisible = false
			end
		end
	end

	-- PR1.5: reaction delay en transición isVisible false→true (target acquisition).
	-- Bloquea el primer disparo durante 150-350ms — feel humano vs aimbot instantáneo.
	-- Tracking continuo no re-arma el timer (target ya visible no afecta).
	local prevVisible = self._isCurrentTargetVisible
	if isVisible and not prevVisible then
		local lo = BotConfig.Combat.ReactionDelayMin
		local hi = BotConfig.Combat.ReactionDelayMax
		self._fireReadyAt = now + lo + math.random() * (hi - lo)
	end

	-- Caché de root + posición: el FSM loop (60Hz) los consume sin volver a
	-- llamar FindFirstChild. Ahorra ~480 lookups/seg con 8 bots en ATTACK/CHASE.
	self._currentTarget = potentialTarget
	self._isCurrentTargetVisible = isVisible
	if potentialTarget then
		local targetRoot = potentialTarget:FindFirstChild("HumanoidRootPart")
		if targetRoot and targetRoot:IsA("BasePart") then
			self._currentTargetRoot = targetRoot
			self._currentTargetPos = (targetRoot :: BasePart).Position
		else
			self._currentTargetRoot = nil
		end
		-- B3: resolve Player una vez por re-target. nil si el target es bot
		-- (tienen FakeUserId attribute → no son players reales).
		if potentialTarget:GetAttribute("FakeUserId") == nil then
			self._currentTargetPlayer = Players:GetPlayerFromCharacter(potentialTarget)
		else
			self._currentTargetPlayer = nil
		end
	else
		self._currentTargetRoot = nil
		self._currentTargetPlayer = nil
	end
end

-- Sprint 4: la lógica de walking + throttle + MoveToFinished vive ahora en
-- Navigator. Este helper queda como wrapper bloqueante para que el bloque
-- PATROL del coroutine pueda esperar a la llegada (o a que la stopCondition
-- detecte un target apareciendo).
function BotAI:_moveToLocation(location: Vector3, stopCondition: () -> boolean)
	local navigator = self._navigator
	if not navigator then
		return
	end

	local done = false
	navigator:goTo(location, {
		onArrived = function()
			done = true
		end,
		onFailed = function()
			-- Tratar fallo de path igual que arrival: el caller pide otro destino.
			done = true
		end,
	})

	while not done and not stopCondition() do
		task.wait()
	end

	if stopCondition() and navigator:isMoving() then
		navigator:cancel()
	end
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
	-- B6: dict compartido por AIService. nil para tests / sin AIService.
	self._botModelByFakeUserId = botModelByFakeUserId
	self:_setupNetworkOwnership()
	self:_setupTool()

	local humanoid = self._humanoid
	local rootPart = self._rootPart

	-- Audit fix P2: cachear RaycastParams una vez. _canSeeTarget se llama
	-- ~160 veces/seg (10Hz × bots × candidates) y reconstruir la tabla
	-- + setter de FilterType en cada call es allocation evitable.
	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = { self._dummy }
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self._raycastParams = raycastParams

	-- Sprint 4: Navigator encapsula Path + walk loop + throttle + MoveToFinished.
	-- Las llamadas a ComputeAsync ahora pasan por la PathfindingQueue global.
	self._navigator = Navigator.new(humanoid, rootPart, AGENT_PARAMS)

	-- Debug: esfera de DetectRange (visible solo si workspace:GetAttribute
	-- "DebugBotDetectRange" == true). Adornment parentado al rootPart →
	-- se destruye con el modelo al morir el bot. La connection se limpia
	-- en Stop vía _connections.
	local _, connDetectViz = DetectRangeViz.attach(rootPart, BotConfig.Combat.DetectRange)
	table.insert(self._connections, connDetectViz)

	-- Sprint 4: StuckDetector. Tick a 10Hz desde una task.spawn paralela —
	-- así detectamos stuck también durante PATROL (donde el loop principal
	-- está bloqueado en _moveToLocation esperando arrival). RoamGraph
	-- aporta nearestPoint() para el teleport del nivel 4.
	self._stuckDetector = StuckDetector.new(
		rootPart,
		humanoid,
		self._navigator :: any,
		self._roamGraph :: any,
		NavMetrics,
		self._dummy.Name,
		if mapRoot then mapRoot.Name else "?"
	)
	task.spawn(function()
		while self._isAlive and humanoid.Health > 0 do
			if self._stuckDetector then
				self._stuckDetector:tick(os.clock())
			end
			task.wait(0.1)
		end
	end)

	-- Sprint 4: tick paralelo de detección de target a 10Hz. Desacoplado del
	-- bucle FSM principal — durante PATROL este coroutine sigue corriendo
	-- aunque el FSM esté bloqueado en _moveToLocation, y actualiza
	-- self._currentTarget. La stopCondition del walk loop lo ve al instante.
	-- 100ms es invisible al jugador (reacción humana ~200ms) y reduce
	-- raycasts ~6× vs un tick a 60Hz.
	task.spawn(function()
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
	local lastJumpTime = 0
	-- Throttle de CHASE-visible MoveTo: reemitir cuando target se mueva
	-- >2 studs respecto al último MoveTo, O cada 3s para evitar el timeout
	-- interno de 8s de Roblox. Si el target orbita al bot manteniéndose
	-- <2 studs del último MoveTo, el delta nunca refresca y el bot se
	-- queda quieto a los 8s con LOS activa.
	local lastDirectMoveTarget = Vector3.zero
	local lastDirectMoveAt = 0

	-- Animaciones reactivas
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

	-- Sprint 4: react-when-shot. Cuando alguien hace daño al bot, el shooter
	-- stampa LastAttackerAt en este humanoid (sistema ya existente para kill
	-- attribution). Suscribirse al cambio nos da un trigger fiable de "me
	-- están disparando" sin polling. El bot fija al atacante como
	-- _forcedTarget durante 4s — AlignOrientation lo gira hacia él y el
	-- estado pasa a ATTACK/CHASE según haya LOS.
	local connDamage = humanoid:GetAttributeChangedSignal("LastAttackerAt"):Connect(function()
		local attackerUserId = humanoid:GetAttribute("LastAttackerUserId")
		if type(attackerUserId) ~= "number" then return end
		if attackerUserId == self._fakeUserId then return end -- self-damage
		local attackerModel = _findAttackerModel(attackerUserId, self._aliveTargets, self._dummy, self._botModelByFakeUserId)
		if attackerModel and attackerModel ~= self._dummy then
			self._forcedTarget = attackerModel
			self._forcedUntil = os.clock() + 4
		end
	end)
	table.insert(self._connections, connDamage)

	-- Sprint 4: MoveToFinished se maneja dentro de Navigator (una sola conexión
	-- por bot, igual que antes — solo cambia el owner del listener).

	-- Sprint 3: Heartbeat eliminado.
	-- Antes hacía dos cosas:
	--   (a) regen — REGEN_RATE = 0, era no-op caro.
	--   (b) rotation — duplicaba el _getBestTarget que el coroutine ya hacía,
	--       a 60Hz contra los 10Hz del coroutine.
	-- Ahora la rotación se aplica desde el coroutine principal cada tick
	-- usando self._currentTarget (cacheado).

	-- Bucle principal en coroutine independiente
	task.spawn(function()
		local currentState = STATES.PATROL
		-- B2: tracking de la última dir aplicada via humanoid:Move. Evita
		-- N×60 escrituras/seg al MoveDirection cuando combatMoveDir no cambia
		-- (los ciclos pause/step duran 300-1400ms). Sentinel inicial distinto
		-- de Vector3.zero para forzar el primer Move.
		local lastAppliedMoveDir: Vector3 = Vector3.new(math.huge, 0, 0)
		local previousState: string = STATES.PATROL

		while self._isAlive and humanoid.Health > 0 do
			-- Sprint 4: lee del cache que mantiene el coroutine de detección
			-- paralelo (10Hz). No re-evalúa aquí — antes lo hacía a 60Hz
			-- pero quedaba bloqueado durante PATROL, causando hasta 3s de
			-- delay en detectar enemigos que entraban en rango mid-walk.
			local potentialTarget = self._currentTarget
			local isVisible = self._isCurrentTargetVisible
			local targetRoot = self._currentTargetRoot
			-- Audit: leer posición live del HRP cuando el root sigue parented.
			-- Antes usábamos `_currentTargetPos` (cacheada por el evaluator a
			-- 10Hz) en la FSM a 20Hz → hasta 100ms de stale → aim de
			-- AlignOrientation + shoot dir + MoveTo apuntaban a posición vieja
			-- con targets moviéndose rápido. Fallback al cache si el root cae.
			local targetPos = if targetRoot and targetRoot.Parent
				then targetRoot.Position
				else self._currentTargetPos

			-- Aplicar rotación al target cacheado (movido desde el Heartbeat).
			-- Cuando AlignOrientation está activo, AutoRotate del humanoid debe
			-- estar OFF — si no compiten por la orientación y se ve jitter.
			-- Audit P1: skip de CFrame write si el target no se movió >0.5 stud.
			-- Antes 480 escrituras/seg al constraint solver; ahora ~10/seg per
			-- bot con target estático.
			if alignOrientation then
				if potentialTarget and targetRoot then
					if (targetPos - self._lastAimPos).Magnitude > 0.5 then
						local lookPos = Vector3.new(targetPos.X, rootPart.Position.Y, targetPos.Z)
						alignOrientation.CFrame = CFrame.lookAt(rootPart.Position, lookPos)
						self._lastAimPos = targetPos
					end
					alignOrientation.Enabled = true
					humanoid.AutoRotate = false
				else
					alignOrientation.Enabled = false
					humanoid.AutoRotate = true
				end
			end

			local currentTarget: Model? = potentialTarget
			if potentialTarget and targetRoot then
				-- ATTACK siempre que haya LOS — un jugador real dispara apenas
				-- ve al enemigo, sin importar el rango (la precisión del arma
				-- se encarga del realismo). Sin LOS (grace), CHASE: persigue
				-- la posición LIVE vía Navigator y dispara cuando recupere LOS.
				if isVisible then
					currentState = STATES.ATTACK
				else
					currentState = STATES.CHASE
				end
			else
				currentState = STATES.PATROL
				-- AutoRotate ya quedó en true por el bloque AlignOrientation
				-- de arriba cuando no hay target.
			end

			-- Audit P1: discriminar player/bot por atributo FakeUserId (O(1))
			-- en lugar de Players:GetPlayerFromCharacter (lookup en tabla
			-- interna). Se necesita para JumpChance, DamageMin/Max y víctima
			-- de HitByOtherPlayer, así que se computa una sola vez por iter.
			local isPlayer = false
			if currentTarget then
				isPlayer = currentTarget:GetAttribute("FakeUserId") == nil
			end
			local profile = if isPlayer then BotConfig.Combat.VsPlayer else BotConfig.Combat.VsBot

			-- ── ATTACK ──────────────────────────────────────────────
			if currentState == STATES.ATTACK and currentTarget and targetRoot then
				-- Sprint 4: cancelar Navigator si seguía caminando — el strafing
				-- (humanoid:Move) entra en conflicto con MoveTo del walk loop.
				if self._navigator and self._navigator:isMoving() then
					self._navigator:cancel()
				end
				-- AutoRotate ya quedó en false por el bloque AlignOrientation
				-- de arriba cuando hay target.

				-- PR1.5: combat micro-movement (override de "Engage estático" v4).
				-- Ciclos no-rítmicos pause/step (60/40 split). Cada ciclo es
				-- una "decisión" random, sin patrón mecánico. AlignOrientation
				-- sigue manteniendo el cuerpo apuntando al target durante el step.
				local now = os.clock()
				if now >= self._combatCycleEndAt then
					if math.random() < BotConfig.Combat.CombatPauseChance then
						-- Pause cycle: bot quieto, "aiming/decision pause"
						self._combatMoveDir = Vector3.zero
						local lo = BotConfig.Combat.CombatPauseMin
						local hi = BotConfig.Combat.CombatPauseMax
						self._combatCycleEndAt = now + lo + math.random() * (hi - lo)
					else
						-- Step cycle: dirección lateral decisiva (no wobble cerca
						-- de zero), ocasional charge/retreat (30% de pasos).
						-- Antes `lateral = (math.random()-0.5)*2` daba valores
						-- como -0.1 o 0.7 → bot parecía indeciso. Ahora signo
						-- explícito 50/50 con magnitud comprometida.
						local toTarget = targetPos - rootPart.Position
						local right = toTarget:Cross(Vector3.new(0, 1, 0))
						if right.Magnitude > 0.01 then
							right = right.Unit
							local lateralSign = if math.random() < 0.5 then -1 else 1
							local lateral = lateralSign * (0.7 + math.random() * 0.3)
							-- 20% de los pasos incluyen componente forward/back leve
							-- (cargar al target o retroceder). Resto: orbita pura.
							local forward = 0
							if math.random() < 0.2 then
								local forwardSign = if math.random() < 0.5 then -1 else 1
								forward = forwardSign * (0.25 + math.random() * 0.25)
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
						local lo = BotConfig.Combat.CombatStepMin
						local hi = BotConfig.Combat.CombatStepMax
						self._combatCycleEndAt = now + lo + math.random() * (hi - lo)
					end
				end
				-- B2: Move solo cuando cambió la dir o entramos a ATTACK desde
				-- otro estado (la pierna anterior pudo dejar MoveDirection no-zero
				-- via MoveTo). Humanoid retiene MoveDirection entre frames.
				local enteredAttack = previousState ~= STATES.ATTACK
				if enteredAttack or self._combatMoveDir ~= lastAppliedMoveDir then
					humanoid:Move(self._combatMoveDir, false)
					lastAppliedMoveDir = self._combatMoveDir
				end

				-- Jump aleatorio (PR1.5: anula la "jump eliminado" de v4).
				-- Gate por lastJumpTime + intervalo random 2-5s, probabilidad
				-- por profile (VsPlayer=0.03, VsBot=0.4).
				if os.clock() - lastJumpTime > math.random(20, 50) / 10 then
					if math.random() < profile.JumpChance then
						humanoid.Jump = true
					end
					lastJumpTime = os.clock()
				end

				local fireRate = BotConfig.Combat.FireRate
				local precision = BotConfig.Combat.Precision

				-- PR1.5: fire block reescrito.
				-- - Gate adicional: reaction delay (self._fireReadyAt) bloquea
				--   primer disparo durante 150-350ms tras acquisition.
				-- - WeaponFired remote firea SIEMPRE (no solo en hits). Misses
				--   tienen spread angular 3-8° → bala visiblemente pasa al lado.
				-- - Damage + directional indicator SOLO en hits.
				if os.clock() - lastShotTime > fireRate
					and isVisible
					and os.clock() >= self._fireReadyAt then
					lastShotTime = os.clock()

					local hit = math.random(1, 100) <= precision
					local weapon = self._tool
					local firedRemote = _getWeaponFiredRemote()

					-- Visual del disparo (siempre, hit o miss):
					if weapon and firedRemote then
						-- Audit P1: TipAttachment cacheado en _setupTool. Evita
						-- FindFirstChild recursivo por shot (10/seg/bot).
						local tipAttach = self._tipAttachment
						local origin: Vector3
						if tipAttach and tipAttach.Parent then
							origin = tipAttach.WorldPosition
						else
							origin = rootPart.Position + Vector3.new(0, 1.5, 0)
						end
						local trueDir = (targetPos - origin).Unit
						local dir = trueDir
						if not hit then
							-- Spread angular random 3-8° en eje aleatorio.
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
						-- Audit: FireClient selectivo por distancia en lugar de
						-- FireAllClients. Con 16 bots × 10Hz = 160 events/seg,
						-- móviles low-end pierden frames decodificando bullets
						-- fuera de su rango visual. Filtramos por char dentro
						-- de BULLET_AUDIBLE_RANGE del origen del shot.
						for _, p in Players:GetPlayers() do
							local pChar = p.Character
							if pChar then
								local pRoot = pChar.PrimaryPart or pChar:FindFirstChild("HumanoidRootPart")
								if pRoot and pRoot:IsA("BasePart") then
									local delta = origin - pRoot.Position
									if delta:Dot(delta) < BULLET_AUDIBLE_RANGE2 then
										firedRemote:FireClient(p, nil, weapon, fireInfo)
									end
								end
							end
						end
					end

					-- Damage + kill attribution + directional indicator: solo en hits.
					if hit then
						local targetHum = currentTarget:FindFirstChildOfClass("Humanoid")
						if targetHum and (targetHum :: Humanoid).Health > 0 then
							local dmg = math.random(profile.DamageMin, profile.DamageMax)

							;(targetHum :: Humanoid):SetAttribute("LastAttackerUserId", self._fakeUserId)
							;(targetHum :: Humanoid):SetAttribute("LastAttackerAt", time())
							;(targetHum :: Humanoid):SetAttribute("LastAttackerWeaponId", if weapon then weapon.Name else "NPC")

							;(targetHum :: Humanoid):TakeDamage(dmg)

							if isPlayer and _weaponDataRemote then
								-- B3: usar el player cacheado en _evaluateTarget (10Hz)
								-- en lugar de GetPlayerFromCharacter por shot.
								local victimPlayer = self._currentTargetPlayer
								if victimPlayer then
									_weaponDataRemote:FireClient(victimPlayer, "HitByOtherPlayer", rootPart.Position)
								end
							end
						end
					end
				end

				-- B1: 20Hz. La detección de target corre en un coroutine
				-- separado a 10Hz (no en este loop). AlignOrientation tiene
				-- Responsiveness=30 e interpola al 60Hz físico aunque
				-- escribamos CFrame a 20Hz. Fire gate (FireRate=0.1s) sufre
				-- ~50ms de quantización worst-case (~10% más lento avg).
				task.wait(0.05)

			-- ── CHASE ───────────────────────────────────────────────
			elseif currentState == STATES.CHASE and currentTarget and targetRoot then
				-- AutoRotate ya está OFF desde el bloque AlignOrientation arriba
				-- (hay target). Mantenemos AlignOrientation como única fuente
				-- de orientación.
				-- Sprint 4: con LOS vamos en línea recta (MoveTo directo) sin
				-- pathfinding — más barato y reactivo. Sin LOS, Navigator
				-- computa path con throttle interno (1s + target-moved-5-studs).
				if isVisible then
					if self._navigator and self._navigator:isMoving() then
						self._navigator:cancel()
					end
					-- Throttle: reemitir MoveTo cuando target se haya movido
					-- >2 studs, O cada 3s. El time-gate evita el timeout interno
					-- de 8s de Roblox cuando un target orbita el bot a sub-2
					-- studs del último MoveTo.
					local nowMv = os.clock()
					if (targetPos - lastDirectMoveTarget).Magnitude > 2
						or nowMv - lastDirectMoveAt > 3 then
						humanoid:MoveTo(targetPos)
						lastDirectMoveTarget = targetPos
						lastDirectMoveAt = nowMv
					end
					-- Audit P0: gate por tiempo + JumpChance del profile. Antes
					-- `if math.random() < 0.05` por frame (60Hz) → ~3 jumps/seg
					-- mientras perseguía con LOS = bot bunny-hopping. Mismo
					-- gate que ATTACK: intervalo random 2-5s y profile.JumpChance.
					if os.clock() - lastJumpTime > math.random(20, 50) / 10 then
						if math.random() < profile.JumpChance then
							humanoid.Jump = true
						end
						lastJumpTime = os.clock()
					end
				else
					if self._navigator then
						self._navigator:goTo(targetPos)
					end
					-- Reset al salir de CHASE-visible: evita que el throttle de
					-- >2 studs omita el primer MoveTo cuando el bot recupere
					-- LOS cerca de la última pos. lastDirectMoveAt=0 fuerza
					-- también el primer refresh por time-gate.
					lastDirectMoveTarget = Vector3.zero
					lastDirectMoveAt = 0
				end

				-- B1: 20Hz. La detección live de target ya está en coroutine
				-- separado; aquí solo hay gates baratos (MoveTo throttled por
				-- 2 studs, jump por intervalo 2-5s).
				task.wait(0.05)

			-- ── PATROL ──────────────────────────────────────────────
			else
				-- Sprint 4: pool plano de RoamGraph en vez de Waypoints/ ordenado.
				-- pickRandomNavigablePoint devuelve random uniforme dentro de
				-- [RoamMinDist, RoamMaxDist] con relax de 4 niveles si el anillo
				-- queda vacío. Sin pool (RoamGraph nil), cae al WanderRadius
				-- legado como safety net mínima.
				local dest: Vector3?

				if self._roamGraph then
					dest = self._roamGraph:pickRandomNavigablePoint(
						rootPart.Position,
						BotConfig.Navigation.RoamMinDist,
						BotConfig.Navigation.RoamMaxDist
					)
				end

				if not dest then
					local randomVec = Vector3.new(
						math.random(-BotConfig.Movement.WanderRadius, BotConfig.Movement.WanderRadius),
						0,
						math.random(-BotConfig.Movement.WanderRadius, BotConfig.Movement.WanderRadius)
					)
					dest = rootPart.Position + randomVec
				end

				-- Cluster jitter: ±4 studs random en XZ. Dos bots que eligen
				-- el mismo punto del pool acaban yendo a posiciones algo
				-- distintas → menos colisiones y "el mismo camino todos".
				-- Idéntico al offset que el código pre-refactor aplicaba
				-- sobre Waypoints/.
				dest = (dest :: Vector3) + Vector3.new(math.random(-4, 4), 0, math.random(-4, 4))

				NavMetrics.record("roam_pick_count", { bot = self._dummy.Name })

				-- Sprint 3: stopCondition reusa la cache de target en lugar de
				-- ejecutar _getBestTarget en cada `task.wait()` interno (varios
				-- raycasts/seg por bot solo en patrullaje).
				self:_moveToLocation(dest :: Vector3, function()
					return self._currentTarget ~= nil or not self._isAlive
				end)

				-- Sin idle entre arrivals: bots siempre en marcha (constant
				-- velocity like real players).

				task.wait()
			end

			previousState = currentState
		end

		-- Audit fix C2: cleanup vive en BotAI:Stop. Aquí solo dejamos el
		-- AlignOrientation deshabilitado para que el cuerpo no se quede
		-- apuntando a un target obsoleto si el coroutine sale por
		-- Health<=0 sin que Stop se haya llamado todavía (race window).
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
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)

	-- Audit P0: liberar refs a Models para que el gc pueda recoger al target
	-- durante los 5s de ragdoll. Sin esto, el BotAIInstance (retenido por
	-- BotRecord) mantenía alive el Model del último target.
	self._currentTarget = nil
	self._currentTargetRoot = nil
	self._currentTargetPlayer = nil
	self._forcedTarget = nil
	table.clear(self._targetCandidates)

	local humanoid = self._humanoid
	if humanoid then
		-- Force movement state to idle so NPCs don't keep run/weapon poses while frozen.
		humanoid:Move(Vector3.zero, false)
		humanoid.AutoRotate = true
		humanoid.Jump = false
		pcall(function()
			humanoid:MoveTo(self._rootPart.Position)
		end)

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				track:Stop(0.1)
			end
		end
		-- Audit: Destroy explícito de los tracks que cargamos. GetPlayingAnimationTracks
		-- solo devuelve los en marcha — Run/Jump cuando el bot estaba quieto
		-- quedaban zombis en el Animator hasta que se destruye el rig (5s
		-- post-muerte). Con 16 bots × respawns/seg, transitorio de ~64 tracks
		-- innecesarios.
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
