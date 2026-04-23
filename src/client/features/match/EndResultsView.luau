--!strict
--[[
	EndResultsView.luau
	Pantalla de resultados final con tres fases animadas:

	  Fase 1 (t = 0):
	    ResultsScreen.Canvas.Result
	      .UP      → slide desde arriba
	      .Bottom  → slide desde abajo
	      .Value   → fade con texto VICTORY / DEFEAT

	  Fase 2 (t = RESULT_PHASE_DURATION):
	    ResultsScreen.Canvas.Summary (aparece)
	      .Main.Result          → color de victoria/derrota
	      .Main.Container.ScoreA.Value / ScoreB.Value
	      .Main.Container.ListA.PlayerList
	      .Main.Container.ListB.PlayerList  (PlayerLabel clonados)
	      .UIStroke              → color de victoria/derrota

	  Fase 3 (tras Summary):
	    ResultsScreen.Canvas.Rewards → ítems aparecen uno a uno con tween
]]

local TweenService = game:GetService("TweenService")
local Players      = game:GetService("Players")
local Lighting     = game:GetService("Lighting")

-- ── Colores ──────────────────────────────────────────────────
local VICTORY_COLOR   = Color3.fromRGB(0,   152, 246)
local DEFEAT_COLOR    = Color3.fromRGB(245,  39,  87)

local GRADIENT_TEAM_A = { Color3.fromRGB(66,  143, 233), Color3.fromRGB(95,  205, 246) }
local GRADIENT_TEAM_B = { Color3.fromRGB(204,  68, 103), Color3.fromRGB(215, 107, 103) }
local GRADIENT_LOCAL  = { Color3.fromRGB(220, 153,  53), Color3.fromRGB(241, 224,  74) }

-- ── Timing ───────────────────────────────────────────────────
local REWARD_STAGGER        = 0.25  -- segundos entre cada ítem de Rewards
local SUMMARY_TO_REWARDS_DELAY = 0.5

-- ── TweenInfos ───────────────────────────────────────────────
local TWEEN_SLIDE  = TweenInfo.new(0.5,  Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local TWEEN_VALUE  = TweenInfo.new(0.35, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TWEEN_REWARD = TweenInfo.new(0.55, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local TWEEN_HIDE   = TweenInfo.new(0.25, Enum.EasingStyle.Quad,  Enum.EasingDirection.In)
local TWEEN_SUMMARY_DROP = TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- ── Tipos ────────────────────────────────────────────────────
export type PlayerEntry = {
	userId:  number,
	name:    string,
	team:    "A" | "B",
	kills:   number,
	deaths:  number,
	level:   number,
}

export type ShowData = {
	winnerTeam: string,        -- "A" | "B" | ""
	localTeam:  string,        -- "A" | "B" | ""
	scoreA:     number,
	scoreB:     number,
	duration:   number,
	players:    { PlayerEntry },
}

-- ── Helpers ──────────────────────────────────────────────────
local function _child(parent: Instance?, name: string): Instance?
	if not parent then return nil end
	return parent:FindFirstChild(name)
end

local function _guiChild(parent: Instance?, name: string): GuiObject?
	local node = _child(parent, name)
	return if node and node:IsA("GuiObject") then node else nil
end

local function _label(parent: Instance?, name: string): TextLabel?
	local node = _child(parent, name)
	return if node and node:IsA("TextLabel") then node else nil
end

-- Aplica color a BackgroundColor3, TextColor3 o UIStroke.Color según el tipo.
local function _applyColor(obj: Instance?, color: Color3)
	if not obj then return end
	if obj:IsA("UIStroke") then
		(obj :: UIStroke).Color = color
	elseif obj:IsA("TextLabel") or obj:IsA("TextButton") then
		(obj :: TextLabel).TextColor3 = color
	elseif obj:IsA("GuiObject") then
		(obj :: GuiObject).BackgroundColor3 = color
	end
end

-- Intenta hacer tween de GroupTransparency (CanvasGroup); si falla, solo muestra.
local function _tweenGroupIn(obj: GuiObject, tweenInfo: TweenInfo)
	obj.Visible = true
	pcall(function()
		(obj :: any).GroupTransparency = 1
		TweenService:Create(obj, tweenInfo, { GroupTransparency = 0 }):Play()
	end)
end

local function _tweenSummaryDropIn(obj: GuiObject)
	local targetPos = obj.Position
	obj.Visible = true
	obj.Position = UDim2.new(targetPos.X.Scale, targetPos.X.Offset, targetPos.Y.Scale - 1, targetPos.Y.Offset)

	pcall(function()
		(obj :: any).GroupTransparency = 1
	end)

	TweenService:Create(obj, TWEEN_SUMMARY_DROP, {
		Position = targetPos,
	}):Play()

	pcall(function()
		TweenService:Create(obj, TWEEN_SUMMARY_DROP, { GroupTransparency = 0 }):Play()
	end)
end

-- Aplica o crea UIGradient en frame.
local function _setGradient(frame: GuiObject, colorA: Color3, colorB: Color3)
	local gradient = frame:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, colorA),
		ColorSequenceKeypoint.new(1, colorB),
	})
	gradient.Rotation = 90
	gradient.Parent = frame
