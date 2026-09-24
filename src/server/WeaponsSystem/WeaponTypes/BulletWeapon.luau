--!strict
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
local WeaponBolt = require(Libraries:WaitForChild("WeaponBolt"))
local ReloadHinge = require(Libraries:WaitForChild("ReloadHinge"))
local FireZone = if IsServer then require(Libraries:WaitForChild("FireZone")) else nil
local TeamUtils = require(Shared.utils.TeamUtils)

local Effects = WeaponsSystemFolder:WaitForChild("Assets"):WaitForChild("Effects")
local ShotsFolder = Effects:WaitForChild("Shots")
local HitMarksFolder = Effects:WaitForChild("HitMarks")

local NO_BULLET_DECALS = false

-- Se refresca periódicamente para no acumular instancias que ya no están en el DataModel.
local IGNORE_LIST_LIFETIME = 5

local MAX_BULLET_TIME = 2
-- Se multiplica por gravityFactor del config.
local PROJECTILE_GRAVITY_BASE = 35
-- Más samples = mejor detección en arcos pronunciados, pero más raycasts.
local PARABOLA_HIGH_GRAVITY_THRESHOLD = 0.66
local PARABOLA_MID_GRAVITY_THRESHOLD = 0.33
local PARABOLA_SAMPLES_HIGH = 3
local PARABOLA_SAMPLES_MID = 2
local PARABOLA_SAMPLES_LOW = 1

-- El AmmoPart reaparece creciendo desde esta fracción de su tamaño.
local AMMO_PART_APPEAR_SCALE = 0.3
local AMMO_PART_GROW_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- Aparte del tamaño: el rebote de Back sobre la transparencia la sacaría de [0, 1].
local AMMO_PART_FADE_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Cada grupo lee sus claves de config con el prefijo (BoltTravel, PumpDelay…). El ciclo
-- por defecto se ajusta a lo que queda de cooldown tras el delay, entre min y max.
-- forward: se mueve hacia la boca en vez de hacia la culata.
local MOVING_PART_GROUPS = {
	{ name = "Bolt", fill = 0.9, minCycle = 0.04, maxCycle = 0.12, forward = false },
	{ name = "Pump", fill = 0.8, minCycle = 0.1, maxCycle = 0.45, forward = false },
	{ name = "SniperBolt", fill = 0.7, minCycle = 0.2, maxCycle = 0.8, forward = true },
}

local localRandom = Random.new()
local localPlayer = not IsServer and Players.LocalPlayer

-- Una única conexión Heartbeat para todos los proyectiles (no una por bala).
type ProjectileEntry = { active: boolean, callback: ((number) -> ())? }
local activeProjectiles: { ProjectileEntry } = {}
local projectileLoopConn: RBXScriptConnection? = nil

-- Buffer reusado: el Send de ByteNet serializa en el momento, así que es seguro
-- mutarlo entre llamadas.
local _hitInfoSendBuffer: { [string]: any } = {}

-- Pool de clones de bulletEffect por template (Parent=nil en reposo): clonar el
-- árbol por bala es caro en móvil con escopeta + autofire.
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

-- Al parquear: el beam se re-enable ANTES del primer render del siguiente disparo,
-- y sin reset ese frame dibujaría el beam entre los extremos del disparo ANTERIOR.
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

	-- Restaurar lo que se muta durante la vida del proyectil (Transparency,
	-- LeadingParticles.Rate) desde el template, que nunca se muta.
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
			-- Sin pcall a propósito: no enmascarar errores reales de código propio.
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

-- Health (replicado por el server) además del state: el state Dead lo decide el
-- dueño del personaje y puede llegar tarde, dejando un frame de impactos al cadáver.
local function isDeadHumanoid(humanoid: Humanoid): boolean
	return humanoid.Health <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Dead
end

