local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IsServer = RunService:IsServer()

local WeaponsSystemFolder = script.Parent.Parent
local AnimationsFolder = WeaponsSystemFolder:WaitForChild("Assets"):WaitForChild("Animations")
local AutoAimSystem = require(script.Parent:WaitForChild("AutoAimSystem"))
local WeaponsNetwork = require(script.Parent:WaitForChild("WeaponsNetwork"))
local PewEffect = require(script.Parent:WaitForChild("PewEffect"))
local SharedConstants = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("constants")
local WeaponLevelConfig = require(SharedConstants:WaitForChild("WeaponLevelConfig"))
local WeaponsConfig = require(SharedConstants:WaitForChild("WeaponsConfig"))

-- DEBUG: forzar comportamiento de autoshoot de movil tambien en PC.
-- Poner en false para volver al gating normal por plataforma.
local DEBUG_FORCE_AUTOSHOOT_ON_PC = false

local function _isTouchPrimaryInput(): boolean
	if DEBUG_FORCE_AUTOSHOOT_ON_PC then return true end
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local localRandom = Random.new()

-- W3: throttle del path mobile-only de autoshoot. Antes corría a 60Hz:
-- workspace barrer + 2 raycasts + RaycastParams.new() por frame. 20Hz (50ms)
-- es imperceptible para detectar enemigo bajo el crosshair.
local AUTO_AIM_TICK_INTERVAL = 0.05

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

	-- Config de combate desde WeaponsConfig (Shared), antes del barrido de hijos.
	self:loadConfigFromDefinition()

	-- Set up child added
	self.connections.childAdded = self.instance.ChildAdded:Connect(function(child)
		self:onChildAdded(child)
	end)
	for _, child in self.instance:GetChildren() do
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
				-- Generación invalida delays/defers obsoletos cuando user cambia
				-- de arma rápido — sin esto, auto-reload encolaba barras fantasma.
				self._equipGeneration = (self._equipGeneration or 0) + 1
				local gen = self._equipGeneration

				self:setEquipped(true)
				if self:getAmmoInWeapon() <= 0 then
					-- 200ms: requiere que user "se quede" en el arma antes de
					-- auto-recargar. Switches rápidos no triggean auto-reload.
					task.delay(0.2, function()
						if gen ~= self._equipGeneration then return end
						if not self.equipped then return end
						if self:getAmmoInWeapon() > 0 then return end
						self:reload()
					end)
				end
			end
		end)
		self.connections.unequipped = self.instance.Unequipped:Connect(function()
			if IsServer or (Players.LocalPlayer and (self.instance:IsDescendantOf(Players.LocalPlayer.Backpack) or self.instance:IsDescendantOf(Players.LocalPlayer.Character))) then
				self._equipGeneration = (self._equipGeneration or 0) + 1

				-- Cancelar ANTES de setEquipped(false): onEquippedChanged invoca
				-- setWeaponEquipped que toca currentWeapon/GUI.
				if self.reloading then
					self:cancelReload()
				end
				self:setEquipped(false)
			end
		end)
		-- Auto-equip de un arma que ya está en el workspace cuando se crea este
		-- BaseWeapon (caso típico: un cliente entra a la partida y barre los Tools
		-- ya etiquetados via CollectionService:GetTagged en WeaponsSystem.setup).
		-- En el CLIENTE solo debe auto-equiparse el arma del LocalPlayer: equipar
		-- la de OTRO jugador dispara setWeaponEquipped → enciende la ShoulderCamera
		-- (tercera persona) y la GUI de arma del jugador local aunque esté desarmado
		-- en el lobby (bug: al conectarte con alguien jugando aparecías bugueado).
		-- Coherente con los handlers Equipped/Unequipped de arriba, ya filtrados al
		-- LocalPlayer en cliente.
		if self.instance:IsDescendantOf(workspace) and self.player then
			if IsServer or self.player == Players.LocalPlayer then
				self:setEquipped(true)
			end
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
	for _, name in args do
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
		for _, part in self.instance:GetDescendants() do
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

	-- Cadencia real: BulletWeapon.onFired actualiza nextFireTime con ShotCooldown
	-- (y BurstShotCooldown). Antes esto usaba FireRate, una clave que no existe
	-- en las armas, por lo que el AutoShoot quedaba clavado al fallback de 0.15s
	-- e ignoraba la cadencia configurada por arma.
	if os.clock() < (self.nextFireTime or 0) then
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
	self.lastFireTime = os.clock()

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
		-- Solo el LocalPlayer ve su propio PewEffect — para otros jugadores
		-- y NPCs no se reproduce. (firingPlayer==LocalPlayer + fromNetwork
		-- ya retornó arriba, así que aquí esa combinación es: tu disparo
		-- local fresh.)
		if firingPlayer == Players.LocalPlayer then
			PewEffect.play(self.instance)
		end
	else
		if self:useAmmo(1) <= 0 then
			return
		end

		WeaponsNetwork.broadcastWeaponFired(firingPlayer, self.instance, fireInfo)
	end
