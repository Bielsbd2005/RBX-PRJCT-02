--!strict
--[[
	Confetti.luau
	Burst de partículas rectangulares (Frames) animadas que se dispersan desde
	una posición de pantalla y caen mientras se desvanecen.

	Uso:
		Confetti.Burst(parentScreenGui, originAbsolutePosition)
		Confetti.BurstFromGui(targetGuiObject)
]]

local TweenService = game:GetService("TweenService")

local Confetti = {}

local DEFAULT_COLORS = {
	Color3.fromRGB(255, 80, 80),
	Color3.fromRGB(255, 165, 60),
	Color3.fromRGB(255, 222, 60),
	Color3.fromRGB(80, 220, 120),
	Color3.fromRGB(80, 170, 255),
	Color3.fromRGB(200, 100, 255),
	Color3.fromRGB(255, 130, 220),
}

export type ConfettiOptions = {
	count: number?,
	colors: { Color3 }?,
	lifetime: number?,
	burstRadius: number?,
	fallExtra: number?,
	zIndex: number?,
}

local function resolveScreenContainer(parent: Instance): Instance
	if parent:IsA("ScreenGui") then
		return parent
	end

	local ancestor = parent:FindFirstAncestorWhichIsA("ScreenGui")
	if ancestor then
		return ancestor
	end

	return parent
end

function Confetti.Burst(parent: Instance, originAbsolutePosition: Vector2, options: ConfettiOptions?)
	local opts = options or {}
	local count = opts.count or 32
	local colors = opts.colors or DEFAULT_COLORS
	local lifetime = opts.lifetime or 1.2
	local burstRadius = opts.burstRadius or 220
	local fallExtra = opts.fallExtra or 200
	local zIndex = opts.zIndex or 100

	local container = resolveScreenContainer(parent)

	for i = 1, count do
		local piece = Instance.new("Frame")
		piece.BackgroundColor3 = colors[((i - 1) % #colors) + 1]
		piece.BorderSizePixel = 0
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Size = UDim2.fromOffset(math.random(8, 14), math.random(4, 8))
		piece.Position = UDim2.fromOffset(originAbsolutePosition.X, originAbsolutePosition.Y)
		piece.Rotation = math.random(0, 360)
		piece.ZIndex = zIndex
		piece.Parent = container

		local angle = math.rad(math.random(0, 359) + math.random())
		local distance = math.random(math.floor(burstRadius * 0.4), burstRadius)
		local targetX = originAbsolutePosition.X + math.cos(angle) * distance
		local targetY = originAbsolutePosition.Y + math.sin(angle) * distance + fallExtra
		local targetRotation = piece.Rotation + math.random(-540, 540)
		local pieceLifetime = lifetime + (math.random() * 0.4 - 0.2)

		local tween = TweenService:Create(piece, TweenInfo.new(pieceLifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromOffset(targetX, targetY),
			Rotation = targetRotation,
			BackgroundTransparency = 1,
		})
		tween:Play()
		tween.Completed:Connect(function()
			piece:Destroy()
		end)
	end
end

function Confetti.BurstFromGui(target: GuiObject, options: ConfettiOptions?)
	if not target or not target:IsDescendantOf(game) then
		return
	end

	local origin = target.AbsolutePosition + target.AbsoluteSize * 0.5
	Confetti.Burst(target, origin, options)
end

export type RainOptions = {
	count: number?,
	colors: { Color3 }?,
	minLifetime: number?,
	maxLifetime: number?,
	spawnDuration: number?,
	horizontalDrift: number?,
	zIndex: number?,
}

function Confetti.Rain(parent: Instance, options: RainOptions?)
	local opts = options or {}
	local count = opts.count or 80
	local colors = opts.colors or DEFAULT_COLORS
	local minLifetime = opts.minLifetime or 1.6
	local maxLifetime = opts.maxLifetime or 2.8
	local spawnDuration = opts.spawnDuration or 0.6
	local horizontalDrift = opts.horizontalDrift or 120
	local zIndex = opts.zIndex or 100

	local container = resolveScreenContainer(parent)
	local containerInstance = container :: any
	local viewportSize: Vector2
	if containerInstance:IsA("GuiBase2d") then
		viewportSize = containerInstance.AbsoluteSize
	else
		local Camera = workspace.CurrentCamera
		viewportSize = if Camera then Camera.ViewportSize else Vector2.new(1920, 1080)
	end

	local screenWidth = math.max(1, viewportSize.X)
	local screenHeight = math.max(1, viewportSize.Y)
	local fallTargetY = screenHeight + 60

	for i = 1, count do
		task.delay((i - 1) / count * spawnDuration, function()
			if not container.Parent then
				return
			end

			local piece = Instance.new("Frame")
			piece.BackgroundColor3 = colors[((i - 1) % #colors) + 1]
			piece.BorderSizePixel = 0
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.Size = UDim2.fromOffset(math.random(8, 14), math.random(4, 8))
			local startX = math.random(0, math.floor(screenWidth))
			local startY = math.random(-80, -20)
			piece.Position = UDim2.fromOffset(startX, startY)
			piece.Rotation = math.random(0, 360)
			piece.ZIndex = zIndex
			piece.Parent = container

			local drift = math.random(-horizontalDrift, horizontalDrift)
			local targetX = startX + drift
			local targetRotation = piece.Rotation + math.random(-720, 720)
			local lifetime = minLifetime + math.random() * (maxLifetime - minLifetime)

			local tween = TweenService:Create(piece, TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.fromOffset(targetX, fallTargetY),
				Rotation = targetRotation,
				BackgroundTransparency = 1,
			})
			tween:Play()
			tween.Completed:Connect(function()
				piece:Destroy()
			end)
		end)
	end
end

return Confetti
