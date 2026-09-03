local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local IsServer = RunService:IsServer()

local WeaponsSystemFolder = script.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local BaseWeapon = require(Libraries:WaitForChild("BaseWeapon"))
local Parabola = require(Libraries:WaitForChild("Parabola"))
local Roblox = require(Libraries:WaitForChild("Roblox"))
local WeaponsNetwork = require(Libraries:WaitForChild("WeaponsNetwork"))
local HitVFX = require(Libraries:WaitForChild("HitVFX"))
local TeamUtils = require(Shared.utils.TeamUtils)

local Effects = WeaponsSystemFolder:WaitForChild("Assets"):WaitForChild("Effects")
local ShotsFolder = Effects:WaitForChild("Shots")
local HitMarksFolder = Effects:WaitForChild("HitMarks")

local NO_BULLET_DECALS = false

--The ignore list will fill up over time. This is how many seconds it will go before
--being refreshed in order to keep it from filling up with instances that aren't in
--the datamodel anymore.
local IGNORE_LIST_LIFETIME = 5

local MAX_BULLET_TIME = 2
-- Gravedad base aplicada al proyectil — multiplicada por gravityFactor del config.
local PROJECTILE_GRAVITY_BASE = 35
-- Umbrales de subdivisión de la trayectoria parabólica (más samples = más detección
-- de impactos en arcos pronunciados, pero más raycasts).
local PARABOLA_HIGH_GRAVITY_THRESHOLD = 0.66
local PARABOLA_MID_GRAVITY_THRESHOLD = 0.33
local PARABOLA_SAMPLES_HIGH = 3
local PARABOLA_SAMPLES_MID = 2
local PARABOLA_SAMPLES_LOW = 1

local localRandom = Random.new()
local localPlayer = not IsServer and Players.LocalPlayer

-- W2: bucle global de proyectiles. Antes cada bala creaba su propia conexión
-- Heartbeat (con shotgun NumProjectiles=8 + auto-fire son decenas de
-- conexiones simultáneas por jugador). Ahora una única conexión itera
-- activeProjectiles y libera entries marcadas inactive via swap-remove.
type ProjectileEntry = { active: boolean, callback: ((number) -> ())? }
local activeProjectiles: { ProjectileEntry } = {}
local projectileLoopConn: RBXScriptConnection? = nil

-- W5: buffer reusado para serializar hitInfo al servidor. Antes cada impacto
-- (shotgun → 8/shot) creaba una tabla nueva + bucle de copia. FireServer
-- serializa de forma síncrona, así que es seguro mutar el buffer entre llamadas.
local _hitInfoSendBuffer: { [string]: any } = {}

-- W13: pool de bulletEffect clones por template. Antes shotgun (8 proj/shot)
-- × autofire 10 RPS = 80 clones/seg de modelos complejos (beams, sounds,
-- particles). Cada clone es un árbol Instance.new + property copies por
-- descendant — caro en mobile. El pool reusa instancias inactive (Parent=nil)
-- y solo clona cuando se vacía. Al release: stop sounds, disable beams,
-- park con Parent=nil. Próximo acquire reusa el mismo árbol — beam/sound/
-- particle refs vía FindFirstChild devuelven los mismos objetos.
local _bulletEffectPool: { [Instance]: { Instance } } = {}
local BULLET_EFFECT_POOL_MAX_PER_TEMPLATE = 32

local function _acquireBulletEffect(template: Instance, parent: Instance): Instance
	local pool = _bulletEffectPool[template]
	if pool then
		local n = #pool
		if n > 0 then
			local effect = pool[n]
			pool[n] = nil
			effect.Parent = parent
			return effect
		end
	end
	local effect = template:Clone()
	effect.Parent = parent
	CollectionService:AddTag(effect, "WeaponsSystemIgnore")
	return effect
end

-- Devuelve los attachments de un beam a su origen (offset local cero) y aplana la
-- curva. Necesario al parquear en el pool: renderToBeam sobrescribe estas posiciones
-- CADA frame, pero el beam se re-enable ANTES del primer render del siguiente disparo
-- (el render vive en el stepped callback del Heartbeat siguiente). Sin reset, ese
-- primer frame dibuja el beam entre los extremos del disparo ANTERIOR — pudiendo
-- aparecer detrás del jugador. Con los offsets a cero, el frame residual es un beam
-- de longitud cero en el muzzle (invisible).
local function _resetBeamAttachments(beam: Beam)
	local att0, att1 = beam.Attachment0, beam.Attachment1
	if att0 then
		att0.CFrame = CFrame.identity
	end
	if att1 then
		att1.CFrame = CFrame.identity
	end
	beam.CurveSize0 = 0
	beam.CurveSize1 = 0
end

local function _releaseBulletEffect(template: Instance, effect: Instance)
	-- Limpiar estado audible/visual antes de parquear. Beams quedan apagados
	-- (siguiente acquire los re-enable), sonidos paran (siguiente Play arranca
	-- de cero), CFrame se sobrescribe en simulateProjectile.
	local beam0 = effect:FindFirstChild("Beam0")
	if beam0 and beam0:IsA("Beam") then
		beam0.Enabled = false
		_resetBeamAttachments(beam0)
	end
	local beam1 = effect:FindFirstChild("Beam1")
	if beam1 and beam1:IsA("Beam") then
		beam1.Enabled = false
		_resetBeamAttachments(beam1)
	end
	local flyingSound = effect:FindFirstChild("Flying", true)
	if flyingSound and flyingSound:IsA("Sound") then flyingSound:Stop() end
	local hitSound = effect:FindFirstChild("HitSound", true)
	if hitSound and hitSound:IsA("Sound") then hitSound:Stop() end

	-- W13b: restaurar propiedades que mutamos durante la vida del proyectil
	-- a los valores del template. Sin esto, el siguiente acquire saldría con
	-- Transparency=1 (la bala se ve invisible) y leadingParticles.Rate=0
	-- (no emite trail). El template nunca se muta, así que es la fuente
	-- canónica de los defaults.
	if template:IsA("BasePart") and effect:IsA("BasePart") then
		effect.Transparency = template.Transparency
	end
	local effectLeading = effect:FindFirstChild("LeadingParticles", true)
	local templateLeading = template:FindFirstChild("LeadingParticles", true)
	if effectLeading and templateLeading
		and effectLeading:IsA("ParticleEmitter")
		and templateLeading:IsA("ParticleEmitter")
	then
		effectLeading.Rate = templateLeading.Rate
	end

	local pool = _bulletEffectPool[template]
	if not pool then
		pool = {}
		_bulletEffectPool[template] = pool
	end
	if #pool >= BULLET_EFFECT_POOL_MAX_PER_TEMPLATE then
		effect:Destroy()
		return
	end
	effect.Parent = nil
	table.insert(pool, effect)
end

local function _projectileLoopTick(dt: number)
	local i = 1
	while i <= #activeProjectiles do
		local entry = activeProjectiles[i]
		if entry.active and entry.callback then
			-- pcall opcional aquí evitaría que una bala con bug detenga el
			-- bucle global. Dejado fuera para no enmascarar errores reales —
			-- los callbacks son código nuestro, no input externo.
			entry.callback(dt)
		end
		if not entry.active then
			local n = #activeProjectiles
			activeProjectiles[i] = activeProjectiles[n]
			activeProjectiles[n] = nil
		else
			i += 1
		end
	end
	if #activeProjectiles == 0 and projectileLoopConn then
		projectileLoopConn:Disconnect()
		projectileLoopConn = nil
	end
end

local function _ensureProjectileLoop()
	if projectileLoopConn then return end
	projectileLoopConn = RunService.Heartbeat:Connect(_projectileLoopTick)
end

local BulletWeapon = {}
BulletWeapon.__index = BulletWeapon
setmetatable(BulletWeapon, BaseWeapon)

local function isEnemyHumanoidForPlayer(humanoid, player)
	if not humanoid or not player or not player.Character then
		return true
	end

	local targetCharacter = humanoid.Parent
	if not targetCharacter or not targetCharacter:IsA("Model") then
		return true
	end

	return TeamUtils.areEnemies(player.Character, targetCharacter)
end

-- Los VFX de impacto a jugador (HitVFX body/headshot) solo deben mostrarse contra
-- enemigos: al disparar a un aliado del propio equipo no se emiten partículas.
-- Impactos que no son contra un Humanoid (superficies) no se bloquean aquí —
-- HitVFX ya es no-op para ellos.
local function shouldPlayPlayerHitVFX(hitInfo, player): boolean
	local h = hitInfo.h
	if h and typeof(h) == "Instance" and h:IsA("Humanoid") then
		return isEnemyHumanoidForPlayer(h, player)
	end
	return true
