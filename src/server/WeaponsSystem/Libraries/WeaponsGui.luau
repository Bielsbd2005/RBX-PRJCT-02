--!strict
-- WeaponsGui.luau
-- Compositor principal del sistema de interfaces de armas (cliente).
-- Coordina retícula, barra de accesos rápidos, controles táctiles y viñetas de retroalimentación.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)

local WeaponsSystemFolder = script.Parent.Parent
local WeaponData = WeaponsSystemFolder:WaitForChild("WeaponData")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local WeaponsSystemGuiTemplate = WeaponsSystemFolder:WaitForChild("Assets"):WaitForChild("WeaponsSystemGui")

-- Módulos del sub-sistema GUI
local GuiFolder = Libraries:WaitForChild("Gui")
local Crosshair = require(GuiFolder:WaitForChild("Crosshair"))
local Hotbar = require(GuiFolder:WaitForChild("Hotbar"))
local MobileControls = require(GuiFolder:WaitForChild("MobileControls"))
local HitFeedback = require(GuiFolder:WaitForChild("HitFeedback"))
local Scope = require(GuiFolder:WaitForChild("Scope"))
local DirectionalIndicators = require(GuiFolder:WaitForChild("DirectionalIndicators"))

local RELOAD_PROGRESS_STYLE = {
	FlipProgress = false,
	ImageId = "3587367081",
	ImageColor = Color3.fromRGB(255, 255, 255),
	ImageTrans = 0,
	MissingPartType = "TransAndColor", -- "Color" | "Trans" | "TransAndColor"
	ColorOfPercentPart = Color3.fromRGB(255, 255, 255),
	ColorOfMissingPart = Color3.fromRGB(0, 0, 0),
	TransOfPercentPart = 0,
	TransOfMissingPart = 0.25,
}

-- Caché pre-construido para las secuencias de reload
local _reloadSeqCache: {
	colorSeq: ColorSequence?,
	transSeq: NumberSequence?,
	whiteColor: ColorSequence?,
	zeroTrans: NumberSequence?,
}
do
	local s = RELOAD_PROGRESS_STYLE
	local colorKp = ColorSequence.new({
		ColorSequenceKeypoint.new(0, s.ColorOfPercentPart),
		ColorSequenceKeypoint.new(0.5, s.ColorOfPercentPart),
		ColorSequenceKeypoint.new(0.501, s.ColorOfMissingPart),
		ColorSequenceKeypoint.new(1, s.ColorOfMissingPart),
	})
	local transKp = NumberSequence.new({
		NumberSequenceKeypoint.new(0, s.TransOfPercentPart),
		NumberSequenceKeypoint.new(0.5, s.TransOfPercentPart),
		NumberSequenceKeypoint.new(0.501, s.TransOfMissingPart),
		NumberSequenceKeypoint.new(1, s.TransOfMissingPart),
	})
	local white = ColorSequence.new(Color3.new(1, 1, 1))
	local zero = NumberSequence.new(0)

	if s.MissingPartType == "Color" then
		_reloadSeqCache = { colorSeq = colorKp, transSeq = nil, whiteColor = nil, zeroTrans = zero }
	elseif s.MissingPartType == "Trans" then
		_reloadSeqCache = { colorSeq = nil, transSeq = transKp, whiteColor = white, zeroTrans = nil }
	elseif s.MissingPartType == "TransAndColor" then
		_reloadSeqCache = { colorSeq = colorKp, transSeq = transKp, whiteColor = nil, zeroTrans = nil }
	else
		_reloadSeqCache = { colorSeq = nil, transSeq = transKp, whiteColor = white, zeroTrans = nil }
	end
end

local WeaponsGui = {}
WeaponsGui.__index = WeaponsGui

local getJumpButton = function()
	if UserInputService.TouchEnabled then
		local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
		if not playerGui then return nil end
		local touchGui = playerGui:FindFirstChild("TouchGui")
		if not touchGui then return nil end
		local touchControlFrame = touchGui:FindFirstChild("TouchControlFrame")
		if not touchControlFrame then return nil end
		return touchControlFrame:FindFirstChild("JumpButton")
	end
	return nil
