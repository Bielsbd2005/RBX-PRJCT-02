local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local HealEffect = require(script.Parent:WaitForChild("HealEffect"))

local HealthBarController = {}

-- El Vignette muestra dos efectos de salud, cada uno con su propio NumberValue
-- driver (hijo del Vignette) que lee Scope.luau vía .Changed:
--
--  * HealthAlphaDriver (rojo): vignette continuo de PELIGRO. Se intensifica de
--    forma proporcional cuando la vida cae por debajo del umbral. Persiste
--    mientras la vida siga baja; vuelve a 0 al recuperarse.
--  * HealAlphaDriver (verde): flash puntual de CURACIÓN. Se dispara cuando el
--    jugador gana salud no trivial (pickup, ability, etc.) y se desvanece solo.
--
-- Antes la curación usaba un frame "Health" dedicado; ahora se pinta sobre el
-- mismo Vignette en verde.
local VIGNETTE_HEALTH_THRESHOLD = 0.4
-- Image transparency del vignette ROJO de peligro en su pico (0 HP). 0 = opaco,
-- 1 = invisible. Editá ESTE valor (es la transparency real); el alpha que usa el
-- renderer se deriva solo.
local VIGNETTE_HEALTH_PEAK_TRANSPARENCY = 0
local VIGNETTE_HEALTH_MAX_ALPHA = 1 - VIGNETTE_HEALTH_PEAK_TRANSPARENCY

-- Flash de curación: el umbral filtra el regen default del Humanoid (~1 HP/s) y
-- solo dispara con heals discretos. Si caen varios seguidos, la generación
-- corta el tween viejo y reinicia desde fade-in.
--
-- HEAL_EFFECT_DURATION es la fuente única de verdad: el flash del Vignette y el
-- efecto de partículas (HealEffect) abarcan exactamente esta misma duración. El
-- ciclo del Vignette (FADE_IN + HOLD + FADE_OUT) se reparte proporcionalmente
-- igual que la envolvente de HealEffect (entra 18% / sostiene / sale 25%).
local HEAL_EFFECT_DURATION = 2.7
-- Image transparency del vignette VERDE de curación en su pico. 0 = opaco,
-- 1 = invisible. Editá ESTE valor (es la transparency real); el alpha que usa el
-- renderer se deriva solo. OJO: esto controla SOLO el flash de viñeta — el glow
-- de bordes y las partículas son el módulo HealEffect, aparte.
local VIGNETTE_HEAL_PEAK_TRANSPARENCY = 0.55
local VIGNETTE_HEAL_PEAK_ALPHA = 1 - VIGNETTE_HEAL_PEAK_TRANSPARENCY
local HEAL_FADE_IN_INFO = TweenInfo.new(HEAL_EFFECT_DURATION * 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HEAL_FADE_OUT_INFO = TweenInfo.new(HEAL_EFFECT_DURATION * 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HEAL_HOLD_SECONDS = HEAL_EFFECT_DURATION * 0.57
local HEALTH_GAIN_THRESHOLD = 5

-- Damage trail ("ghost bar" estilo AAA): una barra roja detrás del Fill que
-- muestra el chunk de vida recién perdido y se drena despacio hasta el valor
-- actual. El Fill cae al instante; el trail lo persigue con un pequeño delay y
-- un tween lento. Al curarse (la barra sube) el trail salta al instante.
local DAMAGE_TRAIL_COLOR = Color3.fromRGB(200, 15, 15) -- rojo intenso
local DAMAGE_TRAIL_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.15)

local fillBar: Frame? = nil
local valueLabel: TextLabel? = nil
local damageTrail: Frame? = nil
local damageTrailTween: Tween? = nil
local vignette: GuiObject? = nil
local healthAlphaDriver: NumberValue? = nil -- rojo, vida baja
local healAlphaDriver: NumberValue? = nil -- verde, curación
local healVignetteTween: Tween? = nil
local healthConn: RBXScriptConnection? = nil
local lastSeenHealth: number? = nil
local healVignetteGeneration = 0

local function getHealthBarNodes(): (Frame?, TextLabel?)
	if fillBar and valueLabel then
		return fillBar, valueLabel
	end

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil, nil end

	local gui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not gui then return nil, nil end

	local healthBar = gui:FindFirstChild("HealthBar")
	if not healthBar then return nil, nil end

	local fill = healthBar:FindFirstChild("Fill")
	local value = healthBar:FindFirstChildWhichIsA("TextLabel", true)

	fillBar = if fill and fill:IsA("Frame") then fill else nil
	valueLabel = if value and value:IsA("TextLabel") then value else nil

	return fillBar, valueLabel
end

-- Encuentra (o crea) la barra de damage trail, hermana del Fill y detrás de él.
-- Copia geometría y corner del Fill para que calce exacto.
local function getDamageTrail(fill: Frame): Frame?
	if damageTrail and damageTrail.Parent then
		return damageTrail
	end

	local parent = fill.Parent
	if not (parent and parent:IsA("GuiObject")) then
		return nil
	end

	-- Reusa el frame si ya existe (la GUI puede persistir entre respawns).
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
	-- Detrás del Fill, delante del fondo del HealthBar (el parent).
	trail.ZIndex = fill.ZIndex - 1

	local corner = fill:FindFirstChildOfClass("UICorner")
	if corner then
		corner:Clone().Parent = trail
	end

	trail.Parent = parent
	damageTrail = trail
	return trail
end

-- Encuentra (o crea) un NumberValue driver con el nombre dado, hijo del Vignette.
local function ensureDriver(parent: GuiObject, name: string): NumberValue
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

local function getVignetteNodes(): (GuiObject?, NumberValue?, NumberValue?)
	if vignette and healthAlphaDriver and healAlphaDriver then
		return vignette, healthAlphaDriver, healAlphaDriver
	end

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil, nil, nil end

	local gui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not gui then return nil, nil, nil end

	local vignetteNode = gui:FindFirstChild("Vignette", true)
	if not vignetteNode then
		vignetteNode = gui:FindFirstChild("KillContainer", true)
	end
	if not (vignetteNode and vignetteNode:IsA("GuiObject")) then
		return nil, nil, nil
	end

	vignette = vignetteNode
	healthAlphaDriver = ensureDriver(vignette, "HealthAlphaDriver")
	healAlphaDriver = ensureDriver(vignette, "HealAlphaDriver")

	return vignette, healthAlphaDriver, healAlphaDriver
end

-- Dispara el flash verde subiendo el HealAlphaDriver hasta el pico y luego
-- bajándolo a 0. Si llega un nuevo heal mientras un flash está en flight, la
-- generación se bumpea, el tween actual se cancela, y la nueva animación
-- arranca desde Value = 0 (snap) para que el fade-in se note siempre.
local function showHealVignette()
	local _, _, driver = getVignetteNodes()
	if not driver then return end

	healVignetteGeneration += 1
	local myGen = healVignetteGeneration

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
	end)