end

local function _setResultsBlurEnabled(enabled: boolean)
	local blur = Lighting:FindFirstChild("Blur")
	if blur and blur:IsA("BlurEffect") then
		blur.Enabled = enabled
	end
end

-- Localiza el Canvas dentro del ScreenGui.
-- Orden: 1) Canvas hijo directo del ScreenGui  2) Canvas dentro de ResultsScreen  3) Canvas en cualquier descendiente
local function _resolveCanvas(gui: ScreenGui): GuiObject?
	-- 1. Canvas es hijo directo del ScreenGui (el ScreenGui se llama ResultsScreen)
	local direct = gui:FindFirstChild("Canvas")
	if direct and direct:IsA("GuiObject") then
		return direct
	end

	-- 2. Canvas está dentro de un Frame hijo llamado ResultsScreen
	local rs = gui:FindFirstChild("ResultsScreen")
	if rs and rs:IsA("GuiObject") then
		local canvas = rs:FindFirstChild("Canvas")
		if canvas and canvas:IsA("GuiObject") then
			return canvas
		end
	end

	-- 3. Búsqueda recursiva como último recurso
	local deepCanvas = gui:FindFirstChild("Canvas", true)
	return if deepCanvas and deepCanvas:IsA("GuiObject") then deepCanvas else nil
end

-- ── Fase 1: Result ────────────────────────────────────────────
local function _playResultPhase(canvas: GuiObject, resultColor: Color3, isVictory: boolean)
	local result = _guiChild(canvas, "Result")
	if not result then return end

	result.Visible = true

	local up     = _guiChild(result, "Up")
	local bottom = _guiChild(result, "Bottom")
	local value  = _label(result, "Value")

	-- Color
	_applyColor(up,     resultColor)
	_applyColor(bottom, resultColor)
	if value then
		value.TextColor3 = resultColor
		value.Text = if isVictory then "VICTORY" else "DEFEAT"
	end

	if up     then up.Visible     = true end
	if bottom then bottom.Visible = true end
	if value  then value.TextTransparency = 0 end
end

-- ── Fase 2: Summary ───────────────────────────────────────────
local function _populateList(
	listNode:    GuiObject?,
	entries:     { PlayerEntry },
	teamSide:    "A" | "B",
	localUserId: number
)
	if not listNode then return end

	-- Buscar template PlayerLabel
	local template: Instance? = listNode:FindFirstChild("PlayerLabel")
	if not (template and template:IsA("GuiObject")) then
		for _, child in listNode:GetChildren() do
			if child:IsA("Frame") then
				template = child
				break
			end
		end
	end
	if not template then return end

	template.Visible = false

	-- Limpiar clones previos
	for _, child in listNode:GetChildren() do
		if child ~= template and child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	-- Filtrar y ordenar por kills
	local filtered: { PlayerEntry } = {}
	for _, entry in entries do
		if entry.team == teamSide then
			table.insert(filtered, entry)
		end
	end
	table.sort(filtered, function(a, b)
		return a.kills > b.kills
	end)

	for _, entry in filtered do
		local clone = (template :: GuiObject):Clone()
		clone.Name    = "PlayerLabel_" .. entry.userId
		clone.Visible = true

		local levelLabel  = _label(clone, "Level")
		local nameLabel   = _label(clone, "Name")
		local killsLabel  = _label(clone, "Kills")
		local deathsLabel = _label(clone, "Deaths")

		if levelLabel  then levelLabel.Text  = tostring(entry.level)  end
		if nameLabel   then nameLabel.Text   = entry.name             end
		if killsLabel  then killsLabel.Text  = tostring(entry.kills)  end
		if deathsLabel then deathsLabel.Text = tostring(entry.deaths) end

		-- Gradiente según equipo / jugador local
		local gradA: Color3
		local gradB: Color3
		if entry.userId == localUserId then
			gradA, gradB = GRADIENT_LOCAL[1],  GRADIENT_LOCAL[2]
		elseif teamSide == "A" then
			gradA, gradB = GRADIENT_TEAM_A[1], GRADIENT_TEAM_A[2]
		else
			gradA, gradB = GRADIENT_TEAM_B[1], GRADIENT_TEAM_B[2]
		end
		_setGradient(clone, gradA, gradB)

		clone.Parent = listNode
	end