end

function WeaponsGui.new(weaponsSystem: any)
	local self = setmetatable({}, WeaponsGui)
	self.weaponsSystem = weaponsSystem
	self.libraries = Libraries
	self.connections = {}
	-- L7: las conexiones de "ciclo de vida" (AbsoluteSize / CurrentCamera /
	-- GuiEnabled) se crean una sola vez en el constructor. Mantenerlas en una
	-- tabla aparte para que setEnabled(false) NO las desconecte — si vivieran en
	-- self.connections, un ciclo disable→enable las perdería y la GUI dejaría de
	-- reescalarse ante cambios de resolución/cámara.
	self.lifetimeConnections = {}
	self.enabled = false
	self.isZoomed = false
	self.scopeEnabled = false
	self._uiReady = false
	self._isShotgun = false

	self.referenceViewportSize = Vector2.new(1000, 1000)
	self.scaleWeight = 0.75
	self.originalScaleAmounts = {}

	-- Estados internos
	self._lastWeaponInstance = nil
	self._toolConns = {}
	self._hotbarDirty = true

	-- Inicializar interfaz clonando el template
	self.gui = WeaponsSystemGuiTemplate:Clone()
	self.gui.Enabled = false

	-- Submódulos desacoplados
	self.crosshair = Crosshair.new(self)
	self.hotbar = Hotbar.new(self)
	self.mobileControls = MobileControls.new(self)
	self.hitFeedback = HitFeedback.new(self)
	self.scope = Scope.new(self)
	self.directionalIndicators = DirectionalIndicators.new(self)

	coroutine.wrap(function()
		self.scalingElementsFolder = self.gui:WaitForChild("ScalingElements")

		-- Configurar submódulos
		self.crosshair:setup(self.scalingElementsFolder)
		self.hotbar:setupLayout(self.gui:FindFirstChild("Hotbar_PC"))
		self.hotbar:setupLayout(self.gui:FindFirstChild("Hotbar_TouchScreen"))
		self.hotbar:setupEvents()

		self.mobileControls:setup(self.gui)
		self.hitFeedback:setup(self.scalingElementsFolder)
		self.scope:setup(self.gui)
		self.directionalIndicators:setup(self.gui)

		self.ammoDisplayNode = self.gui:FindFirstChild("AmmoDisplayNode")
		local ammoFrame = self.scalingElementsFolder:FindFirstChild("Ammo")
		self.ammoDisplayLabel = if ammoFrame then ammoFrame:FindFirstChild("Value") else nil

		self.gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

		-- Limpiar listeners antiguos de forma segura
		if self.lifetimeConnections.absoluteSize then self.lifetimeConnections.absoluteSize:Disconnect() end
		if self.lifetimeConnections.currentCamera then self.lifetimeConnections.currentCamera:Disconnect() end
		if self.lifetimeConnections.guiEnabled then self.lifetimeConnections.guiEnabled:Disconnect() end

		-- L7: estos watchers viven en lifetimeConnections (no en connections) para
		-- sobrevivir a los ciclos disable→enable.
		self.lifetimeConnections.absoluteSize = self.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() self:onScreenSizeChanged() end)
		self.lifetimeConnections.currentCamera = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() self:onScreenSizeChanged() end)
		self.lifetimeConnections.guiEnabled = self.gui:GetPropertyChangedSignal("Enabled"):Connect(function()
			if self.gui.Enabled then
				self:onScreenSizeChanged()
			end
		end)

		self:onScreenSizeChanged()

		-- Precargar assets
		local preloadTargets = {
			self.crosshair.bottom,
			self.crosshair.left,
			self.crosshair.right,
			self.crosshair.top,
			self.scope.scopeFrame,
			self.mobileControls.smallAimButton,
			self.mobileControls.largeAimButton,
			self.mobileControls.smallFireButton,
			self.mobileControls.largeFireButton,
			self.mobileControls.smallReloadButton,
			self.mobileControls.largeReloadButton,
		}
		if self.scope.vignette then
			table.insert(preloadTargets, self.scope.vignette)
		end
		ContentProvider:PreloadAsync(preloadTargets)
	end)()

	return self
