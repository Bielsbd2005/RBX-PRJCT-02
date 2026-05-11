--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local MenuAnimator = require(script.Parent.animators.MenuAnimator)
local MenuHover = require(script.Parent.MenuHover)
local InteractiveScaleTween = require(script.Parent.animators.InteractiveScaleTween)
local UITheme = require(script.Parent.UITheme)
local UIUtils = require(script.Parent.UIUtils)
local DataController = require(script.Parent.Parent.data.DataController)
type StatsData = {
	Level: number,
	XP: number,
	XPToNextLevel: number,
	Cash: number,
}

type HudRefs = {
	cashValue: TextLabel?,
	level: TextLabel?,
	next: TextLabel?,
	barFill: Frame?,
	barValue: TextLabel?,
}

export type MenuController = {
	_gui: ScreenGui,
	_animator: any,
	_hover: any,
	_janitor: any,
	_fusionScope: any,
	_hudRefs: HudRefs,
	_openPanels: { [Instance]: boolean },
	getGui: (self: MenuController) -> ScreenGui,
	hide: (self: MenuController) -> (),
	show: (self: MenuController) -> (),
	isHidden: (self: MenuController) -> boolean,
	registerPanel: (self: MenuController, panel: Instance) -> (),
	unregisterPanel: (self: MenuController, panel: Instance) -> (),
	hasOpenPanel: (self: MenuController) -> boolean,
	onStateChanged: (self: MenuController, callback: () -> ()) -> (() -> ()),
	Destroy: (self: MenuController) -> (),
}

local MenuController = {}
MenuController.__index = MenuController

local function setText(label: TextLabel?, value: string): ()
	if label then
		label.Text = value
	end
end

local function findDescendantByName(root: Instance, names: { string }): Instance?
	for _, descendant in ipairs(root:GetDescendants()) do
		for _, candidate in ipairs(names) do
			if descendant.Name == candidate then
				return descendant
			end
		end
	end

	return nil
end

local function findTextLabel(root: Instance, names: { string }): TextLabel?
	local node = findDescendantByName(root, names)
	if node and node:IsA("TextLabel") then
		return node
	end

	return nil
end

local function resolveHudRefs(menuGui: ScreenGui): HudRefs
	local top = menuGui:FindFirstChild("Top")
	if not top then
		return {
			cashValue = nil,
			level = nil,
			next = nil,
			barFill = nil,
			barValue = nil,
		}
	end

	local cashNode = top:FindFirstChild("Cash")
	local cashValue = if cashNode and cashNode:FindFirstChild("Value") then (if cashNode.Value:IsA("TextLabel") then cashNode.Value else nil) else nil

	local levelNode = top:FindFirstChild("Level")
	local level = if levelNode and levelNode:IsA("TextLabel") then levelNode else nil

	local nextNode = top:FindFirstChild("Next")
	local next = if nextNode and nextNode:IsA("TextLabel") then nextNode else nil

	local barNode = top:FindFirstChild("Bar")
	local barFill = if barNode then (if barNode:FindFirstChild("Fill") then (if barNode.Fill:IsA("Frame") then barNode.Fill else nil) else nil) else nil
	local barValueNode = if barNode then barNode:FindFirstChild("Value") else nil
	local barValue = if barValueNode and barValueNode:IsA("TextLabel") then barValueNode else nil

	return {
		cashValue = cashValue,
		level = level,
		next = next,
		barFill = barFill,
		barValue = barValue,
	}
end

local function updateTopHud(hudRefs: HudRefs, stats: StatsData): ()
	if not hudRefs.cashValue and not hudRefs.level and not hudRefs.next and not hudRefs.barFill and not hudRefs.barValue then
		return
	end

	setText(hudRefs.cashValue, UIUtils.formatCashAmount(stats.Cash))

	local currentXP = math.max(0, math.floor(stats.XP))
	local xpToNext = math.max(0, math.floor(stats.XPToNextLevel))

	if hudRefs.barFill then
		local ratio = if xpToNext > 0 then math.clamp(currentXP / xpToNext, 0, 1) else 0
		hudRefs.barFill.Size = UDim2.new(ratio, 0, 1, 0)
	end

	setText(hudRefs.barValue, string.format("%d/%d", currentXP, xpToNext))
	setText(hudRefs.level, "Lvl " .. tostring(stats.Level))
	setText(hudRefs.next, "Lvl " .. tostring(stats.Level + 1))
end

-- Hover animations específicas por botón. Los listados con liftOffset > 0
-- suben además de crecer; el resto solo escala. Botones no listados conservan
-- su comportamiento por defecto (solo el stroke tween de MenuHover).
local MENU_BUTTON_HOVER_BINDINGS: { { path: { string }, lift: number } } = {
	{ path = { "Top", "settings" }, lift = 0 },
	{ path = { "Top", "rewards" }, lift = 0 },
	{ path = { "Bottom", "Play" }, lift = 0 },
	{ path = { "Bottom", "BattlePass" }, lift = 0 },
	{ path = { "Bottom", "Store" }, lift = 8 },
	{ path = { "Bottom", "Locker" }, lift = 8 },
}

local function resolveDescendant(root: Instance, path: { string }): Instance?
	local node: Instance? = root
	for _, name in path do
		if not node then return nil end
		node = node:FindFirstChild(name)
	end
	return node