end

local function _playSummaryPhase(
	canvas:      GuiObject,
	resultColor: Color3,
	isVictory:   boolean,
	scoreA:      number,
	scoreB:      number,
	players:     { PlayerEntry },
	localUserId: number
)
	local summary = _guiChild(canvas, "Summary")
	if not summary then return end

	-- Color y texto de Summary.Main.Result
	local main       = _guiChild(summary, "Main")
	local mainResult = _child(main, "Result")
	if mainResult then
		local resultText = if isVictory then "VICTORY" else "DEFEAT"
		if mainResult:IsA("TextLabel") then
			local lbl = mainResult :: TextLabel
			lbl.TextColor3 = resultColor
			lbl.Text = resultText
		elseif mainResult:IsA("GuiObject") then
			local gui = mainResult :: GuiObject
			gui.BackgroundColor3 = resultColor
		end
	end

	-- UIStroke bajo Summary.Main.Container
	local container = _guiChild(main, "Container")
	local uiStroke  = container and container:FindFirstChildOfClass("UIStroke")
	_applyColor(uiStroke, resultColor)

	-- Scores
	local scoreALabel = _label(_guiChild(container, "ScoreA"), "Value")
	local scoreBLabel = _label(_guiChild(container, "ScoreB"), "Value")
	if scoreALabel then scoreALabel.Text = tostring(math.max(0, scoreA)) end
	if scoreBLabel then scoreBLabel.Text = tostring(math.max(0, scoreB)) end

	-- Listas de jugadores
	local listANode = _guiChild(_guiChild(container, "ListA"), "PlayerList")
		or _guiChild(container, "ListA")
	local listBNode = _guiChild(_guiChild(container, "ListB"), "PlayerList")
		or _guiChild(container, "ListB")

	_populateList(listANode, players, "A", localUserId)
	_populateList(listBNode, players, "B", localUserId)

	summary.Visible = true
	if main then
		_tweenSummaryDropIn(main)
	else
		_tweenSummaryDropIn(summary)
	end
end

-- ── Fase 3: Rewards ───────────────────────────────────────────
-- Devuelve el tiempo total de animación de los ítems.
local function _playRewardsPhase(canvas: GuiObject): number
	local rewards = _guiChild(canvas, "Rewards")
	if not rewards then return 0 end

	local items: { GuiObject } = {}
	for _, child in rewards:GetChildren() do
		if child:IsA("GuiObject") then
			table.insert(items, child)
		end
	end

	-- Ordenar por LayoutOrder
	table.sort(items, function(a, b)
		return (a :: any).LayoutOrder < (b :: any).LayoutOrder
	end)

	-- Ocultar todos primero
	for _, item in items do
		item.Visible = false
	end

	rewards.Visible = true

	for i, item in items do
		local targetSize = item.Size
		item.Size = UDim2.new(
			targetSize.X.Scale, targetSize.X.Offset,
			0, 0
		)
		task.delay((i - 1) * REWARD_STAGGER, function()
			item.Visible = true
			TweenService:Create(item, TWEEN_REWARD, { Size = targetSize }):Play()
		end)
	end

	return #items * REWARD_STAGGER + TWEEN_REWARD.Time
