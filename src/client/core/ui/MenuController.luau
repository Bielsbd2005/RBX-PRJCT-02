--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Packages = ReplicatedStorage:WaitForChild("Packages")

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

local function asTextLabel(inst: Instance?): TextLabel?
	return if inst and inst:IsA("TextLabel") then inst else nil
end

local function asFrame(inst: Instance?): Frame?
	return if inst and inst:IsA("Frame") then inst else nil
end

-- Level/Cash/Rewards/Settings viven bajo Menu.TopFrame. Resolvemos prefiriendo
-- TopFrame y cayendo al hijo directo de Menu, así la GUI funciona con la nueva
-- disposición (agrupada) o con la antigua (plana) sin tocar el código.
local function findMenuChild(menuGui: ScreenGui, name: string): Instance?
	local topFrame = menuGui:FindFirstChild("TopFrame")
	local underTop = topFrame and topFrame:FindFirstChild(name)
	if underTop then
		return underTop
	end
	return menuGui:FindFirstChild(name)
end

-- Estructura del HUD (bajo Menu.TopFrame):
--   TopFrame.Cash.Value       → efectivo
--   TopFrame.Level.Value      → nivel
--   TopFrame.Level.Bar.Fill   → progreso de XP hacia el siguiente nivel
--   TopFrame.Level.Bar.Value  → texto XP "actual/necesaria" (opcional)
local function resolveHudRefs(menuGui: ScreenGui): HudRefs
	local cashNode = findMenuChild(menuGui, "Cash")
	local cashValue = asTextLabel(cashNode and cashNode:FindFirstChild("Value"))

	local levelNode = findMenuChild(menuGui, "Level")
	local level = asTextLabel(levelNode and levelNode:FindFirstChild("Value"))

	local barNode = levelNode and levelNode:FindFirstChild("Bar")
	local barFill = asFrame(barNode and barNode:FindFirstChild("Fill"))
	local barValue = asTextLabel(barNode and barNode:FindFirstChild("Value"))

	return {
		cashValue = cashValue,
		level = level,
		barFill = barFill,
		barValue = barValue,
	}
end

local function updateTopHud(hudRefs: HudRefs, stats: StatsData): ()
	if not hudRefs.cashValue and not hudRefs.level and not hudRefs.barFill and not hudRefs.barValue then
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
end

-- Hover animations específicas por botón. Los listados con liftOffset > 0
-- suben además de crecer; el resto solo escala. Botones no listados conservan
-- su comportamiento por defecto (solo el stroke tween de MenuHover).
local MENU_BUTTON_HOVER_BINDINGS: { { path: { string }, lift: number } } = {
	{ path = { "Settings" }, lift = 0 },
	{ path = { "Rewards" }, lift = 0 },
	{ path = { "PlayBtn" }, lift = 0 },
	{ path = { "Nav", "BattlePass" }, lift = 0 },
	{ path = { "Nav", "Store" }, lift = 0 },
	{ path = { "Nav", "Locker" }, lift = 8 },
}

-- El primer segmento del path se resuelve con findMenuChild (TopFrame-aware, con
-- fallback al hijo directo de Menu); el resto desciende normal. Así Settings/Rewards
-- (ahora bajo TopFrame) y PlayBtn/Nav (directos bajo Menu) se resuelven igual.
local function resolveMenuButton(menuGui: ScreenGui, path: { string }): Instance?
	local node: Instance? = findMenuChild(menuGui, path[1])
	for i = 2, #path do
		if not node then return nil end
		node = node:FindFirstChild(path[i])
	end
	return node
end

local function bindMenuButtonHovers(menuGui: ScreenGui, janitor: any): ()
	for _, binding in MENU_BUTTON_HOVER_BINDINGS do
		local node = resolveMenuButton(menuGui, binding.path)
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

function MenuController:hide(): ()
	self._isHidden = true
	self._animator:hide()
	self:_fireStateChanged()
end

function MenuController:show(): ()
	self._isHidden = false
	self._animator:show()
	self:_fireStateChanged()
end

function MenuController:registerPanel(panel: Instance): ()
	if self._openPanels[panel] then return end
	-- Reaccionar también cuando el panel se abre/cierra (.Enabled/.Visible) para
	-- notificar a los suscriptores de onStateChanged (p. ej. otros paneles).
	local prop = if panel:IsA("ScreenGui") then "Enabled" else "Visible"
	local conn = panel:GetPropertyChangedSignal(prop):Connect(function()
		self:_fireStateChanged()
	end)
	self._openPanels[panel] = conn
	self:_fireStateChanged()
end

function MenuController:unregisterPanel(panel: Instance): ()
	local conn = self._openPanels[panel]
	if typeof(conn) == "RBXScriptConnection" then
		conn:Disconnect()
	end
	self._openPanels[panel] = nil
	self:_fireStateChanged()
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
