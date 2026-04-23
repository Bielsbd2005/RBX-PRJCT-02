--!strict

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local DeathScreenView = {}
DeathScreenView.__index = DeathScreenView

local STYLE = {
	showTween = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	hideTween = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
}

type Refs = {
	root: ScreenGui,
	container: GuiObject,
	menuButton: GuiButton?,
	respawnButton: GuiButton?,
	menuPcLabel: TextLabel?,
	respawnPcLabel: TextLabel?,
	timerLabel: TextLabel?,
	barFill: GuiObject?,
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

local function _resolveRefs(gui: ScreenGui): Refs?
	local containerNode = gui:FindFirstChild("Container")
	if not containerNode or not containerNode:IsA("GuiObject") then
		return nil
	end

	local menuNode = containerNode:FindFirstChild("Menu")
	local respawnNode = containerNode:FindFirstChild("Respawn")
	local timerNode = containerNode:FindFirstChild("Timer")

	return {
		root = gui,
		container = containerNode,
		menuButton = if menuNode and menuNode:IsA("GuiButton") then menuNode else nil,
		respawnButton = if respawnNode and respawnNode:IsA("GuiButton") then respawnNode else nil,
		menuPcLabel = _resolvePcLabel(menuNode),
		respawnPcLabel = _resolvePcLabel(respawnNode),
		timerLabel = if timerNode and timerNode:IsA("TextLabel") then timerNode else nil,
		barFill = _resolveBarFill(respawnNode),
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

function DeathScreenView.new(gui: ScreenGui): any
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

	refs.root.Enabled = false
	refs.root.ResetOnSpawn = false
	refs.container.BackgroundTransparency = self._baseTransparency
	_setPcHintsVisible(refs)

	return self
end

function DeathScreenView:bind(onRespawn: () -> (), onMenu: () -> ())
	self._onRespawn = onRespawn
	self._onMenu = onMenu

	if self._refs.respawnButton then
		table.insert(self._connections, self._refs.respawnButton.MouseButton1Click:Connect(function()
			if self._onRespawn then
				self._onRespawn()
			end
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
		if gameProcessed or not self._refs.root.Enabled then
			return
		end

		if input.KeyCode == Enum.KeyCode.M then
			if self._onMenu then
				self._onMenu()
			end
			return
		end

		if input.KeyCode == Enum.KeyCode.Space then
			if self._onRespawn then
				self._onRespawn()
			end
		end
	end))
end

function DeathScreenView:show(respawnCooldown: number)
	self._countdownToken += 1
	local token = self._countdownToken
	_setPcHintsVisible(self._refs)
	self._refs.root.Enabled = true
	self._refs.container.BackgroundTransparency = self._baseTransparency
	TweenService:Create(self._refs.container, STYLE.showTween, {
		BackgroundTransparency = self._baseTransparency,
	}):Play()

	_setButtonEnabled(self._refs.menuButton, true)
	-- Respawn button enabled immediately so the player can skip the killcam at any time.
	_setButtonEnabled(self._refs.respawnButton, true)

	-- Reset fill bar to 0
	if self._refs.barFill then
		self._refs.barFill.Size = UDim2.new(0, 0, 1, 0)
	end

	task.spawn(function()
		local duration = math.max(0, respawnCooldown)
		local startAt = time()
		local endAt = startAt + duration

		while self._countdownToken == token do
			local elapsed = time() - startAt
			local progress = math.clamp(if duration > 0 then elapsed / duration else 1, 0, 1)

			-- Update fill bar
			if self._refs.barFill then
				self._refs.barFill.Size = UDim2.new(progress, 0, 1, 0)
			end

			-- Update timer text
			if self._refs.timerLabel then
				local left = math.ceil(math.max(0, endAt - time()))
				self._refs.timerLabel.Text = tostring(left)
			end

			-- Auto-respawn when timer completes
			if progress >= 1 then
				if self._refs.barFill then
					self._refs.barFill.Size = UDim2.new(1, 0, 1, 0)
				end
				if self._refs.timerLabel then
					self._refs.timerLabel.Text = "0"
				end
				-- Trigger auto-respawn
				if self._countdownToken == token and self._onRespawn then
					self._onRespawn()
				end
				return
			end

			task.wait(0.03)
		end
	end)
end

function DeathScreenView:hide()
	self._countdownToken += 1
	_setButtonEnabled(self._refs.respawnButton, false)
	if self._refs.timerLabel then
		self._refs.timerLabel.Text = "0"
	end
	if self._refs.barFill then
		self._refs.barFill.Size = UDim2.new(0, 0, 1, 0)
	end

	local tween = TweenService:Create(self._refs.container, STYLE.hideTween, {
		BackgroundTransparency = self._baseTransparency,
	})
	tween:Play()
	task.delay(STYLE.hideTween.Time, function()
		self._refs.root.Enabled = false
	end)
end

function DeathScreenView:Destroy()
	self._countdownToken += 1
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._refs.root.Enabled = false
end

return DeathScreenView