-- HitVFX de jugador solo contra enemigos vivos. Superficies no se bloquean aquí.
local function shouldPlayPlayerHitVFX(hitInfo, player): boolean
	local h = hitInfo.h
	if h and typeof(h) == "Instance" and h:IsA("Humanoid") then
		return not isDeadHumanoid(h) and isEnemyHumanoidForPlayer(h, player)
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
	self.startupFinished = false
	self.burstFiring = false
	self.burstIdx = 0
	self.nextFireTime = 0

	self.recoilIntensity = 0
	self.aimPoint = Vector3.new()

	-- Retroceso visual solo del LocalPlayer: se offsetea en el cliente (no replica) el
	-- grip hand↔Handle (fallback HandleWeld), que mueve el arma ENTERA.
	-- _viewKick: acumulador 0..1 que sube por disparo y decae por frame.
	self._viewKick = 0
	self._viewKickJoint = nil :: (Weld | Motor6D)?
	self._viewKickProp = "C1" -- "C0" o "C1", según de qué lado esté la parte movida
	self._viewKickBase = nil :: CFrame?
	self._viewKickPart = nil :: BasePart?

	self._ammoParts = nil :: { { part: BasePart, transparency: number, size: Vector3, mesh: SpecialMesh?, meshScale: Vector3?, tweens: { Tween } } }?
	self._ammoPartsHidden = false

	self._movingParts = nil :: { { group: any, bolt: WeaponBolt.WeaponBolt } }?
	-- Apertura al recargar: la pieza "Barrel" gira mientras dura la recarga.
	self._reloadHinge = if IsServer then nil else ReloadHinge.new(self.instance, "Barrel")
	if not IsServer then
		self._movingParts = {}
		for _, group in MOVING_PART_GROUPS do
			table.insert(self._movingParts, { group = group, bolt = WeaponBolt.new(self.instance, group.name) })
		end
	end

	self:addOptionalDescendant("tipAttach", "TipAttachment")

	self:addOptionalDescendant("chargeGlowPart", "ChargeGlow")
	self:addOptionalDescendant("chargeCompleteParticles", "ChargeCompleteParticles")
	self:addOptionalDescendant("dischargeCompleteParticles", "DischargeCompleteParticles")


	self.bulletEffectTemplate = nil
	self.hitMarkTemplate = nil

	self.ignoreList = {}
	self.ignoreListRefreshTime = 0

	self:addOptionalDescendant("handAttach", "LeftHandAttachment")
	self.handAlignPos = nil
	self.handAlignRot = nil

	self.chargingParticles = {}
	-- En self.connections para que onDestroyed la limpie (el Tool puede sobrevivir al arma).
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
	Sólo puede correr DESPUÉS de doInitialSetup: hasta entonces getConfigValue no
	cae al default del esquema. onConfigValueChanged no basta: sólo se dispara por
	claves que la definición DECLARA, y la mayoría heredan ShotEffect/HitMarkEffect.
]]
function BulletWeapon:_resolveEffectTemplates()
	self:_resolveShotEffect()
	self:_resolveHitMarkEffect()
end

