local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local HealthBarController = {}
local VIGNETTE_HEALTH_THRESHOLD = 0.4
local VIGNETTE_HEALTH_MAX_ALPHA = 0.45

-- Health pickup indicator: el frame "Health" del WeaponsSystemGui se muestra
-- brevemente cuando el jugador gana salud no trivial. El umbral filtra el
-- regen default del Humanoid (~1 HP/s) y solo dispara con pickups (+30) u
-- otros heals discretos. Si caen varios pickups seguidos, la generación
-- corta la animación vieja y reinicia desde fade-in en la nueva.
--
-- Ciclo total = FADE_IN + HOLD + FADE_OUT = 0.5s.
local HEALTH_INDICATOR_FADE_IN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HEALTH_INDICATOR_FADE_OUT_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HEALTH_INDICATOR_HOLD_SECONDS = 0.2
local HEALTH_GAIN_THRESHOLD = 5

local fillBar: Frame? = nil
local valueLabel: TextLabel? = nil
local vignette: GuiObject? = nil
local healthAlphaDriver: NumberValue? = nil
local healthIndicator: GuiObject? = nil
local healthIndicatorTween: Tween? = nil
local healthConn: RBXScriptConnection? = nil
local lastSeenHealth: number? = nil
local healthIndicatorGeneration = 0

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

-- El frame "Health" se muestra/oculta vía BackgroundTransparency (0 visible,
-- 1 oculto), no Visible.
local function snapHealthIndicatorHidden(indicator: GuiObject)
	indicator.BackgroundTransparency = 1
end

local function getHealthIndicator(): GuiObject?
	if healthIndicator then
		return healthIndicator
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil end
	local gui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not gui then return nil end
	local node = gui:FindFirstChild("Health", true)
	if node and node:IsA("GuiObject") then
		healthIndicator = node
		-- Estado inicial: oculto. El UI author puede dejarlo opaco en Studio
		-- para posicionarlo, pero al runtime arranca transparente.
		snapHealthIndicatorHidden(healthIndicator)
	end
	return healthIndicator
end

-- Muestra el indicator con tween fade-in → hold → tween fade-out. Si llega
-- un nuevo trigger mientras una animación está en flight, la generación se
-- bumpea, el tween actual se cancela, y la nueva animación arranca desde
-- BackgroundTransparency = 1 (snap a invisible) para que el fade-in se note
-- siempre, sin importar en qué punto del ciclo anterior estábamos.
local function showHealthIndicator()
	local indicator = getHealthIndicator()
	if not indicator then return end

	healthIndicatorGeneration += 1
	local myGen = healthIndicatorGeneration

	if healthIndicatorTween then
		healthIndicatorTween:Cancel()
		healthIndicatorTween = nil
	end

	indicator.BackgroundTransparency = 1
	local fadeIn = TweenService:Create(indicator, HEALTH_INDICATOR_FADE_IN_INFO, {
		BackgroundTransparency = 0,
	})
	healthIndicatorTween = fadeIn
	fadeIn:Play()

	task.spawn(function()
		fadeIn.Completed:Wait()
		if healthIndicatorGeneration ~= myGen then return end

		task.wait(HEALTH_INDICATOR_HOLD_SECONDS)
		if healthIndicatorGeneration ~= myGen then return end
		if not indicator.Parent then return end

		local fadeOut = TweenService:Create(indicator, HEALTH_INDICATOR_FADE_OUT_INFO, {
			BackgroundTransparency = 1,
		})
		healthIndicatorTween = fadeOut
		fadeOut:Play()
		fadeOut.Completed:Wait()
		if healthIndicatorGeneration ~= myGen then return end
		healthIndicatorTween = nil
	end)
end

local function getVignetteNodes(): (GuiObject?, NumberValue?)
	if vignette and healthAlphaDriver then
		return vignette, healthAlphaDriver
	end

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil, nil end

	local gui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not gui then return nil, nil end

	local vignetteNode = gui:FindFirstChild("Vignette", true)
	if not vignetteNode then
		vignetteNode = gui:FindFirstChild("KillContainer", true)
	end
	if not (vignetteNode and vignetteNode:IsA("GuiObject")) then
		return nil, nil
	end

	vignette = vignetteNode
	local driverNode = vignette:FindFirstChild("HealthAlphaDriver")
	if driverNode and driverNode:IsA("NumberValue") then
		healthAlphaDriver = driverNode
	else
		healthAlphaDriver = Instance.new("NumberValue")
		healthAlphaDriver.Name = "HealthAlphaDriver"
		healthAlphaDriver.Value = 0
		healthAlphaDriver.Parent = vignette
	end

	return vignette, healthAlphaDriver
end

local function updateHealthBar(humanoid: Humanoid)
	local bar, value = getHealthBarNodes()

	local maxHealth = math.max(humanoid.MaxHealth, 1)
	local ratio = math.clamp(humanoid.Health / maxHealth, 0, 1)
	if bar then
		bar.Size = UDim2.new(ratio, 0, 1, 0)
	end

	if value then
		value.Text = "+ " .. tostring(math.max(0, math.floor(humanoid.Health + 0.5)))
	end

	local _, driver = getVignetteNodes()
	if driver then
		if ratio >= VIGNETTE_HEALTH_THRESHOLD then
			driver.Value = 0
		else
			local intensity = 1 - (ratio / VIGNETTE_HEALTH_THRESHOLD)
			driver.Value = math.clamp(intensity * VIGNETTE_HEALTH_MAX_ALPHA, 0, VIGNETTE_HEALTH_MAX_ALPHA)
		end
	end
end

function HealthBarController.onCharacterAdded(character: Model)
	-- Disconnect previous listener
	if healthConn then
		healthConn:Disconnect()
		healthConn = nil
	end

	-- Clear cached nodes so they are re-fetched for the new character's GUI
	fillBar = nil
	valueLabel = nil
	vignette = nil
	healthAlphaDriver = nil

	-- Reset baseline e invalida cualquier indicator animation en flight. Si
	-- el respawn ocurre mid-show, cancelamos el tween y snapeamos a oculto
	-- antes de limpiar el cache para que no quede pintado en la GUI
	-- persistente.
	lastSeenHealth = nil
	healthIndicatorGeneration += 1
	if healthIndicatorTween then
		healthIndicatorTween:Cancel()
		healthIndicatorTween = nil
	end
	if healthIndicator and healthIndicator.Parent then
		snapHealthIndicatorHidden(healthIndicator)
	end
	healthIndicator = nil

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then return end

	-- Set initial value
	updateHealthBar(humanoid)
	lastSeenHealth = humanoid.Health

	-- Listen for changes
	healthConn = humanoid.HealthChanged:Connect(function(newHealth: number)
		-- Detecta heal "discreto" (pickup, ability, etc.) excluyendo regen
		-- default de 1 HP/s. lastSeenHealth puede ser nil tras spawn antes
		-- del primer fire — se compara solo cuando ya hay baseline.
		if lastSeenHealth ~= nil and newHealth - lastSeenHealth >= HEALTH_GAIN_THRESHOLD then
			showHealthIndicator()
		end
		lastSeenHealth = newHealth
		updateHealthBar(humanoid)
	end)
end

return HealthBarController
