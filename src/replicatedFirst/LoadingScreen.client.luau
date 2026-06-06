local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local SKIP_IN_STUDIO = false

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor

if SKIP_IN_STUDIO and RunService:IsStudio() then
	local loadingScreen = playerGui:FindFirstChild("LoadingScreen")
	if loadingScreen then
		loadingScreen:Destroy()
	end
	return
end

local MIN_LOAD_TIME = 6
local DOTS_SPEED = 3
local PROGRESS_TWEEN_THRESHOLD = 0.01

local loadingScreen = playerGui:WaitForChild("LoadingScreen", 15)
if not loadingScreen then
	warn("[LoadingScreen] LoadingScreen GUI not found after 15s — skipping")
	return
end
local background = loadingScreen:WaitForChild("Background")
local titleContainer = background:WaitForChild("TitleContainer")
local textOutline = titleContainer:WaitForChild("TextOutline")
local outlineStroke = textOutline:WaitForChild("UIStroke")
local maskFrame = titleContainer:WaitForChild("Mask")
local textFilled = maskFrame:WaitForChild("TextFilled")
local filledStroke = textFilled:WaitForChild("UIStroke")
local subtitle = background:WaitForChild("Subtitle")

-- Conexión en RenderStepped para forzar que textFilled tenga siempre la posición (0,0) y el ancho absoluto exacto de titleContainer
local sizeConnection
sizeConnection = RunService.RenderStepped:Connect(function()
	if not titleContainer:IsDescendantOf(game) or not textFilled:IsDescendantOf(game) then
		if sizeConnection then
			sizeConnection:Disconnect()
		end
		return
	end
	textFilled.Position = UDim2.new(0, 0, 0, 0)
	textFilled.Size = UDim2.new(0, titleContainer.AbsoluteSize.X, 1, 0)
end)

-- Esperar a que el motor de Roblox calcule el tamaño absoluto real en la pantalla
while titleContainer.AbsoluteSize.X == 0 do
	RunService.Heartbeat:Wait()
end

local TITLE_WIDTH = titleContainer.AbsoluteSize.X

local maskYScale = maskFrame.Size.Y.Scale
local maskYOffset = maskFrame.Size.Y.Offset

maskFrame.Position = UDim2.new(0, 0, 0, 0)
maskFrame.Size = UDim2.new(0, 0, maskYScale, maskYOffset)
subtitle.Text = "."

local startTime = os.clock()
local assets = {}

local lobby = workspace:WaitForChild("Lobby", 10)
if lobby then
	for _, descendant in lobby:GetDescendants() do
		if descendant:IsA("MeshPart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			table.insert(assets, descendant)
		end
	end
end

local menuGui = playerGui:WaitForChild("Menu", 5)
if menuGui then
	for _, descendant in menuGui:GetDescendants() do
		if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			table.insert(assets, descendant)
		end
	end
end

local totalAssets = math.max(#assets, 1)
local loadedAssets = 0

task.spawn(function()
	for _, asset in ipairs(assets) do
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync({ asset })
		end)

		if not ok then
			warn("[LoadingScreen] Failed to preload:", asset:GetFullName(), err)
		end

		loadedAssets += 1
	end
end)

local progressTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad)
local lastTweenedProgress = 0

while loadedAssets < totalAssets or (os.clock() - startTime) < MIN_LOAD_TIME do
	local elapsed = os.clock() - startTime
	local realProgress = loadedAssets / totalAssets
	local timeProgress = math.min(elapsed / MIN_LOAD_TIME, 1)
	local progress = math.min(realProgress, timeProgress)

	if progress - lastTweenedProgress >= PROGRESS_TWEEN_THRESHOLD then
		lastTweenedProgress = progress
		TweenService:Create(
			maskFrame,
			progressTweenInfo,
			{
				Size = UDim2.new(0, TITLE_WIDTH * progress, maskYScale, maskYOffset)
			}
		):Play()
	end

	local dotsCount = (math.floor(elapsed * DOTS_SPEED) % 3) + 1
	subtitle.Text = string.rep(".", dotsCount)

	RunService.Heartbeat:Wait()
end

TweenService:Create(
	maskFrame,
	TweenInfo.new(0.3, Enum.EasingStyle.Quad),
	{
		Size = UDim2.new(0, TITLE_WIDTH, maskYScale, maskYOffset)
	}
):Play()

subtitle.Text = "..."

task.wait(0.4)

local IRIS_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local SIZE_BIG = UDim2.new(4, 0, 4, 0)
local SIZE_SMALL = UDim2.new(0, 0, 0, 0)

local circle = Instance.new("Frame")
circle.Name = "IrisCircle"
circle.AnchorPoint = Vector2.new(0.5, 0.5)
circle.Position = UDim2.fromScale(0.5, 0.5)
circle.Size = SIZE_BIG
circle.BorderSizePixel = 0
circle.BackgroundColor3 = Color3.new(0, 0, 0)
circle.BackgroundTransparency = 0
circle.SizeConstraint = Enum.SizeConstraint.RelativeYY
circle.ZIndex = 9999
circle.Parent = loadingScreen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0.5, 0)
corner.Parent = circle

background.Visible = false

local tween = TweenService:Create(circle, IRIS_INFO, { Size = SIZE_SMALL })
tween:Play()
tween.Completed:Wait()

if sizeConnection then
	sizeConnection:Disconnect()
end
loadingScreen:Destroy()