function BulletWeapon:_resolveShotEffect()
	local effectName = self:getConfigValue("ShotEffect")
	self.bulletEffectTemplate = if effectName then ShotsFolder:FindFirstChild(effectName) else nil
	if not self.bulletEffectTemplate then
		-- Sin template simulateProjectile no puede clonar y el disparo no llegaría a
		-- impactar: se cae al "Bullet" para que un asset pendiente no rompa el arma.
		self.bulletEffectTemplate = ShotsFolder:FindFirstChild("Bullet")
		warn(string.format(
			"[BulletWeapon] %s: sin template de bala para ShotEffect=%s (Assets.Effects.Shots), se usa Bullet",
			self.instance:GetFullName(), tostring(effectName)
		))
		if not self.bulletEffectTemplate then
			return
		end
	end

	local beam0 = self.bulletEffectTemplate:FindFirstChild("Beam0")
	-- Preload una sola vez por beam0.
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
		if self.equipped then
			self.startupFinished = false
			if self.player == Players.LocalPlayer then
				self:_startStartupTimer()
			end
		end

		if self.equipped then
			ContextActionService:BindAction("ReloadWeapon", function(...) self:onReloadAction(...) end, false, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
		else
			ContextActionService:UnbindAction("ReloadWeapon")

			self:_resetViewKick()
			self._viewKickJoint = nil
			for _, entry in self._movingParts or {} do
				entry.bolt:reset()
			end
			if self._reloadHinge then
				self._reloadHinge:reset()
			end
			self:_setAmmoPartsHidden(false)

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

		-- Roblox no re-emite Tool.Activated para un botón ya mantenido al cambiar de
		-- arma: sin esto el arma nueva no dispara hasta soltar y volver a pulsar.
		-- En táctil no aplica: cualquier dedo (el del joystick) cuenta como MouseButton1 y
		-- el Deactivate solo llega del FireButton (ManualActivationOnly), así que dispararía solo.
		if self.equipped and self.player == Players.LocalPlayer and not UserInputService.TouchEnabled then
			if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				self:setActivated(true)
			end
		end
	end
end

--[[
	StartupTime cuenta desde el equip, no desde que arranca la animación de apuntar:
	con zoom activo a ese track se le baja el peso a 0 en el mismo frame en que se
	reproduce, IsPlaying rebota cada frame y un temporizador atado a él nunca terminaba
	(cambiar de arma apuntando dejaba el arma nueva sin disparar hasta soltar el zoom).
]]
function BulletWeapon:_startStartupTimer()
	self._startupToken = (self._startupToken or 0) + 1
	local thisToken = self._startupToken
	task.delay(self:getConfigValue("StartupTime"), function()
		if self._startupToken == thisToken and self.equipped then
			self.startupFinished = true
		end
	end)
end

function BulletWeapon:onReloadAction(actionName, inputState, inputObj)
	if inputState == Enum.UserInputState.Begin and not self.reloading then
		self:reload()
	end
end

function BulletWeapon:getRandomSeedForId(id)
	return id
end

-- Los ParticleEmitter hijos de TipAttachment deben ir con Enabled = false en Studio:
-- solo emiten aquí, EmitCount partículas cada uno (1 si no tiene el atributo).
function BulletWeapon:_emitMuzzleEffects()
	if not self.tipAttach then
		return
	end
	for _, emitter in self.tipAttach:GetChildren() do
		if emitter:IsA("ParticleEmitter") then
			emitter:Emit(emitter:GetAttribute("EmitCount") or 1)
		end
	end
end

local HIT_MARK_LIFETIME = 5

-- En un Decal/Texture, Color3 blanco = sin tinte (aspecto normal del agujero).
local HIT_MARK_HEAT_START = Color3.fromRGB(255, 120, 30)
local HIT_MARK_HEAT_END = Color3.fromRGB(255, 255, 255)
local HIT_MARK_HEAT_DURATION = 1.5
local HIT_MARK_HEAT_TWEEN = TweenInfo.new(HIT_MARK_HEAT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- El ScorchMark del RPG (…Explosion.ScorchMark) se autora en Studio: se respeta
-- su color y se entra y sale de su transparencia con fundidos (el de salida acaba
-- justo cuando Debris borra la marca).
local SCORCH_MARK_FADE_IN_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SCORCH_MARK_FADE_OUT_TWEEN = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function isAuthoredScorchMark(instance: Instance): boolean
	return instance:IsA("Decal") and instance.Name == "ScorchMark" and instance:FindFirstAncestor("Explosion") ~= nil
end

local function animateAuthoredScorchMarks(hitMark: Instance)
	for _, descendant in hitMark:GetDescendants() do
		if isAuthoredScorchMark(descendant) then
			local decal = descendant :: Decal
			local targetTransparency = decal.Transparency
			decal.Transparency = 1
			TweenService:Create(decal, SCORCH_MARK_FADE_IN_TWEEN, { Transparency = targetTransparency }):Play()
			task.delay(HIT_MARK_LIFETIME - SCORCH_MARK_FADE_OUT_TWEEN.Time, function()
				if decal.Parent then
					TweenService:Create(decal, SCORCH_MARK_FADE_OUT_TWEEN, { Transparency = 1 }):Play()
				end
			end)
		end
	end
end

function BulletWeapon:_applyHitMarkHeat(hitMark: Instance)
	if hitMark:IsA("BasePart") then
		hitMark.Color = HIT_MARK_HEAT_START
		TweenService:Create(hitMark, HIT_MARK_HEAT_TWEEN, { Color = HIT_MARK_HEAT_END }):Play()
	end
	for _, descendant in hitMark:GetDescendants() do
		if (descendant:IsA("Decal") or descendant:IsA("Texture")) and not isAuthoredScorchMark(descendant) then
			descendant.Color3 = HIT_MARK_HEAT_START
			TweenService:Create(descendant, HIT_MARK_HEAT_TWEEN, { Color3 = HIT_MARK_HEAT_END }):Play()
		end
	end
end

function BulletWeapon:_spawnHitMark(hitPart: BasePart, hitPoint: Vector3, hitNormal: Vector3, parabola: any)
	if NO_BULLET_DECALS or not hitPart or not hitPart.Parent or not self.hitMarkTemplate then
		return
	end
	-- Sin marca sobre partes invisibles (barreras de colisión). Por transparencia y no
	-- por tag a propósito: cubre mapas sin etiquetar. Una parte invisible con Decal o
	-- SurfaceGui hijo también se queda sin marca; haría falta un tag de excepción.
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
	animateAuthoredScorchMarks(hitMark)
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

-- Solo cliente.
function BulletWeapon:simulateFire(firingPlayer, fireInfo)
	BaseWeapon.simulateFire(self, fireInfo)

	if self.lastFireSound then
		self.lastFireSound:Stop()
	end
	self.lastFireSound = self:tryPlaySound("Fired", self:getConfigValue("FiredPlaybackSpeedRange"))

	self:_kickMovingParts()
	self:_emitMuzzleEffects()

	local numProjectiles = self:getConfigValue("NumProjectiles")
	local randomGenerator = Random.new(self:getRandomSeedForId(fireInfo.id))
	for i = 1, numProjectiles do
		self:simulateProjectile(firingPlayer, fireInfo, i, randomGenerator)
	end

	if self.player == Players.LocalPlayer then
		-- Independiente del recoil vertical (que va con RecoilDelayTime).
		local shakeIntensity = self:getConfigValue("ShakeIntensity")
		if shakeIntensity > 0 then
			self.weaponsSystem.camera:addCameraShake(shakeIntensity, self:getConfigValue("ShakeFOVKick"))
		end

		-- onRenderStepped lo aplica y decae.
		self._viewKick = math.min(self._viewKick + self:getConfigValue("ViewKickPerShot"), 1)

		task.delay(self:getConfigValue("RecoilDelayTime"), function()

			local recoilMin, recoilMax = self:getConfigValue("RecoilMin"), self:getConfigValue("RecoilMax")
			local intensityToAdd = randomGenerator:NextNumber(recoilMin, recoilMax)
			local xIntensity = math.sin(os.clock() * 2) * intensityToAdd * math.rad(0.05)
			local yIntensity = intensityToAdd * 0.025
			self.weaponsSystem.camera:addRecoil(Vector2.new(xIntensity, yIntensity))

			if not (self.weaponsSystem.camera:isZoomed() and self:getConfigValue("HasScope")) then
				self.recoilIntensity = math.clamp(self.recoilIntensity * 1 + (intensityToAdd / 10), 0.005, 1)
			end

			local weaponsGui = self.weaponsSystem.gui
			if weaponsGui then
				weaponsGui:setCrosshairScale(1 + intensityToAdd)
			end
		end)
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

-- Solo cliente.
function BulletWeapon:simulateProjectile(firingPlayer, fireInfo, projectileIdx, randomGenerator)
	local localPlayerInitiatedShot = self.player == Players.LocalPlayer

	local bulletSpeed = self:getConfigValue("BulletSpeed")
	local maxDistance = self:getConfigValue("MaxDistance")
	local tracerFadeTime = self:getConfigValue("TracerFadeTime")
	local gravityFactor = self:getConfigValue("GravityFactor")
	local minSpread = self:getConfigValue("MinSpread")
	local maxSpread = self:getConfigValue("MaxSpread")
	local shouldMovePart = self:getConfigValue("ShouldMovePart")
	local explodeOnImpact = self:getConfigValue("ExplodeOnImpact")
	local blastRadius = self:getConfigValue("BlastRadius")

	-- Retrasa el origin si la punta del cañón está dentro de una pared. Solo para el
	-- LocalPlayer: la ignore list solo excluye al tirador local, y en remotos el recast
	-- chocaría con su cuerpo (el tirador ya lo aplicó antes de enviar fireInfo).
	if self.tipAttach ~= nil and localPlayerInitiatedShot then
		local tipCFrame = self.tipAttach.WorldCFrame
		local tipPos = tipCFrame.Position
		local tipDir = tipCFrame.LookVector
		-- Algunas armas (p. ej. Tool de NPC) no tienen un BasePart "Handle".
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

	local bulletEffectTemplate = self.bulletEffectTemplate
	local bulletEffect = _acquireBulletEffect(bulletEffectTemplate, workspace.CurrentCamera)
	bulletEffect.CFrame = CFrame.new(origin, origin + dir)

	local leadingParticles = bulletEffect:FindFirstChild("LeadingParticles", true)

	local hitAttach = bulletEffect:FindFirstChild("HitEffect")
	local hitParticles = bulletEffect:FindFirstChild("HitParticles", true)
	local numHitParticles = self:getConfigValue("NumHitParticles")
	local hitSound = bulletEffect:FindFirstChild("HitSound", true)
	local flyingSound = bulletEffect:FindFirstChild("Flying", true)

	local beamThickness0 = self:getConfigValue("BeamWidth0")
	local beamThickness1 = self:getConfigValue("BeamWidth1")

	local beam0 = bulletEffect:FindFirstChild("Beam0")
	if beam0 then
		beam0.Enabled = true
	end
	local beam1 = bulletEffect:FindFirstChild("Beam1")
	if beam1 then
		beam1.Enabled = true
	end

	if flyingSound then
		flyingSound:Play()
	end

	local parabola = Parabola.new()
	parabola:setPhysicsLaunch(origin, dir * bulletSpeed, nil, -PROJECTILE_GRAVITY_BASE * gravityFactor)
	if gravityFactor > PARABOLA_HIGH_GRAVITY_THRESHOLD then
		parabola:setNumSamples(PARABOLA_SAMPLES_HIGH)
	elseif gravityFactor > PARABOLA_MID_GRAVITY_THRESHOLD then
		parabola:setNumSamples(PARABOLA_SAMPLES_MID)
	else
		parabola:setNumSamples(PARABOLA_SAMPLES_LOW)
	end

	-- Hitscan (auto-fire móvil): hit resuelto en el mismo frame; el tracer se muestra igual.
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

			-- Diferido: BaseWeapon:fire() llama onFired ANTES de fireWeaponFired, y un hit
			-- síncrono llegaría al server antes del shot ("unknown sid" en validateHit).
			local hitPayload = {}
			for k, v in pairs(hitInfo) do
				hitPayload[k] = v
			end
			local weaponInst = self.instance
			task.defer(function()
				WeaponsNetwork.fireWeaponHit(weaponInst, hitPayload)
			end)

			if self:getConfigValue("ModularHitVFX") then
				if shouldPlayPlayerHitVFX(hitInfo, self.player) then
					HitVFX.play(hitInfo, localPlayerInitiatedShot)
				end
			elseif hitSound and shouldPlayPlayerHitVFX(hitInfo, self.player) then
				hitSound:Play()
			end
			self:_spawnHitMark(hitPart, hitPoint, hitNormal, parabola)
		end

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

	-- stepConn es un stub: `:Disconnect()` marca la entry inactive y el bucle global la retira.
	local projectileEntry: ProjectileEntry = { active = true, callback = nil }
	local stepConn = { Disconnect = function() projectileEntry.active = false end }
	local pTravelDistance = 0
	local startTime = os.clock()
	local didHit = false
	local stoppedMotion = false
	local stoppedMotionAt = 0
	local timeSinceStart = 0
	local flyingVisualEffectsFinished = false
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

	-- Vía getIgnoreList: sin TipAttachment self.ignoreList queda {} y la bala chocaría
	-- contra el propio tirador en el primer frame.
	local projectileIgnoreList = self:getIgnoreList(localPlayerInitiatedShot)

	local steppedCallback = function(dt)
		local now = os.clock()
		timeSinceStart = now - startTime

		local travelDist = bulletSpeed * dt

		local projBack = 0
		local projFront = pTravelDistance
		local maxDist = hitInfo.maxDist or 0 -- tras colisionar pasa a ser la distancia al punto de impacto

		projFront = math.clamp(projFront, 0, maxDist)

		if not didHit then
			local castProjBack, castProjFront = projFront, projFront + travelDist
			parabola:setDomain(castProjBack, castProjFront)
			local hitPart, hitPoint, hitNormal, hitMaterial, hitT = parabola:findPart(projectileIgnoreList)

			if hitPart then
				didHit = true
				projFront = castProjBack + hitT * (castProjFront - castProjBack)
				parabola:setDomain(projBack, projFront)

				hitInfo.part = hitPart
				hitInfo.p = hitPoint
				hitInfo.n = hitNormal
				hitInfo.m = hitMaterial
				hitInfo.d = (hitPoint - origin).Magnitude
				hitInfo.t = hitT
				hitInfo.maxDist = projFront

				self:onHit(hitInfo)

				if localPlayerInitiatedShot then
					table.clear(_hitInfoSendBuffer)
					for hitInfoKey, value in pairs(hitInfo) do
						_hitInfoSendBuffer[hitInfoKey] = value
					end
					WeaponsNetwork.fireWeaponHit(self.instance, _hitInfoSendBuffer)
				end

				if flyingSound and flyingSound.IsPlaying then
					flyingSound:Stop()
				end

				if bulletEffect then
					bulletEffect.Transparency = 1
				end

				if leadingParticles then
					leadingParticles.Rate = 0
					visualEffectsLingerTime = math.max(visualEffectsLingerTime, leadingParticles.Lifetime.Max)
				end

				-- Visible=false: las partículas propias llegan por PlayExplosionVFX.
				if explodeOnImpact then
					local explosion = Instance.new("Explosion")
					explosion.Position = hitPoint + (hitNormal * 0.5)
					explosion.BlastRadius = blastRadius
					explosion.BlastPressure = 0 -- la explosión real ocurre en el server
					explosion.ExplosionType = Enum.ExplosionType.NoCraters
					explosion.DestroyJointRadiusPercent = 0
					explosion.Visible = false
					if localPlayerInitiatedShot then
						explosion.Hit:Connect(function(explodedPart, hitDist)
							local humanoid = self.weaponsSystem.getHumanoid(explodedPart)
							if humanoid and
								explodedPart.Name == "UpperTorso" and
								not isDeadHumanoid(humanoid) and
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

				if hitAttach and beam0 and beam0.Attachment1 then
					parabola:renderToBeam(beam0)
					hitAttach.CFrame = beam0.Attachment1.CFrame * CFrame.Angles(0, math.rad(90), 0)
				end

				-- ModularHitVFX = false usa el VFX heredado por arma.
				if self:getConfigValue("ModularHitVFX") then
					if shouldPlayPlayerHitVFX(hitInfo, self.player) then
						HitVFX.play(hitInfo, localPlayerInitiatedShot)
					end
				else
					local hitPartColor = hitPart and hitPart.Color or Color3.fromRGB(255, 255, 255)
					if hitPart and hitPart:IsA("Terrain") then
						hitPartColor = workspace.Terrain:GetMaterialColor(hitMaterial or Enum.Material.Sand)
					end
					if hitInfo.h and hitInfo.h:IsA("Humanoid") and hitParticles and numHitParticles > 0 and hitPart and shouldPlayPlayerHitVFX(hitInfo, self.player) then
						hitParticles.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
						hitParticles:Emit(numHitParticles)
						visualEffectsLingerTime = math.max(visualEffectsLingerTime, hitParticles.Lifetime.Max)
					elseif (not hitInfo.h or not hitInfo.h:IsA("Humanoid")) and hitParticles and numHitParticles > 0 then
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

					if hitSound and shouldPlayPlayerHitVFX(hitInfo, self.player) then
						hitSound:Play()
						visualEffectsLingerTime = math.max(visualEffectsLingerTime, hitSound.TimeLength)
					end
				end

				self:_spawnHitMark(hitPart, hitPoint, hitNormal, parabola)

				flyingVisualEffectsFinished = true
				visualEffectsFinishTime = now + visualEffectsLingerTime
			end
		end

		if projFront >= maxDist then
			if not stoppedMotion then
				stoppedMotion = true
				stoppedMotionAt = now
			end

			if projBack >= maxDist and not flyingVisualEffectsFinished then
				flyingVisualEffectsFinished = true
				visualEffectsFinishTime = now + visualEffectsLingerTime
			end
		end

		parabola:setDomain(projBack, projFront)

		if projBack < maxDist then
			pTravelDistance = math.max(0, timeSinceStart * bulletSpeed)
		end

		-- bulletEffect sigue al frente de la bala (lo necesitan las partículas de estela en Attachment0).
		if not stoppedMotion then
			local bulletPos = parabola:samplePoint(1)
			local bulletVelocity = parabola:sampleVelocity(1)
			bulletEffect.CFrame = CFrame.new(bulletPos, bulletPos + bulletVelocity)
			if shouldMovePart then
				bulletEffect.AssemblyLinearVelocity = bulletVelocity.Unit * bulletSpeed
			end
		end

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

		local timeSinceParticleEffectsFinished = now - visualEffectsFinishTime
		if (flyingVisualEffectsFinished and timeSinceParticleEffectsFinished > 0) or timeSinceStart > MAX_BULLET_TIME then
			if bulletEffect then
				_releaseBulletEffect(bulletEffectTemplate, bulletEffect)
				bulletEffect = nil
			end

			stepConn:Disconnect()
		end
	end

	projectileEntry.callback = steppedCallback
	table.insert(activeProjectiles, projectileEntry)
	_ensureProjectileLoop()

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
	-- No confiar en hitInfo.d (falseable a 0): serverOrigin lo puebla WeaponSecurity.validateHit.
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

	-- _defaultDamageCallback lee hitInfo.wasHeadshot (poblado en onHit). El arma va
	-- explícita: con un proyectil en vuelo el Tool equipado puede ser ya otro.
	self.weaponsSystem.doDamage(hitInfo.h, damage, nil, self.player, hitInfo, self.instance)
end

function BulletWeapon:onHit(hitInfo)
	local hitPoint = hitInfo.p
	local hitNormal = hitInfo.n
	local hitPart = hitInfo.part

	if hitPart and hitPart.Parent then
		local humanoid, wasHeadshot = self.weaponsSystem.getHumanoid(hitPart)
		hitInfo.h = humanoid or hitPart
		hitInfo.wasHeadshot = wasHeadshot == true

		-- En el server, headshot solo si el part golpeado es "Head" (validateHit ya
		-- verificó la proximidad part/punto). El multiplicador se fija aquí y no se lee
		-- del payload, que es del cliente.
		if IsServer then
			hitInfo.wasHeadshot = hitPart.Name == "Head"
			hitInfo.headshotMultiplier = self:getConfigValue("HeadshotMultiplier")
		end

		if IsServer and
			(not hitInfo.h:IsA("Humanoid") or
				isEnemyHumanoidForPlayer(hitInfo.h, self.player))
		then
			self:applyDamage(hitInfo)
		elseif hitInfo.h:IsA("Humanoid") and
			not isDeadHumanoid(hitInfo.h) and
			self.weaponsSystem.gui and
			self.player == Players.LocalPlayer and
			isEnemyHumanoidForPlayer(hitInfo.h, self.player)
		then
			local shownDamage = self:calculateDamage(hitInfo.d)
			if hitPart.Name == "Head" then
				shownDamage *= self:getConfigValue("HeadshotMultiplier")
			end
			self.weaponsSystem.gui:OnHitOtherPlayer(shownDamage, hitInfo.h, hitPart)
		end
	end

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
					self.weaponsSystem.doDamage(humanoid, damageToDeal, nil, self.player, nil, self.instance)
				end
			elseif not CollectionService:HasTag(explodedPart, "WeaponsSystemIgnore") then
				self.weaponsSystem.doDamage(explodedPart, damageToDeal, nil, self.player, nil, self.instance)
			end
		end)

		explosion.Parent = workspace

		WeaponsNetwork.broadcastExplosionVFX(explosion.Position)
	end

	if IsServer and FireZone and self.player and self:getConfigValue("FireZoneOnImpact") then
		local normal = hitNormal
		local impact = hitPoint
		local hitHumanoid = hitInfo.h
		if typeof(hitHumanoid) == "Instance" and hitHumanoid:IsA("Humanoid") then
			if isEnemyHumanoidForPlayer(hitHumanoid, self.player) then
				FireZone.ignite({
					weaponsSystem = self.weaponsSystem,
					dealer = self.player,
					weaponName = self.instance.Name,
					humanoid = hitHumanoid,
					damagePerSecond = self:getConfigValue("FireZoneDamage"),
				})
			end
			-- La zona se apoya bajo el jugador, no bajo el punto del cuerpo donde entró
			-- la bengala (una cabeza a 5 studs con la normal hacia fuera).
			local root = hitHumanoid.RootPart
			if root then
				impact = root.Position
				normal = Vector3.yAxis
			end
		end
		FireZone.spawn({
			weaponsSystem = self.weaponsSystem,
			dealer = self.player,
			weaponName = self.instance.Name,
			impact = impact,
			normal = normal,
			radius = self:getConfigValue("FireZoneRadius"),
			duration = self:getConfigValue("FireZoneDuration"),
			damagePerSecond = self:getConfigValue("FireZoneDamage"),
		})
	end
end

function BulletWeapon:fire(origin, dir, charge)
	if not self:isCharged() then
		return
	end

	-- Antes de enviar fireInfo: el server valida el hit contra este dir y los demás
	-- clientes simulan desde él, así que todos ven la misma bala desviada.
	local hipFireSpread = self:getConfigValue("HipFireSpread")
	local camera = self.weaponsSystem and self.weaponsSystem.camera
	if hipFireSpread > 0 and not IsServer and camera and not camera:isZoomed() then
		dir = Roblox.applySpread(dir, localRandom, 0, math.rad(hipFireSpread))
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
		if self.equipped and self:getAmmoInWeapon() <= 0 then
			self:reload()
			return
		end

		if self.activated and self.player == localPlayer and self:canFire() and os.clock() > self.nextFireTime then
			self:doLocalFire()
		end

		if not self.activated and self.triggerDisconnected and not self.burstFiring then
			self.triggerDisconnected = false
		end
	end
end

-- Perezoso: rig y welds llegan por replicación; devuelve false hasta que estén.
function BulletWeapon:_ensureViewKickRefs(): boolean
	local joint = self._viewKickJoint
	if joint and joint.Parent then
		return true
	end
	local handle = self.instance:FindFirstChild("Handle") :: BasePart?
	if not handle then
		return false
	end

	-- Grip = el joint del Handle que conecta con una parte que NO es del Tool.
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

	-- Fallback HandleWeld: requiere que las partes visibles estén soldadas al PrimaryPart.
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

-- La dirección boca→Handle define el eje de movimiento. En cliente self.handle es nil
-- (sólo lo asigna el servidor).
function BulletWeapon:_resolveMovingParts(): boolean
	if not self._movingParts or not self.tipAttach then
		return false
	end
	for _, entry in self._movingParts do
		if not entry.bolt:isResolved() then
			local handle = self.instance:FindFirstChild("Handle")
			if not (handle and handle:IsA("BasePart")) then
				return false
			end
			local back = handle.Position - self.tipAttach.WorldPosition
			entry.bolt:resolve(if entry.group.forward then -back else back)
		end
	end
	return true
end

function BulletWeapon:_kickMovingParts()
	if not self:_resolveMovingParts() then
		return
	end

	local cooldown = self:getConfigValue("ShotCooldown")
	if self:getConfigValue("FireMode") == "Burst" then
		cooldown = self:getConfigValue("BurstShotCooldown") or cooldown
	end
	local now = os.clock()
	for _, entry in self._movingParts do
		local group = entry.group
		local delay = self:getConfigValue(group.name .. "Delay")
		local cycle = self:getConfigValue(group.name .. "CycleTime")
			or math.clamp((cooldown - delay) * group.fill, group.minCycle, group.maxCycle)
		entry.bolt:kick(now, cycle, delay)
	end
end

-- El proyectil cargado (AmmoPart) desaparece al disparar y vuelve al recargar creciendo
-- desde AMMO_PART_APPEAR_SCALE. Solo cliente: la transparencia y el tamaño locales no
-- replican, pero CurrentAmmo sí, así que cada cliente lo oculta también en las armas de
-- los demás.
function BulletWeapon:_setAmmoPartsHidden(hidden: boolean)
	if IsServer or hidden == self._ammoPartsHidden then
		return
	end
	local parts = self._ammoParts
	if not parts then
		parts = {}
		self._ammoParts = parts
		local partName = self:getConfigValue("AmmoPart")
		for _, part in if partName then self.instance:GetDescendants() else {} do
			if part.Name == partName and part:IsA("BasePart") then
				-- Un SpecialMesh ignora el Size de la parte: hay que escalar el mesh.
				local mesh = part:FindFirstChildOfClass("SpecialMesh")
				table.insert(parts, {
					part = part,
					transparency = part.Transparency,
					size = part.Size,
					mesh = mesh,
					meshScale = mesh and mesh.Scale,
					tweens = {},
				})
			end
		end
	end

	self._ammoPartsHidden = hidden
	for _, entry in parts do
		for _, tween in entry.tweens do
			tween:Cancel()
		end
		table.clear(entry.tweens)

		if hidden then
			entry.part.Transparency = 1
			entry.part.Size = entry.size
			if entry.mesh then
				entry.mesh.Scale = entry.meshScale
			end
		else
			local function play(instance: Instance, info: TweenInfo, goal: { [string]: any })
				local tween = TweenService:Create(instance, info, goal)
				table.insert(entry.tweens, tween)
				tween:Play()
			end

			entry.part.Transparency = 1
			play(entry.part, AMMO_PART_FADE_TWEEN, { Transparency = entry.transparency })
			if entry.mesh then
				entry.mesh.Scale = entry.meshScale * AMMO_PART_APPEAR_SCALE
				play(entry.mesh, AMMO_PART_GROW_TWEEN, { Scale = entry.meshScale })
			else
				entry.part.Size = entry.size * AMMO_PART_APPEAR_SCALE
				play(entry.part, AMMO_PART_GROW_TWEEN, { Size = entry.size })
			end
		end
	end
end

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
		if self._viewKick > 1e-3 then
			local cam = workspace.CurrentCamera
			if cam and self:_ensureViewKickRefs() then
				local joint = self._viewKickJoint :: any
				local base = self._viewKickBase :: CFrame
				local part = self._viewKickPart :: BasePart
				-- Default mayor para explosivas; un ViewKickDistance explícito gana.
				local defaultKick = if self:getConfigValue("ExplodeOnImpact") then 0.85 else 0.07
				local maxBack = self:getConfigValue("ViewKickDistance", defaultKick)
				-- "Hacia atrás" = opuesto al LookVector de la cámara (el TipAttachment no tiene
				-- orientación garantizada).
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

		local aimTrack = self:getAnimTrack(self:getConfigValue("AimTrack"))
		local aimZoomTrack = self:getAnimTrack(self:getConfigValue("AimZoomTrack"))
		if aimTrack then
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

			local recoilDecay = self:getConfigValue("RecoilDecay")
			self.recoilIntensity = math.clamp(self.recoilIntensity * recoilDecay, 0, math.huge)
		elseif not self._warnedNoAimTrack then
			-- onRenderStepped corre cada frame: sin el flag esto inunda el Output.
			self._warnedNoAimTrack = true
			warn(("[BulletWeapon] %s sin aimTrack"):format(self.instance.Name))
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

	local empty = self:getAmmoInWeapon() <= 0
	self:_setAmmoPartsHidden(empty)

	if self:_resolveMovingParts() then
		self._reloadHinge:resolve()
		self._reloadHinge:step(
			dt,
			self.reloading == true,
			self:getConfigValue("ReloadHingeAngle"),
			self:getConfigValue("ReloadHingeOpenTime"),
			self:getConfigValue("ReloadHingeCloseTime")
		)

		for _, entry in self._movingParts do
			local name = entry.group.name
			local locked = empty and self:getConfigValue(name .. "LockOnEmpty")
			entry.bolt:step(now, self:getConfigValue(name .. "Travel"), locked)
		end
	end

	local chargingSound = self:getSound("Charging")
	local dischargingSound = self:getSound("Discharging")

	if self.usesCharging then
		local chargeBefore = self.charge
		self:handleCharging(dt)
		local chargeDelta = self.charge - chargeBefore

		if chargeDelta > 0 then
			self:setChargingParticles(self.charge)
		else
			self:setChargingParticles(0)
		end

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