end

BulletWeapon.CanAimDownSights = true
BulletWeapon.CanBeFired = true
BulletWeapon.CanBeReloaded = true
BulletWeapon.CanHit = true

function BulletWeapon.new(weaponsSystem, instance)
	local self = BaseWeapon.new(weaponsSystem, instance)
	setmetatable(self, BulletWeapon)

	self.usesCharging = false
	self.charge = 0
	self.chargeSoundPitchMin = 0.5
	self.chargeSoundPitchMax = 1

	self.triggerDisconnected = false
	self.startupFinished = false -- TODO: make startup time use a configuration value
	self.burstFiring = false
	self.burstIdx = 0
	self.nextFireTime = 0

	self.recoilIntensity = 0
	self.aimPoint = Vector3.new()

	-- Retroceso visual del arma (kick hacia atrás al disparar). Es puramente
	-- client-side y SOLO lo ve el LocalPlayer: offseteamos un joint (el grip
	-- hand↔Handle, o el HandleWeld como fallback) en el cliente, que no replica
	-- (mismo patrón que ShoulderCamera:applyRootJointFix, que setea rootJoint.C0
	-- por frame en el cliente sin afectar a otros). Preferimos el grip porque
	-- mueve el arma ENTERA (todo es rígido respecto al Handle), sin depender de
	-- cómo esté soldado el modelo internamente. _viewKick es el acumulador 0..1
	-- que sube por disparo y decae por frame.
	self._viewKick = 0
	self._viewKickJoint = nil :: (Weld | Motor6D)? -- joint a offsetear
	self._viewKickProp = "C1" -- "C0" o "C1", según de qué lado esté la parte movida
	self._viewKickBase = nil :: CFrame? -- valor base del prop offseteado
	self._viewKickPart = nil :: BasePart? -- la parte que se mueve (Handle o PrimaryPart)

	self:addOptionalDescendant("tipAttach", "TipAttachment")

	self:addOptionalDescendant("chargeGlowPart", "ChargeGlow")
	self:addOptionalDescendant("chargeCompleteParticles", "ChargeCompleteParticles")
	self:addOptionalDescendant("dischargeCompleteParticles", "DischargeCompleteParticles")

	self:addOptionalDescendant("muzzleFlash0", "MuzzleFlash0")
	self:addOptionalDescendant("muzzleFlash1", "MuzzleFlash1")
	self:addOptionalDescendant("muzzleFlashBeam", "MuzzleFlash")

	-- Los templates de efectos salen de la config, así que se resuelven después
	-- de doInitialSetup (ver _resolveEffectTemplates).
	self.bulletEffectTemplate = nil
	self.hitMarkTemplate = nil

	self.ignoreList = {}
	self.ignoreListRefreshTime = 0

	self:addOptionalDescendant("handAttach", "LeftHandAttachment")
	self.handAlignPos = nil
	self.handAlignRot = nil

	self.chargingParticles = {}
	-- W15: guardar la conexión en self.connections para que onDestroyed la
	-- limpie. Antes era orphan: si BulletWeapon se destruía antes del Tool
	-- (re-equip, switch de arma), el listener seguía vivo con upvalue stale.
	self.connections.chargingParticlesAdded = self.instance.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "ChargingParticles" and descendant:IsA("ParticleEmitter") then
			table.insert(self.chargingParticles, descendant)
		end
	end)
	for _, v in self.instance:GetDescendants() do
		if v.Name == "ChargingParticles" and v:IsA("ParticleEmitter") then
			table.insert(self.chargingParticles, v)
		end
	end

	self:doInitialSetup()
	self:_resolveEffectTemplates()

	return self
end

--[[
	Resuelve los templates de efectos (bala y marca de impacto) desde la config.

	Sólo puede correr DESPUÉS de doInitialSetup: es él quien carga la definición,
	y hasta entonces getConfigValue no sabe caer al default del esquema (devolvía
	nil y FindFirstChild(nil) reventaba la creación del arma entera).

	onConfigValueChanged no basta por sí solo: sólo se dispara por las claves que
	la definición DECLARA, y la mayoría de armas no declaran ShotEffect ni
	HitMarkEffect — heredan el default del esquema ("Bullet"/"BulletHole").
]]
function BulletWeapon:_resolveEffectTemplates()
	self:_resolveShotEffect()
	self:_resolveHitMarkEffect()
end

function BulletWeapon:_resolveShotEffect()
	local effectName = self:getConfigValue("ShotEffect")
	self.bulletEffectTemplate = if effectName then ShotsFolder:FindFirstChild(effectName) else nil
	if not self.bulletEffectTemplate then
		warn(string.format(
			"[BulletWeapon] %s: sin template de bala para ShotEffect=%s (Assets.Effects.Shots)",
			self.instance:GetFullName(), tostring(effectName)
		))
		return
	end

	local beam0 = self.bulletEffectTemplate:FindFirstChild("Beam0")
	-- Audit mobile: preload una sola vez por beam0 (cacheado al nivel de la
	-- instancia). Antes cada onConfigValueChanged disparaba un coroutine de
	-- PreloadAsync (yield real al backend), incluso si ya habíamos pedido ese
	-- mismo beam0 previamente.
	if beam0 and self._preloadedBeam0 ~= beam0 then
		self._preloadedBeam0 = beam0
		task.spawn(function()
			ContentProvider:PreloadAsync({ beam0 })
		end)
	end
end

function BulletWeapon:_resolveHitMarkEffect()
	local effectName = self:getConfigValue("HitMarkEffect")
	self.hitMarkTemplate = if effectName then HitMarksFolder:FindFirstChild(effectName) else nil
end

