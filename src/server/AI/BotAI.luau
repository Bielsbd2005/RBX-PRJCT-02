--!strict

--[[
@desc ModuleScript de servidor que implementa la IA completa de un bot individual.
@desc Se integra con AIService, navegación (Navigator/StuckDetector/RoamGraph),
@desc combate del WeaponsSystem y utilidades de equipo para decidir patrulla,
@desc persecución, selección de objetivo y disparo.
@desc En la arquitectura del juego, este módulo pertenece al gameplay de match
@desc del lado servidor (movimiento NPC, targeting y aplicación de daño).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)
local BotConfig = require(Shared.constants.BotConfig)
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

local _weaponTemplate: Tool? = nil

--[[
@desc Obtiene y cachea el template AR-NPC utilizado por los bots.
@desc Se centraliza aquí para que los spawns reutilicen la misma referencia.
@return Tool? Tool base de NPC o nil si no existe/no es Tool.
]]
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

local BULLET_AUDIBLE_RANGE = 200
local BULLET_AUDIBLE_RANGE2 = BULLET_AUDIBLE_RANGE * BULLET_AUDIBLE_RANGE

--[[
@desc Resuelve y cachea el RemoteEvent WeaponFired del WeaponsSystem.
@desc La caché evita búsquedas repetidas en ReplicatedStorage durante combate.
@return RemoteEvent? Remote de disparo o nil si no está disponible.
]]
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


-- Configuración base de PathfindingService compartida por todos los bots.
-- Estructura esperada: dictionary<string, number|boolean> con parámetros
-- estáticos de navegación usados al crear Navigator.
local AGENT_PARAMS = {
	AgentRadius = BotConfig.Pathfinding.AgentRadius,
	AgentHeight = BotConfig.Pathfinding.AgentHeight,
	AgentCanJump = BotConfig.Pathfinding.AgentCanJump,
	AgentJumpHeight = BotConfig.Movement.JumpHeight,
	AgentMaxSlope = BotConfig.Pathfinding.AgentMaxSlope,
	WaypointSpacing = BotConfig.Pathfinding.WaypointSpacing,
}

-- Catálogo de animaciones por estado lógico del bot.
-- Estructura esperada: dictionary<string, string> donde cada valor es rbxassetid.
local ANIM_IDS = {
	Idle = "rbxassetid://507766388",
	Run = "rbxassetid://507767714",
	Jump = "rbxassetid://507765000",
	ToolHold = "rbxassetid://80449761976468",
}

-- Cache global de instancias Animation para evitar recreación por respawn.
-- Estructura esperada: [animationId: string] = Animation.
local _animationCache: { [string]: Animation } = {}

--[[
@desc Devuelve una instancia Animation cacheada por id.
@desc Se hace así para evitar allocations/destrucciones por cada respawn.
@param id string Asset id de animación (rbxassetid://...).
@return Animation Instancia Animation lista para LoadAnimation.
]]
local function _getCachedAnimation(id: string): Animation
	local existing = _animationCache[id]
	if existing then return existing end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	_animationCache[id] = anim
	return anim
end

local FOV_COS = math.cos(math.rad(BotConfig.Combat.FOVDegrees / 2))

local EYE_OFFSET = Vector3.new(0, 1.5, 0)

-- Cache Player -> HumanoidRootPart para filtrar broadcast de disparos por rango.
-- Estructura esperada: [Player] = root part vigente del Character actual.
local _playerRootByPlayer: { [Player]: BasePart } = {}

--[[
@desc Refresca el cache de HumanoidRootPart para un Character concreto.
@desc Si HRP aún no existe, espera su aparición una sola vez.
@param player Player Dueño del Character.
@param char Model Character a registrar en cache.
@return nil
]]
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

--[[
@desc Conecta señales de Character para mantener el cache Player->HRP vigente.
@desc Esta decisión evita búsquedas costosas por disparo en loops de alta frecuencia.
@param player Player Jugador al que se le instalarán listeners.
@return nil
]]
local function _wirePlayerRootCache(player: Player)
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
	_playerRootByPlayer[p] = nil
end)

-- Estados del FSM principal de comportamiento.
-- Estructura esperada: enum-like dictionary con valores string estables.
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
	_fakeUserId: number,
	_isAlive: boolean,
	_mapRoot: Instance?,
	_connections: { RBXScriptConnection },
	_nextShotId: number,
	_aliveTargets: { AliveTarget },
	_botModelByFakeUserId: { [number]: Model }?,
	_raycastParams: RaycastParams?,
	_currentTarget: Model?,
	_currentTargetRoot: BasePart?,
	_currentTargetPos: Vector3,
	_currentTargetPlayer: Player?,
	_isCurrentTargetVisible: boolean,
	_targetGraceUntil: number,
	_forcedTarget: Model?,
	_forcedUntil: number,
	_fireReadyAt: number,
	_combatCycleEndAt: number,
	_combatMoveDir: Vector3,
	_targetCandidates: { { char: Model, d: number } },
	_tool: Tool?,
	_tipAttachment: Attachment?,
	_wrapId: string?,
	_lastAimPos: Vector3,
	_navigator: Navigator.Navigator?,
	_stuckDetector: StuckDetector.StuckDetector?,
	_roamGraph: RoamGraph.RoamGraph?,
	_animTracks: { [string]: AnimationTrack }?,
}, BotAI))

