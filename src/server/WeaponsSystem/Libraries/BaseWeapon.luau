local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local IsServer = RunService:IsServer()

local WeaponsSystemFolder = script.Parent.Parent
local AnimationsFolder = WeaponsSystemFolder:WaitForChild("Assets"):WaitForChild("Animations")
local AutoAimSystem = require(script.Parent:WaitForChild("AutoAimSystem"))
local WeaponsNetwork = require(script.Parent:WaitForChild("WeaponsNetwork"))

local function _isTouchPrimaryInput(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local localRandom = Random.new()

local BaseWeapon = {}
BaseWeapon.__index = BaseWeapon

BaseWeapon.CanAimDownSights = false
BaseWeapon.CanBeReloaded = false
BaseWeapon.CanBeFired = false
BaseWeapon.CanHit = false

function BaseWeapon.new(weaponsSystem, instance)
	assert(instance, "BaseWeapon.new() requires a valid Instance to be attached to.")

	local self = setmetatable({}, BaseWeapon)
	self.connections = {}
	self.descendants = {}
	self.descendantsRegistered = false
	self.optionalDescendantNames = {}
	self.weaponsSystem = weaponsSystem
	self.instance = instance
	self.animController = nil
	self.player = nil
	self.enabled = false
	self.equipped = false
	self.activated = false
	self.nextShotId = 1
	self.activeRenderStepName = nil
	self.curReloadSound = nil
	self.lastFireTime = 0

	self.animTracks = {}
	self.sounds = {}
	self.configValues = {}
	self.trackedConfigurations = {}

	self.reloading = false
	self.canReload = true

	self:registerDescendants()
	self.connections.descendantAdded = self.instance.DescendantAdded:Connect(function(descendant)
		self:onDescendantAdded(descendant)
	end)

	if IsServer then
		self.instance:SetAttribute("IsReloading", false)
	end

	return self
end

function BaseWeapon:doInitialSetup()
	local selfClass = getmetatable(self)
	self.instanceIsTool = self.instance:IsA("Tool")

	-- Set up child added/removed
	self.connections.childAdded = self.instance.ChildAdded:Connect(function(child)
		self:onChildAdded(child)
	end)
	self.connections.childRemoved = self.instance.ChildRemoved:Connect(function(child)
		self:onChildRemoved(child)
	end)
	for _, child in pairs(self.instance:GetChildren()) do
		self:onChildAdded(child)
	end

	-- CurrentAmmo attribute must be created by user on the Tool (number type)
	if selfClass.CanBeReloaded then
		local currentAmmo = self.instance:GetAttribute("CurrentAmmo")
		if currentAmmo == nil then
			warn(string.format("[BaseWeapon] Missing CurrentAmmo attribute on %s. Create it as a number attribute in Studio.", self.instance:GetFullName()))
		end
	end

	self.connections.ancestryChanged = self.instance.AncestryChanged:Connect(function() self:onAncestryChanged() end)
	self:onAncestryChanged()

	-- Set up equipped/unequipped and activated/deactivated
	if self.instanceIsTool then
		self.connections.equipped = self.instance.Equipped:Connect(function()
			if IsServer or (Players.LocalPlayer and (self.instance:IsDescendantOf(Players.LocalPlayer.Backpack) or self.instance:IsDescendantOf(Players.LocalPlayer.Character))) then
				self:setEquipped(true)
				if self:getAmmoInWeapon() <= 0 then
					-- Esperar un frame: si no, la animación de recarga no se reproduce.
					task.defer(function()
						self:reload()
					end)
				end
			end
		end)
		self.connections.unequipped = self.instance.Unequipped:Connect(function()
			if IsServer or (Players.LocalPlayer and (self.instance:IsDescendantOf(Players.LocalPlayer.Backpack) or self.instance:IsDescendantOf(Players.LocalPlayer.Character))) then
				self:setEquipped(false)
				if self.reloading then
					self:cancelReload()
				end
			end
		end)
		if self.instance:IsDescendantOf(workspace) and self.player then
			self:setEquipped(true)
		end

		self.connections.activated = self.instance.Activated:Connect(function()
			self:setActivated(true)
		end)
		self.connections.deactivated = self.instance.Deactivated:Connect(function()
			self:setActivated(false)
		end)

		-- Weld handle to weapon primary part
		if IsServer then
			self.handle = self.instance:FindFirstChild("Handle")

			local model = self.instance:FindFirstChildOfClass("Model")
			if model then
				local handleAttachment = model:FindFirstChild("HandleAttachment", true)

				if self.handle and handleAttachment then
					local handleOffset = model.PrimaryPart.CFrame:toObjectSpace(handleAttachment.WorldCFrame)

					local weld = Instance.new("Weld")
					weld.Name = "HandleWeld"
					weld.Part0 = self.handle
					weld.Part1 = model.PrimaryPart
					weld.C0 = CFrame.new()
					weld.C1 = handleOffset
					weld.Parent = self.handle

					self.handle.Anchored = false
					model.PrimaryPart.Anchored = false
				end
			end
		end
	end
end

function BaseWeapon:registerDescendants()
	if not self.instance then
		error("No instance set yet!")
	end

	if self.descendantsRegistered then
		warn("Descendants already registered!")
		return
	end

	for _, descendant in ipairs(self.instance:GetDescendants()) do
		if self.descendants[descendant.Name] == nil then
			self.descendants[descendant.Name] = descendant
		else
			self.descendants[descendant.Name] = "Multiple"
		end
	end
	self.descendantsRegistered = true
end

function BaseWeapon:addOptionalDescendant(key, descendantName)
	if self.instance == nil then
		error("No instance set yet!")
	end

	if not self.descendantsRegistered then
		error("Descendants not registered!")
	end

	if self.descendants[descendantName] == "Multiple" then
		error("Weapon \""..self.instance.Name.."\" has multiple descendants named \""..descendantName.."\", so you cannot addOptionalDescendant with that descendant name.")
	end

	local found = self.descendants[descendantName]
	if found then
		self[key] = found
		return
	else
		self.optionalDescendantNames[descendantName] = key
	end
end

function BaseWeapon:onDescendantAdded(descendant)
	if self.descendants[descendant.Name] == nil then
		self.descendants[descendant.Name] = descendant
	else
		self.descendants[descendant.Name] = "Multiple"
	end

	local desiredKey = self.optionalDescendantNames[descendant.Name]
	if desiredKey then
		if self.descendants[descendant.Name] == "Multiple" then
			error("Weapon \""..self.instance.Name.."\" has multiple descendants named \""..descendant.Name.."\", so you cannot addOptionalDependency with that descendant name.")
		end
		self[desiredKey] = descendant
		self.optionalDescendantNames[descendant.Name] = nil
	end
end

function BaseWeapon:cleanupConnection(...)
	local args = { ... }
	for _, name in pairs(args) do
		if typeof(name) == "string" and self.connections[name] then
			self.connections[name]:Disconnect()
			self.connections[name] = nil
		end
	end
end

function BaseWeapon:onAncestryChanged()
	if self.instanceIsTool then
		local player = nil
		if self.instance:IsDescendantOf(Players) then
			local parentPlayer = self.instance.Parent.Parent
			if parentPlayer and parentPlayer:IsA("Player") then
				player = parentPlayer
			end
		elseif self.instance:IsDescendantOf(workspace) then
			local parentPlayer = Players:GetPlayerFromCharacter(self.instance.Parent)
			if parentPlayer and parentPlayer:IsA("Player") then
				player = parentPlayer
			end
		end

		self:setPlayer(player)
	end
end

function BaseWeapon:setPlayer(player)
	if self.player == player then
		return
	end

	self.player = player
end

function BaseWeapon:setEquipped(equipped)
	if self.equipped == equipped then
		return
	end

	self.equipped = equipped
	self:onEquippedChanged()

	if not self.equipped then
		self:stopAnimations()
	end
end

function BaseWeapon:onEquippedChanged()
	if self.activeRenderStepName then
		RunService:UnbindFromRenderStep(self.activeRenderStepName)
		self.activeRenderStepName = nil
	end
	self:cleanupConnection("localStepped")

	if not IsServer and self.weaponsSystem then
		self.weaponsSystem.setWeaponEquipped(self, self.equipped)
		if self.equipped then
			if self.player == Players.LocalPlayer then
				local renderStepName = self.activeRenderStepName or ("WeaponRenderStep_" .. tostring(self))
				RunService:BindToRenderStep(renderStepName, Enum.RenderPriority.Input.Value, function(dt)
					self:onRenderStepped(dt)
				end)
				self.activeRenderStepName = renderStepName
			end
			self.connections.localStepped = RunService.Heartbeat:Connect(function(dt)
				self:onStepped(dt)
			end)
		end
	end

	if self.instanceIsTool then
		for _, part in pairs(self.instance:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = part ~= self.handle and not self.equipped
			end
		end
	end

	self:setActivated(false)
end

function BaseWeapon:setActivated(activated, fromNetwork)
	if not IsServer and fromNetwork and self.player == Players.LocalPlayer then
		return
	end

	if self.activated == activated then
		return
	end

	-- Server-side debounce: descarta cambios de estado más rápidos que ACTIVATE_DEBOUNCE
	-- (protege contra spam por exploit del RemoteEvent).
	if IsServer and fromNetwork then
		local now = os.clock()
		local last = self._lastActivatedAt or 0
		if now - last < 0.1 then
			return
		end
		self._lastActivatedAt = now
	end

	self.activated = activated
	if IsServer and not fromNetwork then
		WeaponsNetwork.broadcastWeaponActivated(self.player, self.instance, self.activated)
	end

	self:onActivatedChanged()
end

function BaseWeapon:onActivatedChanged()

end

function BaseWeapon:renderFire(fireInfo)

end

function BaseWeapon:simulateFire(fireInfo)

end

function BaseWeapon:isOwnerAlive()
	if self.instance:IsA("Tool") then
		local humanoid = self.instance.Parent:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid:GetState() ~= Enum.HumanoidStateType.Dead
		end
	end

	return true
end

function BaseWeapon:fire(origin, dir, charge)
	if not self:isOwnerAlive() or self.reloading then
		return
	end

	local fireRate = self:getConfigValue("FireRate", 0)
	local cooldown = fireRate > 0 and (60 / fireRate) or AutoAimSystem.FIRE_COOLDOWN
	local now = tick()

	if (now - self.lastFireTime) < cooldown then
		return
	end

	if self:useAmmo(1) <= 0 then
		self:reload()
		return
	end

	local fireInfo = {}
	fireInfo.origin = origin
	fireInfo.dir = dir
	fireInfo.charge = math.clamp(charge or 1, 0, 1)
	fireInfo.id = self.nextShotId
	self.nextShotId = self.nextShotId + 1
	self.lastFireTime = tick()

	if not IsServer then
		self:onFired(self.player, fireInfo, false)
		WeaponsNetwork.fireWeaponFired(self.instance, fireInfo)
	else
		self:onFired(self.player, fireInfo, false)
	end
end

function BaseWeapon:onFired(firingPlayer, fireInfo, fromNetwork)
	if not IsServer then
		if firingPlayer == Players.LocalPlayer and fromNetwork then
			return
		end

		self:simulateFire(firingPlayer, fireInfo)
	else
		if self:useAmmo(1) <= 0 then
			return
		end

		WeaponsNetwork.broadcastWeaponFired(firingPlayer, self.instance, fireInfo)
	end
end

function BaseWeapon:getConfigValue(valueName, defaultValue)
	if self.configValues[valueName] ~= nil then
		return self.configValues[valueName]
	else
		return defaultValue
	end
end

function BaseWeapon:tryPlaySound(soundName, playbackSpeedRange)
	playbackSpeedRange = playbackSpeedRange or 0

	local soundTemplate = self.sounds[soundName]
	if not soundTemplate then
		soundTemplate = self.instance:FindFirstChild(soundName, true)
		self.sounds[soundName] = soundTemplate
	end

	if not soundTemplate then
		return
	end

	local sound = soundTemplate:Clone()
	sound.PlaybackSpeed = sound.PlaybackSpeed + localRandom:NextNumber(-playbackSpeedRange * 0.5, playbackSpeedRange * 0.5)
	sound.Parent = soundTemplate.Parent
	sound:Play()
	coroutine.wrap(function()
		wait(sound.TimeLength / sound.PlaybackSpeed)
		sound:Destroy()
	end)()

	return sound
end

function BaseWeapon:getSound(soundName)
	local soundTemplate = self.sounds[soundName]
	if not soundTemplate then
		soundTemplate = self.instance:FindFirstChild(soundName, true)
		self.sounds[soundName] = soundTemplate
	end

	return soundTemplate
end

function BaseWeapon:onDestroyed()
	-- Disconnect all RBXScriptConnections
	if self.connections then
		for name, conn in self.connections do
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			end
			self.connections[name] = nil
		end
	end

	-- Stop and detach any cached animation tracks
	if self.animTracks then
		for name, track in self.animTracks do
			if typeof(track) == "Instance" then
				pcall(function()
					(track :: AnimationTrack):Stop(0)
				end)
			end
			self.animTracks[name] = nil
		end
	end

	-- Clear sound template cache (don't destroy — they live in the instance tree)
	if self.sounds then
		table.clear(self.sounds)
	end
end

function BaseWeapon:onConfigValueAdded(valueObj)
	local valueName = valueObj.Name
	local newValue = valueObj.Value
	self.configValues[valueName] = newValue
	self:onConfigValueChanged(valueName, newValue, nil)

	self.connections["valueChanged:" .. valueName] = valueObj.Changed:Connect(function(changedValue)
		local oldValue = self.configValues[valueName]
		self.configValues[valueName] = changedValue

		self:onConfigValueChanged(valueName, changedValue, oldValue)
	end)
	self.connections["valueRenamed:" .. valueName] = valueObj:GetPropertyChangedSignal("Name"):Connect(function()
		self.configValues[valueName] = nil
		self:cleanupConnection("valueChanged:" .. valueName)
		self:cleanupConnection("valueRenamed:" .. valueName)
		self:onConfigValueAdded(valueObj)
	end)
end

function BaseWeapon:onConfigValueRemoved(valueObj)
	local valueName = valueObj.Name
	self.configValues[valueName] = nil

	self:cleanupConnection("valueChanged:" .. valueName)
	self:cleanupConnection("valueRenamed:" .. valueName)
end

-- This function is used to set configuration values from outside configuration objects/folders
function BaseWeapon:importConfiguration(config)
	if not config or not config:IsA("Configuration") then
		for _, child in pairs(config:GetChildren()) do
			if child:IsA("ValueBase") then
				local valueName = child.Name
				local newValue = child.Value
				local oldValue = self.configValues[valueName]
				self.configValues[valueName] = newValue
				self:onConfigValueChanged(valueName, newValue, oldValue)
			end
		end
	end
end

function BaseWeapon:setConfiguration(config)
	self:cleanupConnection("configChildAdded", "configChildRemoved")
	if not config or not config:IsA("Configuration") then
		return
	end

	for _, child in pairs(config:GetChildren()) do
		if child:IsA("ValueBase") then
			self:onConfigValueAdded(child)
		end
	end
	self.connections.configChildAdded = config.ChildAdded:Connect(function(child)
		if child:IsA("ValueBase") then
			self:onConfigValueAdded(child)
		end
	end)
	self.connections.configChildRemoved = config.ChildRemoved:Connect(function(child)
		if child:IsA("ValueBase") then
			self:onConfigValueRemoved(child)
		end
	end)
end

function BaseWeapon:onChildAdded(child)
	if child:IsA("Configuration") then
		self:setConfiguration(child)
	end
end

function BaseWeapon:onChildRemoved(child)
	if child:IsA("Configuration") then
		self:setConfiguration(nil)
	end
end

function BaseWeapon:onConfigValueChanged(valueName, newValue, oldValue)

end

function BaseWeapon:onRenderStepped(dt)
	if not self.equipped then
		return
	end
	if not self.instance or not self.instance.Parent then
		self:stopAnimations()
		return
	end

	local isSprinting = false
	if self.weaponsSystem and self.weaponsSystem.camera then
		isSprinting = self.weaponsSystem.camera.isSprinting
	end

	-- Check if we fired recently
	local firedRecently = (tick() - self.lastFireTime) < 0.5

	-- Prioritize reload: Do not play run animation if reloading
	if self.reloading then
		isSprinting = false
	end

	local runTrackKey = self:getConfigValue("RunAnimation", "Run")
	local runTrack = self.animTracks[runTrackKey]

	if isSprinting and not firedRecently then
		if not runTrack then
			runTrack = self:getAnimTrack(runTrackKey)
			if runTrack then
				runTrack.Looped = true
			end
		end

		if runTrack and not runTrack.IsPlaying then
			runTrack:Play(0.2)
		end
	else
		if runTrack and runTrack.IsPlaying then
			runTrack:Stop(0.2)
		end
	end
end

function BaseWeapon:onStepped(dt)
	if not self.equipped or IsServer then return end
	if self.player ~= Players.LocalPlayer then return end
	if self.reloading then return end

	local selfClass = getmetatable(self)
	if not selfClass.CanBeFired then return end

	local targetPart, targetPos = AutoAimSystem.findBestTarget(self.weaponsSystem)
	if not targetPart or not targetPos then return end

	-- Verify line of sight from camera
	local camera = workspace.CurrentCamera
	if not camera then return end
	local cameraOrigin = camera.CFrame.Position

	if not AutoAimSystem.isTargetVisible(cameraOrigin, targetPart) then return end

	local cameraRay = camera:ViewportPointToRay(camera.ViewportSize.X * 0.5, camera.ViewportSize.Y * 0.5)
	local targetHitPoint = cameraRay.Origin + cameraRay.Direction * 1000

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { self.player and self.player.Character or self.instance.Parent }
	local result = workspace:Raycast(cameraRay.Origin, cameraRay.Direction * 1000, raycastParams)

	local isAimingAtEnemy = false
	if result then
		targetHitPoint = result.Position
		if targetPart and targetPart.Parent and result.Instance:IsDescendantOf(targetPart.Parent) then
			isAimingAtEnemy = true
		end
	end

	-- Soft camera pull (Aim Assist)
	if self.weaponsSystem and self.weaponsSystem.camera then
		local directionToTarget = (targetPos - cameraOrigin).Unit
		local desiredYaw = math.atan2(-directionToTarget.X, -directionToTarget.Z)
		local desiredPitch = math.asin(directionToTarget.Y)

		local currentYaw = self.weaponsSystem.camera.yaw
		local currentPitch = self.weaponsSystem.camera.pitch

		local deltaYaw = desiredYaw - currentYaw
		while deltaYaw > math.pi do deltaYaw = deltaYaw - math.pi * 2 end
		while deltaYaw < -math.pi do deltaYaw = deltaYaw + math.pi * 2 end

		local deltaPitch = desiredPitch - currentPitch

		-- AutoShoot solo en movil; en PC dejamos un aim assist mucho mas sutil.
		local isTouchInput = _isTouchPrimaryInput()
		local pullStrength: number
		if isTouchInput then
			pullStrength = isAimingAtEnemy and (1.5 * dt) or (4.5 * dt)
		else
			pullStrength = isAimingAtEnemy and (0.2 * dt) or (0.6 * dt)
		end

		self.weaponsSystem.camera.yaw = currentYaw + deltaYaw * pullStrength
		self.weaponsSystem.camera.pitch = math.clamp(
			currentPitch + deltaPitch * pullStrength,
			self.weaponsSystem.camera.minPitch,
			self.weaponsSystem.camera.maxPitch
		)
	end

	-- Auto-fire cooldown check
	local now = tick()
	local fireRate = self:getConfigValue("FireRate", 0)
	local cooldown = fireRate > 0 and (60 / fireRate) or AutoAimSystem.FIRE_COOLDOWN
	if (now - self.lastFireTime) < cooldown then return end
	if not _isTouchPrimaryInput() then return end

	-- Determine weapon muzzle origin matching BulletWeapon's self.tipAttach precisely.
	-- El lookup se cachea: el subárbol del Tool no cambia en runtime, y los
	-- FindFirstChild recursivos (true) son caros — esto se ejecutaba en cada
	-- disparo del auto-aim.
	local weaponOrigin = cameraOrigin
	if self.tipAttach then
		weaponOrigin = self.tipAttach.WorldPosition
	else
		local muzzlePart = self._cachedMuzzlePart
		if not muzzlePart or not muzzlePart.Parent then
			muzzlePart = self.instance:FindFirstChild("TipAttachment", true) or
				self.instance:FindFirstChild("Muzzle", true) or
				self.instance:FindFirstChild("FirePoint", true) or
				self.instance:FindFirstChild("Tip", true) or
				self.instance:FindFirstChild("Hole", true)
			self._cachedMuzzlePart = muzzlePart
		end

		if muzzlePart then
			if muzzlePart:IsA("Attachment") then
				weaponOrigin = muzzlePart.WorldPosition
			elseif muzzlePart:IsA("BasePart") then
				weaponOrigin = muzzlePart.Position
			end
		else
			-- Fallback if no muzzle object is found
			local weaponModel = self.instance:FindFirstChildOfClass("Model")
			if weaponModel and weaponModel.PrimaryPart then
				weaponOrigin = weaponModel.PrimaryPart.Position
			elseif self.handle then
				weaponOrigin = self.handle.Position
			end
		end
	end

	local crosshairDirection = (targetHitPoint - weaponOrigin).Unit
	local enemyDirection = (targetPos - weaponOrigin).Unit

	-- Soft aim assist: blend bullet trajectory if not already aiming precisely at the body
	local direction = crosshairDirection
	if not isAimingAtEnemy then
		direction = crosshairDirection:Lerp(enemyDirection, 0.4).Unit
	end

	local charge = self.charge or 0
	self:fire(weaponOrigin, direction, charge)
end

function BaseWeapon:getAnimationController()
	if self.animController then
		if not self.instanceIsTool or (self.animController.Parent and self.animController.Parent:IsAncestorOf(self.instance)) then
			return self.animController
		end
	end

	self:setAnimationController(nil)

	if self.instanceIsTool then
		if not self.instance or not self.instance.Parent then
			return nil
		end

		local humanoid = nil
		local owner = self.instance.Parent
		if IsServer then
			humanoid = owner:FindFirstChildOfClass("Humanoid")
		else
			-- Client: wait for humanoid with reasonable timeout
			humanoid = owner:FindFirstChildOfClass("Humanoid")
			if not humanoid and owner.Parent then
				humanoid = owner:WaitForChild("Humanoid", 5)
			end
		end
		local animController = nil
		if not humanoid then
			animController = owner:FindFirstChildOfClass("AnimationController")
		end

		self:setAnimationController(humanoid or animController)
		return self.animController
	end
end

function BaseWeapon:setAnimationController(animController)
	if animController == self.animController then
		return
	end
	self:stopAnimations()
	self.animController = animController
end

function BaseWeapon:stopAnimations()
	for _, track in pairs(self.animTracks) do
		if track.IsPlaying then
			track:Stop()
		end
	end
	self.animTracks = {}
end

function BaseWeapon:getAnimTrack(key)
	local track = self.animTracks[key]
	if not track then
		local animController = self:getAnimationController()
		if not animController then
			warn("No animation controller when trying to play ", key)
			return nil
		end

		local animation = AnimationsFolder:FindFirstChild(key)
		if not animation then
			error(string.format("No such animation \"%s\" ", tostring(key)))
		end

		track = animController:LoadAnimation(animation)
		self.animTracks[key] = track
	end

	return track
end

function BaseWeapon:reload(player, fromNetwork)
	if
		not self.equipped or
		self.reloading or
		not self.canReload or
		self:getAmmoInWeapon() == self:getConfigValue("AmmoCapacity", 30)
	then
		return false
	end

	if not IsServer then
		if self.player ~= nil and self.player ~= Players.LocalPlayer then
			return
		end
		WeaponsNetwork.fireReloadRequest(self.instance)
		self:onReloaded(self.player)
	else
		self:onReloaded(player, fromNetwork)
		WeaponsNetwork.broadcastReloaded(player, self.instance)
	end
end

function BaseWeapon:onReloaded(player, fromNetwork)
	if fromNetwork and player == Players.LocalPlayer then -- make sure localplayer doesn't reload twice
		return
	end

	self.reloading = true
	self.instance:SetAttribute("IsReloading", true)

	self.canReload = false

	-- Play reload animation and sound
	if not IsServer then
		local reloadTrackKey = self:getConfigValue("ReloadAnimation", "RifleReload")
		if reloadTrackKey then
			self.reloadTrack = self:getAnimTrack(reloadTrackKey)
			if self.reloadTrack then
				self.reloadTrack:Play()
			end
		end

		self.curReloadSound = self:tryPlaySound("Reload", nil)
		if self.curReloadSound then
			self.curReloadSound.Ended:Connect(function()
				self.curReloadSound = nil
			end)
		end
	end

	local reloadTime = self:getConfigValue("ReloadTime", 2)
	local startTime = tick()

	-- Trigger reload progress bar animation on client
	if not IsServer and self.weaponsSystem.gui then
		--print("[BaseWeapon] Calling playReloadProgressAnimation with reloadTime:", reloadTime, "on weapon:", self.instance:GetFullName())
		self.weaponsSystem.gui:playReloadProgressAnimation(reloadTime)
	else
		--print("[BaseWeapon] Not calling animation - IsServer:", IsServer, "gui exists:", self.weaponsSystem.gui ~= nil)
	end

	-- Token-based: en vez de un Heartbeat ejecutándose 60 veces/seg verificando
	-- si pasó el tiempo, agendamos el cierre de la recarga con task.delay y
	-- usamos un token incremental para invalidar callbacks superpuestos
	-- (cancelReload o un nuevo reload mientras este aún no terminó).
	self._reloadToken = (self._reloadToken or 0) + 1
	local token = self._reloadToken

	task.delay(reloadTime, function()
		if self._reloadToken ~= token then return end
		if not self.reloading then return end

		self.instance:SetAttribute("CurrentAmmo", self:getConfigValue("AmmoCapacity", 30))
		self.reloading = false
		self.instance:SetAttribute("IsReloading", false)
		self.canReload = false
	end)
end

function BaseWeapon:cancelReload(player, fromNetwork)
	if not self.reloading then
		return
	end
	if fromNetwork and player == Players.LocalPlayer then
		return
	end

	if not IsServer and not fromNetwork and player == Players.LocalPlayer then
		WeaponsNetwork.fireReloadCanceled(self.instance)
	elseif IsServer and fromNetwork then
		WeaponsNetwork.broadcastReloadCanceled(player, self.instance)
	end

	self.reloading = false
	self.instance:SetAttribute("IsReloading", false)

	self.canReload = true

	if not IsServer and self.reloadTrack and self.reloadTrack.IsPlaying then
		warn("Stopping reloadTrack")
		self.reloadTrack:Stop()
	end
	if self.curReloadSound then
		self.curReloadSound:Stop()
		self.curReloadSound:Destroy()
		self.curReloadSound = nil
	end

	if not IsServer and self.weaponsSystem.gui and self.weaponsSystem.gui.stopReloadProgressAnimation then
		self.weaponsSystem.gui:stopReloadProgressAnimation()
	end
end

function BaseWeapon:getAmmoInWeapon()
	return self.instance:GetAttribute("CurrentAmmo") or 0
end

function BaseWeapon:useAmmo(amount)
	local currentAmmo = self.instance:GetAttribute("CurrentAmmo") or 0
	local ammoUsed = math.min(amount, currentAmmo)
	self.instance:SetAttribute("CurrentAmmo", currentAmmo - ammoUsed)
	self.canReload = true
	return ammoUsed
end

function BaseWeapon:renderCharge()

end

return BaseWeapon