end

function WeaponsGui:onScreenSizeChanged()
	if not self.scalingElementsFolder or not self.crosshair or not self.crosshair.frame then
		self._uiReady = false
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		self._uiReady = false
		return
	end

	local viewportSize = camera.ViewportSize
	if viewportSize.X <= 0 or viewportSize.Y <= 0 then
		self._uiReady = false
		return
	end

	if self.mobileControls and self.mobileControls.smallTouchscreen then
		local isSmallScreen
		local jumpButton = getJumpButton()
		if jumpButton then
			isSmallScreen = jumpButton.Size.X.Offset <= 70
		else
			isSmallScreen = self.gui.AbsoluteSize.Y < 600
		end
		self.mobileControls.smallTouchscreen.Visible = UserInputService.TouchEnabled and isSmallScreen
		self.mobileControls.largeTouchscreen.Visible = UserInputService.TouchEnabled and not isSmallScreen
	end

	local hotbarPC = self.gui:FindFirstChild("Hotbar_PC")
	if hotbarPC then
		hotbarPC.Visible = not UserInputService.TouchEnabled
	end
	local hotbarTouch = self.gui:FindFirstChild("Hotbar_TouchScreen")
	if hotbarTouch then
		hotbarTouch.Visible = UserInputService.TouchEnabled
	end

	self.hotbar:refresh()

	for _, child in self.scalingElementsFolder:GetChildren() do
		self:updateScale(child, viewportSize)
	end

	self.crosshair:resize(viewportSize)

	self._uiReady = true
end

function WeaponsGui:getWeightedScaleAmount(originalScaleAmount: number, newScreenDim: number, referenceScreenDim: number)
	return (1 - self.scaleWeight) * originalScaleAmount * referenceScreenDim / newScreenDim + self.scaleWeight * originalScaleAmount
end

function WeaponsGui:updateScale(guiObject: Instance, viewportSize: Vector2)
	if guiObject:IsA("GuiObject") then
		local xScale = guiObject.Size.X.Scale
		local yScale = guiObject.Size.Y.Scale
		if xScale ~= 0 or yScale ~= 0 or self.originalScaleAmounts[guiObject] ~= nil then
			if self.originalScaleAmounts[guiObject] == nil then
				self.originalScaleAmounts[guiObject] = Vector2.new(xScale, yScale)
			end
			local weightedX = self:getWeightedScaleAmount(self.originalScaleAmounts[guiObject].X, viewportSize.X, self.referenceViewportSize.X)
			local weightedY = self:getWeightedScaleAmount(self.originalScaleAmounts[guiObject].Y, viewportSize.Y, self.referenceViewportSize.Y)
			guiObject.Size = UDim2.new(weightedX, 0, weightedY, 0)
		end
		return
	end
	for _, child in ipairs(guiObject:GetChildren()) do
		self:updateScale(child, viewportSize)
	end
end

function WeaponsGui:setEnabled(enabled: boolean)
	if self.enabled == enabled then return end
	self.enabled = enabled

	if self.enabled then
		if self.gui then
			self.gui.Enabled = true
		end
		task.defer(function()
			self:onScreenSizeChanged()
		end)
		task.delay(0.1, function()
			self:onScreenSizeChanged()
		end)

		self.connections.renderStepped = RunService.RenderStepped:Connect(function(dt) self:onRenderStepped(dt) end)
		self.connections.inputBegan = UserInputService.InputBegan:Connect(function(input, gp)
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				self.mobileControls:dispatchTouchBegin(input)
			end

			if not gp then
				if input.KeyCode == Enum.KeyCode.One then
					self.hotbar:equipSlot(1)
					return
				elseif input.KeyCode == Enum.KeyCode.Two then
					self.hotbar:equipSlot(2)
					return
				end
			end

			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				self:setZoomed(true)
			elseif not gp and input.UserInputType == Enum.UserInputType.MouseButton1 then
				if self.crosshair.isShotgun then
					self.crosshair:kickShotgunSpread()
				end
			end
		end)
		self.connections.inputEnded = UserInputService.InputEnded:Connect(function(input, gp)
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				self.mobileControls:dispatchTouchEnd(input)
			end

			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				self:setZoomed(false)
			end
		end)
	else
		self:setZoomed(false)
		self:stopReloadProgressAnimation()
		self.mobileControls:stopTouchFire()
		self.mobileControls:setReloadButtonsPressed(false)
		self.mobileControls:setJumpButtonsPressed(false)

		self._lastAmmoDisplayText = nil
		self:_updateAmmoDisplay()

		if self.combatHUD then
			self.combatHUD:hide()
		end

		for _, v in pairs(self.connections) do
			v:Disconnect()
		end
		table.clear(self.connections)
		self:_disconnectToolConns()
	end
