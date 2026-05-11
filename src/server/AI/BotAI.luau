--!strict
-- BotAI: loop completo de comportamiento para un bot individual.
-- Se instancia por bot desde AIService. Portado del EJEMPLO/AI.

local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

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

local JUMP_HEIGHT = 5
local WANDER_RADIUS = 40
local DETECT_RANGE = 35
local DISTANCIA_SUAVIDAD = 4
local FIRE_RATE = 0.1        -- igual que ShotCooldown del arma real
local PRECISION = 40         -- 40% de balas hacen daño
local WALK_SPEED = 16        -- igual que jugadores reales

local PLAYER_AGGRESSION = {
	FIRE_RATE = 0.1,
	PRECISION = 40,
	DAMAGE_MIN = 2,
	DAMAGE_MAX = 5,
	JUMP_CHANCE = 0.03,
}

local AGENT_PARAMS = {
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
	AgentJumpHeight = JUMP_HEIGHT,
	AgentMaxSlope = 45,
}

local ANIM_IDS = {
	Idle = "rbxassetid://507766388",
	Run = "rbxassetid://507767714",
	Jump = "rbxassetid://507768704",
	ToolHold = "rbxassetid://80449761976468",
}

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
	_attackRange: number,
	_alive: boolean,
	_mapRoot: Instance?,
	_connections: { RBXScriptConnection },
	_nextShotId: number,
	-- Sprint 3: cache de target + path persistente.
	_aliveTargets: { Model },
	_currentTarget: Model?,
	_currentTargetVisible: boolean,
	_lastTargetEvalAt: number,
	_path: Path?,
	_lastPathComputeAt: number,
	_lastPathTargetPos: Vector3?,
	_moveReached: boolean,
}, BotAI))