--[[
@desc Construye una instancia BotAI para un rig de bot existente.
@desc Inicializa estado mutable, referencias al rig y caches por instancia.
@param botModel Model Modelo del bot en Workspace.
@param team "A" | "B" Equipo lógico usado en filtros de combate.
@param fakeUserId number? Identificador de bot para kill attribution.
@param wrapId string? Id de wrap visual aplicado al arma del bot.
@return BotAIInstance Instancia lista para Start.
]]
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

--[[
@desc Fuerza network ownership del bot al servidor.
@desc Es clave para mantener movimiento/disparo autoritativos en NPC.
@return nil
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
@desc Clona, equipa y registra el arma del bot.
@desc También aplica wrap visual y cachea TipAttachment para el cálculo de origen.
@return nil
]]
function BotAI:_setupTool()
	local toolTemplate = _getWeaponTemplate()
	if not toolTemplate then
		warn(string.format(
			"[BotAI] %s sin arma: ReplicatedStorage.AR-NPC no encontrado o no es Tool. El bot no disparará.",
			self._dummy.Name
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
end

--[[
@desc Carga tracks de animación para el bot de forma asíncrona.
@desc Se realiza async para no bloquear picos de spawn al iniciar ronda.
@return { [string]: AnimationTrack } Tabla de tracks por nombre lógico.
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
@desc Configura AlignOrientation usado para apuntar al target en combate.
@desc Se prefiere restricción física sobre rotación instantánea para suavidad visual.
@return AlignOrientation? Constraint creado para controlar yaw del bot.
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

	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.MaxTorque = 1e6
	align.MaxAngularVelocity = 20
	align.Responsiveness = 30
	align.Enabled = false
	align.Parent = self._dummy

	return align
end

--[[
@desc Cambia la animación activa con crossfade corto si corresponde.
@desc Evita reiniciar la misma track en cada tick del FSM.
@param name string Nombre lógico de animación a reproducir.
@param tracks { [string]: AnimationTrack } Tabla de tracks cargadas.
@param currentTrack AnimationTrack? Track actualmente activa.
@return AnimationTrack? Nueva track activa o la anterior si no hubo cambio.
]]
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
@desc Evalúa línea de visión real entre el bot y un target.
@desc Esta validación evita disparos a través de cobertura y prioriza combate justo.
@param target Model Character objetivo.
@param preResolvedRoot BasePart? HRP opcional ya resuelto para evitar lookup.
@return boolean true si existe LoS directa al target.
]]
function BotAI:_canSeeTarget(target: Model, preResolvedRoot: BasePart?): boolean
	local targetRoot = preResolvedRoot or target:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return false
	end

	local origin = self._rootPart.Position + EYE_OFFSET
	local targetPos = (targetRoot :: BasePart).Position + EYE_OFFSET
	local direction = targetPos - origin

	if direction.Magnitude > BotConfig.Combat.DetectRange then
		return false
	end

	local params = self._raycastParams
	if not params then
		params = RaycastParams.new()
		params.FilterDescendantsInstances = { self._dummy }
		params.FilterType = Enum.RaycastFilterType.Exclude
	end

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

--[[
@desc Selecciona el mejor target candidato usando filtros de equipo, rango, FOV y LoS.
@desc La estrategia prioriza costo bajo primero y raycast limitado al final.
@return Model? Target elegido o nil si no hay candidato válido.
@return boolean true si el target elegido tiene LoS en esta evaluación.
]]
function BotAI:_getBestTarget(): (Model?, boolean)
	local rootPos = self._rootPart.Position
	local myTeam = TeamUtils.normalize(self._team)
	local facing = self._rootPart.CFrame.LookVector
	local now = time()

	local candidates = self._targetCandidates
	table.clear(candidates)

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

		local protectedUntil = char:GetAttribute("SpawnProtectedUntil")
		if type(protectedUntil) == "number" and protectedUntil > now then continue end

		local delta = (root :: BasePart).Position - rootPos
		local d2 = delta:Dot(delta)
		local detectRange = BotConfig.Combat.DetectRange
		if d2 > detectRange * detectRange then continue end

		local d = math.sqrt(d2)

		if d > 0.001 and facing:Dot(delta) / d < FOV_COS then continue end

		table.insert(candidates, { char = char, d = d, root = root :: BasePart })
	end

	if #candidates == 0 then
		return nil, false
	end

	table.sort(candidates, function(a, b) return a.d < b.d end)

	local maxChecks = math.min(#candidates, BotConfig.Combat.MaxLosChecksPerEval)
	for i = 1, maxChecks do
		local c = candidates[i]
		if self:_canSeeTarget(c.char, c.root) then
			return c.char, true
		end
	end

	return nil, false
end

--[[
@desc Resuelve el modelo atacante desde userId real o fakeUserId de bot.
@desc Se usa en retaliación para reaccionar rápido al daño recibido.
@param attackerUserId number UserId real (>0) o fake id de bot (<0).
@param aliveTargets { AliveTarget } Lista viva de candidatos actuales.
@param selfDummy Model Modelo del bot actual para evitar self-target.
@param botModelByFakeUserId { [number]: Model }? Índice O(1) de bots por fake id.
@return Model? Character atacante resuelto o nil.
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

--[[
@desc Valida y devuelve el forced target temporal de retaliación.
@desc Si deja de cumplir reglas de validez, limpia estado para evitar lock inválido.
@return Model? Target forzado vigente o nil.
]]
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
	local myTeam = TeamUtils.normalize(self._team)
	local theirTeam = TeamUtils.getSide(target)
	if theirTeam and myTeam and theirTeam == myTeam then
		self._forcedTarget = nil
		return nil
	end
	local rangeExt = BotConfig.Combat.DetectRange + 20
	local fd = self._rootPart.Position - (root :: BasePart).Position
	if fd:Dot(fd) > rangeExt * rangeExt then
		self._forcedTarget = nil
		return nil
	end
	return target
end

--[[
@desc Evalúa y actualiza el target activo del bot en el loop paralelo de detección.
@desc Aplica reglas de grace, fast-path estable y reaction delay para el primer disparo.
@param now number Timestamp en segundos (os.clock) de la iteración actual.
@return nil
]]
function BotAI:_evaluateTarget(now: number)
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
		local current = self._currentTarget
		local fastPath = false
		if current and current.Parent then
			local hum = current:FindFirstChildOfClass("Humanoid")
			local root = current:FindFirstChild("HumanoidRootPart")
			if hum and (hum :: Humanoid).Health > 0 and root then
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
						end
					end
				end
			end
		end
		if not fastPath then
			potentialTarget, isVisible = self:_getBestTarget()
		end
	end

	if potentialTarget and isVisible then
		self._targetGraceUntil = now + 3
	elseif not potentialTarget and self._currentTarget and now < self._targetGraceUntil then
		local prev = self._currentTarget
		local prevHum = prev:FindFirstChildOfClass("Humanoid")
		local prevRoot = prev:FindFirstChild("HumanoidRootPart")
		if prev.Parent
			and prevHum and (prevHum :: Humanoid).Health > 0
			and prevRoot then
			local graceRange = BotConfig.Combat.DetectRange + 15
			local gd = self._rootPart.Position - (prevRoot :: BasePart).Position
			if gd:Dot(gd) <= graceRange * graceRange then
				potentialTarget = prev
				isVisible = false
			end
		end
	end

	local prevVisible = self._isCurrentTargetVisible
	if isVisible and not prevVisible then
		local lo = BotConfig.Combat.ReactionDelayMin
		local hi = BotConfig.Combat.ReactionDelayMax
		self._fireReadyAt = now + lo + math.random() * (hi - lo)
	end

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

--[[
@desc Ejecuta movimiento bloqueante hacia un destino usando Navigator.
@desc Se mantiene bloqueante para coordinar el estado PATROL sin carreras de ruta.
@param location Vector3 Punto destino en mundo.
@param stopCondition () -> boolean Condición de cancelación temprana.
@return nil
]]
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

--[[
@desc Arranca todos los subsistemas del bot: navegación, detección, FSM y combate.
@desc Este método conecta listeners, crea coroutines y vuelve autoritativo al servidor.
@param mapRoot Instance? Root del mapa activo para contexto/telemetría.
@param aliveTargets { AliveTarget }? Referencia compartida de objetivos vivos.
@param roamGraph RoamGraph.RoamGraph? Grafo navegable para patrulla.
@param botModelByFakeUserId { [number]: Model }? Índice de bots para retaliación.
@return nil
]]
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
	self._raycastParams = raycastParams

	self._navigator = Navigator.new(humanoid, rootPart, AGENT_PARAMS)

	local _, connDetectViz = DetectRangeViz.attach(rootPart, BotConfig.Combat.DetectRange)
	table.insert(self._connections, connDetectViz)

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
	local lastJumpTime = 0
	local lastChaseMoveDir: Vector3 = Vector3.new(math.huge, 0, 0)

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
			self._forcedTarget = attackerModel
			self._forcedUntil = os.clock() + 4
		end
	end)
	table.insert(self._connections, connDamage)



	task.spawn(function()
		local currentState = STATES.PATROL
		local lastAppliedMoveDir: Vector3 = Vector3.new(math.huge, 0, 0)
		local previousState: string = STATES.PATROL

		while self._isAlive and humanoid.Health > 0 do
			local potentialTarget = self._currentTarget
			local isVisible = self._isCurrentTargetVisible
			local targetRoot = self._currentTargetRoot
			local targetPos = if targetRoot and targetRoot.Parent
				then targetRoot.Position
				else self._currentTargetPos

			if alignOrientation then
				if potentialTarget and targetRoot then
					local aimDelta = targetPos - self._lastAimPos
					if aimDelta:Dot(aimDelta) > 0.25 then
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
				if isVisible then
					currentState = STATES.ATTACK
				else
					currentState = STATES.CHASE
				end
			else
				currentState = STATES.PATROL
			end

			local isPlayer = false
			if currentTarget then
				isPlayer = currentTarget:GetAttribute("FakeUserId") == nil
			end
			local profile = if isPlayer then BotConfig.Combat.VsPlayer else BotConfig.Combat.VsBot

			if currentState == STATES.ATTACK and currentTarget and targetRoot then
				if self._navigator and self._navigator:isMoving() then
					self._navigator:cancel()
				end

				local now = os.clock()
				if now >= self._combatCycleEndAt then
					if math.random() < BotConfig.Combat.CombatPauseChance then
						self._combatMoveDir = Vector3.zero
						local lo = BotConfig.Combat.CombatPauseMin
						local hi = BotConfig.Combat.CombatPauseMax
						self._combatCycleEndAt = now + lo + math.random() * (hi - lo)
					else
						local toTarget = targetPos - rootPart.Position
						local right = toTarget:Cross(Vector3.new(0, 1, 0))
						if right.Magnitude > 0.01 then
							right = right.Unit
							local lateralSign = if math.random() < 0.5 then -1 else 1
							local lateral = lateralSign * (0.7 + math.random() * 0.3)
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
				local enteredAttack = previousState ~= STATES.ATTACK
				if enteredAttack or self._combatMoveDir ~= lastAppliedMoveDir then
					humanoid:Move(self._combatMoveDir, false)
					lastAppliedMoveDir = self._combatMoveDir
				end

				if os.clock() - lastJumpTime > math.random(20, 50) / 10 then
					if math.random() < profile.JumpChance then
						humanoid.Jump = true
					end
					lastJumpTime = os.clock()
				end

				local fireRate = BotConfig.Combat.FireRate
				local precision = BotConfig.Combat.Precision

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
						for p, pRoot in _playerRootByPlayer do
							if pRoot.Parent then
								local delta = origin - pRoot.Position
								if delta:Dot(delta) < BULLET_AUDIBLE_RANGE2 then
									firedRemote:FireClient(p, nil, weapon, fireInfo)
								end
							end
						end
					end

					if hit then
						local targetHum = currentTarget:FindFirstChildOfClass("Humanoid")
						if targetHum and (targetHum :: Humanoid).Health > 0 then
							local dmg = math.random(profile.DamageMin, profile.DamageMax)

							LastAttackerStore.set(targetHum :: Humanoid, self._fakeUserId, if weapon then weapon.Name else "NPC")

							;(targetHum :: Humanoid):TakeDamage(dmg)

							if isPlayer and _weaponDataRemote then
								local victimPlayer = self._currentTargetPlayer
								if victimPlayer then
									_weaponDataRemote:FireClient(victimPlayer, "HitByOtherPlayer", rootPart.Position)
								end
							end
						end
					end
				end

				task.wait(0.05)

			elseif currentState == STATES.CHASE and currentTarget and targetRoot then
				if isVisible then
					if self._navigator and self._navigator:isMoving() then
						self._navigator:cancel()
					end
					local toTarget = targetPos - rootPart.Position
					local planar = Vector3.new(toTarget.X, 0, toTarget.Z)
					local chaseDir: Vector3
					if planar.Magnitude > 0.01 then
						chaseDir = planar.Unit
					else
						chaseDir = Vector3.zero
					end
					if chaseDir ~= lastChaseMoveDir then
						humanoid:Move(chaseDir, false)
						lastChaseMoveDir = chaseDir
					end
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
					lastChaseMoveDir = Vector3.new(math.huge, 0, 0)
				end

				task.wait(0.05)

			else
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

				dest = (dest :: Vector3) + Vector3.new(math.random(-4, 4), 0, math.random(-4, 4))

				NavMetrics.record("roam_pick_count", { bot = self._dummy.Name })

				self:_moveToLocation(dest :: Vector3, function()
					return self._currentTarget ~= nil or not self._isAlive
				end)


				task.wait()
			end

			previousState = currentState
		end

		if alignOrientation then
			alignOrientation.Enabled = false
		end
	end)
end

--[[
@desc Detiene la IA y libera recursos runtime de la instancia.
@desc Limpia conexiones, referencias, navegación y tracks para evitar leaks entre rondas.
@return nil
]]
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

	self._currentTarget = nil
	self._currentTargetRoot = nil
	self._currentTargetPlayer = nil
	self._forcedTarget = nil
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
