local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared:WaitForChild("networking"):WaitForChild("Network"))

local BonusEffect = {}

local PICKUP_SOUND_ID = "rbxassetid://5728423829"
local MAGNET_RADIUS = 15
local GUI_COIN_CLONE_ATTR = "IsBonusGuiCoinClone"

local isRoundEndedCleanupBound = false

-- Referencia a la plantilla física en ReplicatedStorage
local coinTemplate = ReplicatedStorage:WaitForChild("CoinTemplate")

local function getItemCountForStreak(streak: number): number
	-- Solo en rachas específicas: 3, 5, 10, 15, 20, 25, 30...
	if streak == 3 then
		return 15
	elseif streak == 5 then
		return 25
	elseif streak >= 10 and streak % 5 == 0 then
		return 40
	end
	return 0 -- No spawnear items en otras rachas
end

-- =================================================================
-- FUNCIÓN: Maneja la animación de la GUI
-- =================================================================
local function spawnGuiCoin(player)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local weaponsSystemGui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not weaponsSystemGui then return end

	local bonusCoinsContainer = weaponsSystemGui:FindFirstChild("BonusCoins")
	if not bonusCoinsContainer then return end

	local template = bonusCoinsContainer:FindFirstChild("CoinTemplate")
	if not template then return end

	local clone = template:Clone()
	clone:SetAttribute(GUI_COIN_CLONE_ATTR, true)
	clone.Visible = true
	clone.Parent = bonusCoinsContainer

	local randomX = math.random(5, 95) / 100
	local startY = 1.1      -- Punto de inicio (abajo)
	local targetTopY = -0.2 -- Destino final del movimiento (arriba)
	local disappearY = 0.4  -- Punto de desaparición

	clone.Position = UDim2.new(randomX, 0, startY, 0)
	if clone:IsA("ImageLabel") then clone.ImageTransparency = 0 end

	local animDuration = 1.2
	local ratio = (startY - disappearY) / (startY - targetTopY)
	local timeToDisappear = animDuration * ratio
	local fadeStartTime = timeToDisappear * 0.5

	-- Tween de movimiento
	TweenService:Create(clone, TweenInfo.new(animDuration, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {
		Position = UDim2.new(randomX, 0, targetTopY, 0)
	}):Play()

	-- Tween de transparencia sincronizado
	task.delay(fadeStartTime, function()
		if clone.Parent then
			TweenService:Create(clone, TweenInfo.new(timeToDisappear - fadeStartTime, Enum.EasingStyle.Linear), {
				ImageTransparency = 1
			}):Play()
		end
	end)

	Debris:AddItem(clone, animDuration)
end
-- =================================================================

function BonusEffect.Cleanup()
	local folder = workspace:FindFirstChild("ClientVisualEffects")
	if folder then
		for _, child in folder:GetChildren() do
			child:Destroy()
		end
	end

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local weaponsSystemGui = playerGui:FindFirstChild("WeaponsSystemGui")
	if not weaponsSystemGui then
		return
	end

	local bonusCoinsContainer = weaponsSystemGui:FindFirstChild("BonusCoins")
	if not bonusCoinsContainer then
		return
	end

	for _, child in bonusCoinsContainer:GetChildren() do
		if child.Name ~= "CoinTemplate" or child:GetAttribute(GUI_COIN_CLONE_ATTR) then
			child:Destroy()
		end
	end
end

local function bindRoundEndedCleanupOnce()
	if isRoundEndedCleanupBound then
		return
	end
	isRoundEndedCleanupBound = true

	Network.Match.RoundEnded.Listen(function(_: any)
		BonusEffect.Cleanup()
	end)
end

function BonusEffect.Play(victimPos, streak)
	if not victimPos or not streak then return end

	bindRoundEndedCleanupOnce()

	-- Determinar cantidad de items según la racha
	local itemCount = getItemCountForStreak(streak)
	if itemCount == 0 then return end -- No spawnear en rachas que no sean especiales

	local player = Players.LocalPlayer
	if not player then return end

	local character = player.Character
	if not character then return end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local folder = workspace:FindFirstChild("ClientVisualEffects")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ClientVisualEffects"
		folder.Parent = workspace
	end

	-- Generar los items
	for i = 1, itemCount do
		task.delay(i * 0.03, function()
			if not character.Parent or not rootPart then return end

			-- Clonamos la plantilla desde ReplicatedStorage
			local item = coinTemplate:Clone()

			item.Anchored = false
			item.CanCollide = true
			item.CFrame = CFrame.new(victimPos)
			item.Parent = folder
			Debris:AddItem(item, 12)

			-- Fuerza de explosión
			local randomVelocity = Vector3.new(
				(math.random() - 0.5) * 35,
				math.random(25, 45),
				(math.random() - 0.5) * 35
			)
			item.AssemblyLinearVelocity = randomVelocity

			-- Animación inicial del BillboardGui (si existe en la plantilla)
			local billboard = item:FindFirstChildOfClass("BillboardGui")
			if billboard then
				billboard.Size = UDim2.new(0, 0, 0, 0)
				TweenService:Create(billboard, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Size = UDim2.new(1.3, 0, 1.3, 0)}):Play()
			end

			-- Variables de estado para la animación
			local connection
			local state = "Falling"
			local timer = 0
			local t = 0
			local p0, p1, p2, duration

			connection = RunService.RenderStepped:Connect(function(dt)
				if not rootPart or not item.Parent then
					connection:Disconnect()
					return
				end

				if state == "Falling" then
					timer += dt
					if timer >= 1.5 then
						state = "Waiting"
						item.Anchored = true
						item.CanCollide = false
					end

				elseif state == "Waiting" then
					local distToPlayer = (item.Position - rootPart.Position).Magnitude

					if distToPlayer <= MAGNET_RADIUS then
						state = "Magnet"

						p0 = item.Position
						local randomOffset = Vector3.new(
							(math.random() - 0.5) * 10,
							math.random(5, 15),
							(math.random() - 0.5) * 10
						)
						p1 = p0 + randomOffset

						local individualSpeed = math.random(85, 115) / 100
						duration = math.clamp(distToPlayer / 40, 0.3, 0.8) * individualSpeed
					end

				elseif state == "Magnet" then
					t += dt / duration
					p2 = rootPart.Position

					if t >= 1 then
						connection:Disconnect()

						local sound = Instance.new("Sound")
						sound.SoundId = PICKUP_SOUND_ID
						sound.Volume = 0.25
						sound.PlaybackSpeed = math.random(95, 135) / 100
						sound.Parent = rootPart
						sound:Play()
						Debris:AddItem(sound, 1.5)

						spawnGuiCoin(player)

						if billboard then
							TweenService:Create(billboard, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(0, 0, 0, 0)}):Play()
						end

						Debris:AddItem(item, 0.15)
						return
					end

					local smoothT = TweenService:GetValue(t, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
					local currentPos = (1 - smoothT)^2 * p0 + 2 * (1 - smoothT) * smoothT * p1 + smoothT^2 * p2
					item.CFrame = CFrame.lookAt(currentPos, p2)
				end
			end)
		end)
	end
end

return BonusEffect