end

local function bindMenuButtonHovers(menuGui: ScreenGui, janitor: any): ()
	for _, binding in MENU_BUTTON_HOVER_BINDINGS do
		local node = resolveDescendant(menuGui, binding.path)
		if node and node:IsA("GuiButton") then
			InteractiveScaleTween.bindButton(node, janitor, {
				hoverScale = UITheme.ButtonHoverScale,
				clickScale = UITheme.ButtonClickScale,
				liftOffset = binding.lift,
			})
		end
	end
end

function MenuController.new(): MenuController
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local menuGui = playerGui:WaitForChild("Menu") :: ScreenGui
	menuGui.ResetOnSpawn = false

	local starterMenu = StarterGui:FindFirstChild("Menu")
	if starterMenu and starterMenu:IsA("ScreenGui") then
		starterMenu.ResetOnSpawn = false
	end

	local self = setmetatable({}, MenuController) :: any

	self._gui = menuGui
	self._janitor = Janitor.new()
	self._fusionScope = Fusion.scoped(Fusion)
	self._animator = MenuAnimator.new(menuGui)
	self._hover = MenuHover.new(menuGui)
	self._hudRefs = resolveHudRefs(menuGui)
	self._openPanels = {}
	self._stateChangeListeners = {} :: { () -> () }

	bindMenuButtonHovers(menuGui, self._janitor)

	local mapVoteNode = menuGui:FindFirstChild("MapVote")
	self._mapVote = if mapVoteNode and mapVoteNode:IsA("GuiObject") then mapVoteNode else nil

	self._janitor:Add(self._animator, "Destroy")
	self._janitor:Add(self._hover, "Destroy")
	self._janitor:Add(function()
		Fusion.doCleanup(self._fusionScope)
	end, true)

	DataController:WhenReady():andThen(function()
		local function updateHudFromState()
			local stats = Fusion.peek(DataController.Stats) :: StatsData
			updateTopHud(self._hudRefs, stats)
		end

		local statsObserver = self._fusionScope:Observer(DataController.Stats)
		self._janitor:Add(statsObserver:onBind(updateHudFromState), true)
	end)

	return self
end

function MenuController:getGui(): ScreenGui
	return self._gui
end

function MenuController:_applyMapVoteVisibility(): ()
	if self._mapVote then
		-- MapVote solo visible cuando: la votación está activa, el menú no está
		-- oculto (no estamos dentro del match), y no hay otro panel abierto encima
		-- (locker, settings, etc.).
		local shouldShow = self._mapVoteShouldBeVisible == true
			and not self._isHidden
			and not self:hasOpenPanel()
		self._mapVote.Visible = shouldShow
	end

	self:_fireStateChanged()
end

function MenuController:_fireStateChanged(): ()
	-- Snapshot defensivo: una callback puede unsubscribirse durante su propia
	-- ejecución (mutaría la lista mientras iteramos).
	local snapshot = table.clone(self._stateChangeListeners)
	for _, fn in snapshot do
		local ok, err = pcall(fn)
		if not ok then
			warn("[MenuController] state listener error:", err)
		end
	end
end

function MenuController:onStateChanged(callback: () -> ()): (() -> ())
	table.insert(self._stateChangeListeners, callback)
	return function()
		for i, fn in self._stateChangeListeners do
			if fn == callback then
				table.remove(self._stateChangeListeners, i)
				return
			end
		end
	end
end

function MenuController:isHidden(): boolean
	return self._isHidden == true
end

function MenuController:setMapVoteVisible(visible: boolean): ()
	self._mapVoteShouldBeVisible = visible
	self:_applyMapVoteVisibility()
end

function MenuController:hide(): ()
	self._isHidden = true
	self._animator:hide()
	self:_applyMapVoteVisibility()
end

function MenuController:show(): ()
	self._isHidden = false
	self._animator:show()
	self:_applyMapVoteVisibility()
end

function MenuController:registerPanel(panel: Instance): ()
	if self._openPanels[panel] then return end
	-- Reaccionar también cuando el panel se abre/cierra (.Enabled/.Visible).
	-- Sin esto, abrir el locker después de que arranque la votación no
	-- recalculaba la visibilidad de MapVote.
	local prop = if panel:IsA("ScreenGui") then "Enabled" else "Visible"
	local conn = panel:GetPropertyChangedSignal(prop):Connect(function()
		self:_applyMapVoteVisibility()
	end)
	self._openPanels[panel] = conn
	self:_applyMapVoteVisibility()
end

function MenuController:unregisterPanel(panel: Instance): ()
	local conn = self._openPanels[panel]
	if typeof(conn) == "RBXScriptConnection" then
		conn:Disconnect()
	end
	self._openPanels[panel] = nil
	self:_applyMapVoteVisibility()
end

function MenuController:hasOpenPanel(): boolean
	for panel in self._openPanels do
		if panel:IsA("ScreenGui") and panel.Enabled then
			return true
		elseif panel:IsA("GuiObject") and panel.Visible then
			return true
		end
	end
	return false
end

function MenuController:Destroy(): ()
	for _, conn in self._openPanels do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
	end
	table.clear(self._openPanels)
	table.clear(self._stateChangeListeners)
	self._janitor:Destroy()
end

return MenuController
