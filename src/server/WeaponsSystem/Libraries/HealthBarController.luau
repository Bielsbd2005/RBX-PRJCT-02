local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local HealthBarController = {}

local fillBar: Frame? = nil
local valueLabel: TextLabel? = nil
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

local function updateHealthBar(humanoid: Humanoid)
	local bar, value = getHealthBarNodes()
	if not bar then return end

	local ratio = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
	bar.Size = UDim2.new(ratio, 0, 1, 0)

	if value then
		value.Text = "+ " .. tostring(math.max(0, math.floor(humanoid.Health + 0.5)))
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
