--[[
	Anima ReplicatedFirst.LoadingScreenGui de Studio (Background + Logo +
	LoadingDots/Dot1..N) sin crear elementos visibles.
	La GUI vive en ReplicatedFirst y no en StarterGui: con CharacterAutoLoads=false
	StarterGui no se copia a PlayerGui hasta el primer spawn.
	Se cierra con assets precargados + MIN_LOAD_TIME + ClientBootStage MenuReady,
	o al llegar a HARD_TIMEOUT.
]]

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Segundos. Mínimo en pantalla para que no parpadee en joins calientes.
local MIN_LOAD_TIME = 4
local HARD_TIMEOUT = 20
local TEMPLATE_WAIT_SECONDS = 15

-- Misma convención que Shared/utils/DebugFlags.luau (BoolValue en ReplicatedStorage.Debug,
-- solo en Studio), leída a mano porque este script corre antes de que replique Shared.
local DEBUG_FOLDER_NAME = "Debug"
local SKIP_LOADING_SCREEN_FLAG = "SkipLoadingScreen"
local DEBUG_FOLDER_WAIT_SECONDS = 2

-- Duplicados de Shared/constants/ClientBootStage.luau (no se puede requerir aún):
-- mantener sincronizados. ClientBootstrap lo pone con cámara y menú listos.
local BOOT_STAGE_ATTRIBUTE = "ClientBootStage"
local BOOT_STAGE_READY = "MenuReady"

local DOTS_CONTAINER_NAME = "LoadingDots"
local DOT_NAME_PREFIX = "Dot"
local DOT_BOUNCE_HEIGHT = 10 -- px
local DOT_CYCLE_SECONDS = 1.2
-- Retraso entre puntos, en fracción de ciclo.
local DOT_PHASE_STEP = 0.18

-- Relleno con un UIGradient blanco→oscuro desplazando Offset.X. El gradiente tiñe
-- también el fondo del objeto: el Logo debe tener BackgroundTransparency = 1.
local FILL_TARGET_NAMES = { "Logo" }
local FILL_DARK_COLOR = Color3.fromRGB(40, 40, 40)
-- Media anchura del borde, en fracción del objeto. No puede ser 0: los keypoints
-- del ColorSequence deben ir en orden estrictamente creciente.
local FILL_EDGE_SOFTNESS = 0.001
-- Tope mientras falte algo, para que nunca parezca completo con la pantalla puesta.
local FILL_CAP_UNTIL_READY = 0.9
-- Mayor = más seco.
local FILL_SMOOTHING = 6
local FILL_DONE_THRESHOLD = 0.995
local FILL_FINISH_TIMEOUT = 1

-- En producción el flag ni se mira: uno olvidado en true dejaría el mundo sin tapar.
if RunService:IsStudio() then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local debugFolder = ReplicatedStorage:WaitForChild(DEBUG_FOLDER_NAME, DEBUG_FOLDER_WAIT_SECONDS)
	local skipFlag = debugFolder and debugFolder:FindFirstChild(SKIP_LOADING_SCREEN_FLAG)
	if skipFlag and skipFlag:IsA("BoolValue") and skipFlag.Value then
		return
	end
end

local template = ReplicatedFirst:WaitForChild("LoadingScreenGui", TEMPLATE_WAIT_SECONDS)
if not template or not template:IsA("ScreenGui") then
	warn("[LoadingScreen] ReplicatedFirst.LoadingScreenGui no encontrado; sin pantalla de carga")
	return
end

local loadingScreen = template:Clone()
-- La feature de gifting espera a que se destruya "LoadingScreen" para mostrar avisos.
loadingScreen.Name = "LoadingScreen"
loadingScreen.ResetOnSpawn = false
loadingScreen.IgnoreGuiInset = true
loadingScreen.DisplayOrder = math.max(loadingScreen.DisplayOrder, 1000)

loadingScreen.Parent = playerGui