end

function BaseWeapon:getConfigValue(valueName, defaultValue)
	local value
	if self.configValues[valueName] ~= nil then
		value = self.configValues[valueName]
	else
		value = defaultValue
	end

	-- Escalado por nivel de arma (1..5). Sólo afecta a stats whitelisted en
	-- WeaponLevelConfig (daño, cadencia, recarga, cargador). El nivel viaja como
	-- atributo `WeaponLevel` en el Tool (lo escribe el servidor; se replica), así
	-- que cliente y servidor calculan el MISMO valor escalado de forma determinista.
	if WeaponLevelConfig.IsScaledStat(valueName) then
		local level = self.instance and self.instance:GetAttribute(WeaponLevelConfig.ATTRIBUTE)
		if type(level) == "number" and level > 1 then
			value = WeaponLevelConfig.ApplyScaling(valueName, value, level)
		end
	end

	return value
end

--[[
	Sprint 3: pool de Sound clones por weapon × soundName (round-robin de 5).

	Antes cada disparo hacía Sound:Clone() + coroutine wait(TimeLength) +
	Destroy. Para una arma automática (ShotCooldown 0.05-0.1s) eso era 10-20
	clones/seg/jugador, todos con el mismo overhead de Instance.new + GC.

	Patrón idéntico al de DamageBillboardHandler.luau:177-196 — round-robin
	pre-clonado de 5 items. Si firerate × duración > 5 overlaps, el sound más
	viejo se reinicia (ya inaudible). Las clones viven en el mismo parent
	que el template y se destruyen junto con el Tool al unequip.
]]

local POOL_PER_SOUND = 5

