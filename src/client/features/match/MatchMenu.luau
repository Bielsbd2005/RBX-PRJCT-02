--!strict
--[[
	MatchMenu.luau
	Gestión del menú principal y del label de fase en el botón Play.
	Instancia por feature (no singleton) — usar MatchMenu.new(...).
]]

local UserInputService = game:GetService("UserInputService")

local MatchMenu = {}
MatchMenu.__index = MatchMenu

export type MatchMenu = {
	_menuController: any,
	_playerGui: PlayerGui,
	_menuGui: ScreenGui,
	_shouldKeepHiddenFn: () -> boolean,
	_currentPhaseLabel: string,
	getCurrentGui: (self: MatchMenu) -> ScreenGui?,
	shouldKeepHidden: (self: MatchMenu) -> boolean,
	enforceHidden: (self: MatchMenu) -> (),
	forceShow: (self: MatchMenu) -> (),
	setPhaseLabel: (self: MatchMenu, phase: string) -> (),
	applyPhaseLabelToNewGui: (self: MatchMenu, gui: ScreenGui) -> (),
	hasOpenLobbyPanel: (self: MatchMenu) -> boolean,
	getPlayButton: (self: MatchMenu) -> GuiButton?,
}

-- ── Helpers de resolución ──────────────────────────────────────

local function _findPlayButton(menuGui: ScreenGui): GuiButton?
	local playNode = menuGui:FindFirstChild("PlayBtn")
	if playNode and playNode:IsA("GuiButton") then
		return playNode
	end
	return nil
end

local function _findPlayStatusLabel(playButton: GuiButton): TextLabel?
	local indicator = playButton:FindFirstChild("Indicator")
	if not indicator then return nil end

	local statusNode = indicator:FindFirstChild("Status")
	if statusNode and statusNode:IsA("TextLabel") then
		return statusNode
	end
	return nil
end

local function _findPlayPcNode(playButton: GuiButton): GuiObject?
	local indicator = playButton:FindFirstChild("Indicator")
	if not indicator then return nil end

	local pcNode = indicator:FindFirstChild("PC")
	if pcNode and pcNode:IsA("GuiObject") then
		return pcNode
	end
	return nil
end

local function _isDesktopPlatform(): boolean
	return UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled
end

local function _applyPlatformVisibilityToButton(button: GuiButton?)
	if not button then return end
	local pcNode = _findPlayPcNode(button)
	if pcNode then
		pcNode.Visible = _isDesktopPlatform()
	end
end

-- ── API ────────────────────────────────────────────────────────

function MatchMenu.new(
	menuController: any,
	playerGui: PlayerGui,
	menuGui: ScreenGui,
	shouldKeepHiddenFn: () -> boolean
): MatchMenu
	local self = setmetatable({}, MatchMenu) :: any
	self._menuController = menuController
	self._playerGui = playerGui
	self._menuGui = menuGui
	self._shouldKeepHiddenFn = shouldKeepHiddenFn
	self._currentPhaseLabel = "DEPLOY"

	menuGui.ResetOnSpawn = false

	local playButton = _findPlayButton(menuGui)
	self:_applyPhaseLabelToButton(playButton)
	_applyPlatformVisibilityToButton(playButton)

	return self
end

function MatchMenu:_applyPhaseLabelToButton(button: GuiButton?)
	if not button then return end
	local statusLabel = _findPlayStatusLabel(button)
	if statusLabel then
		statusLabel.Text = self._currentPhaseLabel
	end
end

function MatchMenu:getCurrentGui(): ScreenGui?
	local current = self._playerGui:FindFirstChild("Menu")
	if current and current:IsA("ScreenGui") then
		return current
	end

	if self._menuGui and self._menuGui.Parent then
		return self._menuGui
	end

	return nil
end

function MatchMenu:shouldKeepHidden(): boolean
	return self._shouldKeepHiddenFn()
end

function MatchMenu:enforceHidden()
	local currentGui = self:getCurrentGui()
	if not currentGui then return end

	currentGui.ResetOnSpawn = false
	if self:shouldKeepHidden() and currentGui.Enabled then
		currentGui.Enabled = false
	end
end

function MatchMenu:forceShow()
	local currentGui = self:getCurrentGui() or self._menuGui
	currentGui.ResetOnSpawn = false
	currentGui.Enabled = true
	self._menuController:show()

	task.delay(0.2, function()
		if self:shouldKeepHidden() then return end
		local lateMenu = self:getCurrentGui()
		if lateMenu then
			lateMenu.Enabled = true
		end
	end)
end

function MatchMenu:setPhaseLabel(phase: string)
	self._currentPhaseLabel = phase
	local currentGui = self:getCurrentGui()
	if currentGui then
		self:_applyPhaseLabelToButton(_findPlayButton(currentGui))
	end
end

function MatchMenu:applyPhaseLabelToNewGui(gui: ScreenGui)
	local playButton = _findPlayButton(gui)
	self:_applyPhaseLabelToButton(playButton)
	_applyPlatformVisibilityToButton(playButton)
end

function MatchMenu:hasOpenLobbyPanel(): boolean
	if self._menuController and self._menuController.hasOpenPanel then
		return self._menuController:hasOpenPanel()
	end
	return false
end

function MatchMenu:getPlayButton(): GuiButton?
	local currentGui = self:getCurrentGui()
	if not currentGui then return nil end
	return _findPlayButton(currentGui)
end

return MatchMenu