end

local function updateHealthBar(humanoid: Humanoid)
	local bar, value = getHealthBarNodes()

	local maxHealth = math.max(humanoid.MaxHealth, 1)
	local ratio = math.clamp(humanoid.Health / maxHealth, 0, 1)
	if bar then
		bar.Size = UDim2.new(ratio, 0, 1, 0)

		-- Damage trail: si la barra baja (daño), el trail se queda en el valor
		-- previo y se drena despacio hasta el actual. Si sube (heal), salta al
		-- instante. Leemos el ancho actual del trail (interpolado mid-tween) para
		-- continuar suave si llegan varios golpes seguidos.
		local trail = getDamageTrail(bar)
		if trail then
			if damageTrailTween then
				damageTrailTween:Cancel()
				damageTrailTween = nil
			end
			if ratio >= trail.Size.X.Scale then
				trail.Size = UDim2.new(ratio, 0, 1, 0)
			else
				damageTrailTween = TweenService:Create(trail, DAMAGE_TRAIL_INFO, {
					Size = UDim2.new(ratio, 0, 1, 0),
				})
				damageTrailTween:Play()
			end
		end
	end

	if value then
		value.Text = "+ " .. tostring(math.max(0, math.floor(humanoid.Health + 0.5)))
	end

	-- Vignette rojo de peligro: proporcional por debajo del umbral, 0 si la vida
	-- está sana.
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
	-- Disconnect previous listener
	if healthConn then
		healthConn:Disconnect()
		healthConn = nil
	end

	-- Reset baseline e invalida cualquier flash de curación en flight. Si el
	-- respawn ocurre mid-flash, cancelamos el tween y snapeamos los drivers a 0
	-- antes de limpiar el cache para que no quede pintado en la GUI persistente.
	lastSeenHealth = nil
	healVignetteGeneration += 1
	if healVignetteTween then
		healVignetteTween:Cancel()
		healVignetteTween = nil
	end
	HealEffect.reset()
	if damageTrailTween then
		damageTrailTween:Cancel()
		damageTrailTween = nil
	end
	if healthAlphaDriver and healthAlphaDriver.Parent then
		healthAlphaDriver.Value = 0
	end
	if healAlphaDriver and healAlphaDriver.Parent then
		healAlphaDriver.Value = 0
	end

	-- Clear cached nodes so they are re-fetched for the new character's GUI
	fillBar = nil
	valueLabel = nil
	damageTrail = nil
	vignette = nil
	healthAlphaDriver = nil
	healAlphaDriver = nil

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then return end

	-- Set initial value
	updateHealthBar(humanoid)
	lastSeenHealth = humanoid.Health

	-- Listen for changes
	healthConn = humanoid.HealthChanged:Connect(function(newHealth: number)
		-- Detecta heal "discreto" (pickup, ability, etc.) excluyendo regen
		-- default de 1 HP/s. lastSeenHealth puede ser nil tras spawn antes del
		-- primer fire — se compara solo cuando ya hay baseline.
		if lastSeenHealth ~= nil and newHealth - lastSeenHealth >= HEALTH_GAIN_THRESHOLD then
			showHealVignette()
			HealEffect.play(HEAL_EFFECT_DURATION)
		end
		lastSeenHealth = newHealth
		updateHealthBar(humanoid)
	end)
end

return HealthBarController
