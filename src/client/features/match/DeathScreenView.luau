--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AssetIds = require(ReplicatedStorage:WaitForChild("Shared").constants.AssetIds)
local BannerCard = require(script.Parent.Parent.Parent.core.ui.BannerCard)

local DeathScreenView = {}
DeathScreenView.__index = DeathScreenView

local STYLE = {
	showTween = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	hideTween = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
}

local KILLER_VIEWPORT_ANIM_ID = AssetIds.Animations.KillerViewportIdle

type Refs = {
	root: GuiObject,
	container: GuiObject,
	menuButton: GuiButton?,
	respawnButton: GuiButton?,
	menuPcLabel: TextLabel?,
	respawnPcLabel: TextLabel?,
	barFill: GuiObject?,
	-- Tarjeta del asesino (ImageLabel con el banner + Name + Level).
	card: BannerCard.Refs?,
	viewportFrame: ViewportFrame?,
}

export type KillerInfo = {
	name: string,
	level: number,
	-- Id en ItemsConfig.Banners; nil/"Default" → banner por defecto.
	bannerId: string?,
	character: Model?,
}

local function _resolvePcLabel(buttonNode: Instance?): TextLabel?
	if not buttonNode then
		return nil
	end
	local pcNode = buttonNode:FindFirstChild("PC")
	if pcNode and pcNode:IsA("TextLabel") then
		return pcNode
	end
	return nil
end

local function _isPcPlatform(): boolean
	return UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled
end

local function _resolveBarFill(respawnNode: Instance?): GuiObject?
	if not respawnNode then
		return nil
	end
	local barNode = respawnNode:FindFirstChild("Bar")
	if not barNode then
		return nil
	end
	local fillNode = barNode:FindFirstChild("Fill")
	if fillNode and fillNode:IsA("GuiObject") then
		return fillNode
	end
	return nil
end

local function _resolveRefs(gui: GuiObject): Refs?
	-- Backdrop (para el fade): wrapper `Container` si existe, si no el propio gui.
	local containerNode = gui:FindFirstChild("Container")
	local container: GuiObject = if containerNode and containerNode:IsA("GuiObject")
		then containerNode
		else gui

	-- Buscamos los nodos de contenido de forma recursiva: así funcionan tanto si
	-- cuelgan del Container como si viven dentro de los paneles Up/Down.
	local menuNode = gui:FindFirstChild("Menu", true)
	local respawnNode = gui:FindFirstChild("Respawn", true)
	local cardNode = gui:FindFirstChild("Card", true)
	local viewportNode = gui:FindFirstChild("ViewportFrame", true)

	if not menuNode and not respawnNode then
		return nil
	end

	return {
		root = gui,
		container = container,
		menuButton = if menuNode and menuNode:IsA("GuiButton") then menuNode else nil,
		respawnButton = if respawnNode and respawnNode:IsA("GuiButton") then respawnNode else nil,
		menuPcLabel = _resolvePcLabel(menuNode),
		respawnPcLabel = _resolvePcLabel(respawnNode),
		barFill = _resolveBarFill(respawnNode),
		card = if cardNode then BannerCard.resolve(cardNode) else nil,
		viewportFrame = if viewportNode and viewportNode:IsA("ViewportFrame") then viewportNode else nil,
	}
end

local function _setPcHintsVisible(refs: Refs)
	local isPc = _isPcPlatform()
	if refs.menuPcLabel then
		refs.menuPcLabel.Visible = isPc
	end
	if refs.respawnPcLabel then
		refs.respawnPcLabel.Visible = isPc
	end
end

local function _setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end
	button.Active = enabled
	button.AutoButtonColor = enabled
end

local function _populateCard(refs: Refs, killer: KillerInfo?)
	if not refs.card then
		return
	end
	if killer then
		BannerCard.populate(refs.card, killer.name, killer.level, killer.bannerId)
	else
		BannerCard.populate(refs.card, "", 0, nil)
	end
end

local function _stripUnsafeDescendants(model: Model)
	for _, desc in model:GetDescendants() do
		-- Inútiles o dañinos en un ViewportFrame: scripts, Highlights (replican el
		-- rojo enemigo) y BillboardGuis (nombre/HP del personaje original).
		if desc:IsA("Script") or desc:IsA("LocalScript") or desc:IsA("BillboardGui") or desc:IsA("Highlight") then
			desc:Destroy()
		end
	end
end

local function _clearViewport(viewportFrame: ViewportFrame)
	for _, child in viewportFrame:GetChildren() do
		if child:IsA("WorldModel") or child:IsA("Camera") then
			child:Destroy()
		end
	end
end

local function _renderKillerInViewport(viewportFrame: ViewportFrame, characterModel: Model?): AnimationTrack?
	_clearViewport(viewportFrame)

	if not characterModel then
		return nil
	end

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewportFrame

	local clone = characterModel:Clone()
	_stripUnsafeDescendants(clone)
	clone.Parent = worldModel
	clone:PivotTo(clone:GetPivot() * CFrame.Angles(-0.4, math.rad(210), 0))

	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	viewportFrame.CurrentCamera = cam
	cam.Parent = viewportFrame

	local rootPart = clone:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		local rp = rootPart :: BasePart
		cam.CFrame = CFrame.new(rp.Position + Vector3.new(0, 5, 16), rp.Position)
	end

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local anim = Instance.new("Animation")
	anim.AnimationId = KILLER_VIEWPORT_ANIM_ID
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(anim)
	end)
	anim:Destroy()

	if ok and track then
		local t = track :: AnimationTrack
		t.Looped = true
		t:Play()
		return t
	end
	return nil
