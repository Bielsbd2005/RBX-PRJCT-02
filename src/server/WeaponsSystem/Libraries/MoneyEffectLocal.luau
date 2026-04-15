local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local MoneyEffectLocal = {}

local MONEY_ICON = "rbxassetid://134631266173013"
local PICKUP_SOUND_ID = "rbxassetid://5728423829"

function MoneyEffectLocal.Play(startPos, amount)
	local player = Players.LocalPlayer
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

	local coinsToSpawn = amount or 6

	for i = 1, coinsToSpawn do
		-- 1. TIEMPO ORGÁNICO: Cascada escalonada + leve variación aleatoria
		local delayTime = (i * 0.08) + (math.random() * 0.05)

		task.delay(delayTime, function()
			if not character.Parent or not rootPart then return end

			local item = Instance.new("Part")
			item.Size = Vector3.new(0.5, 0.5, 0.5)
			item.Color = Color3.fromRGB(247, 195, 0)
			item.Transparency = 1
			item.Anchored = true
			item.CanCollide = false
			item.CFrame = CFrame.new(startPos)
			item.Parent = folder

			local billboard = Instance.new("BillboardGui")
			billboard.Adornee = item
			billboard.Size = UDim2.new(0, 0, 0, 0)
			billboard.AlwaysOnTop = true
			billboard.Parent = item

			local image = Instance.new("ImageLabel")
			image.BackgroundTransparency = 1
			image.Image = MONEY_ICON
			image.Size = UDim2.new(1, 0, 1, 0)
			image.Parent = billboard

			local attach0 = Instance.new("Attachment")
			attach0.Position = Vector3.new(0, 0.25, 0)
			attach0.Parent = item

			local attach1 = Instance.new("Attachment")
			attach1.Position = Vector3.new(0, -0.25, 0)
			attach1.Parent = item

			local trail = Instance.new("Trail")
			trail.Attachment0 = attach0
			trail.Attachment1 = attach1
			trail.Lifetime = 0.25
			trail.FaceCamera = true
			trail.Color = ColorSequence.new(Color3.fromRGB(247, 161, 0))
			trail.WidthScale = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(1, 0)
			})
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.5),
				NumberSequenceKeypoint.new(1, 1)
			})
			trail.Parent = item

			local p0 = startPos
			local p2 = rootPart.Position
			local dist = (p2 - p0).Magnitude

			-- 2. DISPERSIÓN ORGÁNICA: Apertura mucho más amplia en X y Z, y alturas variadas
			local randomOffset = Vector3.new(
				(math.random() - 0.5) * 25, -- Mucho más ancho a los lados
				math.random(12, 28),        -- Arco más pronunciado hacia arriba
				(math.random() - 0.5) * 25  -- Mucho más ancho en profundidad
			)
			local p1 = p0 + randomOffset

			local t = 0
			-- 3. VELOCIDAD ORGÁNICA: Cada moneda viaja a una velocidad ligeramente distinta (85% a 115%)
			local individualSpeed = math.random(85, 115) / 100
			local duration = math.clamp(dist / 40, 0.7, 1.4) * individualSpeed

			-- Animación "Pop"
			TweenService:Create(billboard, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Size = UDim2.new(1.3, 0, 1.3, 0)}):Play()

			local connection
			connection = RunService.RenderStepped:Connect(function(dt)
				t += dt / duration

				if t >= 1 then
					connection:Disconnect()

					if rootPart then
						local sound = Instance.new("Sound")
						sound.SoundId = PICKUP_SOUND_ID
						sound.Volume = 0.25
						sound.PlaybackSpeed = math.random(95, 135) / 100 -- Tintineo variado
						sound.Parent = rootPart
						sound:Play()
						Debris:AddItem(sound, 1.5)
					end

					TweenService:Create(billboard, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(0, 0, 0, 0)}):Play()
					Debris:AddItem(item, 0.15)
					return
				end

				if rootPart then
					p2 = rootPart.Position
				end

				local smoothT = TweenService:GetValue(t, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)

				local currentPos = (1 - smoothT)^2 * p0 + 2 * (1 - smoothT) * smoothT * p1 + smoothT^2 * p2
				item.CFrame = CFrame.lookAt(currentPos, p2)
			end)
		end)
	end
end

return MoneyEffectLocal
