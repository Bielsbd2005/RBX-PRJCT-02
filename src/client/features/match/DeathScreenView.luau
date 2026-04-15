--!strict

local TweenService = game:GetService("TweenService")

local DeathScreenView = {}
DeathScreenView.__index = DeathScreenView

local STYLE = {
	showTween = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	hideTween = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	visibleTransparency = 0,
	hiddenTransparency = 1,
}

type Refs = {
	root: ScreenGui,
	container: GuiObject,
	menuButton: GuiButton?,
	respawnButton: GuiButton?,
	timerLabel: TextLabel?,
}

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
		timerLabel = if timerNode and timerNode:IsA("TextLabel") then timerNode else nil,
	}
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

	refs.root.Enabled = false
	refs.root.ResetOnSpawn = false
	refs.container.BackgroundTransparency = STYLE.hiddenTransparency

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
end

function DeathScreenView:show(respawnCooldown: number)
	self._countdownToken += 1
	local token = self._countdownToken
	self._refs.root.Enabled = true
	self._refs.container.BackgroundTransparency = STYLE.hiddenTransparency
	TweenService:Create(self._refs.container, STYLE.showTween, {
		BackgroundTransparency = STYLE.visibleTransparency,
	}):Play()

	_setButtonEnabled(self._refs.menuButton, true)
	_setButtonEnabled(self._refs.respawnButton, false)

	task.spawn(function()
		local endAt = time() + math.max(0, respawnCooldown)
		while self._countdownToken == token do
			local left = math.ceil(math.max(0, endAt - time()))
			if self._refs.timerLabel then
				self._refs.timerLabel.Text = tostring(left)
			end

			if left <= 0 then
				_setButtonEnabled(self._refs.respawnButton, true)
				return
			end
			task.wait(0.1)
		end
	end)
end

function DeathScreenView:hide()
	self._countdownToken += 1
	_setButtonEnabled(self._refs.respawnButton, false)
	if self._refs.timerLabel then
		self._refs.timerLabel.Text = "0"
	end

	local tween = TweenService:Create(self._refs.container, STYLE.hideTween, {
		BackgroundTransparency = STYLE.hiddenTransparency,
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
