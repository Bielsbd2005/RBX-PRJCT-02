local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local HealEffect = require(script.Parent:WaitForChild("HealEffect"))

local HealthBarController = {}

-- El Vignette muestra efectos de salud, cada uno con su propio NumberValue
-- driver (hijo del Vignette) que lee Scope.luau vía .Changed:
--
--  * HealthAlphaDriver (rojo): vignette continuo de PELIGRO. Se intensifica de
--    forma proporcional cuando la vida cae por debajo del umbral. Persiste
--    mientras la vida siga baja; vuelve a 0 al recuperarse.
--  * DamageAlphaDriver (rojo): flash puntual al RECIBIR DAÑO (hit indicator).
--    Sube rápido al pico y vuelve a 0. Driver propio para no pisar el de peligro;
--    el renderer compone ambos rojos por max.
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
-- Al curarse, el Fill sube animado (no instantáneo) mientras se muestra el efecto
-- de curación. Duración atada a HEAL_EFFECT_DURATION para que ambos coincidan.
local HEAL_FILL_INFO = TweenInfo.new(HEAL_EFFECT_DURATION * 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Flash ROJO de viñeta al recibir daño (hit indicator). Sube rápido al pico y
-- vuelve a 0. Usa un driver propio (DamageAlphaDriver) para no pisar el rojo de
-- peligro de vida baja (HealthAlphaDriver); el renderer compone ambos por max.
local DAMAGE_FLASH_THRESHOLD = 1 -- HP mínimos perdidos para disparar el flash
local VIGNETTE_DAMAGE_PEAK_TRANSPARENCY = 0.5 -- 0 = opaco, 1 = invisible (en el pico)
local VIGNETTE_DAMAGE_PEAK_ALPHA = 1 - VIGNETTE_DAMAGE_PEAK_TRANSPARENCY
local DAMAGE_FLASH_IN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DAMAGE_FLASH_OUT_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- Flash AMARILLO de viñeta al conseguir una baja propia. Se dispara junto al kick de
-- FOV (ver NetworkingCallbacks.PlayerEliminated). Driver propio (KillAlphaDriver),
-- que el renderer compone con menor prioridad que rojo/verde. Solo se dispara si
-- la viñeta NO está ya ocupada por daño o curación.
local VIGNETTE_KILL_PEAK_TRANSPARENCY = 0.2 -- 0 = opaco, 1 = invisible (en el pico)
local VIGNETTE_KILL_PEAK_ALPHA = 1 - VIGNETTE_KILL_PEAK_TRANSPARENCY
-- Entra igual de rápido que el flash de daño, pero aguanta un beat en el pico y
-- se apaga más despacio: la baja se tiene que notar sin llegar a estorbar.
local KILL_FLASH_IN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local KILL_FLASH_HOLD_SECONDS = 0.15
local KILL_FLASH_OUT_INFO = TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

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
local fillTween: Tween? = nil -- subida animada del Fill al curarse
local vignette: GuiObject? = nil
local healthAlphaDriver: NumberValue? = nil -- rojo, vida baja
local healAlphaDriver: NumberValue? = nil -- verde, curación
local damageAlphaDriver: NumberValue? = nil -- rojo, flash al recibir daño
local killAlphaDriver: NumberValue? = nil -- amarillo, flash de baja propia
local healVignetteTween: Tween? = nil
local damageVignetteTween: Tween? = nil
local killVignetteTween: Tween? = nil
local healthConn: RBXScriptConnection? = nil
local lastSeenHealth: number? = nil
local healVignetteGeneration = 0
local damageVignetteGeneration = 0
local killVignetteGeneration = 0
-- true mientras el flash verde de curación está en pantalla: durante ese tiempo
-- los disparos NO ponen la viñeta roja (el verde manda).
local healVignetteActive = false

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
	if vignette and healthAlphaDriver and healAlphaDriver and damageAlphaDriver then
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
	damageAlphaDriver = ensureDriver(vignette, "DamageAlphaDriver")
	killAlphaDriver = ensureDriver(vignette, "KillAlphaDriver")

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
	healVignetteActive = true

	-- Mientras dura el heal, la viñeta es verde y los disparos no la ponen roja:
	-- cancelamos cualquier flash de daño en curso y lo apagamos.
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

-- Flash rojo de daño: sube rápido al pico y baja a 0 (sin hold). Driver propio,
-- así no interfiere con el rojo de peligro de vida baja. Misma lógica de
-- generación que el heal para reiniciar limpio si llegan varios golpes seguidos.
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

-- Flash amarillo de baja propia. Sube rápido al pico, aguanta un beat y baja a 0.
-- GATE: no se dispara si la viñeta ya está ocupada por curación
-- (verde) o por daño/peligro de vida baja (rojo) — en esos casos el otro efecto
-- manda y no queremos pisarlo con amarillo.
local function showKillVignette()
	getVignetteNodes()
	local driver = killAlphaDriver
	if not driver then return end

	-- "Si no está visible por daño o curación": verde activo, flash de daño en
	-- curso, o vignette rojo de peligro por vida baja → abortamos.
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

	-- Una nueva actualización (daño, respawn, otro heal) cancela la subida en curso.
	if fillTween then
		fillTween:Cancel()
		fillTween = nil
	end

	if bar then
		local targetSize = UDim2.new(ratio, 0, 1, 0)
		local trail = getDamageTrail(bar)

		if animateUp then
			-- Curación: el Fill sube animado mientras dura el efecto de curación. El
			-- trail sube en sync para no mostrar rojo por encima del Fill ascendente.
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

			-- Damage trail: si la barra baja (daño), el trail se queda en el valor
			-- previo y se drena despacio hasta el actual. Si sube sin animar (p. ej.
			-- regen bajo el umbral), salta al instante. Leemos el ancho actual del
			-- trail (interpolado mid-tween) para continuar suave si llegan varios
			-- golpes seguidos.
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

	-- Clear cached nodes so they are re-fetched for the new character's GUI
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

	-- Set initial value
	updateHealthBar(humanoid)
	lastSeenHealth = humanoid.Health

	-- Listen for changes
	healthConn = humanoid.HealthChanged:Connect(function(newHealth: number)
		-- Detecta heal "discreto" (pickup, ability, etc.) excluyendo regen
		-- default de 1 HP/s. lastSeenHealth puede ser nil tras spawn antes del
		-- primer fire — se compara solo cuando ya hay baseline.
		local isHeal = lastSeenHealth ~= nil and newHealth - lastSeenHealth >= HEALTH_GAIN_THRESHOLD
		local isDamage = lastSeenHealth ~= nil and lastSeenHealth - newHealth >= DAMAGE_FLASH_THRESHOLD
		if isHeal then
			showHealVignette()
			HealEffect.play(HEAL_EFFECT_DURATION)
		elseif isDamage and not healVignetteActive then
			-- Al recibir daño, flash rojo de viñeta (hit indicator). Suprimido
			-- mientras la viñeta verde de curación está activa: el verde manda.
			showDamageVignette()
		end
		lastSeenHealth = newHealth
		-- En un heal discreto la barra sube animada (mientras dura el efecto); el
		-- resto (daño, regen, respawn) se aplica al instante.
		updateHealthBar(humanoid, isHeal)
	end)
end

-- Flash amarillo de baja propia. Se llama desde NetworkingCallbacks.PlayerEliminated
-- junto al kick de FOV. Internamente se auto-suprime si hay daño/curación visible.
function HealthBarController.onKill()
	showKillVignette()
end

return HealthBarController