function BotAI.new(botModel: Model, team: "A" | "B", fakeUserId: number?): BotAIInstance
	local humanoid = botModel:FindFirstChildOfClass("Humanoid") :: Humanoid
	local rootPart = botModel:FindFirstChild("HumanoidRootPart") :: BasePart

	local self = setmetatable({
		_dummy = botModel,
		_humanoid = humanoid,
		_rootPart = rootPart,
		_team = team,
		_fakeUserId = fakeUserId or 0,
		_attackRange = math.random(10, 30),
		_alive = true,
		_mapRoot = nil :: Instance?,
		_connections = {} :: { RBXScriptConnection },
		_nextShotId = 1,
		_aliveTargets = {},
		_currentTarget = nil,
		_currentTargetVisible = false,
		_lastTargetEvalAt = 0,
		_path = nil,
		_lastPathComputeAt = 0,
		_lastPathTargetPos = nil,
		_moveReached = false,
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
	local toolTemplate = ReplicatedStorage:FindFirstChild("AR-NPC")
	if toolTemplate and toolTemplate:IsA("Tool") then
		local tool = toolTemplate:Clone()
		tool.Parent = self._dummy
		if not CollectionService:HasTag(tool, WEAPON_TAG) then
			CollectionService:AddTag(tool, WEAPON_TAG)
		end
		self._humanoid:EquipTool(tool)
		self._nextShotId = 1
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
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local ok, track = pcall(function()
			return (animator :: Animator):LoadAnimation(anim)
		end)
		if ok then
			tracks[name] = track :: AnimationTrack
		end
		anim:Destroy()
	end

	if tracks.ToolHold then
		tracks.ToolHold.Priority = Enum.AnimationPriority.Action
		tracks.ToolHold.Looped = true
		tracks.ToolHold:Play()
	end

	return tracks
end

function BotAI:_setupRotationConstraint(): AlignOrientation?
	local attachment = Instance.new("Attachment")
	attachment.Name = "RotationAttachment"
	attachment.Parent = self._rootPart

	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = true
	align.MaxTorque = 100000
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

	if direction.Magnitude > DETECT_RANGE then
		return false
	end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { self._dummy }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(origin, direction, params)
	if result and result.Instance:IsDescendantOf(target) then
		return true
	end

	return false
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

	-- Pass 1: filtrado liviano (sin raycast).
	local candidates = {} :: { { char: Model, d: number } }
	for _, char in self._aliveTargets do
		if char == self._dummy then continue end

		local hum = char:FindFirstChildOfClass("Humanoid")
		local root = char:FindFirstChild("HumanoidRootPart")
		if not hum or not root or (hum :: Humanoid).Health <= 0 then continue end

		local charTeam = TeamUtils.getSide(char)
		if charTeam and myTeam and charTeam == myTeam then continue end

		local d = (rootPos - (root :: BasePart).Position).Magnitude
		if d > DETECT_RANGE then continue end

		table.insert(candidates, { char = char, d = d })
	end

	if #candidates == 0 then
		return nil, false
	end

	-- Pass 2: ordenar por distancia, raycastear desde el más cercano.
	table.sort(candidates, function(a, b) return a.d < b.d end)

	for _, c in candidates do
		if self:_canSeeTarget(c.char) then
			return c.char, true
		end
	end

	return nil, false
end

function BotAI:_refreshWaypoints(mapRoot: Instance?): { BasePart }
	local searchRoot: Instance = mapRoot or workspace

	local folder = searchRoot:FindFirstChild("Waypoints", true)
	if not folder then
		folder = workspace:FindFirstChild("Waypoints")
	end

	if not folder then
		return {}
	end

	local list = {} :: { BasePart }
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(list, child :: BasePart)
		end
	end

	table.sort(list, function(a, b)
		local numA = tonumber(a.Name)
		local numB = tonumber(b.Name)
		if numA and numB then return numA < numB end
		return a.Name < b.Name
	end)

	return list
end

--[[
	Sprint 3: usa el Path persistente (`self._path`) y una conexión única a
	MoveToFinished (`self._moveReached`) en lugar de crear/destruir ambos
	por cada llamada.

	Antes: cada `_moveToLocation` hacía CreatePath+ComputeAsync (decenas de ms)
	y conectaba/desconectaba MoveToFinished por waypoint (10-20 conexiones por
	patrullaje). En CHASE sin LoS, este coste se pagaba a 10Hz.
]]
function BotAI:_moveToLocation(location: Vector3, stopCondition: () -> boolean)
	local path = self._path
	if not path then
		return
	end

	local ok = pcall(function()
		path:ComputeAsync(self._rootPart.Position, location)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		return
	end

	local waypoints = path:GetWaypoints()
	for i = 2, #waypoints do
		if stopCondition() then
			return
		end

		local wp = waypoints[i]
		if wp.Action == Enum.PathWaypointAction.Jump then
			self._humanoid.Jump = true
		end

		self._moveReached = false
		self._humanoid:MoveTo(wp.Position)

		while not self._moveReached do
			if i < #waypoints and (self._rootPart.Position - wp.Position).Magnitude < DISTANCIA_SUAVIDAD then
				break
			end
			if stopCondition() then
				return
			end
			task.wait()
		end
	end
end

function BotAI:_addHighlight()
	local highlight = Instance.new("Highlight")
	highlight.Name = "BotHighlight"
	highlight.FillTransparency = 0.6
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	-- Color inicial neutro; el cliente lo ajustará por perspectiva de equipo
	highlight.FillColor = Color3.fromRGB(128, 128, 128)
	highlight.OutlineColor = Color3.fromRGB(200, 200, 200)
	highlight.Parent = self._dummy
end

function BotAI:Start(mapRoot: Instance?, aliveTargets: { Model }?)
	self._mapRoot = mapRoot
	self._aliveTargets = aliveTargets or {}
	self:_setupNetworkOwnership()
	self:_setupTool()
	self:_addHighlight()

	-- Sprint 3: Path persistente. Una sola allocation por bot — el ComputeAsync
	-- es lo costoso, no el CreatePath, pero reusarlo limita allocations.
	self._path = PathfindingService:CreatePath(AGENT_PARAMS)

	local humanoid = self._humanoid
	local rootPart = self._rootPart

	humanoid.UseJumpPower = false
	humanoid.JumpHeight = JUMP_HEIGHT
	humanoid.WalkSpeed = WALK_SPEED

	local tracks = self:_setupAnimations()
	local alignOrientation = self:_setupRotationConstraint()
	local waypointsList = self:_refreshWaypoints(mapRoot)
	local waypointIndex = if #waypointsList > 0 then math.random(1, #waypointsList) else 1

	local currentTrack: AnimationTrack? = nil
	local lastShotTime = 0
	local lastStrafeTime = math.random() * 2
	local lastJumpTime = 0
	local strafeDirection = 1

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

	-- Sprint 3: una sola conexión MoveToFinished compartida en lugar de
	-- connect/disconnect por waypoint en _moveToLocation.
	local connMoveDone = humanoid.MoveToFinished:Connect(function()
		self._moveReached = true
	end)
	table.insert(self._connections, connMoveDone)

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

		while self._alive and humanoid.Health > 0 do
			-- Sprint 3: una sola llamada a _getBestTarget por tick. El resultado
			-- (target + visibility) se cachea en self para que ATTACK lo reuse
			-- sin un raycast extra.
			local potentialTarget, isVisible = self:_getBestTarget()
			self._currentTarget = potentialTarget
			self._currentTargetVisible = isVisible
			self._lastTargetEvalAt = os.clock()

			-- Aplicar rotación al target cacheado (movido desde el Heartbeat).
			if alignOrientation then
				if potentialTarget then
					local targetRoot = potentialTarget:FindFirstChild("HumanoidRootPart")
					if targetRoot then
						local targetPos = (targetRoot :: BasePart).Position
						local lookPos = Vector3.new(targetPos.X, rootPart.Position.Y, targetPos.Z)
						alignOrientation.Enabled = true
						alignOrientation.CFrame = CFrame.lookAt(rootPart.Position, lookPos)
					end
				else
					alignOrientation.Enabled = false
				end
			end

			local currentTarget: Model? = potentialTarget
			if potentialTarget then
				local targetRoot = potentialTarget:FindFirstChild("HumanoidRootPart")
				local dist = if targetRoot
					then (rootPart.Position - (targetRoot :: BasePart).Position).Magnitude
					else math.huge

				if dist <= self._attackRange then
					currentState = STATES.ATTACK
				else
					currentState = STATES.CHASE
				end
			else
				currentState = STATES.PATROL
				humanoid.AutoRotate = true
			end

			-- ── ATTACK ──────────────────────────────────────────────
			if currentState == STATES.ATTACK and currentTarget then
				humanoid.AutoRotate = false
				local targetRoot = currentTarget:FindFirstChild("HumanoidRootPart")

				if targetRoot then
					local toTarget = (targetRoot :: BasePart).Position - rootPart.Position
					local distance = toTarget.Magnitude

					if os.clock() - lastStrafeTime > 0.5 then
						if math.random() < 0.2 then
							strafeDirection = -strafeDirection
						end
						lastStrafeTime = os.clock()
					end

					local rightVec = toTarget:Cross(Vector3.new(0, 1, 0)).Unit
					local forwardMult = 0
					local myHealthPct = humanoid.Health / humanoid.MaxHealth
					local idealDist = if myHealthPct < 0.3 then 25 elseif myHealthPct > 0.7 then 10 else 15

					if distance > idealDist + 2 then forwardMult = 1
					elseif distance < idealDist - 2 then forwardMult = -1
					end

					local moveDir = (rightVec * strafeDirection) + (toTarget.Unit * forwardMult * 0.5)
					if moveDir.Magnitude > 0 then
						humanoid:Move(moveDir.Unit)
					end

					local isPlayer = Players:GetPlayerFromCharacter(currentTarget) ~= nil
					local jumpChance = if isPlayer then PLAYER_AGGRESSION.JUMP_CHANCE else 0.4
					if os.clock() - lastJumpTime > math.random(20, 50) / 10 then
						if math.random() < jumpChance then
							humanoid.Jump = true
						end
						lastJumpTime = os.clock()
					end
				end

				local isPlayer = Players:GetPlayerFromCharacter(currentTarget) ~= nil
				local fireRate = if isPlayer then PLAYER_AGGRESSION.FIRE_RATE else FIRE_RATE
				local precision = if isPlayer then PLAYER_AGGRESSION.PRECISION else PRECISION

				-- Sprint 3: reusar la visibility del _getBestTarget de este tick.
				-- Antes esto hacía un tercer raycast por tick en ATTACK.
				if os.clock() - lastShotTime > fireRate and isVisible then
					lastShotTime = os.clock()

					if math.random(1, 100) <= precision then
						local targetHum = currentTarget:FindFirstChildOfClass("Humanoid")
						if targetHum and (targetHum :: Humanoid).Health > 0 then
							local dmg = if isPlayer
								then math.random(PLAYER_AGGRESSION.DAMAGE_MIN, PLAYER_AGGRESSION.DAMAGE_MAX)
								else math.random(10, 25)

							-- Stamp attacker attributes so kill tracking works
							;(targetHum :: Humanoid):SetAttribute("LastAttackerUserId", self._fakeUserId)
							;(targetHum :: Humanoid):SetAttribute("LastAttackerAt", time())
							local weapon = self._dummy:FindFirstChildOfClass("Tool")
							;(targetHum :: Humanoid):SetAttribute("LastAttackerWeaponName", if weapon then weapon.Name else "NPC")

							;(targetHum :: Humanoid):TakeDamage(dmg)

							-- Fire directional damage indicator for real players
							if isPlayer and _weaponDataRemote then
								local victimPlayer = Players:GetPlayerFromCharacter(currentTarget)
								if victimPlayer then
									_weaponDataRemote:FireClient(victimPlayer, "HitByOtherPlayer", rootPart.Position)
								end
							end

							-- Efectos visuales del disparo: usar el mismo pipeline que humanos
							-- (broadcast WeaponFired → cada cliente corre BulletWeapon:simulateFire).
							local fxTargetRoot = currentTarget:FindFirstChild("HumanoidRootPart")
							local firedRemote = _getWeaponFiredRemote()
							if weapon and fxTargetRoot and firedRemote then
								local tipAttach = weapon:FindFirstChild("TipAttachment", true)
								local origin: Vector3
								if tipAttach and tipAttach:IsA("Attachment") then
									origin = (tipAttach :: Attachment).WorldPosition
								else
									origin = rootPart.Position + Vector3.new(0, 1.5, 0)
								end
								local dir = ((fxTargetRoot :: BasePart).Position - origin).Unit
								local fireInfo = {
									origin = origin,
									dir = dir,
									charge = 1,
									id = self._nextShotId,
								}
								self._nextShotId += 1
								firedRemote:FireAllClients(nil, weapon, fireInfo)
							end
						end
					end
				end

				task.wait(0.1)

			-- ── CHASE ───────────────────────────────────────────────
			elseif currentState == STATES.CHASE and currentTarget then
				humanoid.AutoRotate = true
				local targetRoot = currentTarget:FindFirstChild("HumanoidRootPart")

				if targetRoot then
					-- Sprint 3: reusar `isVisible` del _getBestTarget de este tick
					-- en lugar de llamar _canSeeTarget de nuevo (raycast extra).
					if isVisible then
						humanoid:MoveTo((targetRoot :: BasePart).Position)
						if math.random() < 0.05 then
							humanoid.Jump = true
						end
					else
						-- Sprint 3: throttle de ComputeAsync. Antes se hacía cada tick
						-- (10Hz) — ComputeAsync es síncrono y costoso. Recompute solo
						-- cuando pasaron ≥0.5s O el target se movió >5 studs.
						local targetPos = (targetRoot :: BasePart).Position
						local now = os.clock()
						local lastPos = self._lastPathTargetPos
						local needRecompute = (now - self._lastPathComputeAt) > 0.5
							or lastPos == nil
							or ((lastPos :: Vector3) - targetPos).Magnitude > 5

						if needRecompute and self._path then
							local ok = pcall(function()
								(self._path :: Path):ComputeAsync(rootPart.Position, targetPos)
							end)
							if ok then
								self._lastPathComputeAt = now
								self._lastPathTargetPos = targetPos
							end
						end

						local path = self._path
						if path and path.Status == Enum.PathStatus.Success then
							local wps = path:GetWaypoints()
							if wps and #wps >= 2 then
								humanoid:MoveTo(wps[2].Position)
							end
						else
							humanoid:MoveTo(targetPos)
						end
					end
				end

				task.wait(0.1)

			-- ── PATROL ──────────────────────────────────────────────
			else
				local dest: Vector3

				if #waypointsList > 0 then
					local wp = waypointsList[waypointIndex]
					waypointIndex = (waypointIndex % #waypointsList) + 1
					local offset = Vector3.new(math.random(-3, 3), 0, math.random(-3, 3))
					dest = wp.Position + offset
				else
					local randomVec = Vector3.new(
						math.random(-WANDER_RADIUS, WANDER_RADIUS),
						0,
						math.random(-WANDER_RADIUS, WANDER_RADIUS)
					)
					dest = rootPart.Position + randomVec
				end

				-- Sprint 3: stopCondition reusa la cache de target en lugar de
				-- ejecutar _getBestTarget en cada `task.wait()` interno (varios
				-- raycasts/seg por bot solo en patrullaje).
				self:_moveToLocation(dest, function()
					return self._currentTarget ~= nil or not self._alive
				end)

				task.wait()
			end
		end

		-- Bot muerto o detenido: limpiar constraints
		if alignOrientation then
			alignOrientation.Enabled = false
		end
		for _, conn in self._connections do
			conn:Disconnect()
		end
		table.clear(self._connections)
	end)
end

function BotAI:Stop()
	self._alive = false
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)

	local humanoid = self._humanoid
	if humanoid then
		-- Force movement state to idle so NPCs don't keep run/weapon poses while frozen.
		humanoid:Move(Vector3.zero)
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
	end
end

return BotAI
