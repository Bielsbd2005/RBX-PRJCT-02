--!strict
--[[
	MatchMenu.luau
	Gestión centralizada del menú principal y el label de fase en el botón Play.
]]

local MatchMenu = {}
local UserInputService = game:GetService("UserInputService")

local _menuController: any = nil
local _playerGui: PlayerGui = nil :: any
local _menuGui: ScreenGui = nil :: any
local _shouldKeepHiddenFn: (() -> boolean)? = nil
local _currentPhaseLabel = "DEPLOY"

-- ── Helpers de resolución de Play button ──────────────────────

local function _findPlayButton(menuGui: ScreenGui): GuiButton?
	local bottom = menuGui:FindFirstChild("BottomContainer")
	if not bottom then
		return nil
	end

	local footer = bottom:FindFirstChild("Footer")
	if not footer then
		return nil
	end

	local playNode = footer:FindFirstChild("Play") or footer:FindFirstChild("play")
	if playNode and playNode:IsA("GuiButton") then
		return playNode
	end

	return nil
end

local function _findPlayStatusLabel(playButton: GuiButton): TextLabel?
	local contentNode = playButton:FindFirstChild("Content")
	if contentNode then
		local statusNode = contentNode:FindFirstChild("Status")
		if statusNode and statusNode:IsA("TextLabel") then
			return statusNode
		end

		local recursiveStatusNode = contentNode:FindFirstChild("Status", true)
		if recursiveStatusNode and recursiveStatusNode:IsA("TextLabel") then
			return recursiveStatusNode
		end
	end

	local directStatusNode = playButton:FindFirstChild("Status", true)
	if directStatusNode and directStatusNode:IsA("TextLabel") then
		return directStatusNode
	end

	return nil
end

local function _findPlayPcNode(playButton: GuiButton): GuiObject?
	local contentNode = playButton:FindFirstChild("Content")
	if not contentNode then
		return nil
	end

	local pcNode = contentNode:FindFirstChild("PC")
	if pcNode and pcNode:IsA("GuiObject") then
		return pcNode
	end

	local recursivePcNode = contentNode:FindFirstChild("PC", true)
	if recursivePcNode and recursivePcNode:IsA("GuiObject") then
		return recursivePcNode
	end

	return nil
end

local function _isDesktopPlatform(): boolean
	return UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled
end

local function _applyPlatformVisibilityToButton(button: GuiButton?)
	if not button then
		return
	end

	local pcNode = _findPlayPcNode(button)
	if pcNode then
		pcNode.Visible = _isDesktopPlatform()
	end
end

local function _applyPhaseLabelToButton(button: GuiButton?)
	if not button then
		return
	end

	local statusLabel = _findPlayStatusLabel(button)
	if statusLabel then
		statusLabel.Text = _currentPhaseLabel
	end
end

-- ── API pública ──────────────────────────────────────────────

function MatchMenu.init(
	menuController: any,
	playerGui: PlayerGui,
	menuGui: ScreenGui,
	shouldKeepHiddenFn: () -> boolean
)
	_menuController = menuController
	_playerGui = playerGui
	_menuGui = menuGui
	_shouldKeepHiddenFn = shouldKeepHiddenFn

	menuGui.ResetOnSpawn = false

	local playButton = _findPlayButton(menuGui)
	_applyPhaseLabelToButton(playButton)
	_applyPlatformVisibilityToButton(playButton)
end

function MatchMenu.getCurrentGui(): ScreenGui?
	local current = _playerGui:FindFirstChild("Menu")
	if current and current:IsA("ScreenGui") then
		return current
	end

	if _menuGui and _menuGui.Parent then
		return _menuGui
	end

	return nil
end

function MatchMenu.shouldKeepHidden(): boolean
	if _shouldKeepHiddenFn then
		return _shouldKeepHiddenFn()
	end
	return false
end

function MatchMenu.enforceHidden()
	local currentGui = MatchMenu.getCurrentGui()
	if not currentGui then
		return
	end

	currentGui.ResetOnSpawn = false
	if MatchMenu.shouldKeepHidden() and currentGui.Enabled then
		currentGui.Enabled = false
	end
end

--- Hard-reset: muestra el menú forzosamente con re-check en delay.
function MatchMenu.forceShow()
	local currentGui = MatchMenu.getCurrentGui() or _menuGui
	currentGui.ResetOnSpawn = false
	currentGui.Enabled = true
	_menuController:show()

	task.delay(0.2, function()
		if MatchMenu.shouldKeepHidden() then
			return
		end
		local lateMenu = MatchMenu.getCurrentGui()
		if lateMenu then
			lateMenu.Enabled = true
		end
	end)
end

--- Actualiza el texto de fase en el botón Play ("DEPLOY" / "VOTING" / "ENDING").
function MatchMenu.setPhaseLabel(phase: string)
	_currentPhaseLabel = phase

	local currentGui = MatchMenu.getCurrentGui()
	if currentGui then
		local playButton = _findPlayButton(currentGui)
		_applyPhaseLabelToButton(playButton)
	end
end

--- Aplica el label de fase a un nuevo ScreenGui de menú (para ChildAdded).
function MatchMenu.applyPhaseLabelToNewGui(gui: ScreenGui)
	local playButton = _findPlayButton(gui)
	_applyPhaseLabelToButton(playButton)
	_applyPlatformVisibilityToButton(playButton)
end

--- Detecta si hay algún panel de lobby abierto (Locker, Settings, Store, etc.).
function MatchMenu.hasOpenLobbyPanel(): boolean
	local panelNames = {
		"LockerGui",
		"SettingsGui",
		"Store",
		"Cases",
		"Rewards",
	}

	for _, panelName in panelNames do
		local panel = _playerGui:FindFirstChild(panelName)
		if panel and panel:IsA("ScreenGui") and panel.Enabled then
			return true
		end
	end

	return false
end

--- Devuelve el botón Play del menú actual (para binding externo).
function MatchMenu.getPlayButton(): GuiButton?
	local currentGui = MatchMenu.getCurrentGui()
	if not currentGui then
		return nil
	end
	return _findPlayButton(currentGui)
end

return MatchMenu