end

function WeaponsGui:_disconnectToolConns()
	for _, c in pairs(self._toolConns) do
		c:Disconnect()
	end
	table.clear(self._toolConns)
end

function WeaponsGui:_connectToolConns(tool: Instance?)
	self:_disconnectToolConns()
	if not tool then return end
	if tool:IsA("Tool") then
		tool.ManualActivationOnly = UserInputService.TouchEnabled
	end
	table.insert(self._toolConns, tool.Activated:Connect(function()
		if self.crosshair.isShotgun then
			self.crosshair:kickShotgunSpread()
		end
	end))
	if tool:IsA("Tool") then
		table.insert(self._toolConns, tool.AncestryChanged:Connect(function(_, parent)
			if not parent then self:_disconnectToolConns() end
		end))
	end
end

function WeaponsGui:onRenderStepped(dt: number)
	if not self._uiReady then
		self:onScreenSizeChanged()
		return
	end
	if not self.enabled or not self.gui then return end

	-- Comprobar cambio de arma
	local w = self.weaponsSystem.currentWeapon
	local tool = w and w.instance
	if tool ~= self._lastWeaponInstance then
		self._lastWeaponInstance = tool
		self._hotbarDirty = true
		local isShotgun = tool and tool:GetAttribute("Shotgun") == true or false
		self.crosshair:setVariant(isShotgun)
		self:_connectToolConns(tool)
	end

	if self._hotbarDirty then
		self.hotbar:refresh()
	end

	self.crosshair:update(dt)
	self:_updateAmmoDisplay()
end

function WeaponsGui:_updateAmmoDisplay()
	local weapon = self.weaponsSystem.currentWeapon
	local ammoText = ""

	if weapon and weapon.instance then
		local currentAmmo = weapon.instance:GetAttribute("CurrentAmmo")
		if type(currentAmmo) == "number" then
			ammoText = tostring(math.max(0, math.floor(currentAmmo + 0.5)))
		end
	end

	if self._lastAmmoDisplayText == ammoText then
		return
	end
	self._lastAmmoDisplayText = ammoText

	local textNode = self.ammoDisplayLabel
	if textNode and (
		textNode:IsA("TextLabel")
		or textNode:IsA("TextButton")
		or textNode:IsA("TextBox")
	) then
		textNode.Text = ammoText
		return
	end

	if self.ammoDisplayNode and self.ammoDisplayNode:IsA("StringValue") then
		self.ammoDisplayNode.Value = ammoText
	elseif self.ammoDisplayNode and (self.ammoDisplayNode:IsA("IntValue") or self.ammoDisplayNode:IsA("NumberValue")) then
		self.ammoDisplayNode.Value = tonumber(ammoText) or 0
	end
end

function WeaponsGui:setZoomed(zoomed: boolean)
	if zoomed == self.isZoomed then return end
	self.isZoomed = zoomed
	self.mobileControls:updateAimButtonsVisual()
	if self.weaponsSystem.camera then
		self.weaponsSystem.camera:setForceZoomed(self.isZoomed)
	end
end

function WeaponsGui:OnHitOtherPlayer(damage: number, humanoidHit: Humanoid, hitPart: BasePart?)
	self.hitFeedback:onHitOtherPlayer(damage, humanoidHit, hitPart)