function BaseWeapon:_getPooledSound(soundName: string): Sound?
	if not self.soundPools then
		self.soundPools = {}
	end

	local pool = self.soundPools[soundName]
	if pool then
		local sound = pool.items[pool.idx]
		pool.idx = (pool.idx % #pool.items) + 1
		return sound
	end

	local template = self.sounds[soundName]
	if not template then
		template = self.instance:FindFirstChild(soundName, true)
		self.sounds[soundName] = template
	end
	if not template then
		return nil
	end

	pool = { items = {} :: { Sound }, idx = 1 }
	for i = 1, POOL_PER_SOUND do
		local clone = (template :: Sound):Clone()
		clone.Parent = (template :: Sound).Parent
		pool.items[i] = clone
	end
	self.soundPools[soundName] = pool

	pool.idx = 2 -- siguiente acquire devolverá items[2]
	return pool.items[1]
end

function BaseWeapon:tryPlaySound(soundName, playbackSpeedRange)
	playbackSpeedRange = playbackSpeedRange or 0

	local sound = self:_getPooledSound(soundName)
	if not sound then
		return
	end

	-- Si la sound estaba sonando (overlap con firerate alto), reiniciar.
	sound.TimePosition = 0
	sound.PlaybackSpeed = sound.PlaybackSpeed + localRandom:NextNumber(-playbackSpeedRange * 0.5, playbackSpeedRange * 0.5)
	sound:Play()

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
	-- Desvincular el render loop por-frame. Se bindea con BindToRenderStep en
	-- onEquippedChanged y se guarda en self.activeRenderStepName (NO en
	-- self.connections), así que el loop de disconnect de abajo no lo toca.
	-- Si el Tool se destruye estando equipado (p.ej. RagdollCleanup borra el
	-- cadáver tras morir, sin que dispare Unequipped), el render seguiría
	-- corriendo para siempre spammeando "No animation controller"/"no aimTrack"
	-- cada frame porque self.instance.Parent ya es nil. Limpiar equipped
	-- garantiza además que los guards `if not self.equipped then return end`
	-- cortan cualquier callback en vuelo.
	if self.activeRenderStepName then
		RunService:UnbindFromRenderStep(self.activeRenderStepName)
		self.activeRenderStepName = nil
	end
	self.equipped = false

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

	-- Sprint 3: destroy pooled sound clones. Si el Tool aún existe (unequip
	-- sin destruir), el pool sigue vivo bajo el Parent del template — sin
	-- limpieza acumularían N×POOL_PER_SOUND clones por re-equip.
	if self.soundPools then
		for _, pool in self.soundPools do
			for _, sound in pool.items do
				pcall(function() sound:Destroy() end)
			end
		end
		table.clear(self.soundPools)
	end
end

--[[
	Carga la config del arma desde WeaponsConfig (Shared/constants/WeaponsConfig),
	resolviendo la identidad del Tool por atributos (ver WeaponsConfig.StampTool).
	WeaponsSystem.createWeaponForInstance ya garantiza que hay definición; si
	aun así faltara, el arma queda con los defaults de cada getConfigValue.
]]
function BaseWeapon:loadConfigFromDefinition()
	local definition = WeaponsConfig.GetForTool(self.instance)
	self.definition = definition
	if not definition then
		warn(string.format("[BaseWeapon] %s no tiene definición en WeaponsConfig; usando defaults.", self.instance:GetFullName()))
		return false
	end

	for valueName, value in definition.Config do
		self.configValues[valueName] = value
		self:onConfigValueChanged(valueName, value, nil)
	end
	return true
end

function BaseWeapon:onChildAdded(child)
	-- La config ya no vive en el Tool. Una Configuration aquí es un resto de
	-- la migración: se ignora, y en Studio se avisa para que se borre.
	if child:IsA("Configuration") and RunService:IsStudio() then
		warn(string.format(
			"[BaseWeapon] %s tiene una Configuration obsoleta que se ignora (la config vive en WeaponsConfig). Bórrala con tools/weapons/StudioMigration.luau.",
			self.instance:GetFullName()
		))
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
	local firedRecently = (os.clock() - self.lastFireTime) < 0.5

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

	-- Autoshoot es exclusivo de móvil. En PC nos saltamos los raycasts de
	-- target-finding por completo.
	if not _isTouchPrimaryInput() then return end

	if Players.LocalPlayer:GetAttribute("AutoShoot") == false then return end

	-- Rocket launcher: nunca autoshoot (riesgo de splash al teammate / al jugador).
	if self:getConfigValue("ExplodeOnImpact", false) then return end

	-- Sniper: solo autoshoot cuando el jugador esta apuntando (ADS).
	if self:getConfigValue("HasScope", false) then
		local cam = self.weaponsSystem and self.weaponsSystem.camera
		if not (cam and cam.isZoomed and cam:isZoomed()) then return end
	end

	-- Detección de target throttled a 20Hz (caro: findBestTarget + 2 raycasts).
	-- El camera pull NO está throttled — corre cada frame con el target cacheado
	-- para evitar el efecto a trompicones al moverse en pasos discretos de 50ms.
	local now = os.clock()
	local lastTickAt = self._autoAimLastTickAt or 0
	local shouldRefreshTarget = (now - lastTickAt) >= AUTO_AIM_TICK_INTERVAL

	if shouldRefreshTarget then
		self._autoAimLastTickAt = now

		local targetPart, targetPos = AutoAimSystem.findBestTarget(self.weaponsSystem)
		local camera = workspace.CurrentCamera

		if targetPart and targetPos and camera and AutoAimSystem.isTargetVisible(camera.CFrame.Position, targetPart) then
			local cameraRay = camera:ViewportPointToRay(camera.ViewportSize.X * 0.5, camera.ViewportSize.Y * 0.5)

			-- W3: RaycastParams + filter cacheados en self. Antes new() + table
			-- literal por frame → GC churn constante. Solo mutamos filter[1] que
			-- cambia con el character (respawn).
			local raycastParams = self._autoAimRaycastParams
			if not raycastParams then
				raycastParams = RaycastParams.new()
				raycastParams.FilterType = Enum.RaycastFilterType.Exclude
				self._autoAimRaycastParams = raycastParams
			end
			local filter = self._autoAimFilter
			if not filter then
				filter = table.create(1)
				self._autoAimFilter = filter
			end
			filter[1] = self.player and self.player.Character or self.instance.Parent
			raycastParams.FilterDescendantsInstances = filter
			local result = workspace:Raycast(cameraRay.Origin, cameraRay.Direction * 1000, raycastParams)

			local isAimingAtEnemy = result and targetPart.Parent
				and result.Instance:IsDescendantOf(targetPart.Parent) or false

			self._autoAimTargetPart = targetPart
			self._autoAimTargetPos = targetPos
			self._autoAimResultPos = result and result.Position or nil
			self._autoAimIsAimingAtEnemy = isAimingAtEnemy
		else
			self._autoAimTargetPart = nil
			self._autoAimTargetPos = nil
			self._autoAimResultPos = nil
			self._autoAimIsAimingAtEnemy = false
		end
	end

	local targetPart = self._autoAimTargetPart
	local targetPos = self._autoAimTargetPos
	if not targetPart or not targetPart.Parent or not targetPos then return end

	local camera = workspace.CurrentCamera
	if not camera then return end
	local cameraOrigin = camera.CFrame.Position

	-- Tracking continuo cada frame (no throttled). Usa `dt` real del Heartbeat
	-- para que el desplazamiento por segundo sea independiente del framerate.
	-- IMPORTANTE: no aplicamos el pull mientras el jugador arrastra la cámara
	-- activamente (touchObj activo). Antes el pull sobreescribía yaw/pitch cada
	-- frame aunque el jugador estuviera moviendo el dedo → la cámara se sentía
	-- magnetizada/bloqueada al enemigo durante el autoshoot y no se podía apuntar
	-- a otro lado. El auto-fire (más abajo) sigue funcionando; solo se cede el
	-- control de encuadre al jugador mientras arrastra.
	local playerIsDraggingCamera = self.weaponsSystem
		and self.weaponsSystem.camera
		and self.weaponsSystem.camera.touchObj ~= nil
	if self.weaponsSystem and self.weaponsSystem.camera and not playerIsDraggingCamera then
		local directionToTarget = (targetPos - cameraOrigin).Unit
		local desiredYaw = math.atan2(-directionToTarget.X, -directionToTarget.Z)
		local desiredPitch = math.asin(directionToTarget.Y)

		local currentYaw = self.weaponsSystem.camera.yaw
		local currentPitch = self.weaponsSystem.camera.pitch

		local deltaYaw = desiredYaw - currentYaw
		while deltaYaw > math.pi do deltaYaw = deltaYaw - math.pi * 2 end
		while deltaYaw < -math.pi do deltaYaw = deltaYaw + math.pi * 2 end

		local deltaPitch = desiredPitch - currentPitch

		-- Interpolación `delta * (strength * dt)` por frame: asintótica (nunca snap),
		-- y al correr a cada frame en vez de cada 50ms el movimiento se siente
		-- continuo en lugar de a trompicones.
		local pullStrength = if self._autoAimIsAimingAtEnemy then (4.5 * dt) else (7.0 * dt)

		self.weaponsSystem.camera.yaw = currentYaw + deltaYaw * pullStrength
		self.weaponsSystem.camera.pitch = math.clamp(
			currentPitch + deltaPitch * pullStrength,
			self.weaponsSystem.camera.minPitch,
			self.weaponsSystem.camera.maxPitch
		)
	end

	-- Path de auto-fire: corre cada frame (no gated por el refresh de target) para
	-- igualar la cadencia del disparo manual, que también chequea nextFireTime
	-- cada frame en BulletWeapon:onStepped. Si lo gateamos a 20Hz, hasta 50ms de
	-- latencia se suman cuando nextFireTime cae entre ticks → autoshoot percibido
	-- como más lento. nextFireTime ya bloquea el spam de cadencia.
	if not self._autoAimIsAimingAtEnemy then return end

	-- Shotgun: no auto-disparar si el target esta fuera del rango optimo.
	if self.instance and self.instance:GetAttribute("Shotgun") == true then
		local optimalRange = self.instance:GetAttribute("OptimalRange")
		if type(optimalRange) ~= "number" or optimalRange <= 0 then
			optimalRange = 30
		end
		if (targetPos - cameraOrigin).Magnitude > optimalRange then return end
	end

	-- Auto-fire respeta la cadencia real del arma. BulletWeapon.onFired actualiza
	-- nextFireTime con ShotCooldown / BurstShotCooldown tras cada disparo, igual
	-- que el flujo manual de fuego (ver BulletWeapon.onActivatedChanged).
	if os.clock() < (self.nextFireTime or 0) then return end

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
			muzzlePart = self.instance:FindFirstChild("TipAttachment", true)
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

	-- Trayectoria directa: del muzzle al punto exacto del raycast del crosshair,
	-- sin blend hacia el cuerpo del enemigo (no aimbot en las balas).
	local resultPos = self._autoAimResultPos or targetPos
	local direction = (resultPos - weaponOrigin).Unit
	local charge = self.charge or 0

	-- Hitscan: marcar para que simulateProjectile resuelva el impacto
	-- instantáneamente en vez de simular un proyectil con viaje. Así el
	-- auto-fire no falla contra enemigos en movimiento.
	self._hitscanMode = true
	self:fire(weaponOrigin, direction, charge)
	self._hitscanMode = nil
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
		self:getAmmoInWeapon() >= self:getConfigValue("AmmoCapacity", 30)
	then
		return false
	end

	-- Solo la weapon actualmente equipada puede iniciar reload en cliente.
	if not IsServer then
		local cw = self.weaponsSystem and self.weaponsSystem.currentWeapon
		if cw ~= self then
			return false
		end
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
			-- :Once — con :Connect cada recarga acumulaba una conexión viva sobre
			-- los clones del soundPool, que persisten toda la vida del arma.
			self.curReloadSound.Ended:Once(function()
				self.curReloadSound = nil
			end)
		end
	end

	local reloadTime = self:getConfigValue("ReloadTime", 2)
	local startTime = os.clock()

	-- GUI solo si esta weapon es la currentWeapon del LocalPlayer.
	if not IsServer and self.weaponsSystem.gui
		and self.player == Players.LocalPlayer
		and self.weaponsSystem.currentWeapon == self then
		self.weaponsSystem.gui:playReloadProgressAnimation(reloadTime)
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
		-- L9: restaurar canReload tras una recarga completada normalmente. Antes
		-- quedaba en false y solo useAmmo/cancelReload lo reponían, dejando una
		-- weapon a tope (que nunca disparó) incapaz de volver a recargar.
		self.canReload = true
	end)