type DotState = { frame: Frame, restPosition: UDim2, restTransparency: number }
local dots: { DotState } = {}
local dotsContainer = loadingScreen:FindFirstChild(DOTS_CONTAINER_NAME)
if dotsContainer then
	local frames: { Frame } = {}
	for _, child in dotsContainer:GetChildren() do
		if child:IsA("Frame") and string.sub(child.Name, 1, #DOT_NAME_PREFIX) == DOT_NAME_PREFIX then
			table.insert(frames, child)
		end
	end
	table.sort(frames, function(a, b)
		return a.Name < b.Name
	end)
	for _, frame in frames do
		table.insert(dots, {
			frame = frame,
			restPosition = frame.Position,
			restTransparency = frame.BackgroundTransparency,
		})
	end
end
if #dots == 0 then
	warn("[LoadingScreen] LoadingScreenGui sin", DOTS_CONTAINER_NAME .. "/" .. DOT_NAME_PREFIX .. "N; sin animación")
end

-- Roblox solo aplica un UIGradient por objeto: si ya tiene uno, no se rellena.
local function fillOffset(fill: number): Vector2
	return Vector2.new(-(0.5 + FILL_EDGE_SOFTNESS) + fill * (1 + 2 * FILL_EDGE_SOFTNESS), 0)
end

local fillGradients: { UIGradient } = {}
for _, targetName in FILL_TARGET_NAMES do
	local target = loadingScreen:FindFirstChild(targetName) or loadingScreen:FindFirstChild(targetName, true)
	if not target or not target:IsA("GuiObject") then
		warn("[LoadingScreen] LoadingScreenGui sin", targetName, "; no se rellena")
	elseif target:FindFirstChildOfClass("UIGradient") then
		warn("[LoadingScreen]", targetName, "ya tiene un UIGradient; no se rellena")
	else
		local gradient = Instance.new("UIGradient")
		gradient.Name = "LoadingFillGradient"
		gradient.Rotation = 0
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.5 - FILL_EDGE_SOFTNESS, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.5 + FILL_EDGE_SOFTNESS, FILL_DARK_COLOR),
			ColorSequenceKeypoint.new(1, FILL_DARK_COLOR),
		})
		gradient.Offset = fillOffset(0)
		gradient.Parent = target
		table.insert(fillGradients, gradient)
	end
end

local startTime = os.clock()
local loadingFinished = false
local fill = 0

local animationConnection = RunService.RenderStepped:Connect(function(dt: number)
	local elapsed = os.clock() - startTime

	if #fillGradients > 0 then
		local target = if loadingFinished
			then 1
			else math.min(elapsed / MIN_LOAD_TIME, FILL_CAP_UNTIL_READY)
		fill += (target - fill) * (1 - math.exp(-FILL_SMOOTHING * dt))
		local offset = fillOffset(fill)
		for _, gradient in fillGradients do
			gradient.Offset = offset
		end
	end

	for index, dot in dots do
		local phase = (elapsed / DOT_CYCLE_SECONDS - (index - 1) * DOT_PHASE_STEP) % 1
		local lift = if phase < 0.5 then math.sin(phase * 2 * math.pi) else 0
		local rest = dot.restPosition
		dot.frame.Position = UDim2.new(
			rest.X.Scale, rest.X.Offset,
			rest.Y.Scale, rest.Y.Offset - lift * DOT_BOUNCE_HEIGHT
		)
		dot.frame.BackgroundTransparency = dot.restTransparency * (1 - lift)
	end
end)

-- Arranca antes de las esperas de replicación para acotar todo el tiempo de pantalla.
local hardTimeoutReached = false
local hardTimeoutThread = task.delay(HARD_TIMEOUT, function()
	hardTimeoutReached = true
end)

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

local assetsReady = false

task.spawn(function()
	for _, asset in assets do
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync({ asset })
		end)
		if not ok then
			warn("[LoadingScreen] Failed to preload:", asset:GetFullName(), err)
		end
	end
	assetsReady = true
end)

local function isClientReady(): boolean
	return player:GetAttribute(BOOT_STAGE_ATTRIBUTE) == BOOT_STAGE_READY
end

while
	not hardTimeoutReached
	and (not assetsReady or (os.clock() - startTime) < MIN_LOAD_TIME or not isClientReady())
do
	RunService.Heartbeat:Wait()
end

if not hardTimeoutReached then
	task.cancel(hardTimeoutThread)
end

loadingFinished = true
if #fillGradients > 0 then
	local finishDeadline = os.clock() + FILL_FINISH_TIMEOUT
	while fill < FILL_DONE_THRESHOLD and os.clock() < finishDeadline do
		RunService.Heartbeat:Wait()
	end
end

local IRIS_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local SIZE_BIG = UDim2.new(4, 0, 4, 0)
local SIZE_SMALL = UDim2.new(0, 0, 0, 0)

animationConnection:Disconnect()

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

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0.5, 0)
corner.Parent = circle

for _, child in loadingScreen:GetChildren() do
	if child:IsA("GuiObject") then
		child.Visible = false
	end
end
circle.Parent = loadingScreen

local tween = TweenService:Create(circle, IRIS_INFO, { Size = SIZE_SMALL })
tween:Play()
tween.Completed:Wait()

loadingScreen:Destroy()