end

function WeaponsGui:onWeaponEquipped(weapon: any)
	self:stopReloadProgressAnimation()
	self._hotbarDirty = true
end

function WeaponsGui:onWeaponUnequipped()
	self:stopReloadProgressAnimation()
	self._hotbarDirty = true
end

function WeaponsGui:onWeaponReloadStarted(weapon: any, reloadTime: number)
	self:playReloadProgressAnimation(reloadTime)
end

function WeaponsGui:stopReloadProgressAnimation()
	self:_stopReloadProgressAnimation(true)
end

function WeaponsGui:_getReloadProgressFrame()
	if self.scalingElementsFolder then
		local fromScaling = self.scalingElementsFolder:FindFirstChild("Progress")
		if fromScaling then
			return fromScaling
		end
	end
	return self.gui:FindFirstChild("Progress")
end

function WeaponsGui:_setReloadProgressVisible(isVisible: boolean)
	local progressFrame = self:_getReloadProgressFrame()
	if progressFrame and progressFrame:IsA("GuiObject") then
		progressFrame.Visible = isVisible
	end
end

function WeaponsGui:_stopReloadProgressAnimation(hideProgress: boolean)
	self._reloadProgressRunId = (self._reloadProgressRunId or 0) + 1

	if self._reloadProgressTween then
		self._reloadProgressTween:Cancel()
		self._reloadProgressTween = nil
	end

	if self._reloadProgressConnection then
		self._reloadProgressConnection:Disconnect()
		self._reloadProgressConnection = nil
	end

	self._isReloadProgressAnimating = false
	self.crosshair:refreshVisibility()

	if hideProgress ~= false then
		self:_setReloadProgressVisible(false)
		self._reloadProgressOwner = nil
		self._reloadProgressStartedAt = nil
	end
end

