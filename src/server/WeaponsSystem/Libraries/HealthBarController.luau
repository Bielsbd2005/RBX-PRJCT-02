local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local HealthBarController = {}
local VIGNETTE_HEALTH_THRESHOLD = 0.4
local VIGNETTE_HEALTH_MAX_ALPHA = 0.45

local fillBar: Frame? = nil
local valueLabel: TextLabel? = nil
local vignette: GuiObject? = nil
local healthAlphaDriver: NumberValue? = nil
local healthConn: RBXScriptConnection? = nil

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

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then return end

	-- Set initial value
	updateHealthBar(humanoid)

	-- Listen for changes
	healthConn = humanoid.HealthChanged:Connect(function()
		updateHealthBar(humanoid)
	end)
end

return HealthBarController
