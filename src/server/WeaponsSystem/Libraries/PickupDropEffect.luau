--!nonstrict
--[[
	PickupDropEffect.luau (cliente)
	Spawnea un orbe de Health desde el suelo bajo la victima cada vez que el
	jugador local mata a alguien. El orbe orbita en su sitio durante unos
	segundos; si el jugador se acerca se imanta hacia el. Si nadie lo recoge
	se desvanece con un tween de tamano.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared:WaitForChild("networking"):WaitForChild("Network"))

local PickupDropEffect = {}

local PICKUP_SOUND_ID = "rbxassetid://5728423829"
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

local function _getItemHeight(item: Instance): number
	if item:IsA("Model") then
		local size = item:GetExtentsSize()
		return math.max(0, size.Y)
	end
	if item:IsA("BasePart") then
		return math.max(0, item.Size.Y)
	end
	return 0
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

	local restingPos: Vector3 = victimPos
	local floatAnchorPos: Vector3 = victimPos

	local state = "Falling"
	local fallElapsed = 0
	local restFrames = 0
	local floatTime = 0
	local riseElapsed = 0
	local waitElapsed = 0
	local despawnElapsed = 0
	local t = 0
	local p0, p1, p2, duration
	local connection: RBXScriptConnection? = nil
	local picked = false

	local function _settleAndStartFloat()
		_setAnchored(item, true, false)
		local landedPivot = _getPivotPosition(item) or victimPos

		-- restingPos = posicion fisica al aterrizar (sirve de inicio del rise).
		-- floatAnchorPos = centro de la orbita, elevado lo suficiente para que la
		-- oscilacion mas baja quede claramente sobre el suelo. El rise interpola
		-- de uno a otro suavemente, sin saltos.
		local lift = FLOAT_GROUND_OFFSET + 1.4
		restingPos = landedPivot
		floatAnchorPos = landedPivot + Vector3.new(0, lift + FLOAT_AMPLITUDE, 0)
		state = "Waiting"
		floatTime = 0
		riseElapsed = 0
		waitElapsed = 0
	end

	connection = RunService.RenderStepped:Connect(function(dt)
		if not item.Parent or not rootPart.Parent then
			if connection then
				connection:Disconnect()
				connection = nil
			end
			return
		end

		if state == "Falling" then
			fallElapsed += dt
			local speed = if primary then primary.AssemblyLinearVelocity.Magnitude else 0
			if speed < FALL_REST_SPEED then
				restFrames += 1
			else
				restFrames = 0
			end

			if restFrames >= FALL_REST_FRAMES or fallElapsed >= FALL_MAX_SECONDS then
				_settleAndStartFloat()
			end
			return
		end

		if state == "Waiting" then
			floatTime += dt
			riseElapsed = math.min(FLOAT_RISE_SECONDS, riseElapsed + dt)
			waitElapsed += dt

			local riseRatio = if FLOAT_RISE_SECONDS > 0 then riseElapsed / FLOAT_RISE_SECONDS else 1
			local riseSmoothT = TweenService:GetValue(riseRatio, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
			local centerPos = restingPos:Lerp(floatAnchorPos, riseSmoothT)
			local bob = math.sin(floatTime * FLOAT_FREQUENCY * math.pi * 2) * FLOAT_AMPLITUDE * riseSmoothT
			_setPivot(item, CFrame.new(centerPos + Vector3.new(0, bob, 0)))

			local distToPlayer = (floatAnchorPos - rootPart.Position).Magnitude
			if distToPlayer <= MAGNET_RADIUS and _canPickupHealth(character) then
				state = "Magnet"
				p0 = _getPivotPosition(item) or floatAnchorPos
				local randomOffset = Vector3.new(
					(math.random() - 0.5) * 8,
					math.random(4, 10),
					(math.random() - 0.5) * 8
				)
				p1 = p0 + randomOffset
				local individualSpeed = math.random(85, 115) / 100
				duration = math.clamp(distToPlayer / 35, 0.3, 0.7) * individualSpeed
				return
			end

			if waitElapsed >= EXPIRE_AFTER_SECONDS then
				state = "Despawning"
				despawnElapsed = 0
			end
		elseif state == "Magnet" then
			t += dt / duration
			p2 = rootPart.Position
			if t >= 1 then
				if connection then
					connection:Disconnect()
					connection = nil
				end

				if not picked then
					picked = true

					local sound = Instance.new("Sound")
					sound.SoundId = PICKUP_SOUND_ID
					sound.Volume = 0.25
					sound.PlaybackSpeed = math.random(95, 135) / 100
					sound.Parent = rootPart
					sound:Play()
					Debris:AddItem(sound, 1.5)

					Network.Match.RequestPickup.Send({ kind = "Health" })
				end

				Debris:AddItem(item, 0.1)
				return
			end

			local smoothT = TweenService:GetValue(t, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
			local currentPos = (1 - smoothT)^2 * p0 + 2 * (1 - smoothT) * smoothT * p1 + smoothT^2 * p2
			_setPivot(item, CFrame.new(currentPos))
		elseif state == "Despawning" then
			floatTime += dt
			despawnElapsed = math.min(DESPAWN_TWEEN_SECONDS, despawnElapsed + dt)
			local ratio = if DESPAWN_TWEEN_SECONDS > 0 then despawnElapsed / DESPAWN_TWEEN_SECONDS else 1
			local easedRatio = TweenService:GetValue(ratio, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local scaleRatio = 1 - easedRatio
			_scaleItem(item, scaleRatio, baseScale, basePartSizes)

			local bob = math.sin(floatTime * FLOAT_FREQUENCY * math.pi * 2) * FLOAT_AMPLITUDE
			_setPivot(item, CFrame.new(floatAnchorPos + Vector3.new(0, bob, 0)))

			if despawnElapsed >= DESPAWN_TWEEN_SECONDS then
				if connection then
					connection:Disconnect()
					connection = nil
				end
				item:Destroy()
			end
		end
	end)
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