function WeaponsGui:playReloadProgressAnimation(reloadTime: number)
	local currentWeapon = self.weaponsSystem and self.weaponsSystem.currentWeapon
	local now = os.clock()
	if self._isReloadProgressAnimating
		and self._reloadProgressOwner == currentWeapon
		and self._reloadProgressStartedAt
		and (now - self._reloadProgressStartedAt) < 0.15
	then
		return
	end
	self._reloadProgressStartedAt = now
	self._reloadProgressOwner = currentWeapon

	if self._reloadProgressTween or self._reloadProgressConnection then
		self:_stopReloadProgressAnimation(false)
	end

	self._isReloadProgressAnimating = true
	self.crosshair:refreshVisibility()
	self:_setReloadProgressVisible(true)

	self._reloadProgressRunId = (self._reloadProgressRunId or 0) + 1
	local runId = self._reloadProgressRunId

	local progressFrame = self:_getReloadProgressFrame()
	if not progressFrame then
		warn("[WeaponsGui] Progress frame not found for reload animation.")
		self._isReloadProgressAnimating = false
		self.crosshair:refreshVisibility()
		return
	end

	local progressValue = progressFrame:FindFirstChild("ProgressValue") :: NumberValue?
	if not progressValue then
		local val = Instance.new("NumberValue")
		val.Name = "ProgressValue"
		val.Value = 0
		val.Parent = progressFrame
		progressValue = val
	end
	progressValue.Value = 0

	local frame1 = progressFrame:FindFirstChild("Frame1")
	local frame2 = progressFrame:FindFirstChild("Frame2")
	if frame1 and frame2 then
		local f1img = frame1:FindFirstChildOfClass("ImageLabel") or frame1
		local f2img = frame2:FindFirstChildOfClass("ImageLabel") or frame2
		local style = RELOAD_PROGRESS_STYLE
		local imageAsset = "rbxassetid://" .. style.ImageId
		for _, img in { f1img, f2img } do
			if img:IsA("ImageLabel") or img:IsA("ImageButton") then
				img.ImageColor3 = style.ImageColor
				img.ImageTransparency = style.ImageTrans
				img.Image = imageAsset
			end
		end
		local g1 = f1img:FindFirstChildOfClass("UIGradient")
		local g2 = f2img:FindFirstChildOfClass("UIGradient")
		if g1 and g2 then
			local cache = _reloadSeqCache
			if cache.colorSeq then g1.Color = cache.colorSeq; g2.Color = cache.colorSeq end
			if cache.whiteColor then g1.Color = cache.whiteColor; g2.Color = cache.whiteColor end
			if cache.transSeq then g1.Transparency = cache.transSeq; g2.Transparency = cache.transSeq end
			if cache.zeroTrans then g1.Transparency = cache.zeroTrans; g2.Transparency = cache.zeroTrans end
		end
	end

	self:_updateReloadProgressBar(0)

	local tweenInfo = TweenInfo.new(math.max(0.01, tonumber(reloadTime) or 0.01), Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
	self._reloadProgressTween = TweenService:Create(progressValue, tweenInfo, { Value = 100 })

	self._reloadProgressConnection = progressValue.Changed:Connect(function(value)
		if runId ~= self._reloadProgressRunId then return end
		self:_updateReloadProgressBar(value)
	end)

	self._reloadProgressTween:Play()

	local activeTween = self._reloadProgressTween
	activeTween.Completed:Connect(function()
		if runId ~= self._reloadProgressRunId then return end

		if self._reloadProgressConnection then
			self._reloadProgressConnection:Disconnect()
			self._reloadProgressConnection = nil
		end
		self._reloadProgressTween = nil
		self._isReloadProgressAnimating = false
		self.crosshair:refreshVisibility()
		self:_updateReloadProgressBar(0)
		self:_setReloadProgressVisible(false)
		self._reloadProgressOwner = nil
		self._reloadProgressStartedAt = nil
		progressValue.Value = 0
	end)
end

function WeaponsGui:_updateReloadProgressBar(progressPercent: number)
	local progressFrame = self:_getReloadProgressFrame()
	if not progressFrame then return end

	local frame1 = progressFrame:FindFirstChild("Frame1")
	local frame2 = progressFrame:FindFirstChild("Frame2")
	if not frame1 or not frame2 then return end

	local frame1ImageLabel = frame1:FindFirstChildOfClass("ImageLabel") or frame1
	local frame2ImageLabel = frame2:FindFirstChildOfClass("ImageLabel") or frame2
	if not (frame1ImageLabel:IsA("ImageLabel") or frame1ImageLabel:IsA("ImageButton")) then return end
	if not (frame2ImageLabel:IsA("ImageLabel") or frame2ImageLabel:IsA("ImageButton")) then return end

	local g1 = frame1ImageLabel:FindFirstChildOfClass("UIGradient")
	local g2 = frame2ImageLabel:FindFirstChildOfClass("UIGradient")
	if not g1 or not g2 then return end

	local percentNumber = math.clamp(progressPercent * 3.6, 0, 360)

	g1.Rotation = (RELOAD_PROGRESS_STYLE.FlipProgress == false)
		and math.clamp(percentNumber, 180, 360)
		or 180 - math.clamp(percentNumber, 0, 180)
	g2.Rotation = (RELOAD_PROGRESS_STYLE.FlipProgress == false)
		and math.clamp(percentNumber, 0, 180)
		or 180 - math.clamp(percentNumber, 180, 360)
end

-- Funciones puente delegadas para mantener compatibilidad
function WeaponsGui:setCrosshairEnabled(crosshairEnabled: boolean)
	self.crosshair:setEnabled(crosshairEnabled)
end

function WeaponsGui:setScopeEnabled(scopeEnabled: boolean)
	self.scopeEnabled = scopeEnabled
	self.scope:setScopeEnabled(scopeEnabled)
end

function WeaponsGui:setCrosshairWeaponScale(scale: number)
	self.crosshair:setWeaponScale(scale)
end

function WeaponsGui:setCrosshairScaleTarget(target: number, dampingRatio: number?, frequency: number?)
	self.crosshair:setScaleTarget(target, dampingRatio, frequency)
end

function WeaponsGui:setCrosshairScale(scale: number)
	self.crosshair:setScale(scale)
end

return WeaponsGui