end

function DeathScreenView.new(gui: GuiObject): any
	local refs = _resolveRefs(gui)
	if not refs then
		return nil
	end

	local self = setmetatable({}, DeathScreenView)
	self._refs = refs
	self._connections = {} :: { RBXScriptConnection }
	self._countdownToken = 0
	self._onRespawn = nil :: (() -> ())?
	self._onMenu = nil :: (() -> ())?
	self._baseTransparency = refs.container.BackgroundTransparency
	self._respawnReady = false
	self._destroyed = false
	self._viewportTrack = nil :: AnimationTrack?
	self._countdownTween = nil :: Tween?

	refs.root.Visible = false
	_setPcHintsVisible(refs)

	return self
end

function DeathScreenView:_tryRespawn()
	if not self._respawnReady then
		return
	end
	if self._onRespawn then
		self._onRespawn()
	end
end

function DeathScreenView:bind(onRespawn: () -> (), onMenu: () -> ())
	self._onRespawn = onRespawn
	self._onMenu = onMenu

	if self._refs.respawnButton then
		table.insert(self._connections, self._refs.respawnButton.MouseButton1Click:Connect(function()
			self:_tryRespawn()
		end))
	end

	if self._refs.menuButton then
		table.insert(self._connections, self._refs.menuButton.MouseButton1Click:Connect(function()
			if self._onMenu then
				self._onMenu()
			end
		end))
	end

	table.insert(self._connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not self._refs.root.Visible then
			return
		end

		if input.KeyCode == Enum.KeyCode.M then
			if self._onMenu then
				self._onMenu()
			end
			return
		end

		if input.KeyCode == Enum.KeyCode.Space then
			self:_tryRespawn()
		end
	end))
end

function DeathScreenView:show(respawnCooldown: number, killer: KillerInfo?)
	self._countdownToken += 1
	local token = self._countdownToken
	_setPcHintsVisible(self._refs)
	self._refs.root.Visible = true
	-- Arrancar desde 1: tweenear a la transparencia actual sería un no-op.
	self._refs.container.BackgroundTransparency = 1
	TweenService:Create(self._refs.container, STYLE.showTween, {
		BackgroundTransparency = self._baseTransparency,
	}):Play()

	_setButtonEnabled(self._refs.menuButton, true)
	_setButtonEnabled(self._refs.respawnButton, false)
	self._respawnReady = false

	if self._refs.barFill then
		self._refs.barFill.Size = UDim2.new(0, 0, 1, 0)
	end

	_populateCard(self._refs, killer)

	if self._viewportTrack then
		pcall(function()
			(self._viewportTrack :: AnimationTrack):Stop()
		end)
		self._viewportTrack = nil
	end
	if self._refs.viewportFrame then
		self._viewportTrack = _renderKillerInViewport(
			self._refs.viewportFrame,
			if killer then killer.character else nil
		)
	end

	-- El token cancela: show()/hide()/Destroy() lo incrementan y el task.delay
	-- tardío no hace nada.
	if self._countdownTween then
		self._countdownTween:Cancel()
		self._countdownTween = nil
	end

	local duration = math.max(0, respawnCooldown)
	local barFill = self._refs.barFill
	if duration <= 0 then
		if barFill then
			barFill.Size = UDim2.new(1, 0, 1, 0)
		end
		self._respawnReady = true
		_setButtonEnabled(self._refs.respawnButton, true)
	else
		if barFill then
			local tween = TweenService:Create(
				barFill,
				TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
				{ Size = UDim2.new(1, 0, 1, 0) }
			)
			self._countdownTween = tween
			tween:Play()
		end
		task.delay(duration, function()
			if self._destroyed or self._countdownToken ~= token then
				return
			end
			if barFill and barFill.Parent then
				barFill.Size = UDim2.new(1, 0, 1, 0)
			end
			self._respawnReady = true
			_setButtonEnabled(self._refs.respawnButton, true)
		end)
	end
end

function DeathScreenView:hide()
	self._countdownToken += 1
	local token = self._countdownToken
	self._respawnReady = false
	_setButtonEnabled(self._refs.respawnButton, false)
	if self._countdownTween then
		self._countdownTween:Cancel()
		self._countdownTween = nil
	end
	if self._refs.barFill then
		self._refs.barFill.Size = UDim2.new(0, 0, 1, 0)
	end

	if self._viewportTrack then
		pcall(function()
			(self._viewportTrack :: AnimationTrack):Stop()
		end)
		self._viewportTrack = nil
	end
	if self._refs.viewportFrame then
		_clearViewport(self._refs.viewportFrame)
	end

	local tween = TweenService:Create(self._refs.container, STYLE.hideTween, {
		BackgroundTransparency = 1,
	})
	tween:Play()
	-- Guardado con token: si llega un show() durante el fade, no ocultamos.
	task.delay(STYLE.hideTween.Time, function()
		if self._destroyed or self._countdownToken ~= token then
			return
		end
		self._refs.root.Visible = false
	end)
end

function DeathScreenView:Destroy()
	self._destroyed = true
	self._countdownToken += 1
	if self._countdownTween then
		self._countdownTween:Cancel()
		self._countdownTween = nil
	end
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	if self._viewportTrack then
		pcall(function()
			(self._viewportTrack :: AnimationTrack):Stop()
		end)
		self._viewportTrack = nil
	end
	if self._refs.viewportFrame then
		_clearViewport(self._refs.viewportFrame)
	end
	self._refs.root.Visible = false
end

return DeathScreenView