end

-- ── Módulo ────────────────────────────────────────────────────
local EndResultsView = {}
EndResultsView.__index = EndResultsView

function EndResultsView.new(gui: ScreenGui): any
	local canvas = _resolveCanvas(gui)
	if not canvas then
		return nil
	end

	local self = setmetatable({}, EndResultsView)
	self._gui    = gui
	self._canvas = canvas
	self._token  = 0
	self._onFinished = nil :: (() -> ())?
	self._closeBtnConnection = nil :: RBXScriptConnection?

	gui.Enabled      = false
	gui.ResetOnSpawn = false

	-- Ocultar paneles al inicio
	local resultPanel  = _guiChild(canvas, "Result")
	local summaryPanel = _guiChild(canvas, "Summary")
	local rewardsPanel = _guiChild(canvas, "Rewards")
	if resultPanel  then resultPanel.Visible  = false end
	if summaryPanel then summaryPanel.Visible = false end
	if rewardsPanel then rewardsPanel.Visible = false end

	-- Vincular CloseBtn dentro de Canvas
	local closeBtn = canvas:FindFirstChild("CloseBtn")
	if closeBtn and closeBtn:IsA("GuiButton") then
		self._closeBtnConnection = closeBtn.MouseButton1Click:Connect(function()
			if self._onFinished then
				self._onFinished()
			end
		end)
	end

	return self
end

function EndResultsView:show(data: ShowData, onFinished: (() -> ())?)
	self._token += 1
	local token = self._token
	self._onFinished = onFinished

	local isVictory   = data.winnerTeam ~= "" and data.winnerTeam == data.localTeam
	local resultColor = if isVictory then VICTORY_COLOR else DEFEAT_COLOR

	local canvas: GuiObject = self._canvas

	-- Resetear paneles
	local resultPanel  = _guiChild(canvas, "Result")
	local summaryPanel = _guiChild(canvas, "Summary")
	local rewardsPanel = _guiChild(canvas, "Rewards")
	if resultPanel  then resultPanel.Visible  = false end
	if summaryPanel then summaryPanel.Visible = false end
	if rewardsPanel then rewardsPanel.Visible = false end

	_setResultsBlurEnabled(true)
	self._gui.Enabled = true

	task.spawn(function()
		local localUserId = Players.LocalPlayer.UserId

		-- Fase 2: Summary
		_playSummaryPhase(canvas, resultColor, isVictory, data.scoreA, data.scoreB, data.players, localUserId)

		-- Esperar a que Summary termine de entrar
		task.wait(SUMMARY_TO_REWARDS_DELAY)
		if self._token ~= token then return end

		-- Fase 3: Rewards
		_playRewardsPhase(canvas)

		-- El cierre lo controla el jugador pulsando CloseBtn.
	end)
end

function EndResultsView:hide(onHidden: (() -> ())?)
	self._token += 1
	_setResultsBlurEnabled(false)

	local canvas: GuiObject = self._canvas
	local gui = self._gui

	local resultPanel  = _guiChild(canvas, "Result")
	local summaryPanel = _guiChild(canvas, "Summary")
	local rewardsPanel = _guiChild(canvas, "Rewards")

	local function tweenHide(obj: GuiObject?)
		if not obj or not obj.Visible then return end
		pcall(function()
			TweenService:Create(obj, TWEEN_HIDE, { GroupTransparency = 1 }):Play()
		end)
	end

	tweenHide(resultPanel)
	tweenHide(summaryPanel)
	tweenHide(rewardsPanel)

	task.delay(TWEEN_HIDE.Time, function()
		gui.Enabled = false
		if resultPanel  then resultPanel.Visible  = false end
		if summaryPanel then summaryPanel.Visible = false end
		if rewardsPanel then rewardsPanel.Visible = false end
		if onHidden then
			onHidden()
		end
	end)
end

function EndResultsView:Destroy()
	self._token += 1
	self._onFinished = nil
	if self._closeBtnConnection then
		self._closeBtnConnection:Disconnect()
		self._closeBtnConnection = nil
	end
	_setResultsBlurEnabled(false)
	self._gui.Enabled = false
end

return EndResultsView
