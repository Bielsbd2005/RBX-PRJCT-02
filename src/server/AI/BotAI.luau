--!strict
-- BotAI: loop completo de comportamiento para un bot individual.
-- Se instancia por bot desde AIService. Portado del EJEMPLO/AI.

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NPCWeaponFX = require(script.Parent:WaitForChild("NPCWeaponFX"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local _weaponDataRemote: RemoteEvent? = nil
do
	local wsFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
	if wsFolder then
		local remote = wsFolder:FindFirstChild("WeaponData")
		if remote and remote:IsA("RemoteEvent") then
			_weaponDataRemote = remote
		end
	end
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
local REGEN_RATE = 0
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
		NPCWeaponFX.SetupWeapon(tool)
		self._humanoid:EquipTool(tool)
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

function BotAI:_getBestTarget(): Model?
	local closest: Model? = nil
	local minDist = math.huge

	local function _checkCandidate(char: Instance)
		if not char:IsA("Model") or char == self._dummy then
			return
		end

		local hum = char:FindFirstChildOfClass("Humanoid")
		local root = char:FindFirstChild("HumanoidRootPart")
		if not hum or not root or (hum :: Humanoid).Health <= 0 then
			return
		end

		local charTeam = TeamUtils.getSide(char :: Model)
		local myTeam = TeamUtils.normalize(self._team)
		if charTeam and myTeam and charTeam == myTeam then
			return
		end

		local d = (self._rootPart.Position - (root :: BasePart).Position).Magnitude
		if d < minDist and self:_canSeeTarget(char :: Model) then
			minDist = d
			closest = char :: Model
		end
	end

	-- Jugadores reales (sus personajes son hijos directos de workspace)
	for _, char in workspace:GetChildren() do
		_checkCandidate(char)
	end

	-- Bots enemigos (están dentro de mapRoot/Bots)
	if self._mapRoot then
		local botsFolder = (self._mapRoot :: Instance):FindFirstChild("Bots")
		if botsFolder then
			for _, char in botsFolder:GetChildren() do
				_checkCandidate(char)
			end
		end
	end

	return closest
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

function BotAI:_moveToLocation(location: Vector3, stopCondition: () -> boolean)
	local path = PathfindingService:CreatePath(AGENT_PARAMS)
	pcall(function()
		path:ComputeAsync(self._rootPart.Position, location)
	end)

	if path.Status ~= Enum.PathStatus.Success then
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

		self._humanoid:MoveTo(wp.Position)

		local reached = false
		local conn = self._humanoid.MoveToFinished:Connect(function()
			reached = true
		end)

		while not reached do
			if i < #waypoints and (self._rootPart.Position - wp.Position).Magnitude < DISTANCIA_SUAVIDAD then
				break
			end
			if stopCondition() then
				conn:Disconnect()
				return
			end
			task.wait()
		end
		conn:Disconnect()
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

function BotAI:Start(mapRoot: Instance?)
	self._mapRoot = mapRoot
	self:_setupNetworkOwnership()
	self:_setupTool()
	self:_addHighlight()

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

	-- Heartbeat: regeneracion y rotacion
	local connHB = RunService.Heartbeat:Connect(function(dt: number)
		if not self._alive or humanoid.Health <= 0 then
			return
		end

		-- Regeneracion en patrulla
		if humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + REGEN_RATE * dt)
		end

		-- Rotacion en ataque
		if alignOrientation then
			local target = self:_getBestTarget()
			if target then
				local targetRoot = target:FindFirstChild("HumanoidRootPart")
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
	end)
	table.insert(self._connections, connHB)

	-- Bucle principal en coroutine independiente
	task.spawn(function()
		local currentState = STATES.PATROL
		local currentTarget: Model? = nil

		while self._alive and humanoid.Health > 0 do
			local potentialTarget = self:_getBestTarget()

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
				currentTarget = potentialTarget
			else
				currentState = STATES.PATROL
				currentTarget = nil
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

				if os.clock() - lastShotTime > fireRate and self:_canSeeTarget(currentTarget) then
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

							-- Efectos visuales del disparo
							local fxTargetRoot = currentTarget:FindFirstChild("HumanoidRootPart")
							if weapon and fxTargetRoot then
								NPCWeaponFX.Fire(weapon, (fxTargetRoot :: BasePart).Position, self._dummy)
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
					if self:_canSeeTarget(currentTarget) then
						humanoid:MoveTo((targetRoot :: BasePart).Position)
						if math.random() < 0.05 then
							humanoid.Jump = true
						end
					else
						local path = PathfindingService:CreatePath(AGENT_PARAMS)
						pcall(function()
							path:ComputeAsync(rootPart.Position, (targetRoot :: BasePart).Position)
						end)
						if path.Status == Enum.PathStatus.Success then
							local wps = path:GetWaypoints()
							if wps and #wps >= 2 then
								humanoid:MoveTo(wps[2].Position)
							end
						else
							humanoid:MoveTo((targetRoot :: BasePart).Position)
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

				self:_moveToLocation(dest, function()
					return self:_getBestTarget() ~= nil or not self._alive
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
