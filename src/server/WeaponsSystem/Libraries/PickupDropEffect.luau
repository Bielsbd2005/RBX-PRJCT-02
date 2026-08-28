--!nonstrict
--[[
	PickupDropEffect.luau (cliente)
	Spawnea un orbe de Health desde el suelo bajo la victima cada vez que el
	jugador local mata a alguien. El orbe orbita en su sitio durante unos
	segundos; si el jugador se acerca se imanta hacia el. Si nadie lo recoge
	se desvanece con un tween de tamano.

	W4-style: bucle único compartido (Heartbeat) para TODOS los pickups
	activos. Antes cada pickup creaba su propio RunService.RenderStepped:Connect
	+ closure pesada; en una kill streak coexistían N conexiones simultáneas
	hasta que cada pickup expirara (5s+). Mismo patrón que BonusEffect.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared:WaitForChild("networking"):WaitForChild("Network"))
local AssetIds = require(Shared:WaitForChild("constants"):WaitForChild("AssetIds"))

local SoundService = game:GetService("SoundService")

local PickupDropEffect = {}

local PICKUP_SOUND_ID = AssetIds.Sounds.Pickup

local _pickupSoundPool: { Sound } = {}
local _PICKUP_SOUND_POOL_SIZE = 2

local function _playPickupSound()
	for _, s in _pickupSoundPool do
		if not s.IsPlaying then
			s.PlaybackSpeed = math.random(95, 135) / 100
			s:Play()
			return
		end
	end

	if #_pickupSoundPool < _PICKUP_SOUND_POOL_SIZE then
		local s = Instance.new("Sound")
		s.SoundId = PICKUP_SOUND_ID
		s.Volume = 0.25
		s.PlaybackSpeed = math.random(95, 135) / 100
		s.Parent = SoundService
		table.insert(_pickupSoundPool, s)
		s:Play()
	end
end
local MAGNET_RADIUS = 16
local EXPIRE_AFTER_SECONDS = 5
local DESPAWN_TWEEN_SECONDS = 0.45
local FLOAT_AMPLITUDE = 0.55
local FLOAT_FREQUENCY = 0.55
local FLOAT_GROUND_OFFSET = 0.3
local FLOAT_RISE_SECONDS = 0.6
local FALL_MAX_SECONDS = 1.6
local FALL_REST_SPEED = 0.8
local FALL_REST_FRAMES = 6
local LAUNCH_HORIZONTAL_SPEED = 22
local LAUNCH_VERTICAL_SPEED = 26

local TEMPLATE_NAME = "Health"

type PickupEntry = {
	item: Instance,
	character: Model,
	rootPart: BasePart,
	primary: BasePart?,
	basePartSizes: { [BasePart]: Vector3 },
	baseScale: number,
	state: string,
	fallElapsed: number,
	restFrames: number,
	floatTime: number,
	riseElapsed: number,
	waitElapsed: number,
	restingPos: Vector3,
	floatAnchorPos: Vector3,
	p0: Vector3?,
	p1: Vector3?,
	p2: Vector3?,
	duration: number?,
	t: number,
	picked: boolean,
	despawnElapsed: number,
	active: boolean,
}

local activePickups: { PickupEntry } = {}
local pickupLoopConn: RBXScriptConnection? = nil

local function _resolveTemplate(): Instance?
	local template = ReplicatedStorage:FindFirstChild(TEMPLATE_NAME)
	if not template then
		warn("PickupDropEffect: template missing in ReplicatedStorage: " .. TEMPLATE_NAME)
	end
	return template
end

local function _ensureFolder(): Folder
	local folder = workspace:FindFirstChild("ClientVisualEffects")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ClientVisualEffects"
		folder.Parent = workspace
	end
	return folder :: Folder
end

local function _resolvePrimary(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary then
			return primary
		end
		for _, child in instance:GetDescendants() do
			if child:IsA("BasePart") then
				return child
			end
		end
	end
	return nil
end

local function _setPivot(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function _getPivotPosition(instance: Instance): Vector3?
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	elseif instance:IsA("BasePart") then
		return instance.Position
	end
	return nil
end

local function _setAnchored(instance: Instance, anchored: boolean, canCollide: boolean)
	if instance:IsA("BasePart") then
		instance.Anchored = anchored
		instance.CanCollide = canCollide
		return
	end
	if instance:IsA("Model") then
		for _, child in instance:GetDescendants() do
			if child:IsA("BasePart") then
				child.Anchored = anchored
				child.CanCollide = canCollide
			end
		end
	end
end

local function _canPickupHealth(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	return humanoid.Health < humanoid.MaxHealth
end

local function _scaleItem(item: Instance, ratio: number, baseScale: number, basePartSizes: { [BasePart]: Vector3 }?)
	local clamped = math.max(0.001, ratio)
	if item:IsA("Model") then
		local target = baseScale * clamped
		item:ScaleTo(target)
		return
	end

	if item:IsA("BasePart") and basePartSizes then
		local original = basePartSizes[item]
		if original then
			item.Size = original * clamped
		end
	end
end

local function _captureBaseSizes(item: Instance): { [BasePart]: Vector3 }
	local sizes: { [BasePart]: Vector3 } = {}
	if item:IsA("BasePart") then
		sizes[item] = item.Size
	end
	return sizes
end

local function _settleAndStartFloat(entry: PickupEntry)
	_setAnchored(entry.item, true, false)
	local landedPivot = _getPivotPosition(entry.item) or entry.restingPos

	-- restingPos = posicion fisica al aterrizar (sirve de inicio del rise).
	-- floatAnchorPos = centro de la orbita, elevado lo suficiente para que la
	-- oscilacion mas baja quede claramente sobre el suelo. El rise interpola
	-- de uno a otro suavemente, sin saltos.
	local lift = FLOAT_GROUND_OFFSET + 1.4
	entry.restingPos = landedPivot
	entry.floatAnchorPos = landedPivot + Vector3.new(0, lift + FLOAT_AMPLITUDE, 0)
	entry.state = "Waiting"
	entry.floatTime = 0
	entry.riseElapsed = 0
	entry.waitElapsed = 0
end

local function _pickupTickEntry(entry: PickupEntry, dt: number)
	local item = entry.item
	local rootPart = entry.rootPart
	if not item.Parent or not rootPart.Parent then
		entry.active = false
		return
	end

	local state = entry.state
	if state == "Falling" then
		entry.fallElapsed += dt
		local primary = entry.primary
		local speed = if primary then primary.AssemblyLinearVelocity.Magnitude else 0
		if speed < FALL_REST_SPEED then
			entry.restFrames += 1
		else
			entry.restFrames = 0
		end

		if entry.restFrames >= FALL_REST_FRAMES or entry.fallElapsed >= FALL_MAX_SECONDS then
			_settleAndStartFloat(entry)
		end
		return
	end

	if state == "Waiting" then
		entry.floatTime += dt
		entry.riseElapsed = math.min(FLOAT_RISE_SECONDS, entry.riseElapsed + dt)
		entry.waitElapsed += dt

		local riseRatio = if FLOAT_RISE_SECONDS > 0 then entry.riseElapsed / FLOAT_RISE_SECONDS else 1
		local riseSmoothT = TweenService:GetValue(riseRatio, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		local centerPos = entry.restingPos:Lerp(entry.floatAnchorPos, riseSmoothT)
		local bob = math.sin(entry.floatTime * FLOAT_FREQUENCY * math.pi * 2) * FLOAT_AMPLITUDE * riseSmoothT
		_setPivot(item, CFrame.new(centerPos + Vector3.new(0, bob, 0)))

		local distToPlayer = (entry.floatAnchorPos - rootPart.Position).Magnitude
		if distToPlayer <= MAGNET_RADIUS and _canPickupHealth(entry.character) then
			entry.state = "Magnet"
			local p0 = _getPivotPosition(item) or entry.floatAnchorPos
			entry.p0 = p0
			local randomOffset = Vector3.new(
				(math.random() - 0.5) * 8,
				math.random(4, 10),
				(math.random() - 0.5) * 8
			)
			entry.p1 = p0 + randomOffset
			local individualSpeed = math.random(85, 115) / 100
			entry.duration = math.clamp(distToPlayer / 35, 0.3, 0.7) * individualSpeed
			entry.t = 0
			return
		end

		if entry.waitElapsed >= EXPIRE_AFTER_SECONDS then
			entry.state = "Despawning"
			entry.despawnElapsed = 0
		end
		return
	end

	if state == "Magnet" then
		local duration = entry.duration or 0.5
		entry.t += dt / duration
		entry.p2 = rootPart.Position
		if entry.t >= 1 then
			entry.active = false

			if not entry.picked then
				entry.picked = true

				_playPickupSound()

				Network.Match.RequestPickup.Send({ kind = "Health" })
			end

			Debris:AddItem(item, 0.1)
			return
		end

		local smoothT = TweenService:GetValue(entry.t, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
		local p0, p1, p2 = entry.p0 :: Vector3, entry.p1 :: Vector3, entry.p2 :: Vector3
		local currentPos = (1 - smoothT) ^ 2 * p0 + 2 * (1 - smoothT) * smoothT * p1 + smoothT ^ 2 * p2
		_setPivot(item, CFrame.new(currentPos))
		return
	end

	if state == "Despawning" then
		entry.floatTime += dt
		entry.despawnElapsed = math.min(DESPAWN_TWEEN_SECONDS, entry.despawnElapsed + dt)
		local ratio = if DESPAWN_TWEEN_SECONDS > 0 then entry.despawnElapsed / DESPAWN_TWEEN_SECONDS else 1
		local easedRatio = TweenService:GetValue(ratio, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local scaleRatio = 1 - easedRatio
		_scaleItem(item, scaleRatio, entry.baseScale, entry.basePartSizes)

		local bob = math.sin(entry.floatTime * FLOAT_FREQUENCY * math.pi * 2) * FLOAT_AMPLITUDE
		_setPivot(item, CFrame.new(entry.floatAnchorPos + Vector3.new(0, bob, 0)))

		if entry.despawnElapsed >= DESPAWN_TWEEN_SECONDS then
			entry.active = false
			item:Destroy()
		end
	end
end

local function _pickupLoopTick(dt: number)
	local i = 1
	while i <= #activePickups do
		local entry = activePickups[i]
		if entry.active then
			_pickupTickEntry(entry, dt)
		end
		if not entry.active then
			local n = #activePickups
			activePickups[i] = activePickups[n]
			activePickups[n] = nil
		else
			i += 1
		end
	end
	-- Autodesconexión en idle (mismo patrón que el bucle global de proyectiles
	-- de BulletWeapon): _ensurePickupLoop reconecta en el próximo spawn.
	if #activePickups == 0 and pickupLoopConn then
		pickupLoopConn:Disconnect()
		pickupLoopConn = nil
	end
end

local function _ensurePickupLoop()
	if pickupLoopConn then return end
	pickupLoopConn = RunService.Heartbeat:Connect(_pickupLoopTick)
end

local function _spawnHealth(victimPos: Vector3, folder: Folder, character: Model, rootPart: BasePart)
	local template = _resolveTemplate()
	if not template then
		return
	end

	local item = template:Clone()
	if not (item:IsA("Model") or item:IsA("BasePart")) then
		item:Destroy()
		warn("PickupDropEffect: template is not a Model/BasePart")
		return
	end

	item.Name = "HealthPickup"

	_setAnchored(item, false, true)
	_setPivot(item, CFrame.new(victimPos + Vector3.new(0, 1, 0)))
	item.Parent = folder

	local basePartSizes = _captureBaseSizes(item)
	local baseScale = if item:IsA("Model") then item:GetScale() else 1
	local primary = _resolvePrimary(item)

	-- Lanzar con velocidad horizontal aleatoria + impulso vertical para que
	-- aterrice unos studs alejado del cuerpo en vez de caer en el sitio.
	if primary then
		local angle = math.random() * math.pi * 2
		primary.AssemblyLinearVelocity = Vector3.new(
			math.cos(angle) * LAUNCH_HORIZONTAL_SPEED,
			LAUNCH_VERTICAL_SPEED,
			math.sin(angle) * LAUNCH_HORIZONTAL_SPEED
		)
	end

	_ensurePickupLoop()

	table.insert(activePickups, {
		item = item,
		character = character,
		rootPart = rootPart,
		primary = primary,
		basePartSizes = basePartSizes,
		baseScale = baseScale,
		state = "Falling",
		fallElapsed = 0,
		restFrames = 0,
		floatTime = 0,
		riseElapsed = 0,
		waitElapsed = 0,
		restingPos = victimPos,
		floatAnchorPos = victimPos,
		p0 = nil,
		p1 = nil,
		p2 = nil,
		duration = nil,
		t = 0,
		picked = false,
		despawnElapsed = 0,
		active = true,
	})
end

function PickupDropEffect.Cleanup()
	local folder = workspace:FindFirstChild("ClientVisualEffects")
	if folder then
		for _, child in folder:GetChildren() do
			if string.match(child.Name, "Pickup$") then
				child:Destroy()
			end
		end
	end
	-- El loop se queda conectado (idle si activePickups está vacío) — el
	-- coste de un Heartbeat:Connect ocioso es negligible y evita el churn
	-- de connect/disconnect entre kills. Mismo trade-off que BonusEffect.
end

function PickupDropEffect.Play(victimPos: Vector3?)
	if not victimPos then
		return
	end

	local player = Players.LocalPlayer
	if not player then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local folder = _ensureFolder()
	_spawnHealth(victimPos, folder, character, rootPart)
end

return PickupDropEffect
