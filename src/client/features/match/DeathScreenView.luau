--!strict

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local DeathScreenView = {}
DeathScreenView.__index = DeathScreenView

local STYLE = {
	showTween = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	hideTween = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
}

local KILLER_VIEWPORT_ANIM_ID = "rbxassetid://126774009783214"

type Refs = {
	root: GuiObject,
	container: GuiObject,
	menuButton: GuiButton?,
	respawnButton: GuiButton?,
	menuPcLabel: TextLabel?,
	respawnPcLabel: TextLabel?,
	barFill: GuiObject?,
	cardName: TextLabel?,
	cardKills: TextLabel?,
	cardLevel: TextLabel?,
	viewportFrame: ViewportFrame?,
}

export type KillerInfo = {
	name: string,
	kills: number,
	level: number,
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

local function _resolveCardLabel(cardNode: Instance?, name: string): TextLabel?
	if not cardNode then
		return nil
	end
	local node = cardNode:FindFirstChild(name)
	if node and node:IsA("TextLabel") then
		return node
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

	-- Sin ningún botón no es una pantalla de muerte funcional (GUI incompleta o
	-- nodo equivocado): devolvemos nil para no crear una view rota.
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
		cardName = _resolveCardLabel(cardNode, "Name"),
		cardKills = _resolveCardLabel(cardNode, "Kills"),
		cardLevel = _resolveCardLabel(cardNode, "Level"),
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

-- ────────────────────────────────────────────────────────────────
-- Killer card
-- ────────────────────────────────────────────────────────────────

local function _setCardLabel(label: TextLabel?, text: string)
	if label then
		label.Text = text
	end
end

local function _populateCard(refs: Refs, killer: KillerInfo?)
	if killer then
		_setCardLabel(refs.cardName, "Eliminated by " .. killer.name)
		_setCardLabel(refs.cardKills, tostring(killer.kills) .. " Kills")
		_setCardLabel(refs.cardLevel, tostring(killer.level) .. " Lvl")
	else
		_setCardLabel(refs.cardName, "")
		_setCardLabel(refs.cardKills, "0 Kills")
		_setCardLabel(refs.cardLevel, "0 Lvl")
	end
end

-- ────────────────────────────────────────────────────────────────
-- Killer viewport
-- ────────────────────────────────────────────────────────────────

local function _stripUnsafeDescendants(model: Model)
	for _, desc in model:GetDescendants() do
		-- Estos no aportan nada en un ViewportFrame y pueden errar / pintarse mal:
		-- scripts (no corren), Highlights (replican el rojo enemigo), BillboardGuis
		-- (nombre/HP del personaje original).
		if desc:IsA("Script") or desc:IsA("LocalScript") then
			desc:Destroy()
		elseif desc:IsA("BillboardGui") or desc:IsA("Highlight") then
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

-- ────────────────────────────────────────────────────────────────
-- DeathScreenView
-- ────────────────────────────────────────────────────────────────

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
	-- Tween nativo de la barra de respawn (sustituye el while task.wait(0.03)
	-- que allocaba UDim2.new ~33×/s justo cuando el cliente carga killcam +
	-- viewport). Lo cancelamos en show/hide/Destroy.
	self._countdownTween = nil :: Tween?

	refs.root.Visible = false
	refs.container.BackgroundTransparency = self._baseTransparency
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
	self._refs.container.BackgroundTransparency = self._baseTransparency
	TweenService:Create(self._refs.container, STYLE.showTween, {
		BackgroundTransparency = self._baseTransparency,
	}):Play()

	-- Menu siempre disponible. Respawn arranca DESHABILITADO y se habilita
	-- cuando la barra llega al 100%.
	_setButtonEnabled(self._refs.menuButton, true)
	_setButtonEnabled(self._refs.respawnButton, false)
	self._respawnReady = false

	-- Reset barra
	if self._refs.barFill then
		self._refs.barFill.Size = UDim2.new(0, 0, 1, 0)
	end

	-- Card del killer
	_populateCard(self._refs, killer)

	-- Viewport con clon del killer + animación
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

	-- Animación nativa: un solo Tween lineal de la barra + un task.delay para
	-- habilitar el botón cuando llegue al 100%. El token sirve como cancel:
	-- show()/hide()/Destroy() lo bumpean y la task.delay tardía no hace nada.
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
		BackgroundTransparency = self._baseTransparency,
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
