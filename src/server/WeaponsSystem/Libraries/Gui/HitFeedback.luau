--!strict
-- HitFeedback.luau (Client/Server Library)
-- Gestiona los hitmarkers en pantalla, vibraciones hápticas (móviles) y efectos de highlight locales al impactar.

local Players = game:GetService("Players")
local HapticService = game:GetService("HapticService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local HIT_HIGHLIGHT_NAME = "WSLocalHitHighlight"
local HIT_HIGHLIGHT_OUTLINE_COLOR = Color3.fromRGB(255, 64, 64)
local HIT_HIGHLIGHT_TO_OUTLINE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIT_HIGHLIGHT_FADE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local CENTER_ANCHOR_V2 = Vector2.new(0.5, 0.5)
local HIT_MARKER_CENTER_POS = UDim2.new(0.5, 0, 0.5, 0)
local HIT_COLOR_INITIAL = Color3.new(1, 0.3, 0.3)
local HIT_COLOR_PEAK = Color3.new(1, 0, 0)
local HIT_COLOR_FADE = Color3.new(1, 1, 0.7)

local MOBILE_HAPTIC_HIT_INTENSITY = 0.18
local MOBILE_HAPTIC_HEADSHOT_INTENSITY = 0.4
local MOBILE_HAPTIC_HIT_DURATION = 0.04
local MOBILE_HAPTIC_HEADSHOT_DURATION = 0.065
local MOBILE_HAPTIC_COOLDOWN = 0.07
local MOBILE_HAPTIC_INPUT_TYPES = { Enum.UserInputType.Touch, Enum.UserInputType.Gamepad1 }
local MOBILE_HAPTIC_MOTORS = { Enum.VibrationMotor.Small, Enum.VibrationMotor.Large }

local HitFeedback = {}
HitFeedback.__index = HitFeedback

local _cachedHapticTargets: { { inputType: Enum.UserInputType, motor: Enum.VibrationMotor } }? = nil

local function isMobileTouchDevice()
	return UserInputService.TouchEnabled
end

local function getSupportedHapticTargets()
	if _cachedHapticTargets then
		return _cachedHapticTargets
	end
	local targets = {}
	for _, inputType in ipairs(MOBILE_HAPTIC_INPUT_TYPES) do
		for _, motor in ipairs(MOBILE_HAPTIC_MOTORS) do
			local ok, supported = pcall(function()
				return HapticService:IsMotorSupported(inputType, motor)
			end)
			if ok and supported then
				table.insert(targets, { inputType = inputType, motor = motor })
			end
		end
	end
	_cachedHapticTargets = targets
	return targets
end

function HitFeedback.new(weaponsGui: any)
	local self = setmetatable({}, HitFeedback)
	self.weaponsGui = weaponsGui

	self._activeHitHighlights = {}
	self._hitHighlightSerial = 0
	self._mobileHapticPulseId = 0
	self._lastMobileHapticAt = 0

	return self
end

function HitFeedback:setup(scalingElementsFolder: Folder)
	self.hitMarker = scalingElementsFolder:WaitForChild("HitMarker"):WaitForChild("HitMarkerImage") :: ImageLabel
end

function HitFeedback:_pulseMobileHaptics(isHeadshot: boolean)
	if not isMobileTouchDevice() then
		return
	end

	if LocalPlayer:GetAttribute("Vibration") == false then
		return
	end

	local now = os.clock()
	if now - self._lastMobileHapticAt < MOBILE_HAPTIC_COOLDOWN then
		return
	end
	self._lastMobileHapticAt = now

	local targets = getSupportedHapticTargets()
	if #targets == 0 then
		if not self._warnedNoMobileHaptics then
			self._warnedNoMobileHaptics = true
			warn("HitFeedback: HapticService no reporta motores soportados para este dispositivo")
		end
		return
	end

	local intensity = if isHeadshot then MOBILE_HAPTIC_HEADSHOT_INTENSITY else MOBILE_HAPTIC_HIT_INTENSITY
	local duration = if isHeadshot then MOBILE_HAPTIC_HEADSHOT_DURATION else MOBILE_HAPTIC_HIT_DURATION
	local pulseId = self._mobileHapticPulseId + 1
	self._mobileHapticPulseId = pulseId

	pcall(function()
		for _, target in ipairs(targets) do
			HapticService:SetMotor(target.inputType, target.motor, intensity)
		end
	end)

	task.delay(duration, function()
		if self._mobileHapticPulseId ~= pulseId then
			return
		end
		pcall(function()
			for _, target in ipairs(targets) do
				HapticService:SetMotor(target.inputType, target.motor, 0)
			end
		end)
	end)
end

function HitFeedback:_playLocalHitHighlight(humanoidHit: Humanoid)
	local targetModel = humanoidHit.Parent
	if not targetModel or not targetModel:IsA("Model") then
		return
	end

	local existingState = self._activeHitHighlights[targetModel]
	if existingState then
		if existingState.colorTween then
			existingState.colorTween:Cancel()
		end
		if existingState.fadeTween then
			existingState.fadeTween:Cancel()
		end
		if existingState.highlight and existingState.highlight.Parent then
			existingState.highlight:Destroy()
		end
		self._activeHitHighlights[targetModel] = nil
	end

	local oldHighlight = targetModel:FindFirstChild(HIT_HIGHLIGHT_NAME)
	if oldHighlight and oldHighlight:IsA("Highlight") then
		oldHighlight:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = HIT_HIGHLIGHT_NAME
	highlight.Adornee = targetModel
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineColor = HIT_HIGHLIGHT_OUTLINE_COLOR
	highlight.FillTransparency = 0
	highlight.OutlineTransparency = 0
	highlight.Parent = targetModel

	self._hitHighlightSerial += 1
	local serial = self._hitHighlightSerial

	local colorTween = TweenService:Create(highlight, HIT_HIGHLIGHT_TO_OUTLINE_TWEEN, {
		FillColor = highlight.OutlineColor,
	})

	self._activeHitHighlights[targetModel] = {
		serial = serial,
		highlight = highlight,
		colorTween = colorTween,
		fadeTween = nil,
	}

	colorTween.Completed:Connect(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		local state = self._activeHitHighlights[targetModel]
		if not state or state.serial ~= serial or not highlight.Parent then
			return
		end

		local fadeTween = TweenService:Create(highlight, HIT_HIGHLIGHT_FADE_TWEEN, {
			FillTransparency = 1,
			OutlineTransparency = 1,
		})
		state.fadeTween = fadeTween

		fadeTween.Completed:Connect(function()
			local currentState = self._activeHitHighlights[targetModel]
			if currentState and currentState.serial == serial then
				self._activeHitHighlights[targetModel] = nil
			end
			if highlight.Parent then
				highlight:Destroy()
			end
		end)

		fadeTween:Play()
	end)

	colorTween:Play()
end

function HitFeedback:onHitOtherPlayer(damage: number, humanoidHit: Humanoid, hitPart: BasePart?)
	if self.currentHitTween then self.currentHitTween:Cancel() end
	if self.currentFadeTween then self.currentFadeTween:Cancel() end

	local isHeadshot = hitPart and hitPart.Name == "Head" or false
	self:_pulseMobileHaptics(isHeadshot)

	if not self._hitMarkerAnchorSet then
		self.hitMarker.AnchorPoint = CENTER_ANCHOR_V2
		self._hitMarkerAnchorSet = true
	end
	self.hitMarker.Position = HIT_MARKER_CENTER_POS
	self.hitMarker.ImageTransparency = 0
	self.hitMarker.Size = UDim2.new(0.03, 0, 0, 0)
	self.hitMarker.ImageColor3 = HIT_COLOR_INITIAL
	self.hitMarker.Rotation = 0

	local minSize = 30
	local initialSize = math.max(self.hitMarker.AbsoluteSize.X, minSize)
	self.hitMarker.Size = UDim2.new(0, initialSize, 0, initialSize)

	local hitTweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
	local maxSize = math.max(self.hitMarker.AbsoluteSize.X * 3.5, minSize * 3.5)
	local hitGoal = {
		Size = UDim2.new(0, maxSize, 0, maxSize),
		ImageColor3 = HIT_COLOR_PEAK,
		Rotation = math.random(-15, 15),
	}
	self.currentHitTween = TweenService:Create(self.hitMarker, hitTweenInfo, hitGoal)
	self.currentHitTween:Play()

	local fadeTweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, 0.15)
	local midSize = math.max(maxSize * 0.75, minSize * 1.5)
	local fadeGoal = {
		Size = UDim2.new(0, midSize, 0, midSize),
		ImageTransparency = 1,
		ImageColor3 = HIT_COLOR_FADE,
		Rotation = 0,
	}
	self.currentFadeTween = TweenService:Create(self.hitMarker, fadeTweenInfo, fadeGoal)
	self.currentFadeTween:Play()

	self:_playLocalHitHighlight(humanoidHit)

	local DamageBillboardHandler = require(self.weaponsGui.libraries.DamageBillboardHandler)
	local hitHead = humanoidHit.Parent and humanoidHit.Parent:FindFirstChild("Head")
	DamageBillboardHandler:ShowDamageBillboard(damage, hitHead, isHeadshot)
end

function HitFeedback:Destroy()
	if self.currentHitTween then self.currentHitTween:Cancel() end
	if self.currentFadeTween then self.currentFadeTween:Cancel() end
	for _, state in pairs(self._activeHitHighlights) do
		if state.colorTween then state.colorTween:Cancel() end
		if state.fadeTween then state.fadeTween:Cancel() end
		if state.highlight then state.highlight:Destroy() end
	end
	table.clear(self._activeHitHighlights)
end

return HitFeedback
