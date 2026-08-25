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
local BattlePassConfig = require(Shared.constants.BattlePassConfig)

type StatsData = {
	Level: number,
	XP: number,
	XPToNextLevel: number,
	Cash: number,
	-- Opcional: un perfil cargado antes del Reconcile de esta versión puede
	-- no traer el campo todavía.
	Gems: number?,
}

type HudRefs = {
	cashValue: TextLabel?,
	gemsValue: TextLabel?,
	levelCurrent: TextLabel?,
	levelNext: TextLabel?,
	barFill: Frame?,
	famePassSeason: TextLabel?,
	famePassTimer: TextLabel?,
	famePassLevel: TextLabel?,
	famePassBarFill: Frame?,
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

-- Estructura del HUD bajo Menu.Container:
--   Container.Stats.CashFrame.Value   → efectivo actual
--   Container.Stats.GemsFrame.Value   → gems actuales (opcional)
--   Container.TopFrame.Level.Current  → nivel actual
--   Container.TopFrame.Level.Next     → siguiente nivel
--   Container.TopFrame.Level.Bar.Fill → progreso de XP hacia el siguiente nivel
--   Container.FamePass.Season         → nombre de la season
--   Container.FamePass.Timer          → tiempo restante ("Ends in X, Y")
--   Container.FamePass.Level          → nivel en formato "Lv. X"
--   Container.FamePass.Bar.Fill       → progreso de tier del BattlePass
local function resolveHudRefs(menuGui: ScreenGui): HudRefs
	local container = menuGui:FindFirstChild("Container")
	local topFrame = container and container:FindFirstChild("TopFrame")
	local statsNode = container and container:FindFirstChild("Stats")
	local famePassNode = container and container:FindFirstChild("FamePass")

	-- 1. Cash
	local cashFrame = statsNode and statsNode:FindFirstChild("CashFrame")
	local cashValue = asTextLabel(cashFrame and cashFrame:FindFirstChild("Value"))

	-- 1b. Gems (opcional: la GUI puede no tener todavía el GemsFrame).
	local gemsFrame = statsNode and statsNode:FindFirstChild("GemsFrame")
	local gemsValue = asTextLabel(gemsFrame and gemsFrame:FindFirstChild("Value"))

	-- 2. Level
	local levelNode = topFrame and topFrame:FindFirstChild("Level")
	local levelCurrent = asTextLabel(levelNode and levelNode:FindFirstChild("Current"))
	local levelNext = asTextLabel(levelNode and levelNode:FindFirstChild("Next"))
	local barNode = levelNode and levelNode:FindFirstChild("Bar")
	local barFill = asFrame(barNode and barNode:FindFirstChild("Fill"))

	-- 3. FamePass
	local famePassSeason = asTextLabel(famePassNode and famePassNode:FindFirstChild("Season"))
	local famePassTimer = asTextLabel(famePassNode and famePassNode:FindFirstChild("Timer"))
	local famePassLevel = asTextLabel(famePassNode and famePassNode:FindFirstChild("Level"))
	local famePassBar = famePassNode and famePassNode:FindFirstChild("Bar")
	local famePassBarFill = asFrame(famePassBar and famePassBar:FindFirstChild("Fill"))

	return {
		cashValue = cashValue,
		gemsValue = gemsValue,
		levelCurrent = levelCurrent,
		levelNext = levelNext,
		barFill = barFill,
		famePassSeason = famePassSeason,
		famePassTimer = famePassTimer,
		famePassLevel = famePassLevel,
		famePassBarFill = famePassBarFill,
	}
end

local function updateTopHud(hudRefs: HudRefs, stats: StatsData): ()
	if hudRefs.cashValue then
		setText(hudRefs.cashValue, UIUtils.formatCashAmount(stats.Cash))
	end

	if hudRefs.gemsValue then
		-- `or 0` cubre el perfil que aún no pasó por Reconcile en esta sesión.
		setText(hudRefs.gemsValue, UIUtils.formatCashAmount(stats.Gems or 0))
	end

	local currentXP = math.max(0, math.floor(stats.XP))
	local xpToNext = math.max(0, math.floor(stats.XPToNextLevel))

	if hudRefs.barFill then
		local ratio = if xpToNext > 0 then math.clamp(currentXP / xpToNext, 0, 1) else 0
		hudRefs.barFill.Size = UDim2.new(ratio, 0, 1, 0)
	end

	setText(hudRefs.levelCurrent, tostring(stats.Level))
	setText(hudRefs.levelNext, tostring(stats.Level + 1))
end

local function updateFamePassHud(hudRefs: HudRefs, bpState: any): ()
	local season = BattlePassConfig.GetActiveSeason()
	local maxTier = BattlePassConfig.GetMaxTier(season)

	setText(hudRefs.famePassSeason, season.Name)

	if hudRefs.famePassTimer then
		if season.EndsAt <= 0 then
			hudRefs.famePassTimer.Visible = false
		else
			local remaining = season.EndsAt - os.time()
			local text = UIUtils.formatTimeLeft(remaining)
			if text == "" then
				hudRefs.famePassTimer.Visible = false
			else
				hudRefs.famePassTimer.Visible = true
				hudRefs.famePassTimer.Text = text
			end
		end
	end

	local currentTier = if bpState and type(bpState.CurrentTier) == "number"
		then math.floor(bpState.CurrentTier)
		else 1
	local displayTier = math.clamp(currentTier, 1, maxTier)
	setText(hudRefs.famePassLevel, "Lv. " .. tostring(displayTier))

	if hudRefs.famePassBarFill then
		if currentTier > maxTier then
			hudRefs.famePassBarFill.Size = UDim2.new(1, 0, 1, 0)
		else
			local tierDef = BattlePassConfig.GetTier(season, displayTier)
			local xpRequired = if tierDef then tierDef.XPRequired else 0
			local currentXP = if bpState and type(bpState.XP) == "number" then bpState.XP else 0
			local ratio = if xpRequired > 0 then math.clamp(currentXP / xpRequired, 0, 1) else 0
			hudRefs.famePassBarFill.Size = UDim2.new(ratio, 0, 1, 0)
		end
	end
end

-- Hover animations específicas por botón.
local MENU_BUTTON_HOVER_BINDINGS: { { path: { string }, lift: number } } = {
	{ path = { "Container", "TopFrame", "RightContainer", "Settings" }, lift = 0 },
	{ path = { "Container", "TopFrame", "RightContainer", "Rewards" }, lift = 0 },
	{ path = { "Container", "PlayBtn" }, lift = 0 },
	{ path = { "Container", "Store" }, lift = 0 },
	{ path = { "Container", "Locker" }, lift = 8 },
	{ path = { "Container", "FamePass" }, lift = 0 },
}

local function resolveMenuButton(menuGui: ScreenGui, path: { string }): Instance?
	local node: Instance? = menuGui
	for _, segment in path do
		if not node then return nil end
		node = node:FindFirstChild(segment)
	end
	return node
end

local function bindMenuButtonHovers(menuGui: ScreenGui, janitor: any): ()
	local boundButtons: { [Instance]: boolean } = {}
	for _, binding in MENU_BUTTON_HOVER_BINDINGS do
		local node = resolveMenuButton(menuGui, binding.path)
		if node and node:IsA("GuiButton") and not boundButtons[node] then
			boundButtons[node] = true
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

		local function updateBpHudFromState()
			local bpState = Fusion.peek(DataController.BattlePass)
			updateFamePassHud(self._hudRefs, bpState)
		end

		local statsObserver = self._fusionScope:Observer(DataController.Stats)
		self._janitor:Add(statsObserver:onBind(updateHudFromState), true)

		local bpObserver = self._fusionScope:Observer(DataController.BattlePass)
		self._janitor:Add(bpObserver:onBind(updateBpHudFromState), true)

		-- Actualización periódica del timer de temporada del FamePass (mismo esquema de UserInterface.BattlePass.Main.Timer)
		if self._hudRefs.famePassTimer then
			local timerRunning = true
			task.spawn(function()
				while timerRunning do
					local season = BattlePassConfig.GetActiveSeason()
					if season.EndsAt <= 0 then
						if self._hudRefs.famePassTimer then
							self._hudRefs.famePassTimer.Visible = false
						end
						task.wait(3600)
					else
						local remaining = season.EndsAt - os.time()
						local text = UIUtils.formatTimeLeft(remaining)
						if self._hudRefs.famePassTimer then
							if text == "" then
								self._hudRefs.famePassTimer.Visible = false
							else
								self._hudRefs.famePassTimer.Visible = true
								self._hudRefs.famePassTimer.Text = text
							end
						end
						local pollInterval = if remaining > 3600 then 3600 else 60
						task.wait(pollInterval)
					end
				end
			end)
			self._janitor:Add(function()
				timerRunning = false
			end, true)
		end
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