end

function BaseWeapon:cancelReload(player, fromNetwork)
	if not self.reloading then
		return
	end
	if fromNetwork and player == Players.LocalPlayer then
		return
	end

	-- `not fromNetwork` (no `player == LocalPlayer`) — cancelReload se llama
	-- desde Unequipped sin args, así garantizamos que server recibe el cancel.
	if not IsServer and not fromNetwork then
		WeaponsNetwork.fireReloadCanceled(self.instance)
	elseif IsServer and fromNetwork then
		WeaponsNetwork.broadcastReloadCanceled(player, self.instance)
	end

	self.reloading = false
	self.instance:SetAttribute("IsReloading", false)
	self._reloadToken = (self._reloadToken or 0) + 1
	self.canReload = true

	if not IsServer and self.reloadTrack and self.reloadTrack.IsPlaying then
		self.reloadTrack:Stop()
	end

	if self.curReloadSound then
		-- Stop SIN Destroy: el sonido viene del soundPool round-robin (5 clones
		-- que viven toda la vida del arma). Destruirlo dejaba un clon muerto en
		-- pool.items — tras 5 reloads cancelados el arma se quedaba sin sonido
		-- de recarga para siempre.
		self.curReloadSound:Stop()
		self.curReloadSound = nil
	end

	if not IsServer and self.player == Players.LocalPlayer
		and self.weaponsSystem and self.weaponsSystem.gui
		and self.weaponsSystem.gui.stopReloadProgressAnimation then
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