function BulletWeapon:onEquippedChanged()
	BaseWeapon.onEquippedChanged(self)

	if not IsServer then
		if self.weaponsSystem.camera then
			if self.equipped then
				self.startupFinished = false
			end
		end

		if self.equipped then
			ContextActionService:BindAction("ReloadWeapon", function(...) self:onReloadAction(...) end, false, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
		else
			ContextActionService:UnbindAction("ReloadWeapon")

			-- Al desequipar, deshacer cualquier retroceso visual pendiente para no
			-- dejar el arma desplazada (y soltar el ref del joint del tool anterior).
			self:_resetViewKick()
			self._viewKickJoint = nil

			-- Stop charging/discharging sounds
			local chargingSound = self:getSound("Charging")
			local dischargingSound = self:getSound("Discharging")
			if chargingSound and chargingSound.Playing then
				chargingSound:Stop()
			end
			if dischargingSound and dischargingSound.Playing then
				dischargingSound:Stop()
			end
		end

		self.triggerDisconnected = false

		-- Re-sincroniza el gatillo con el botón físico al equipar. Si el jugador
		-- cambia de arma SIN soltar el disparo (p. ej. mientras apunta y dispara a
		-- la vez), Roblox no vuelve a emitir Tool.Activated para el botón que ya
		-- estaba mantenido, así que el arma recién equipada nunca se entera de que
		-- el gatillo sigue presionado y no dispara hasta soltar y volver a pulsar.
		-- Solo cliente y solo para el arma del jugador local.
		if self.equipped and self.player == Players.LocalPlayer then
			if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				self:setActivated(true)
			end
		end
	end
end

function BulletWeapon:onReloadAction(actionName, inputState, inputObj)
	if inputState == Enum.UserInputState.Begin and not self.reloading then
		self:reload()
	end
end

function BulletWeapon:getRandomSeedForId(id)
	return id
end

-- Emite partículas de muzzle desde el bulletEffect.
-- W8: 1 emit + 1 escritura Velocity por proyectil (antes 5 + 5). La dispersión
-- por-partícula viene del SpreadAngle/VelocitySpread del template ParticleEmitter
-- (configurado en el .rbxm). Con shotgun (NumProjectiles=8) eran 40 writes + 40
-- emits/shot.
local function _emitMuzzleParticles(bulletEffect: Instance, origin: Vector3, dir: Vector3, totalParticles: number)
	local muzzleParticles = bulletEffect:FindFirstChild("MuzzleParticles", true)
	if not muzzleParticles then
		return
	end
	local emitter = muzzleParticles.Parent
	emitter.CFrame = CFrame.new(origin, origin + dir)
	emitter.Velocity = Vector3.new(
		localRandom:NextNumber(-10, 10),
		localRandom:NextNumber(-10, 10),
		localRandom:NextNumber(-10, 10)
	)
	muzzleParticles:Emit(totalParticles)
end

-- Muestra el muzzle flash en self.tipAttach. Devuelve true si se mostró (para que el caller
-- pueda hacer fade-out con timer).
function BulletWeapon:_showMuzzleFlash(randomGenerator: Random): boolean
	if not (self.tipAttach and self.muzzleFlash0 and self.muzzleFlash1 and self.muzzleFlashBeam) then
		return false
	end

	local minFlashRotation = self:getConfigValue("MuzzleFlashRotation0")
	local maxFlashRotation = self:getConfigValue("MuzzleFlashRotation1")
	local minFlashSize = self:getConfigValue("MuzzleFlashSize0")
	local maxFlashSize = self:getConfigValue("MuzzleFlashSize1")
	local flashRotation = randomGenerator:NextNumber(minFlashRotation, maxFlashRotation)
	local flashSize = randomGenerator:NextNumber(minFlashSize, maxFlashSize)
	local baseCFrame = self.tipAttach.CFrame * CFrame.Angles(0, 0, flashRotation)
	self.muzzleFlash0.CFrame = baseCFrame * CFrame.new(flashSize * -0.5, 0, 0) * CFrame.Angles(0, math.pi, 0)
	self.muzzleFlash1.CFrame = baseCFrame * CFrame.new(flashSize * 0.5, 0, 0) * CFrame.Angles(0, math.pi, 0)

	self.muzzleFlashBeam.Enabled = true
	self.muzzleFlashBeam.Width0 = flashSize
	self.muzzleFlashBeam.Width1 = flashSize
	return true
end

-- Spawnea un hitMark sobre la superficie golpeada (decals/billboards). Lo weldéa al hitPart
-- y lo destruye automáticamente tras HIT_MARK_LIFETIME segundos.
local HIT_MARK_LIFETIME = 5

-- Efecto "caliente": el impacto arranca incandescente (rojo) y se enfría a blanco
-- neutro. En un Decal/Texture, Color3 = blanco no tinta la imagen, así que el
-- estado final es el aspecto normal del agujero; el rojo inicial simula el calor.
local HIT_MARK_HEAT_START = Color3.fromRGB(255, 120, 30) -- naranja incandescente
local HIT_MARK_HEAT_END = Color3.fromRGB(255, 255, 255) -- blanco (sin tinte)
local HIT_MARK_HEAT_DURATION = 1.5
local HIT_MARK_HEAT_TWEEN = TweenInfo.new(HIT_MARK_HEAT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Aplica el gradiente de enfriamiento rojo→blanco al hitMark recién spawneado.
-- Tinta tanto la parte (Color) como cualquier Decal/Texture (Color3) para no
-- depender de la estructura interna del template.
function BulletWeapon:_applyHitMarkHeat(hitMark: Instance)
	if hitMark:IsA("BasePart") then
		hitMark.Color = HIT_MARK_HEAT_START
		TweenService:Create(hitMark, HIT_MARK_HEAT_TWEEN, { Color = HIT_MARK_HEAT_END }):Play()
	end
	for _, descendant in hitMark:GetDescendants() do
		if descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Color3 = HIT_MARK_HEAT_START
			TweenService:Create(descendant, HIT_MARK_HEAT_TWEEN, { Color3 = HIT_MARK_HEAT_END }):Play()
		end
	end
end

function BulletWeapon:_spawnHitMark(hitPart: BasePart, hitPoint: Vector3, hitNormal: Vector3, parabola: any)
	if NO_BULLET_DECALS or not hitPart or not hitPart.Parent or not self.hitMarkTemplate then
		return
	end
	-- Barreras de colisión invisibles: los mapas las usan para cerrar el paso sin
	-- que se vean, y la marca se quedaba flotando en el aire. Se corta ANTES del
	-- clone, así que ahorra el clone, el weld, los tweens de calor y el Debris —
	-- con una escopeta (NumProjectiles = 8) eso es todo eso por perdigón.
	--
	-- Se filtra por transparencia y no por tag a propósito: vale en los mapas que
	-- ya existen sin etiquetarlos uno a uno, un mapa nuevo no puede olvidarse de
	-- la regla, y leer una propiedad cruda es más barato que HasTag/GetAttribute.
	-- Además es la regla correcta de por sí: una marca sobre algo que no se ve
	-- siempre sobra, sea barrera o no.
	--
	-- Ojo si algún día hay una parte invisible cuyo aspecto lo pone un Decal o
	-- SurfaceGui hijo (un cartel sin geometría): esa también se quedaría sin
	-- marca, y haría falta un tag de excepción aquí.
	if hitPart.Transparency >= 1 then
		return
	end
	if hitPart.Parent:FindFirstChildOfClass("Humanoid") then
		return
	end

	local hitPointObjectSpace = hitPart.CFrame:pointToObjectSpace(hitPoint)
	local hitNormalObjectSpace = hitPart.CFrame:vectorToObjectSpace(hitNormal)
	if not hitPointObjectSpace or not hitNormalObjectSpace then
		return
	end

	local hitMark = self.hitMarkTemplate:Clone()
	hitMark.Parent = hitPart
	CollectionService:AddTag(hitMark, "WeaponsSystemIgnore")

	local incomingVec = parabola:sampleVelocity(1).Unit
	if self:getConfigValue("AlignHitMarkToNormal") then
		local forward = hitNormalObjectSpace
		local up = incomingVec
		local right = -forward:Cross(up).Unit
		up = forward:Cross(right)
		local orientationCFrame = CFrame.fromMatrix(hitPointObjectSpace + hitNormalObjectSpace * 0.05, right, up, -forward)
		hitMark.CFrame = hitPart.CFrame:toWorldSpace(orientationCFrame)
	else
		hitMark.CFrame = hitPart.CFrame * CFrame.new(hitPointObjectSpace, hitPointObjectSpace + hitPart.CFrame:vectorToObjectSpace(incomingVec))
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hitMark
	weld.Part1 = hitPart
	weld.Parent = hitMark

	if self:getConfigValue("HitMarkHeatEffect") then
		self:_applyHitMarkHeat(hitMark)
	end

	Debris:AddItem(hitMark, HIT_MARK_LIFETIME)
end

-- This function is only called on clients
function BulletWeapon:simulateFire(firingPlayer, fireInfo)
	BaseWeapon.simulateFire(self, fireInfo)

	-- Play "Fired" sound
	if self.lastFireSound then
		self.lastFireSound:Stop()
	end
	self.lastFireSound = self:tryPlaySound("Fired", self:getConfigValue("FiredPlaybackSpeedRange"))

	-- Simulate each projectile/bullet fired from current weapon
	local numProjectiles = self:getConfigValue("NumProjectiles")
	local randomGenerator = Random.new(self:getRandomSeedForId(fireInfo.id))
	for i = 1, numProjectiles do
		self:simulateProjectile(firingPlayer, fireInfo, i, randomGenerator)
	end

	if self.player == Players.LocalPlayer then
		-- Temblor de cámara inmediato al disparar (independiente del recoil
		-- vertical, que va con RecoilDelayTime). Configurable por arma:
		-- ShakeIntensity acumula trauma, ShakeFOVKick añade un punch de FOV leve.
		local shakeIntensity = self:getConfigValue("ShakeIntensity")
		if shakeIntensity > 0 then
			self.weaponsSystem.camera:addCameraShake(shakeIntensity, self:getConfigValue("ShakeFOVKick"))
		end

		-- Retroceso visual del modelo del arma: acumula kick (clamp a 1 para que el
		-- full-auto no lo mande al infinito). onRenderStepped lo aplica y decae.
		self._viewKick = math.min(self._viewKick + self:getConfigValue("ViewKickPerShot"), 1)

		coroutine.wrap(function()
			-- W12: task.wait sólo. El RenderStepped:Wait extra que había aquí
			-- añadía 1 frame (~16ms) de latencia sin propósito documentado —
			-- el recoil delay ya está cubierto por task.wait.
			local recoilDelayTime = self:getConfigValue("RecoilDelayTime")
			task.wait(recoilDelayTime)

			-- Add recoil to camera
			local recoilMin, recoilMax = self:getConfigValue("RecoilMin"), self:getConfigValue("RecoilMax")
			local intensityToAdd = randomGenerator:NextNumber(recoilMin, recoilMax)
			local xIntensity = math.sin(os.clock() * 2) * intensityToAdd * math.rad(0.05)
			local yIntensity = intensityToAdd * 0.025
			self.weaponsSystem.camera:addRecoil(Vector2.new(xIntensity, yIntensity))

			if not (self.weaponsSystem.camera:isZoomed() and self:getConfigValue("HasScope")) then
				self.recoilIntensity = math.clamp(self.recoilIntensity * 1 + (intensityToAdd / 10), 0.005, 1)
			end

			-- Make crosshair reflect recoil/spread amount
			local weaponsGui = self.weaponsSystem.gui
			if weaponsGui then
				weaponsGui:setCrosshairScale(1 + intensityToAdd)
			end
		end)()
	end
end

function BulletWeapon:getIgnoreList(includeLocalPlayer)
	local now = os.clock()
	local ignoreList = self.ignoreList
	if not ignoreList or now - self.ignoreListRefreshTime > IGNORE_LIST_LIFETIME then
		ignoreList = {
			self.instanceIsTool and self.instance.Parent or self.instance,
			workspace.CurrentCamera
		}
		if not RunService:IsServer() then
			if includeLocalPlayer and Players.LocalPlayer and Players.LocalPlayer.Character then
				table.insert(ignoreList, Players.LocalPlayer.Character)
			end
		end
		self.ignoreList = ignoreList
		self.ignoreListRefreshTime = now
	end
	return ignoreList
end

-- This function is only called on clients
function BulletWeapon:simulateProjectile(firingPlayer, fireInfo, projectileIdx, randomGenerator)
	local localPlayerInitiatedShot = self.player == Players.LocalPlayer

	-- Retrieve config values
	local bulletSpeed = self:getConfigValue("BulletSpeed")
	local maxDistance = self:getConfigValue("MaxDistance")
	-- Tracer: always show the full trajectory from origin to current bullet position
	local tracerFadeTime = self:getConfigValue("TracerFadeTime")
	local gravityFactor = self:getConfigValue("GravityFactor")
	local minSpread = self:getConfigValue("MinSpread")
	local maxSpread = self:getConfigValue("MaxSpread")
	local shouldMovePart = self:getConfigValue("ShouldMovePart")
	local explodeOnImpact = self:getConfigValue("ExplodeOnImpact")
	local blastRadius = self:getConfigValue("BlastRadius")

	-- Cheat the origin of the shot back if gun tip in wall/object.
	-- Solo en el disparo del jugador local: el cheat-back recasta desde detrás del
	-- cañón, y su ignore list únicamente excluye al personaje del tirador cuando es
	-- el LocalPlayer (ver getIgnoreList). Al re-simular el disparo de un jugador
	-- remoto, el recast chocaría contra el propio cuerpo del tirador y reubicaría
	-- fireInfo.origin DETRÁS de él (beam saliendo por la espalda). El tirador ya
	-- aplicó este ajuste antes de enviar el fireInfo por red, así que aquí se salta.
	if self.tipAttach ~= nil and localPlayerInitiatedShot then
		local tipCFrame = self.tipAttach.WorldCFrame
		local tipPos = tipCFrame.Position
		local tipDir = tipCFrame.LookVector
		-- Algunas armas (ej. Tool de NPC) pueden no tener un BasePart "Handle"
		-- estándar — usar self.handle si existe, o saltar el cheat-back.
		local handlePart = self.handle or self.instance:FindFirstChild("Handle")
		if handlePart and handlePart:IsA("BasePart") then
			local amountToCheatBack = math.abs((handlePart.Position - tipPos):Dot(tipDir)) + 1
			local gunRay = Ray.new(tipPos - tipDir.Unit * amountToCheatBack, tipDir.Unit * amountToCheatBack)
			local hitPart, hitPoint = Roblox.penetrateCast(gunRay, self:getIgnoreList(localPlayerInitiatedShot))
			if hitPart and math.abs((tipPos - hitPoint).Magnitude) > 0 then
				fireInfo.origin = hitPoint - tipDir.Unit * 0.1
				fireInfo.dir = tipDir.Unit
			end
		end
	end

	local origin, dir = fireInfo.origin, fireInfo.dir

	dir = Roblox.applySpread(dir, randomGenerator, math.rad(minSpread), math.rad(maxSpread))

	-- Initialize variables for visuals/particle effects
	-- W13: pool en lugar de Clone+Destroy por proyectil. Mismo template/instance
	-- vuelve al pool al destruir y se reusa en el próximo disparo.
	local bulletEffectTemplate = self.bulletEffectTemplate
	local bulletEffect = _acquireBulletEffect(bulletEffectTemplate, workspace.CurrentCamera)
	bulletEffect.CFrame = CFrame.new(origin, origin + dir)

	local leadingParticles = bulletEffect:FindFirstChild("LeadingParticles", true)

	local hitAttach = bulletEffect:FindFirstChild("HitEffect")
	local hitParticles = bulletEffect:FindFirstChild("HitParticles", true)
	local numHitParticles = self:getConfigValue("NumHitParticles")
	local hitSound = bulletEffect:FindFirstChild("HitSound", true)
	local flyingSound = bulletEffect:FindFirstChild("Flying", true)

	local muzzleFlashTime = self:getConfigValue("MuzzleFlashTime")
	local muzzleFlashShown = false

	local beamThickness0 = self:getConfigValue("BeamWidth0")
	local beamThickness1 = self:getConfigValue("BeamWidth1")

	-- Enable beam trails for projectile
	local beam0 = bulletEffect:FindFirstChild("Beam0")
	if beam0 then
		beam0.Enabled = true
	end
	local beam1 = bulletEffect:FindFirstChild("Beam1")
	if beam1 then
		beam1.Enabled = true
	end

	-- Emit muzzle particles
	local numMuzzleParticles = self:getConfigValue("NumMuzzleParticles")
	_emitMuzzleParticles(bulletEffect, origin, dir, numMuzzleParticles)

	-- Show muzzle flash (solo en el primer proyectil de un disparo multi-bala)
	if projectileIdx == 1 then
		muzzleFlashShown = self:_showMuzzleFlash(localRandom)
	end

	-- Play projectile flying sound
	if flyingSound then
		flyingSound:Play()
	end

	-- Set up parabola for projectile path
	local parabola = Parabola.new()
	parabola:setPhysicsLaunch(origin, dir * bulletSpeed, nil, -PROJECTILE_GRAVITY_BASE * gravityFactor)
	-- More samples for higher gravity since path will be more curved but raycasts can only be straight lines
	if gravityFactor > PARABOLA_HIGH_GRAVITY_THRESHOLD then
		parabola:setNumSamples(PARABOLA_SAMPLES_HIGH)
	elseif gravityFactor > PARABOLA_MID_GRAVITY_THRESHOLD then
		parabola:setNumSamples(PARABOLA_SAMPLES_MID)
	else
		parabola:setNumSamples(PARABOLA_SAMPLES_LOW)
	end

	-- ── Hitscan: resolución instantánea del impacto ──────────────
	-- En auto-fire móvil, el proyectil viaja tan rápido como un raycast:
	-- resolvemos el hit en el mismo frame en vez de simular viaje por tiempo.
	-- El tracer visual se muestra igualmente y se desvanece con tracerFadeTime.
	if self._hitscanMode and localPlayerInitiatedShot then
		parabola:setDomain(0, maxDistance)
		local hitPart, hitPoint, hitNormal, hitMaterial, hitT = parabola:findPart(self:getIgnoreList(true))

		local projEnd = if hitPart then hitT * maxDistance else maxDistance
		parabola:setDomain(0, projEnd)

		if hitPart then
			local hitDist = (hitPoint - origin).Magnitude
			local hitInfo = {
				sid = fireInfo.id,
				pid = projectileIdx,
				maxDist = projEnd,
				part = hitPart,
				p = hitPoint,
				n = hitNormal,
				m = hitMaterial,
				d = hitDist,
				t = hitT,
			}
			self:onHit(hitInfo)

			-- Diferir el envío del hit: BaseWeapon:fire() llama onFired (→ aquí)
			-- ANTES de fireWeaponFired. Si enviamos el hit síncronamente, el
			-- server lo recibe antes de que el shot esté registrado y validateHit
			-- lo descarta con "unknown sid". task.defer encola tras fire().
			local hitPayload = {}
			for k, v in pairs(hitInfo) do
				hitPayload[k] = v
			end
			local weaponInst = self.instance
			task.defer(function()
				WeaponsNetwork.fireWeaponHit(weaponInst, hitPayload)
			end)

			-- VFX de impacto: sistema modular por superficie (HitVFX) por
			-- defecto; fallback al hitSound heredado si ModularHitVFX = false.
			if self:getConfigValue("ModularHitVFX") then
				if shouldPlayPlayerHitVFX(hitInfo, self.player) then
					HitVFX.play(hitInfo, localPlayerInitiatedShot)
				end
			elseif hitSound then
				hitSound:Play()
			end
			self:_spawnHitMark(hitPart, hitPoint, hitNormal, parabola)
		end

		-- Tracer: renderizar beam desde origin hasta el final, luego fade-out.
		if beam0 then parabola:renderToBeam(beam0) end
		if beam1 then parabola:renderToBeam(beam1) end

		task.delay(tracerFadeTime, function()
			if bulletEffect then
				_releaseBulletEffect(bulletEffectTemplate, bulletEffect)
			end
		end)

		if not IsServer and self.usesCharging then
			self.charge = math.clamp(self.charge - self:getConfigValue("FireDischarge"), 0, 1)
		end
		return
	end

	-- Set up/initialize variables used in steppedCallback
	-- W2: stepConn ahora es un stub. Su `:Disconnect()` marca la entry como
	-- inactive — el bucle global la elimina via swap-remove en la próxima
	-- iteración. El closure no se entera del cambio (sigue usando upvalue
	-- stepConn igual que antes).
	local projectileEntry: ProjectileEntry = { active = true, callback = nil }
	local stepConn = { Disconnect = function() projectileEntry.active = false end }
	local pTravelDistance = 0 -- projected travel distance so far if projectile never stops
	local startTime = os.clock()
	local didHit = false
	local stoppedMotion = false
	local stoppedMotionAt = 0
	local timeSinceStart = 0
	local flyingVisualEffectsFinished = false -- true if all particle effects shown while projectile is flying are done
	local visualEffectsFinishTime = math.huge
	local visualEffectsLingerTime = tracerFadeTime
	local hitInfo = {
		sid = fireInfo.id,
		pid = projectileIdx,
		maxDist = maxDistance,
		part = nil,
		p = nil,
		n = nil,
		m = Enum.Material.Air,
		d = 1e9,
	}

	-- Ignore list para los raycasts del proyectil. Construirla vía getIgnoreList
	-- (igual que el path hitscan) garantiza ignorar al tirador/cámara incluso en
	-- armas sin TipAttachment, donde self.ignoreList nunca se puebla (queda {})
	-- y la bala colisionaría contra el propio tirador en el primer frame.
	local projectileIgnoreList = self:getIgnoreList(localPlayerInitiatedShot)

	local steppedCallback = function(dt)
		local now = os.clock()
		timeSinceStart = now - startTime

		local travelDist = bulletSpeed * dt -- distance projectile has travelled since last frame

		-- Tracer: always show from origin (0) to current bullet position
		local projBack = 0 -- always start from the origin
		local projFront = pTravelDistance -- most forward part of projectile
		local maxDist = hitInfo.maxDist or 0 -- before it collides, this is the max distance the projectile can travel. After it collides, this is the hit point

		-- Clamp front to max distance
		projFront = math.clamp(projFront, 0, maxDist)

		if not didHit then
			-- Check if bullet hit since last frame
			local castProjBack, castProjFront = projFront, projFront + travelDist
			parabola:setDomain(castProjBack, castProjFront)
			local hitPart, hitPoint, hitNormal, hitMaterial, hitT = parabola:findPart(projectileIgnoreList)

			if hitPart then
				didHit = true
				projFront = castProjBack + hitT * (castProjFront - castProjBack) -- set projFront to point along projectile arc where an object was hit
				parabola:setDomain(projBack, projFront) -- update parabola domain to match new projFront

				-- Update hitInfo
				hitInfo.part = hitPart
				hitInfo.p = hitPoint
				hitInfo.n = hitNormal
				hitInfo.m = hitMaterial
				hitInfo.d = (hitPoint - origin).Magnitude
				hitInfo.t = hitT
				hitInfo.maxDist = projFront -- since the projectile hit, maxDist is now the hitPoint instead of maxDistance

				-- Register hit on clients
				self:onHit(hitInfo)

				-- Notify the server that this projectile hit something from client that initiated the shot
				-- Show hit indicators on gui of client that shot projectile
				if localPlayerInitiatedShot then
					-- W5: reuse del buffer module-level. FireServer serializa
					-- sincronamente, así que el contenido se envía antes de
					-- volver y podemos sobrescribir en el siguiente impacto.
					table.clear(_hitInfoSendBuffer)
					for hitInfoKey, value in pairs(hitInfo) do
						_hitInfoSendBuffer[hitInfoKey] = value
					end
					WeaponsNetwork.fireWeaponHit(self.instance, _hitInfoSendBuffer)
				end


				-- Deal with all effects that start/stop/change on hit

				-- Stop bullet flying sound
				if flyingSound and flyingSound.IsPlaying then
					flyingSound:Stop()
				end

				-- Hide the actual projectile model
				if bulletEffect then
					bulletEffect.Transparency = 1
				end

				-- Stop emitting leading particles
				if leadingParticles then
					leadingParticles.Rate = 0
					visualEffectsLingerTime = math.max(visualEffectsLingerTime, leadingParticles.Lifetime.Max)
				end

				-- Show the explosion on clients for explosive projectiles. Visible=false
				-- porque las partículas custom se reproducen vía PlayExplosionVFX
				-- broadcast — el flash naranja default de Roblox compite visualmente.
				if explodeOnImpact then
					local explosion = Instance.new("Explosion")
					explosion.Position = hitPoint + (hitNormal * 0.5)
					explosion.BlastRadius = blastRadius
					explosion.BlastPressure = 0 -- no blast pressure because the real explosion happens on server
					explosion.ExplosionType = Enum.ExplosionType.NoCraters
					explosion.DestroyJointRadiusPercent = 0
					explosion.Visible = false
					if localPlayerInitiatedShot then
						-- Trigger hit indicators on client that initiated the shot if the explosion hit another player/humanoid
						explosion.Hit:Connect(function(explodedPart, hitDist)
							local humanoid = self.weaponsSystem.getHumanoid(explodedPart)
							if humanoid and
								explodedPart.Name == "UpperTorso" and
								humanoid:GetState() ~= Enum.HumanoidStateType.Dead and
								self.weaponsSystem.gui and
								explodedPart.Parent ~= self.player.Character and
								isEnemyHumanoidForPlayer(humanoid, self.player)
							then
								self.weaponsSystem.gui:OnHitOtherPlayer(self:calculateDamage(hitInfo.d), humanoid, explodedPart)
							end
						end)
					end
					explosion.Parent = workspace
				end

				-- Make sure hitAttach is in correct position before showing hit effects
				if hitAttach and beam0 and beam0.Attachment1 then
					parabola:renderToBeam(beam0)
					hitAttach.CFrame = beam0.Attachment1.CFrame * CFrame.Angles(0, math.rad(90), 0)
				end

				-- Efectos de impacto: sistema modular por superficie (HitVFX) por
				-- defecto. Resuelve dirt/metal/body/headshot/... y reproduce sus
				-- partículas + sonido propios. El VFX heredado por-arma queda como
				-- fallback cuando ModularHitVFX = false.
				if self:getConfigValue("ModularHitVFX") then
					if shouldPlayPlayerHitVFX(hitInfo, self.player) then
						HitVFX.play(hitInfo, localPlayerInitiatedShot)
					end
				else
					-- Show hit particle effect
					local hitPartColor = hitPart and hitPart.Color or Color3.fromRGB(255, 255, 255)
					if hitPart and hitPart:IsA("Terrain") then
						hitPartColor = workspace.Terrain:GetMaterialColor(hitMaterial or Enum.Material.Sand)
					end
					if hitInfo.h and hitInfo.h:IsA("Humanoid") and hitParticles and numHitParticles > 0 and hitPart and isEnemyHumanoidForPlayer(hitInfo.h, self.player) then
						-- Show particle effect for hitting a player/humanoid
						hitParticles.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
						hitParticles:Emit(numHitParticles)
						visualEffectsLingerTime = math.max(visualEffectsLingerTime, hitParticles.Lifetime.Max)
					elseif (not hitInfo.h or not hitInfo.h:IsA("Humanoid")) and hitParticles and numHitParticles > 0 then
						-- Show particle effect for hitting anything else
						if hitPart and self:getConfigValue("HitParticlesUsePartColor") then
							local existingSeq = hitParticles.Color
							local newKeypoints = {}

							for i, keypoint in pairs(existingSeq.Keypoints) do
								local newColor = keypoint.Value
								if newColor == Color3.fromRGB(255, 0, 255) then
									newColor = hitPartColor
								end
								newKeypoints[i] = ColorSequenceKeypoint.new(keypoint.Time, newColor)
							end

							hitParticles.Color = ColorSequence.new(newKeypoints)
						end

						hitParticles:Emit(numHitParticles)
						visualEffectsLingerTime = math.max(visualEffectsLingerTime, hitParticles.Lifetime.Max)
					end

					-- Play hit sound
					if hitSound then
						hitSound:Play()
						visualEffectsLingerTime = math.max(visualEffectsLingerTime, hitSound.TimeLength)
					end
				end

				-- Manage/show decals, billboards, and models (such as an arrow) that appear where the projectile hit
				self:_spawnHitMark(hitPart, hitPoint, hitNormal, parabola)

				flyingVisualEffectsFinished = true
				visualEffectsFinishTime = now + visualEffectsLingerTime
			end
		end

		-- Will enter this if-statement if projectile hit something or maxDistance has been reached
		if projFront >= maxDist then
			if not stoppedMotion then
				stoppedMotion = true
				stoppedMotionAt = now
			end

			-- Stop particle effects if projectile didn't hit anything and projBack has reached the end
			if projBack >= maxDist and not flyingVisualEffectsFinished then
				flyingVisualEffectsFinished = true
				visualEffectsFinishTime = now + visualEffectsLingerTime
			end
		end

		-- Update parabola domain
		parabola:setDomain(projBack, projFront)

		-- Continue updating pTravelDistance until projBack has reached maxDist (this helps with some visual effects)
		if projBack < maxDist then
			pTravelDistance = math.max(0, timeSinceStart * bulletSpeed)
		end


		-- Update visual effects each frame

		-- Always update bulletEffect position to follow the bullet front (needed for trail particles on Attachment0)
		if not stoppedMotion then
			local bulletPos = parabola:samplePoint(1)
			local bulletVelocity = parabola:sampleVelocity(1)
			bulletEffect.CFrame = CFrame.new(bulletPos, bulletPos + bulletVelocity)
			if shouldMovePart then
				bulletEffect.AssemblyLinearVelocity = bulletVelocity.Unit * bulletSpeed
			end
		end

		-- Tracer beam: show full trajectory and fade out after hit
		local thickness0 = beamThickness0
		local thickness1 = beamThickness1
		if stoppedMotion and tracerFadeTime > 0 then
			local timeSinceEnd = now - stoppedMotionAt
			local fadeAlpha = math.clamp(timeSinceEnd / tracerFadeTime, 0, 1)
			thickness0 = thickness0 * (1 - fadeAlpha)
			thickness1 = thickness1 * (1 - fadeAlpha)
		end
		if beam0 then
			beam0.Width0 = thickness0
			beam0.Width1 = thickness1
			parabola:renderToBeam(beam0)
		end
		if beam1 then
			beam1.Width0 = thickness0
			beam1.Width1 = thickness1
			parabola:renderToBeam(beam1)
		end

		-- Disable muzzle flash after muzzleFlashTime seconds have passed
		if muzzleFlashShown and timeSinceStart > muzzleFlashTime and self.muzzleFlashBeam then
			self.muzzleFlashBeam.Enabled = false
			muzzleFlashShown = false
		end

		-- Destroy projectile and attached visual effects when visual effects are done showing or max bullet time has been reached
		local timeSinceParticleEffectsFinished = now - visualEffectsFinishTime
		if (flyingVisualEffectsFinished and timeSinceParticleEffectsFinished > 0) or timeSinceStart > MAX_BULLET_TIME then
			if bulletEffect then
				-- W13: devolver al pool en lugar de :Destroy(). El pool resetea
				-- sounds/beams; CFrame se sobrescribe en el próximo acquire.
				_releaseBulletEffect(bulletEffectTemplate, bulletEffect)
				bulletEffect = nil
			end

			stepConn:Disconnect()
		end
	end

	-- W2: push al bucle global en lugar de Connect propio.
	projectileEntry.callback = steppedCallback
	table.insert(activeProjectiles, projectileEntry)
	_ensureProjectileLoop()

	-- Get rid of charge on chargeable weapons
	if not IsServer and self.usesCharging then
		self.charge = math.clamp(self.charge - self:getConfigValue("FireDischarge"), 0, 1)
	end
end

function BulletWeapon:calculateDamage(travelDistance)
	local zeroDamageDistance = self:getConfigValue("ZeroDamageDistance")
	local fullDamageDistance = self:getConfigValue("FullDamageDistance")
	local distRange = zeroDamageDistance - fullDamageDistance
	local falloff = math.clamp(1 - (math.max(0, travelDistance - fullDamageDistance) / math.max(1, distRange)), 0, 1)
	return math.max(self:getConfigValue("HitDamage") * falloff, 0)
end

function BulletWeapon:applyDamage(hitInfo)
	-- S1: no confiar en hitInfo.d (el cliente puede enviar 0 para forzar max
	-- damage). Recomputar la distancia de falloff desde el origin server-trusted
	-- del disparo registrado (WeaponSecurity.validateHit puebla serverOrigin).
	-- Si no hay origin disponible, caer al hitInfo.d clampeado a >= 0.
	local travelDistance
	if typeof(hitInfo.serverOrigin) == "Vector3" and typeof(hitInfo.p) == "Vector3" then
		travelDistance = (hitInfo.p - hitInfo.serverOrigin).Magnitude
	else
		travelDistance = math.max(hitInfo.d or 0, 0)
	end
	local damage = self:calculateDamage(travelDistance)

	if damage <= 0 then
		return
	end

	-- Pasar hitInfo a doDamage para que _defaultDamageCallback acceda a
	-- hitInfo.wasHeadshot (poblado en onHit). Antes el flag era global y
	-- racy entre hits concurrentes.
	self.weaponsSystem.doDamage(hitInfo.h, damage, nil, self.player, hitInfo)
end

function BulletWeapon:onHit(hitInfo)
	local hitPoint = hitInfo.p
	local hitNormal = hitInfo.n
	local hitPart = hitInfo.part

	if hitPart and hitPart.Parent then
		local humanoid, wasHeadshot = self.weaponsSystem.getHumanoid(hitPart)
		hitInfo.h = humanoid or hitPart
		hitInfo.wasHeadshot = wasHeadshot == true

		-- S1: en el servidor, el multiplicador de headshot solo aplica si el
		-- part directamente golpeado es el "Head" real (WeaponSecurity.validateHit
		-- ya verificó la proximidad part/punto). Esto bloquea el guaranteed-headshot
		-- que envía un Head como hitInfo.part sin haberlo golpeado realmente.
		if IsServer then
			hitInfo.wasHeadshot = hitPart.Name == "Head"
		end

		if IsServer and
			(not hitInfo.h:IsA("Humanoid") or
				isEnemyHumanoidForPlayer(hitInfo.h, self.player))
		then
			self:applyDamage(hitInfo)
		elseif hitInfo.h:IsA("Humanoid") and
			hitInfo.h:GetState() ~= Enum.HumanoidStateType.Dead and
			self.weaponsSystem.gui and
			self.player == Players.LocalPlayer and
			isEnemyHumanoidForPlayer(hitInfo.h, self.player)
		then
			-- Show hit indicators on gui of client that shot projectile if players are not on same team
			self.weaponsSystem.gui:OnHitOtherPlayer(self:calculateDamage(hitInfo.d), hitInfo.h, hitPart)
		end
	end

	-- Create invisible explosion on server that deals damage to anything caught in the explosion
	if IsServer and self:getConfigValue("ExplodeOnImpact") then
		local blastRadius = self:getConfigValue("BlastRadius")
		local blastPressure = self:getConfigValue("BlastPressure")
		local blastDamage = self:getConfigValue("BlastDamage")

		local explosion = Instance.new("Explosion")
		explosion.Position = hitPoint + (hitNormal * 0.5)
		explosion.BlastRadius = blastRadius
		explosion.BlastPressure = blastPressure
		explosion.ExplosionType = Enum.ExplosionType.NoCraters
		explosion.DestroyJointRadiusPercent = 0
		explosion.Visible = false

		explosion.Hit:Connect(function(explodedPart, hitDist)
			local damageMultiplier = (1 - math.clamp((hitDist / blastRadius), 0, 1))
			local damageToDeal = blastDamage * damageMultiplier

			local humanoid = self.weaponsSystem.getHumanoid(explodedPart)
			if humanoid then
				if explodedPart.Name == "UpperTorso" and
					humanoid:GetState() ~= Enum.HumanoidStateType.Dead and
					self.weaponsSystem.playersOnDifferentTeams(self.weaponsSystem.getPlayerFromHumanoid(humanoid), self.player)
				then
					-- Do damage to players/humanoids
					self.weaponsSystem.doDamage(humanoid, damageToDeal, nil, self.player)
				end
			elseif not CollectionService:HasTag(explodedPart, "WeaponsSystemIgnore") then
				-- Do damage to a part (sends damage to breaking system)
				self.weaponsSystem.doDamage(explodedPart, damageToDeal, nil, self.player)
			end
		end)

		explosion.Parent = workspace

		-- Broadcast a todos los clientes para que reproduzcan las partículas
		-- de explosión locales (template en Effects.ExplosionParticles).
		WeaponsNetwork.broadcastExplosionVFX(explosion.Position)
	end
end

function BulletWeapon:fire(origin, dir, charge)
	if not self:isCharged() then
		return
	end

	BaseWeapon.fire(self, origin, dir, charge)
end

function BulletWeapon:onFired(firingPlayer, fireInfo, fromNetwork)
	if not IsServer and firingPlayer == Players.LocalPlayer and fromNetwork then
		return
	end

	local cooldownTime = self:getConfigValue("ShotCooldown")
	local fireMode = self:getConfigValue("FireMode")
	local isSemiAuto = fireMode == "Semiautomatic"
	local isBurst = fireMode == "Burst"

	if isBurst and not self.burstFiring then
		self.burstIdx = 0
		self.burstFiring = true
	elseif isSemiAuto then
		self.triggerDisconnected = true
	end

	-- Calculate cooldown time for burst firing
	if self.burstFiring then
		self.burstIdx = self.burstIdx + 1
		if self.burstIdx >= self:getConfigValue("NumBurstShots") then
			self.burstFiring = false
			self.triggerDisconnected = true
		else
			cooldownTime = self:getConfigValue("BurstShotCooldown") or cooldownTime
		end
	end

	self.nextFireTime = os.clock() + cooldownTime

	BaseWeapon.onFired(self, firingPlayer, fireInfo, fromNetwork)
end

function BulletWeapon:onConfigValueChanged(valueName, newValue, oldValue)
	BaseWeapon.onConfigValueChanged(self, valueName, newValue, oldValue)
	if valueName == "ShotEffect" then
		self:_resolveShotEffect()
	elseif valueName == "HitMarkEffect" then
		self:_resolveHitMarkEffect()
	elseif valueName == "ChargeRate" then
		self.usesCharging = newValue ~= nil
	end
end

function BulletWeapon:onActivatedChanged()
	BaseWeapon.onActivatedChanged(self)

	if not IsServer then
		-- Reload if no ammo left in clip
		if self.equipped and self:getAmmoInWeapon() <= 0 then
			self:reload()
			return
		end

		-- Fire weapon
		if self.activated and self.player == localPlayer and self:canFire() and os.clock() > self.nextFireTime then
			self:doLocalFire()
		end

		-- Reenable trigger after activated changes to false
		if not self.activated and self.triggerDisconnected and not self.burstFiring then
			self.triggerDisconnected = false
		end
	end
end

-- Resuelve (una vez, perezoso) el joint a offsetear y la parte que se mueve. El
-- rig y los welds llegan por replicación, así que puede no estar listo el primer
-- frame; devolvemos false hasta que lo esté. Solo cliente / LocalPlayer.
--
-- Preferencia: el GRIP (weld hand↔Handle) — mover ahí desplaza el arma entera. Si
-- no está (raro), fallback al HandleWeld (Handle→PrimaryPart del modelo).
function BulletWeapon:_ensureViewKickRefs(): boolean
	local joint = self._viewKickJoint
	if joint and joint.Parent then
		return true
	end
	local handle = self.instance:FindFirstChild("Handle") :: BasePart?
	if not handle then
		return false
	end

	-- Grip: entre los joints del Handle, el que conecta con una parte que NO es
	-- del propio Tool (es un miembro del personaje). El HandleWeld conecta con el
	-- modelo (descendiente del Tool), así que ese queda excluido aquí.
	for _, j in handle:GetJoints() do
		if j:IsA("Weld") or j:IsA("Motor6D") then
			local other = if j.Part0 == handle then j.Part1 else j.Part0
			if other and not other:IsDescendantOf(self.instance) then
				self._viewKickJoint = j
				self._viewKickProp = if j.Part0 == handle then "C0" else "C1"
				self._viewKickBase = (j :: any)[self._viewKickProp]
				self._viewKickPart = handle
				return true
			end
		end
	end

	-- Fallback: HandleWeld (Handle→PrimaryPart). Mueve solo el modelo respecto al
	-- Handle; requiere que las partes visibles estén soldadas al PrimaryPart.
	local model = self.instance:FindFirstChildOfClass("Model")
	local weld = handle:FindFirstChild("HandleWeld")
	if model and model.PrimaryPart and weld and weld:IsA("Weld") then
		self._viewKickJoint = weld
		self._viewKickProp = "C1"
		self._viewKickBase = weld.C1
		self._viewKickPart = model.PrimaryPart
		return true
	end

	return false
end

-- Restaura el joint a su valor base y limpia el kick. Idempotente.
function BulletWeapon:_resetViewKick()
	self._viewKick = 0
	local joint = self._viewKickJoint
	if joint and joint.Parent and self._viewKickBase then
		(joint :: any)[self._viewKickProp] = self._viewKickBase
	end
end

function BulletWeapon:onRenderStepped(dt)
	BaseWeapon.onRenderStepped(self, dt)
	if not self.tipAttach then return end
	if not self.equipped then return end

	local tipCFrame = self.tipAttach.WorldCFrame

	if self.player == Players.LocalPlayer then
		-- Retroceso visual del arma hacia atrás (client-only, solo LocalPlayer).
		-- Offsetea el joint resuelto (grip o HandleWeld) y decae exponencial (mismo
		-- estilo de decay que recoilIntensity). Snap final al valor base para no dejar
		-- residuo. Config por arma: ViewKickDistance (studs), ViewKickReturn.
		if self._viewKick > 1e-3 then
			local cam = workspace.CurrentCamera
			if cam and self:_ensureViewKickRefs() then
				local joint = self._viewKickJoint :: any
				local base = self._viewKickBase :: CFrame
				local part = self._viewKickPart :: BasePart
				-- Las armas explosivas (RPG) patean bastante más que las balísticas.
				-- Un ViewKickDistance explícito en la config del Tool gana igualmente.
				local defaultKick = if self:getConfigValue("ExplodeOnImpact") then 0.85 else 0.07
				local maxBack = self:getConfigValue("ViewKickDistance", defaultKick)
				-- "Hacia atrás" = hacia el jugador = opuesto al LookVector de la cámara
				-- (referencia fiable; el TipAttachment no tiene orientación garantizada).
				-- Lo pasamos al espacio local de la parte movida para offsetear el joint.
				local backLocal = part.CFrame:VectorToObjectSpace(-cam.CFrame.LookVector)
				local offset = backLocal * (self._viewKick * maxBack)
				-- part_new = part_old * CFrame.new(offset) ⇒ prop = CFrame.new(-offset) * base
				joint[self._viewKickProp] = CFrame.new(-offset) * base
			end
			local returnRate = self:getConfigValue("ViewKickReturn")
			self._viewKick *= math.exp(-returnRate * dt)
			if self._viewKick <= 1e-3 then
				self:_resetViewKick()
			end
		end

		-- Retrieve aim point from camera and update player's aim animation
		local aimTrack = self:getAnimTrack(self:getConfigValue("AimTrack"))
		local aimZoomTrack = self:getAnimTrack(self:getConfigValue("AimZoomTrack"))
		if aimTrack then
			-- W6: gunLookRay solo se usa como fallback cuando NO hay aimRayCallback.
			-- Con ShoulderCamera activa el callback siempre está set, así que
			-- antes hacíamos 2 penetrateCast/frame y descartábamos el primero.
			if self.weaponsSystem.aimRayCallback then
				local _, hitPoint = Roblox.penetrateCast(self.weaponsSystem.aimRayCallback(), self.ignoreList)
				self.aimPoint = hitPoint
			else
				local aimDir = tipCFrame.LookVector
				local gunLookRay = Ray.new(tipCFrame.p, aimDir * 500)
				local _, gunHitPoint = Roblox.penetrateCast(gunLookRay, self.ignoreList)
				self.aimPoint = gunHitPoint
			end

			if not aimTrack.IsPlaying and not self.reloading then
				aimTrack:Play(0.15)
				-- Audit mobile: generation token + task.delay. Antes
				-- coroutine.wrap+wait(0.2) usaba el `wait` global legacy y, si
				-- el render path entraba aquí 2× rápidamente (rebote de
				-- IsPlaying), arrancaba múltiples coroutines redundantes que
				-- seteaban startupFinished=true por turno. El token corta los
				-- pendientes cuando se inicia uno nuevo.
				self._startupToken = (self._startupToken or 0) + 1
				local thisToken = self._startupToken
				task.delay(self:getConfigValue("StartupTime"), function()
					if self._startupToken == thisToken then
						self.startupFinished = true
					end
				end)
			end

			if aimZoomTrack and not self.reloading then
				if not aimZoomTrack.IsPlaying then
					aimZoomTrack:Play(0.15)
				end
				aimZoomTrack:AdjustSpeed(0.001)
				if self.weaponsSystem.camera:isZoomed() then
					if aimTrack.WeightTarget ~= 0 then
						aimZoomTrack:AdjustWeight(1)
						aimTrack:AdjustWeight(0)
					end
				elseif aimTrack.WeightTarget ~= 1 then
					aimZoomTrack:AdjustWeight(0)
					aimTrack:AdjustWeight(1)
				end
			end

			-- W6: trabajamos directamente en radianes. Antes hacíamos math.deg(...)
			-- 2× por frame (la rama del camera enabled siempre se toma con
			-- ShoulderCamera activa) y luego normalizábamos contra [-80,80] grados.
			-- Equivalente en radianes: [math.rad(-80), math.rad(80)] ≈ [-1.396, 1.396].
			local MIN_ANGLE_RAD = -1.3962634015954636 -- math.rad(-80)
			local MAX_ANGLE_RAD = 1.3962634015954636  -- math.rad(80)
			local aimYAngle = self.recoilIntensity
			if self.weaponsSystem.camera.enabled then
				aimYAngle = self.weaponsSystem.camera:getRelativePitch() + self.weaponsSystem.camera.currentRecoil.Y + self.recoilIntensity
			end
			local aimTimePos = 2 * ((aimYAngle - MIN_ANGLE_RAD) / (MAX_ANGLE_RAD - MIN_ANGLE_RAD))

			aimTrack:AdjustSpeed(0.001)
			aimTrack.TimePosition = math.clamp(aimTimePos, 0.001, 1.97)

			if aimZoomTrack then
				aimZoomTrack.TimePosition = math.clamp(aimTimePos, 0.001, 1.97)
			end

			-- Update recoil (decay over time)
			local recoilDecay = self:getConfigValue("RecoilDecay")
			self.recoilIntensity = math.clamp(self.recoilIntensity * recoilDecay, 0, math.huge)
		else
			warn("no aimTrack")
		end
	end
end

function BulletWeapon:setChargingParticles(charge)
	local ratePerCharge = self:getConfigValue("ChargingParticlesRatePerCharge")
	local rate = ratePerCharge * charge
	for _, v in self.chargingParticles do
		v.Rate = rate
	end
end

function BulletWeapon:onStepped(dt)
	if not self.tipAttach then return end
	if not self.equipped then return end

	BaseWeapon.onStepped(self, dt)

	local now = os.clock()

	local chargingSound = self:getSound("Charging")
	local dischargingSound = self:getSound("Discharging")

	if self.usesCharging then
		-- Update charge amount
		local chargeBefore = self.charge
		self:handleCharging(dt)
		local chargeDelta = self.charge - chargeBefore

		-- Update charge particles
		if chargeDelta > 0 then
			self:setChargingParticles(self.charge)
		else
			self:setChargingParticles(0)
		end

		-- Play charging sounds
		if chargingSound then
			if chargingSound.Looped then
				if chargeDelta < 0 then
					chargingSound:Stop()
				else
					if not chargingSound.Playing and self.charge < 1 and chargeDelta > 0 then
						chargingSound:Play()
					end
					chargingSound.PlaybackSpeed = self.chargeSoundPitchMin + (self.charge * (self.chargeSoundPitchMax - self.chargeSoundPitchMin))
				end
			else
				if chargeDelta > 0 and self.charge <= 1 and not chargingSound.Playing then
					chargingSound.TimePosition = chargingSound.TimeLength * self.charge
					chargingSound:Play()
				elseif chargeDelta <= 0 and chargingSound.Playing then
					chargingSound:Stop()
				end
			end
		end
		if dischargingSound then
			if dischargingSound.Looped then
				if chargeDelta > 0 then
					dischargingSound:Stop()
				else
					if not dischargingSound.Playing and self.charge > 0 then
						dischargingSound:Play()
					end
					dischargingSound.PlaybackSpeed = self.chargeSoundPitchMin + (self.charge * (self.chargeSoundPitchMax - self.chargeSoundPitchMin))
				end
			else
				if chargeDelta < 0 and self.charge >= 0 and not dischargingSound.Playing then
					dischargingSound.TimePosition = dischargingSound.TimeLength * self.charge
					dischargingSound:Play()
				elseif chargeDelta >= 0 and dischargingSound.Playing then
					dischargingSound:Stop()
				end
			end
		end

		-- Play charge/discharge completed sounds and particle effects
		if chargeBefore < 1 and self.charge >= 1 then
			local chargeCompleteSound = self:getSound("ChargeComplete")
			if chargeCompleteSound then
				chargeCompleteSound:Play()
			end
			if chargingSound and chargingSound.Playing then
				chargingSound:Stop()
			end
			if self.chargeCompleteParticles then
				self.chargeCompleteParticles:Emit(self:getConfigValue("NumChargeCompleteParticles"))
			end
		end
		if chargeBefore > 0 and self.charge <= 0 then
			local dischargeCompleteSound = self:getSound("DischargeComplete")
			if dischargeCompleteSound then
				dischargeCompleteSound:Play()
			end
			if dischargingSound and dischargingSound.Playing then
				dischargingSound:Stop()
			end
			if self.dischargeCompleteParticles then
				self.dischargeCompleteParticles:Emit(self:getConfigValue("NumDischargeCompleteParticles"))
			end
		end

		self:renderCharge()
	else
		if chargingSound then
			chargingSound:Stop()
		end
		if dischargingSound then
			dischargingSound:Stop()
		end
	end

	if self.usesCharging and self.chargeGlowPart then
		self.chargeGlowPart.Transparency = 1 - self.charge
	end

	-- Fire weapon if it is fully charged
	if self:canFire() and now > self.nextFireTime then
		self:doLocalFire()
	end
end

function BulletWeapon:handleCharging(dt)
	local chargeDelta
	local shouldCharge = self.activated or self.burstFiring or self:getConfigValue("ChargePassively")
	if self.reloading or self.triggerDisconnected then
		shouldCharge = false
	end

	if shouldCharge then
		chargeDelta = self:getConfigValue("ChargeRate") * dt
	else
		chargeDelta = self:getConfigValue("DischargeRate") * -dt
	end

	self.charge = math.clamp(self.charge + chargeDelta, 0, 1)
end

function BulletWeapon:isCharged()
	return not self.usesCharging or self.charge >= 1
end

function BulletWeapon:canFire()
	return self.player == Players.LocalPlayer and (self.burstFiring or self.activated) and not self.triggerDisconnected and not self.reloading and self:isCharged() and self.startupFinished
end

function BulletWeapon:doLocalFire()
	if self.tipAttach then
		local tipCFrame = self.tipAttach.WorldCFrame
		local tipPos = tipCFrame.Position
		local aimDir = (self.aimPoint - tipPos).Unit

		self:fire(tipPos, aimDir, self.charge)
	end
end

return BulletWeapon
