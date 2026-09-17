local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local HealEffect = require(script.Parent:WaitForChild("HealEffect"))

local HealthBarController = {}

-- Cada efecto de viñeta tiene su propio NumberValue driver (hijo del Vignette) que
-- Scope.luau lee vía .Changed y compone: HealthAlphaDriver (rojo, vida baja),
-- DamageAlphaDriver (rojo, golpe; ambos rojos por max), HealAlphaDriver (verde) y
-- KillAlphaDriver (amarillo, menor prioridad). Los nombres deben coincidir con Scope.
local VIGNETTE_HEALTH_THRESHOLD = 0.4
-- *_PEAK_TRANSPARENCY: ImageTransparency real en el pico (0 = opaco, 1 = invisible);
-- el alpha del renderer se deriva.
local VIGNETTE_HEALTH_PEAK_TRANSPARENCY = 0
local VIGNETTE_HEALTH_MAX_ALPHA = 1 - VIGNETTE_HEALTH_PEAK_TRANSPARENCY

-- HEAL_EFFECT_DURATION es la fuente única de la duración del flash y de HealEffect;
-- el reparto 18% / 57% / 25% debe coincidir con la envolvente de HealEffect.
local HEAL_EFFECT_DURATION = 2.7
local VIGNETTE_HEAL_PEAK_TRANSPARENCY = 0.55
local VIGNETTE_HEAL_PEAK_ALPHA = 1 - VIGNETTE_HEAL_PEAK_TRANSPARENCY
local HEAL_FADE_IN_INFO = TweenInfo.new(HEAL_EFFECT_DURATION * 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HEAL_FADE_OUT_INFO = TweenInfo.new(HEAL_EFFECT_DURATION * 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HEAL_HOLD_SECONDS = HEAL_EFFECT_DURATION * 0.57
-- Filtra el regen default del Humanoid (~1 HP/s): solo heals discretos disparan el flash.
local HEALTH_GAIN_THRESHOLD = 5
local HEAL_FILL_INFO = TweenInfo.new(HEAL_EFFECT_DURATION * 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local DAMAGE_FLASH_THRESHOLD = 1 -- HP mínimos perdidos para disparar el flash
local VIGNETTE_DAMAGE_PEAK_TRANSPARENCY = 0.5
local VIGNETTE_DAMAGE_PEAK_ALPHA = 1 - VIGNETTE_DAMAGE_PEAK_TRANSPARENCY
local DAMAGE_FLASH_IN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DAMAGE_FLASH_OUT_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local VIGNETTE_KILL_PEAK_TRANSPARENCY = 0.2
local VIGNETTE_KILL_PEAK_ALPHA = 1 - VIGNETTE_KILL_PEAK_TRANSPARENCY
local KILL_FLASH_IN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local KILL_FLASH_HOLD_SECONDS = 0.15
local KILL_FLASH_OUT_INFO = TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- Damage trail: barra detrás del Fill que muestra la vida recién perdida y se drena despacio.
local DAMAGE_TRAIL_COLOR = Color3.fromRGB(200, 15, 15)
local DAMAGE_TRAIL_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.15)

local fillBar: Frame? = nil
local valueLabel: TextLabel? = nil
local damageTrail: Frame? = nil
local damageTrailTween: Tween? = nil
local fillTween: Tween? = nil
local vignette: Instance? = nil
local healthAlphaDriver: NumberValue? = nil
local healAlphaDriver: NumberValue? = nil
local damageAlphaDriver: NumberValue? = nil
local killAlphaDriver: NumberValue? = nil
local healVignetteTween: Tween? = nil
local damageVignetteTween: Tween? = nil
local killVignetteTween: Tween? = nil
local healthConn: RBXScriptConnection? = nil
local lastSeenHealth: number? = nil
local healVignetteGeneration = 0
local damageVignetteGeneration = 0
local killVignetteGeneration = 0
-- Mientras el flash verde está en pantalla, el daño NO pone la viñeta roja.
local healVignetteActive = false

local function getHealthBarNodes(): (Frame?, TextLabel?)
	if fillBar and valueLabel then
		return fillBar, valueLabel
	end

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil, nil end

	-- HealthBar vive en WeaponSystemInsets (safe-area); fallback a WeaponsSystemGui.
	local healthBar: Instance? = nil
	for _, guiName in { "WeaponSystemInsets", "WeaponsSystemGui" } do
		local gui = playerGui:FindFirstChild(guiName)
		healthBar = gui and gui:FindFirstChild("HealthBar")
		if healthBar then break end
	end
	if not healthBar then return nil, nil end

	local fill = healthBar:FindFirstChild("Fill")
	local value = healthBar:FindFirstChildWhichIsA("TextLabel", true)

	fillBar = if fill and fill:IsA("Frame") then fill else nil
	valueLabel = if value and value:IsA("TextLabel") then value else nil

	return fillBar, valueLabel
end

local function getDamageTrail(fill: Frame): Frame?
	if damageTrail and damageTrail.Parent then
		return damageTrail
	end

	local parent = fill.Parent
	if not (parent and parent:IsA("GuiObject")) then
		return nil
	end

	-- La GUI puede persistir entre respawns.
	local existing = parent:FindFirstChild("DamageTrail")
	if existing and existing:IsA("Frame") then
		damageTrail = existing
		return existing
	end

	local trail = Instance.new("Frame")
	trail.Name = "DamageTrail"
	trail.AnchorPoint = fill.AnchorPoint
	trail.Position = fill.Position
	trail.Size = fill.Size
	trail.BackgroundColor3 = DAMAGE_TRAIL_COLOR
	trail.BorderSizePixel = 0
	trail.ZIndex = fill.ZIndex - 1

	local corner = fill:FindFirstChildOfClass("UICorner")
	if corner then
		corner:Clone().Parent = trail
	end

	trail.Parent = parent
	damageTrail = trail
	return trail
end

local function ensureDriver(parent: Instance, name: string): NumberValue
	local node = parent:FindFirstChild(name)
	if node and node:IsA("NumberValue") then
		return node
	end
	local val = Instance.new("NumberValue")
	val.Name = name
	val.Value = 0
	val.Parent = parent
	return val
end

local function getVignetteNodes(): (Instance?, NumberValue?, NumberValue?)
	if vignette and healthAlphaDriver and healAlphaDriver and damageAlphaDriver then
		return vignette, healthAlphaDriver, healAlphaDriver
	end

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil, nil, nil end

	-- Mismo Vignette que resuelve Scope.luau.
	local gui = playerGui:FindFirstChild("WeaponsSystemGui")
	local vignetteNode = gui and gui:FindFirstChild("Vignette", true)
	if not vignetteNode then
		return nil, nil, nil
	end

	vignette = vignetteNode
	healthAlphaDriver = ensureDriver(vignette, "HealthAlphaDriver")
	healAlphaDriver = ensureDriver(vignette, "HealAlphaDriver")
	damageAlphaDriver = ensureDriver(vignette, "DamageAlphaDriver")
	killAlphaDriver = ensureDriver(vignette, "KillAlphaDriver")

	return vignette, healthAlphaDriver, healAlphaDriver
end

-- Un heal nuevo en vuelo bumpea la generación y reinicia desde 0 para que el fade-in se note.
local function showHealVignette()
	local _, _, driver = getVignetteNodes()
	if not driver then return end

	healVignetteGeneration += 1
	local myGen = healVignetteGeneration
	healVignetteActive = true

	damageVignetteGeneration += 1
	if damageVignetteTween then
		damageVignetteTween:Cancel()
		damageVignetteTween = nil
	end
	if damageAlphaDriver and damageAlphaDriver.Parent then
		damageAlphaDriver.Value = 0
	end

	if healVignetteTween then
		healVignetteTween:Cancel()
		healVignetteTween = nil
	end

	driver.Value = 0
	local fadeIn = TweenService:Create(driver, HEAL_FADE_IN_INFO, {
		Value = VIGNETTE_HEAL_PEAK_ALPHA,
	})
	healVignetteTween = fadeIn
	fadeIn:Play()

	task.spawn(function()
		fadeIn.Completed:Wait()
		if healVignetteGeneration ~= myGen then return end

		task.wait(HEAL_HOLD_SECONDS)
		if healVignetteGeneration ~= myGen then return end
		if not driver.Parent then return end

		local fadeOut = TweenService:Create(driver, HEAL_FADE_OUT_INFO, {
			Value = 0,
		})
		healVignetteTween = fadeOut
		fadeOut:Play()
		fadeOut.Completed:Wait()
		if healVignetteGeneration ~= myGen then return end
		healVignetteTween = nil
		healVignetteActive = false
	end)
end

local function showDamageVignette()
	getVignetteNodes()
	local driver = damageAlphaDriver
	if not driver then return end

	damageVignetteGeneration += 1
	local myGen = damageVignetteGeneration

	if damageVignetteTween then
		damageVignetteTween:Cancel()
		damageVignetteTween = nil
	end

	driver.Value = 0
	local fadeIn = TweenService:Create(driver, DAMAGE_FLASH_IN_INFO, {
		Value = VIGNETTE_DAMAGE_PEAK_ALPHA,
	})
	damageVignetteTween = fadeIn
	fadeIn:Play()

	task.spawn(function()
		fadeIn.Completed:Wait()
		if damageVignetteGeneration ~= myGen then return end
		if not driver.Parent then return end

		local fadeOut = TweenService:Create(driver, DAMAGE_FLASH_OUT_INFO, {
			Value = 0,
		})
		damageVignetteTween = fadeOut
		fadeOut:Play()
		fadeOut.Completed:Wait()
		if damageVignetteGeneration ~= myGen then return end
		damageVignetteTween = nil
	end)
end

-- No se dispara si la viñeta ya está ocupada por curación, daño o vida baja.
local function showKillVignette()
	getVignetteNodes()
	local driver = killAlphaDriver
	if not driver then return end

	local dangerActive = healthAlphaDriver ~= nil and healthAlphaDriver.Value > 0
	local damageActive = damageAlphaDriver ~= nil and damageAlphaDriver.Value > 0
	if healVignetteActive or dangerActive or damageActive then
		return
	end

	killVignetteGeneration += 1
	local myGen = killVignetteGeneration

	if killVignetteTween then
		killVignetteTween:Cancel()
		killVignetteTween = nil
	end

	driver.Value = 0
	local fadeIn = TweenService:Create(driver, KILL_FLASH_IN_INFO, {
		Value = VIGNETTE_KILL_PEAK_ALPHA,
	})
	killVignetteTween = fadeIn
	fadeIn:Play()

	task.spawn(function()
		fadeIn.Completed:Wait()
		if killVignetteGeneration ~= myGen then return end
		task.wait(KILL_FLASH_HOLD_SECONDS)
		if killVignetteGeneration ~= myGen then return end
		if not driver.Parent then return end

		local fadeOut = TweenService:Create(driver, KILL_FLASH_OUT_INFO, {
			Value = 0,
		})
		killVignetteTween = fadeOut
		fadeOut:Play()
		fadeOut.Completed:Wait()
		if killVignetteGeneration ~= myGen then return end
		killVignetteTween = nil
	end)
end

local function updateHealthBar(humanoid: Humanoid, animateUp: boolean?)
	local bar, value = getHealthBarNodes()

	local maxHealth = math.max(humanoid.MaxHealth, 1)
	local ratio = math.clamp(humanoid.Health / maxHealth, 0, 1)

	if fillTween then
		fillTween:Cancel()
		fillTween = nil
	end

	if bar then
		local targetSize = UDim2.new(ratio, 0, 1, 0)
		local trail = getDamageTrail(bar)

		if animateUp then
			-- El trail sube en sync para no mostrar rojo por encima del Fill ascendente.
			if damageTrailTween then
				damageTrailTween:Cancel()
				damageTrailTween = nil
			end
			fillTween = TweenService:Create(bar, HEAL_FILL_INFO, { Size = targetSize })
			fillTween:Play()
			if trail then
				damageTrailTween = TweenService:Create(trail, HEAL_FILL_INFO, { Size = targetSize })
				damageTrailTween:Play()
			end
		else
			bar.Size = targetSize

			-- Se parte del ancho actual del trail (interpolado mid-tween) para continuar
			-- suave con golpes seguidos.
			if trail then
				if damageTrailTween then
					damageTrailTween:Cancel()
					damageTrailTween = nil
				end
				if ratio >= trail.Size.X.Scale then
					trail.Size = targetSize
				else
					damageTrailTween = TweenService:Create(trail, DAMAGE_TRAIL_INFO, {
						Size = targetSize,
					})
					damageTrailTween:Play()
				end
			end
		end
	end

	if value then
		value.Text = "+ " .. tostring(math.max(0, math.floor(humanoid.Health + 0.5)))
	end

	local _, dangerDriver = getVignetteNodes()
	if dangerDriver then
		if ratio >= VIGNETTE_HEALTH_THRESHOLD then
			dangerDriver.Value = 0
		else
			local intensity = 1 - (ratio / VIGNETTE_HEALTH_THRESHOLD)
			dangerDriver.Value = math.clamp(intensity * VIGNETTE_HEALTH_MAX_ALPHA, 0, VIGNETTE_HEALTH_MAX_ALPHA)
		end
	end
end

function HealthBarController.onCharacterAdded(character: Model)
	if healthConn then
		healthConn:Disconnect()
		healthConn = nil
	end

	-- Drivers a 0 antes de limpiar el cache: la GUI persiste y quedaría pintada.
	lastSeenHealth = nil
	healVignetteGeneration += 1
	damageVignetteGeneration += 1
	killVignetteGeneration += 1
	healVignetteActive = false
	if healVignetteTween then
		healVignetteTween:Cancel()
		healVignetteTween = nil
	end
	if damageVignetteTween then
		damageVignetteTween:Cancel()
		damageVignetteTween = nil
	end
	if killVignetteTween then
		killVignetteTween:Cancel()
		killVignetteTween = nil
	end
	HealEffect.reset()
	if damageTrailTween then
		damageTrailTween:Cancel()
		damageTrailTween = nil
	end
	if fillTween then
		fillTween:Cancel()
		fillTween = nil
	end
	if healthAlphaDriver and healthAlphaDriver.Parent then
		healthAlphaDriver.Value = 0
	end
	if healAlphaDriver and healAlphaDriver.Parent then
		healAlphaDriver.Value = 0
	end
	if damageAlphaDriver and damageAlphaDriver.Parent then
		damageAlphaDriver.Value = 0
	end
	if killAlphaDriver and killAlphaDriver.Parent then
		killAlphaDriver.Value = 0
	end

	fillBar = nil
	valueLabel = nil
	damageTrail = nil
	vignette = nil
	healthAlphaDriver = nil
	healAlphaDriver = nil
	damageAlphaDriver = nil
	killAlphaDriver = nil

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then return end

	updateHealthBar(humanoid)
	lastSeenHealth = humanoid.Health

	healthConn = humanoid.HealthChanged:Connect(function(newHealth: number)
		local isHeal = lastSeenHealth ~= nil and newHealth - lastSeenHealth >= HEALTH_GAIN_THRESHOLD
		local isDamage = lastSeenHealth ~= nil and lastSeenHealth - newHealth >= DAMAGE_FLASH_THRESHOLD
		if isHeal then
			showHealVignette()
			HealEffect.play(HEAL_EFFECT_DURATION)
		elseif isDamage and not healVignetteActive then
			showDamageVignette()
		end
		lastSeenHealth = newHealth
		updateHealthBar(humanoid, isHeal)
	end)
end

-- Lo llama NetworkingCallbacks.PlayerEliminated.
function HealthBarController.onKill()
	showKillVignette()
end

return HealthBarController
