--[[
	NPCWeaponFX - Módulo de efectos visuales para armas de NPC
	Replica el pipeline visual de BulletWeapon del TPS-System para que
	los NPCs tengan los mismos efectos que los jugadores reales:
	- Muzzle flash con Beam
	- Trayectoria parabólica (Parabola)
	- Beam trails (Beam0/Beam1)
	- Partículas de impacto, sonido de impacto, hit marks
	- Explosiones visuales
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local NPCWeaponFX = {}

-- Dependencias cargadas en Init()
local Parabola = nil
local ShotsFolder = nil
local HitMarksFolder = nil
local isInitialized = false

local localRandom = Random.new()
local MAX_BULLET_TIME = 10

-- Intenta localizar el TPS-System automáticamente para inicializar FX.
local function tryAutoInit()
	if isInitialized then
		return true
	end

	local searchRoots = {
		game:GetService("ReplicatedStorage"),
		game:GetService("ServerStorage"),
		workspace,
	}

	local candidates = {
		"WeaponsSystem",
		"TPS-System",
	}

	for _, root in ipairs(searchRoots) do
		for _, name in ipairs(candidates) do
			local folder = root:FindFirstChild(name)
			if folder and folder:FindFirstChild("Libraries") and folder:FindFirstChild("Assets") then
				NPCWeaponFX.Init(folder)
				return isInitialized
			end
		end
	end

	return false
end

-- Lee valores de configuración de la Configuration del arma (igual que BulletWeapon:getConfigValue)
local function getConfigValue(weaponModel, key, default)
	local config = weaponModel:FindFirstChildOfClass("Configuration")
	if config then
		local valueObj = config:FindFirstChild(key)
		if valueObj and valueObj:IsA("ValueBase") then
			return valueObj.Value
		end
	end
	return default
end

-- Reproduce sonidos clonándolos (igual que BaseWeapon:tryPlaySound)
local function playSound(parent, soundName, playbackSpeedRange)
	playbackSpeedRange = playbackSpeedRange or 0
	if not parent then return end

	local soundTemplate = parent:FindFirstChild(soundName, true)
	if not soundTemplate or not soundTemplate:IsA("Sound") then return end

	local sound = soundTemplate:Clone()
	sound.PlaybackSpeed = sound.PlaybackSpeed
		+ localRandom:NextNumber(-playbackSpeedRange * 0.5, playbackSpeedRange * 0.5)
	sound.Parent = soundTemplate.Parent
	sound:Play()
	Debris:AddItem(sound, sound.TimeLength / math.max(sound.PlaybackSpeed, 0.01) + 0.1)
	return sound
end

-- Busca humanoid hacia arriba en la jerarquía (igual que weaponsSystem.getHumanoid)
local function getHumanoidFromPart(part)
	local node = part
	while node do
		local h = node:FindFirstChildOfClass("Humanoid")
		if h then return h end
		node = node.Parent
	end
	return nil
end

------------------------------------------------------------------------
-- INIT: Carga dependencias del TPS-System
------------------------------------------------------------------------
function NPCWeaponFX.Init(weaponsSystemFolder)
	if isInitialized then return end

	local Libraries = weaponsSystemFolder:WaitForChild("Libraries")
	Parabola = require(Libraries:WaitForChild("Parabola"))

	local Assets = weaponsSystemFolder:WaitForChild("Assets")
	local Effects = Assets:WaitForChild("Effects")
	ShotsFolder = Effects:WaitForChild("Shots")
	HitMarksFolder = Effects:WaitForChild("HitMarks")

	isInitialized = true
end

------------------------------------------------------------------------
-- SETUP: Verifica estructura del arma
------------------------------------------------------------------------
function NPCWeaponFX.SetupWeapon(weaponModel)
	if not weaponModel then return end
	if not isInitialized then
		tryAutoInit()
	end

	local tipAttach = weaponModel:FindFirstChild("TipAttachment", true)
	if not tipAttach then
		warn("NPCWeaponFX: No se encontró TipAttachment en " .. weaponModel.Name)
	end
end

------------------------------------------------------------------------
-- FIRE: Pipeline visual completo (réplica de BulletWeapon:simulateProjectile)
------------------------------------------------------------------------
function NPCWeaponFX.Fire(weaponModel, targetPosition, npcModel)
	if not isInitialized and not tryAutoInit() then
		warn("NPCWeaponFX: Módulo no inicializado. Llama NPCWeaponFX.Init() primero.")
		return
	end
	if not weaponModel then return end

	local tipAttach = weaponModel:FindFirstChild("TipAttachment", true)
	if not tipAttach then return end

	local origin = tipAttach.WorldPosition
	local dir = (targetPosition - origin).Unit

	-- Leer configuración del arma (mismos defaults que BulletWeapon)
	local bulletSpeed             = getConfigValue(weaponModel, "BulletSpeed", 1000)
	local maxDistance             = getConfigValue(weaponModel, "MaxDistance", 2000)
	local trailLengthFactor       = getConfigValue(weaponModel, "TrailLengthFactor", 1)
	local trailLength             = getConfigValue(weaponModel, "TrailLength", nil)
	local showEntireTrailUntilHit = getConfigValue(weaponModel, "ShowEntireTrailUntilHit", false)
	local gravityFactor           = getConfigValue(weaponModel, "GravityFactor", 0)
	local shouldMovePart          = getConfigValue(weaponModel, "ShouldMovePart", false)
	local explodeOnImpact         = getConfigValue(weaponModel, "ExplodeOnImpact", false)
	local blastRadius             = getConfigValue(weaponModel, "BlastRadius", 8)
	local muzzleFlashTime         = getConfigValue(weaponModel, "MuzzleFlashTime", 0.03)
	local beamThickness0          = getConfigValue(weaponModel, "BeamWidth0", 1.5)
	local beamThickness1          = getConfigValue(weaponModel, "BeamWidth1", 1.8)
	local beamFadeTime            = getConfigValue(weaponModel, "BeamFadeTime", nil)
	local numHitParticles         = getConfigValue(weaponModel, "NumHitParticles", 3)
	local numMuzzleParticles      = getConfigValue(weaponModel, "NumMuzzleParticles", 50)
	local shotEffect              = getConfigValue(weaponModel, "ShotEffect", "Bullet")
	local hitMarkEffect           = getConfigValue(weaponModel, "HitMarkEffect", "BulletHole")
	local alignHitMarkToNormal    = getConfigValue(weaponModel, "AlignHitMarkToNormal", true)

	-----------------------------------------------------------------
	-- 1. SONIDO DE DISPARO
	-----------------------------------------------------------------
	playSound(weaponModel, "Fired", getConfigValue(weaponModel, "FiredPlaybackSpeedRange", 0.1))

	-----------------------------------------------------------------
	-- 2. MUZZLE FLASH
	-----------------------------------------------------------------
	local muzzleFlash0    = weaponModel:FindFirstChild("MuzzleFlash0", true)
	local muzzleFlash1    = weaponModel:FindFirstChild("MuzzleFlash1", true)
	local muzzleFlashBeam = weaponModel:FindFirstChild("MuzzleFlash", true)
	local muzzleFlashShown = false

	if tipAttach and muzzleFlash0 and muzzleFlash1 and muzzleFlashBeam then
		local minRot  = getConfigValue(weaponModel, "MuzzleFlashRotation0", -math.pi)
		local maxRot  = getConfigValue(weaponModel, "MuzzleFlashRotation1", math.pi)
		local minSize = getConfigValue(weaponModel, "MuzzleFlashSize0", 1)
		local maxSize = getConfigValue(weaponModel, "MuzzleFlashSize1", 1)

		local flashRotation = localRandom:NextNumber(minRot, maxRot)
		local flashSize     = localRandom:NextNumber(minSize, maxSize)
		local baseCFrame    = tipAttach.CFrame * CFrame.Angles(0, 0, flashRotation)

		muzzleFlash0.CFrame = baseCFrame * CFrame.new(flashSize * -0.5, 0, 0) * CFrame.Angles(0, math.pi, 0)
		muzzleFlash1.CFrame = baseCFrame * CFrame.new(flashSize *  0.5, 0, 0) * CFrame.Angles(0, math.pi, 0)

		muzzleFlashBeam.Enabled = true
		muzzleFlashBeam.Width0 = flashSize
		muzzleFlashBeam.Width1 = flashSize
		muzzleFlashShown = true
	end

	for _, child in pairs(tipAttach:GetChildren()) do
		if child:IsA("ParticleEmitter") and string.find(child.Name, "Flash") then
			child:Emit(1)
		elseif child:IsA("Light") then
			child.Enabled = true
			task.delay(muzzleFlashTime, function()
				if child then
					child.Enabled = false
				end
			end)
		end
	end

	-----------------------------------------------------------------
	-- 3. CLONAR BULLET EFFECT
	-----------------------------------------------------------------
	local bulletEffectTemplate = ShotsFolder:FindFirstChild(shotEffect)
	if not bulletEffectTemplate then
		warn("NPCWeaponFX: Efecto '" .. shotEffect .. "' no encontrado en Shots")
		return
	end

	local bulletEffect = bulletEffectTemplate:Clone()
	bulletEffect.CFrame = CFrame.new(origin, origin + dir)
	bulletEffect.Parent = workspace
	CollectionService:AddTag(bulletEffect, "WeaponsSystemIgnore")

	local leadingParticles = bulletEffect:FindFirstChild("LeadingParticles", true)
	local attachment0      = bulletEffect:FindFirstChild("Attachment0")
	local trailParticles   = attachment0 and attachment0:FindFirstChild("TrailParticles")
	local hitAttach        = bulletEffect:FindFirstChild("HitEffect")
	local hitParticles     = bulletEffect:FindFirstChild("HitParticles", true)
	local hitSound         = bulletEffect:FindFirstChild("HitSound", true)
	local flyingSound      = bulletEffect:FindFirstChild("Flying", true)

	local beam0 = bulletEffect:FindFirstChild("Beam0")
	if beam0 then
		beam0.Enabled = true
	end
	local beam1 = bulletEffect:FindFirstChild("Beam1")
	if beam1 then
		beam1.Enabled = true
	end

	-----------------------------------------------------------------
	-- 4. MUZZLE PARTICLES
	-----------------------------------------------------------------
	local muzzleParticles = bulletEffect:FindFirstChild("MuzzleParticles", true)
	if muzzleParticles then
		muzzleParticles.Parent.CFrame = CFrame.new(origin, origin + dir)
		local numSteps = 5
		for _ = 1, numSteps do
			muzzleParticles.Parent.Velocity = Vector3.new(
				localRandom:NextNumber(-10, 10),
				localRandom:NextNumber(-10, 10),
				localRandom:NextNumber(-10, 10)
			)
			muzzleParticles:Emit(numMuzzleParticles / numSteps)
		end
	end

	if flyingSound then
		flyingSound:Play()
	end
	if trailParticles then
		trailParticles.Enabled = true
	end

	-----------------------------------------------------------------
	-- 5. PARABOLA
	-----------------------------------------------------------------
	local parabola = Parabola.new()
	parabola:setPhysicsLaunch(origin, dir * bulletSpeed, nil, 35 * -gravityFactor)
	if gravityFactor > 0.66 then
		parabola:setNumSamples(3)
	elseif gravityFactor > 0.33 then
		parabola:setNumSamples(2)
	else
		parabola:setNumSamples(1)
	end

	local ignoreList = {}
	if npcModel then
		table.insert(ignoreList, npcModel)
	end
	table.insert(ignoreList, weaponModel)

	local hitMarkTemplate = HitMarksFolder and HitMarksFolder:FindFirstChild(hitMarkEffect)

	-----------------------------------------------------------------
	-- 6. HEARTBEAT LOOP
	-----------------------------------------------------------------
	local stepConn = nil
	local pTravelDistance = 0
	local startTime = tick()
	local didHit = false
	local stoppedMotion = false
	local stoppedMotionAt = 0
	local timeSinceStart = 0
	local flyingVisualEffectsFinished = false
	local visualEffectsFinishTime = math.huge
	local visualEffectsLingerTime = beamFadeTime or 0

	local hitInfo = {
		maxDist = maxDistance,
		part = nil,
		p = nil,
		n = nil,
		m = Enum.Material.Air,
		d = 1e9,
	}

	stepConn = RunService.Heartbeat:Connect(function(dt)
		local now = tick()
		timeSinceStart = now - startTime

		local travelDist = bulletSpeed * dt
		trailLength = trailLength or travelDist * trailLengthFactor

		local projBack  = pTravelDistance - trailLength
		local projFront = pTravelDistance
		local maxDist   = hitInfo.maxDist or 0

		if showEntireTrailUntilHit then
			projBack = 0
		end

		projBack  = math.clamp(projBack, 0, maxDist)
		projFront = math.clamp(projFront, 0, maxDist)

		if not didHit then
			local castProjBack  = projFront
			local castProjFront = projFront + travelDist
			parabola:setDomain(castProjBack, castProjFront)
			local hitPart, hitPoint, hitNormal, hitMaterial, hitT = parabola:findPart(ignoreList)

			if hitPart then
				didHit = true
				projFront = castProjBack + hitT * (castProjFront - castProjBack)
				parabola:setDomain(projBack, projFront)

				hitInfo.part    = hitPart
				hitInfo.p       = hitPoint
				hitInfo.n       = hitNormal
				hitInfo.m       = hitMaterial
				hitInfo.d       = (hitPoint - origin).Magnitude
				hitInfo.t       = hitT
				hitInfo.maxDist = projFront

				if trailParticles then
					trailParticles.Enabled = false
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

				if explodeOnImpact then
					local explosion = Instance.new("Explosion")
					explosion.Position = hitPoint + (hitNormal * 0.5)
					explosion.BlastRadius = blastRadius
					explosion.BlastPressure = 0
					explosion.ExplosionType = Enum.ExplosionType.NoCraters
					explosion.DestroyJointRadiusPercent = 0
					explosion.Visible = true
					explosion.Parent = workspace
				end

				if hitAttach and beam0 and beam0.Attachment1 then
					parabola:renderToBeam(beam0)
					hitAttach.CFrame = beam0.Attachment1.CFrame * CFrame.Angles(0, math.rad(90), 0)
				end

				local hitPartColor = hitPart and hitPart.Color or Color3.fromRGB(255, 255, 255)
				if hitPart and hitPart:IsA("Terrain") then
					hitPartColor = workspace.Terrain:GetMaterialColor(hitMaterial or Enum.Material.Sand)
				end

				local hitHumanoid = getHumanoidFromPart(hitPart)

				if hitHumanoid and hitParticles and numHitParticles > 0 and hitPart then
					hitParticles.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
					hitParticles:Emit(numHitParticles)
					visualEffectsLingerTime = math.max(visualEffectsLingerTime, hitParticles.Lifetime.Max)
				elseif not hitHumanoid and hitParticles and numHitParticles > 0 then
					if hitPart then
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

				if hitSound then
					hitSound:Play()
					visualEffectsLingerTime = math.max(visualEffectsLingerTime, hitSound.TimeLength)
				end

				if hitPart and hitMarkTemplate and not hitHumanoid then
					local hitPointOS  = hitPart.CFrame:pointToObjectSpace(hitPoint)
					local hitNormalOS = hitPart.CFrame:vectorToObjectSpace(hitNormal)

					local hitMark = hitMarkTemplate:Clone()
					hitMark.Parent = hitPart
					CollectionService:AddTag(hitMark, "WeaponsSystemIgnore")

					local incomingVec = parabola:sampleVelocity(1).Unit

					if alignHitMarkToNormal then
						local forward = hitNormalOS
						local up = incomingVec
						local right = -forward:Cross(up).Unit
						up = forward:Cross(right)
						local orientCF = CFrame.fromMatrix(
							hitPointOS + hitNormalOS * 0.05,
							right, up, -forward
						)
						hitMark.CFrame = hitPart.CFrame:toWorldSpace(orientCF)
					else
						hitMark.CFrame = hitPart.CFrame * CFrame.new(
							hitPointOS,
							hitPointOS + hitPart.CFrame:vectorToObjectSpace(incomingVec)
						)
					end

					local weld = Instance.new("WeldConstraint")
					weld.Part0 = hitMark
					weld.Part1 = hitPart
					weld.Parent = hitMark

					local impactBillboard = hitMark:FindFirstChild("ImpactBillboard")
					if impactBillboard then
						local impact = impactBillboard:FindFirstChild("Impact")
						if impact then
							local impactTween = TweenService:Create(
								impact,
								TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
								{ Size = UDim2.new(1, 0, 1, 0) }
							)
							impactTween.Completed:Connect(function()
								TweenService:Create(
									impact,
									TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
									{ Size = UDim2.new(0.5, 0, 0.5, 0), ImageTransparency = 1 }
								):Play()
							end)
							impactTween:Play()
						end
					end

					Debris:AddItem(hitMark, 5)
				end

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

		if shouldMovePart and bulletEffect then
			local bulletPos = parabola:samplePoint(1)
			local bulletVelocity = parabola:sampleVelocity(1)
			bulletEffect.CFrame = CFrame.new(bulletPos, bulletPos + bulletVelocity)
			bulletEffect.Velocity = bulletVelocity.Unit * bulletSpeed
		end

		local thickness0 = beamThickness0
		local thickness1 = beamThickness1
		if beamFadeTime then
			local timeSinceEnd = stoppedMotion and (now - stoppedMotionAt) or 0
			local fadeAlpha = math.clamp(timeSinceEnd / beamFadeTime, 0, 1)
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

		if muzzleFlashShown and timeSinceStart > muzzleFlashTime and muzzleFlashBeam then
			muzzleFlashBeam.Enabled = false
			muzzleFlashShown = false
		end

		local timeSinceParticlesDone = now - visualEffectsFinishTime
		if (flyingVisualEffectsFinished and timeSinceParticlesDone > 0) or timeSinceStart > MAX_BULLET_TIME then
			if bulletEffect then
				bulletEffect:Destroy()
				bulletEffect = nil
			end
			stepConn:Disconnect()
		end
	end)
end

return NPCWeaponFX
