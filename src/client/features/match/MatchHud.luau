--!strict
--[[
	Estructura esperada bajo `MatchHud.Container`:
		GlobalKillFeedContainer.Template
		Cash.Value, Level.{Value, Bar.Fill}, Version   (opcionales)
		MainFrame.Timer
		MainFrame.{ATeamBar, BTeamBar}.{Fill, Value}
		MainFrame.{ATeamIndicator, BTeamIndicator}   (spritesheet 2x2)
		MainFrame.{ATeamPlayers, BTeamPlayers}.Template.Value
		Missions.{1, 2, 3}   (las pinta features/dailyTasks)
	Los popups de MainFrame los resuelve MatchNotificationsQueue. El de ganancias vive
	en otro ScreenGui (StarterGui.MatchStats.Stats, StatsCoinsPopup): llega como
	segundo argumento de new y setEnabled lo enciende/apaga junto al HUD.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)
local GameConfig = require(Shared.GameConfig)
local UIUtils = require(script.Parent.Parent.Parent.core.ui.UIUtils)
local Janitor = require(ReplicatedStorage:WaitForChild("Packages").janitor) :: any
local MatchNotificationsQueue = require(script.Parent.MatchNotificationsQueue)
local StatsCoinsPopup = require(script.Parent.StatsCoinsPopup)
local GlobalKillFeed = require(script.Parent.GlobalKillFeed)

local LOCAL_PLAYER_KILLS_COLOR = Color3.fromRGB(255, 194, 0)
local OTHER_PLAYER_KILLS_COLOR = Color3.fromRGB(255, 255, 255)

-- ATeamIndicator/BTeamIndicator: spritesheets 2x2 de 512x512.
local TEAM_INDICATOR_SHEET_SIZE = Vector2.new(512, 512)
local TEAM_INDICATOR_COLUMNS = 2
local TEAM_INDICATOR_ROWS = 2
local TEAM_INDICATOR_TOTAL_FRAMES = TEAM_INDICATOR_COLUMNS * TEAM_INDICATOR_ROWS
local TEAM_INDICATOR_TILE_SIZE = Vector2.new(
	TEAM_INDICATOR_SHEET_SIZE.X / TEAM_INDICATOR_COLUMNS,
	TEAM_INDICATOR_SHEET_SIZE.Y / TEAM_INDICATOR_ROWS
)
local TEAM_INDICATOR_FRAME_TIME = 1 / 13

local TIMER_ALERT_THRESHOLD = 20         -- segundos: naranja + escala grande
local TIMER_CRITICAL_THRESHOLD = 10      -- segundos: rojo + blink + pulso
local TIMER_NORMAL_COLOR = Color3.fromRGB(255, 255, 255)
local TIMER_ALERT_COLOR = Color3.fromRGB(255, 140, 0)
local TIMER_CRITICAL_COLOR = Color3.fromRGB(255, 50, 50)
local TIMER_BLINK_TWEEN_INFO = TweenInfo.new(
	0.35,
	Enum.EasingStyle.Sine,
	Enum.EasingDirection.InOut,
	-1,
	true
)
local TIMER_PULSE_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TIMER_BASE_SCALE_TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TIMER_BASE_SCALE = 1
local TIMER_LARGE_SCALE = 1.4
local TIMER_PULSE_FACTOR = 1.2  -- multiplica la escala base
local TIMER_BLINK_FLASH_COLOR = Color3.fromRGB(255, 255, 255)

type HudPlayerRowRefs = {
	root: GuiObject,
	profile: ImageLabel?,
	killsValue: TextLabel?,
}

type HudRefs = {
	timer: TextLabel?,
	teamABarFill: GuiObject?,
	teamBBarFill: GuiObject?,
	teamABarValue: TextLabel?,
	teamBBarValue: TextLabel?,
	teamAIndicator: ImageLabel?,
	teamBIndicator: ImageLabel?,
	cashValue: TextLabel?,
	levelValue: TextLabel?,
	levelBarFill: GuiObject?,
	version: TextLabel?,
	teamAPlayersFrame: GuiObject?,
	teamBPlayersFrame: GuiObject?,
	teamATemplate: GuiObject?,
	teamBTemplate: GuiObject?,
}

export type BotRosterEntry = {
	displayName: string,
	team: string,
	image: string,
	level: number,
	outfitId: string,
	faceId: string,
	hatId: string,
}

export type PlayerCosmetics = {
	outfitId: string,
	faceId: string,
	hatId: string,
}

export type EndResultsPlayerEntry = {
	userId: number,
	name: string,
	team: "A" | "B",
	kills: number,
	deaths: number,
	assists: number,
	level: number,
	isBot: boolean,
	-- Para bots vienen del roster; para reales, del packet TeamCosmetics; "" para el
	-- local (ResultsView usa su loadout).
	outfitId: string,
	faceId: string,
	hatId: string,
}

local function _setHorizontalFill(fillNode: GuiObject?, ratio: number)
	if not fillNode then
		return
	end
	local clampedRatio = math.min(1, math.max(0, ratio))
	local baseScale = fillNode:GetAttribute("BaseFillScale")
	local baseOffset = fillNode:GetAttribute("BaseFillOffset")
	local currentSize = fillNode.Size

	if type(baseScale) ~= "number" then
		baseScale = currentSize.X.Scale
		fillNode:SetAttribute("BaseFillScale", baseScale)
	end
	if type(baseOffset) ~= "number" then
		baseOffset = currentSize.X.Offset
		fillNode:SetAttribute("BaseFillOffset", baseOffset)
	end

	local nextScale = baseScale + ((1 - baseScale) * clampedRatio)
	fillNode.Size = UDim2.new(nextScale, baseOffset, currentSize.Y.Scale, currentSize.Y.Offset)
end

local function _formatMatchTime(timeLeft: number): (string, number)
	local totalSeconds = math.max(0, math.floor(timeLeft))
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds % 60
	return string.format("%02d:%02d", minutes, seconds), totalSeconds
end

local function _setTeamBarValue(valueLabel: TextLabel?, score: number, objective: number)
	if not valueLabel then
		return
	end
	valueLabel.RichText = true
	valueLabel.Text = UIUtils.formatProgressValue(score, objective)
end

local function _resolveTimerColor(totalSeconds: number): (Color3, boolean)
	if totalSeconds <= TIMER_CRITICAL_THRESHOLD then
		return TIMER_CRITICAL_COLOR, true
	elseif totalSeconds <= TIMER_ALERT_THRESHOLD then
		return TIMER_ALERT_COLOR, false
	end
	return TIMER_NORMAL_COLOR, false
end

local function _initTeamIndicator(indicator: ImageLabel?)
	if not indicator then
		return
	end
	indicator.ImageRectSize = TEAM_INDICATOR_TILE_SIZE
	indicator.ImageRectOffset = Vector2.zero
	indicator.Visible = false
end

local function _ensureTimerScale(label: TextLabel): UIScale
	local scaleNode = label:FindFirstChildOfClass("UIScale")
	if scaleNode then
		return scaleNode
	end
	local created = Instance.new("UIScale")
	created.Name = "TimerScale"
	created.Scale = 1
	created.Parent = label
	return created
end

-- Oculto, el UIListLayout ignora el Template y no ocupa hueco en la fila.
local function _resolveRowTemplate(playersFrame: GuiObject): GuiObject
	local template = playersFrame:WaitForChild("Template") :: GuiObject
	template.Visible = false
	return template
end

-- El UIListLayout ordena por Name: el nombre codifica el puesto. El mejor (rank 1)
-- va a la derecha en el equipo A y a la izquierda en el B.
local function _rowSortName(side: string, rank: number, total: number): string
	local position = if side == "A" then (total - rank + 1) else rank
	return string.format("%02d", position)
end

local function _resolveHudRefs(matchHudGui: ScreenGui?): HudRefs
	if not matchHudGui then
		return {}
	end

	local container = matchHudGui:WaitForChild("Container") :: Frame
	local mainFrame = container:WaitForChild("MainFrame") :: Frame
	local cash = container:FindFirstChild("Cash")
	local level = container:FindFirstChild("Level")
	local levelBar = if level then level:FindFirstChild("Bar") else nil

	local teamABar = mainFrame:WaitForChild("ATeamBar") :: Frame
	local teamBBar = mainFrame:WaitForChild("BTeamBar") :: Frame

	local teamAPlayers = mainFrame:WaitForChild("ATeamPlayers") :: Frame
	local teamBPlayers = mainFrame:WaitForChild("BTeamPlayers") :: Frame

	local versionNode = container:FindFirstChild("Version")
	local versionLabel: TextLabel? = if versionNode
		then (if versionNode:IsA("TextLabel") then versionNode else versionNode:FindFirstChild("Value") :: TextLabel?)
		else nil

	return {
		timer = mainFrame:WaitForChild("Timer") :: TextLabel,
		teamABarFill = teamABar:WaitForChild("Fill") :: GuiObject,
		teamBBarFill = teamBBar:WaitForChild("Fill") :: GuiObject,
		teamABarValue = teamABar:WaitForChild("Value") :: TextLabel,
		teamBBarValue = teamBBar:WaitForChild("Value") :: TextLabel,
		teamAIndicator = mainFrame:WaitForChild("ATeamIndicator") :: ImageLabel,
		teamBIndicator = mainFrame:WaitForChild("BTeamIndicator") :: ImageLabel,
		cashValue = if cash then cash:FindFirstChild("Value") :: TextLabel? else nil,
		levelValue = if level then level:FindFirstChild("Value") :: TextLabel? else nil,
		levelBarFill = if levelBar then levelBar:FindFirstChild("Fill") :: GuiObject? else nil,
		version = versionLabel,
		teamAPlayersFrame = teamAPlayers,
		teamBPlayersFrame = teamBPlayers,
		teamATemplate = _resolveRowTemplate(teamAPlayers),
		teamBTemplate = _resolveRowTemplate(teamBPlayers),
	}
end

local MatchHud = {}
MatchHud.__index = MatchHud

function MatchHud.new(matchHudGui: ScreenGui?, matchStatsGui: ScreenGui?): any
	local self = setmetatable({}, MatchHud)
	self._gui = matchHudGui
	self._statsGui = matchStatsGui
	self._hudRefs = _resolveHudRefs(matchHudGui)
	self._localUserId = Players.LocalPlayer.UserId
	self._destroyed = false
	self._janitor = Janitor.new()
	_initTeamIndicator(self._hudRefs.teamAIndicator)
	_initTeamIndicator(self._hudRefs.teamBIndicator)
	self._indicatorSide = nil :: string?
	self._indicatorToken = 0
	self._notificationsQueue = MatchNotificationsQueue.new(matchHudGui)
	-- Las filas de jugadores se ocultan mientras hay notificación para no solaparse.
	self._notificationsQueue:setOnNotifyingChanged(function(notifying)
		self:_setTeamPlayersHidden(notifying)
	end)
	self._statsCoinsPopup = StatsCoinsPopup.new(matchStatsGui)
	-- nil hasta la primera lectura para no animar el total inicial como ganancia.
	self._lastCashSeen = nil :: number?
	-- Lo que pinta el popup = cash real − reservado por desafíos sin entregar.
	self._lastVisibleCash = nil :: number?
	self._reservedChallengeCash = 0
	self._pendingCash = 0
	self._cashFlushQueued = false
	self._hudEnabled = false
	-- Devuelve la duración del vuelo de monedas para que el popup no se retire antes.
	self._notificationsQueue:setOnChallengeReward(function(spawnNode: ImageLabel, amount: number): number?
		return self:_deliverChallengeCash(spawnNode, amount)
	end)

	if matchHudGui then
		self._globalKillFeed = GlobalKillFeed.new(matchHudGui, self)
		self._janitor:Add(self._globalKillFeed, "Destroy")
	end

	-- FPS solo en Studio: en producción no se paga la conexión a RenderStepped.
	if self._hudRefs.version then
		local versionLabel = self._hudRefs.version
		local placePrefix = "v" .. tostring(game.PlaceVersion)
		local localPlayer = Players.LocalPlayer
		local showFps = RunService:IsStudio()
		local frameCount = 0

		if showFps then
			self._janitor:Add(RunService.RenderStepped:Connect(function()
				frameCount += 1
			end), "Disconnect")
		end

		task.spawn(function()
			while not self._destroyed do
				local framesAtStart = frameCount
				local dt = task.wait(1)
				if self._destroyed then
					return
				end
				local pingMs = math.floor(localPlayer:GetNetworkPing() * 1000 + 0.5)
				if versionLabel.Parent then
					if showFps then
						local fps = math.floor((frameCount - framesAtStart) / dt + 0.5)
						versionLabel.Text = string.format("%s | %dms | %dfps", placePrefix, pingMs, fps)
					else
						versionLabel.Text = string.format("%s | %dms", placePrefix, pingMs)
					end
				end
			end
		end)
	end

	self._killsByUserId = {} :: { [number]: number }
	self._deathsByUserId = {} :: { [number]: number }
	self._assistsByUserId = {} :: { [number]: number }
	self._botRoster = {} :: { [number]: BotRosterEntry }
	-- Al acabar la ronda el Character puede quedar sin Team: fallback para Resultados.
	self._lastKnownLocalSide = nil :: string?
	-- Lo llena el packet TeamCosmetics.
	self._playerCosmeticsByUserId = {} :: { [number]: PlayerCosmetics }

	self._thumbnailByUserId = {} :: { [number]: string }
	self._thumbnailRequestInFlight = {} :: { [number]: boolean }

	-- Pool de clones de `Template` por equipo. El rowKey "A1"/"B2" indexa el pool,
	-- no el orden visual (que lo decide el Name del clon).
	self._playerRows = { A = {} :: { HudPlayerRowRefs }, B = {} :: { HudPlayerRowRefs } }
	self._rowUserIdByKey = {} :: { [string]: number? }
	self._updateQueued = false

	self._timerLastSecond = -1
	self._timerBlinkTween = nil :: Tween?
	self._timerPulseTween = nil :: Tween?
	self._timerBaseScaleTween = nil :: Tween?
	self._timerCurrentBaseScale = TIMER_BASE_SCALE
	self._timerScale = nil :: UIScale?

	if matchHudGui then
		matchHudGui.Enabled = false
	end
	if matchStatsGui then
		matchStatsGui.Enabled = false
	end

	self:resetMatchState()

	return self
end

function MatchHud:setEnabled(enabled: boolean)
	self._hudEnabled = enabled
	if self._gui then
		self._gui.Enabled = enabled
	end
	if self._statsGui then
		self._statsGui.Enabled = enabled
	end
	if not enabled then
		self:_clearTimerEffects()
		self:_setWinningTeam(nil)
		-- Libera reservas sin entregar (popup cortado a medias) para que el label cuadre
		-- con el cash real.
		self._reservedChallengeCash = 0
		if self._statsCoinsPopup then
			self._statsCoinsPopup:hideImmediate()
			local cash = self._lastCashSeen
			if cash then
				self._lastVisibleCash = cash
				self._statsCoinsPopup:setCash(cash)
			end
		end
	end
end

-- nil = empate. Cada cambio invalida el bucle anterior vía token.
function MatchHud:_setWinningTeam(side: string?)
	if side == self._indicatorSide then
		return
	end
	self._indicatorSide = side
	self._indicatorToken += 1

	local refs = self._hudRefs
	if refs.teamAIndicator then
		refs.teamAIndicator.Visible = side == "A"
	end
	if refs.teamBIndicator then
		refs.teamBIndicator.Visible = side == "B"
	end

	local indicator = if side == "A" then refs.teamAIndicator
		elseif side == "B" then refs.teamBIndicator
		else nil
	if not indicator then
		return
	end

	local token = self._indicatorToken
	task.spawn(function()
		local frameIndex = 0
		while not self._destroyed and self._indicatorToken == token and indicator.Parent do
			local column = frameIndex % TEAM_INDICATOR_COLUMNS
			local row = math.floor(frameIndex / TEAM_INDICATOR_COLUMNS)
			indicator.ImageRectOffset = Vector2.new(
				column * TEAM_INDICATOR_TILE_SIZE.X,
				row * TEAM_INDICATOR_TILE_SIZE.Y
			)
			frameIndex = (frameIndex + 1) % TEAM_INDICATOR_TOTAL_FRAMES
			task.wait(TEAM_INDICATOR_FRAME_TIME)
		end
	end)
end

function MatchHud:_clearTimerEffects()
	if self._timerBlinkTween then
		self._timerBlinkTween:Cancel()
		self._timerBlinkTween = nil
	end
	if self._timerPulseTween then
		self._timerPulseTween:Cancel()
		self._timerPulseTween = nil
	end
	if self._timerBaseScaleTween then
		self._timerBaseScaleTween:Cancel()
		self._timerBaseScaleTween = nil
	end
	if self._timerScale then
		self._timerScale.Scale = TIMER_BASE_SCALE
	end
	local timerLabel = self._hudRefs.timer
	if timerLabel then
		timerLabel.TextTransparency = 0
		timerLabel.TextColor3 = TIMER_NORMAL_COLOR
	end
	self._timerLastSecond = -1
	self._timerCurrentBaseScale = TIMER_BASE_SCALE
end

-- El pulso solo se dispara al cambiar el segundo, no cada frame.
function MatchHud:_updateTimerEffects(timerLabel: TextLabel, totalSeconds: number)
	local color, isCritical = _resolveTimerColor(totalSeconds)

	if isCritical then
		if not self._timerBlinkTween then
			timerLabel.TextTransparency = 0
			timerLabel.TextColor3 = color
			local tween = TweenService:Create(timerLabel, TIMER_BLINK_TWEEN_INFO, {
				TextColor3 = TIMER_BLINK_FLASH_COLOR,
			})
			self._timerBlinkTween = tween
			tween:Play()
		end
	else
		if self._timerBlinkTween then
			self._timerBlinkTween:Cancel()
			self._timerBlinkTween = nil
		end
		timerLabel.TextTransparency = 0
		timerLabel.TextColor3 = color
	end

	local targetBaseScale = if totalSeconds <= TIMER_ALERT_THRESHOLD then TIMER_LARGE_SCALE else TIMER_BASE_SCALE
	local scaleNode = self._timerScale
	if not scaleNode then
		scaleNode = _ensureTimerScale(timerLabel)
		self._timerScale = scaleNode
	end

	if targetBaseScale ~= self._timerCurrentBaseScale then
		self._timerCurrentBaseScale = targetBaseScale
		if self._timerBaseScaleTween then
			self._timerBaseScaleTween:Cancel()
		end
		-- En crítico la transición la hace el pulso.
		if not isCritical then
			if self._timerPulseTween then
				self._timerPulseTween:Cancel()
				self._timerPulseTween = nil
			end
			local tween = TweenService:Create(scaleNode, TIMER_BASE_SCALE_TWEEN_INFO, { Scale = targetBaseScale })
			self._timerBaseScaleTween = tween
			tween:Play()
		end
	end

	if isCritical and totalSeconds ~= self._timerLastSecond then
		if self._timerPulseTween then
			self._timerPulseTween:Cancel()
		end
		if self._timerBaseScaleTween then
			self._timerBaseScaleTween:Cancel()
			self._timerBaseScaleTween = nil
		end
		scaleNode.Scale = targetBaseScale * TIMER_PULSE_FACTOR
		local tween = TweenService:Create(scaleNode, TIMER_PULSE_TWEEN_INFO, { Scale = targetBaseScale })
		self._timerPulseTween = tween
		tween:Play()
	elseif not isCritical and self._timerPulseTween then
		self._timerPulseTween:Cancel()
		self._timerPulseTween = nil
	end

	self._timerLastSecond = totalSeconds
end

function MatchHud:setScores(scoreA: number, scoreB: number, timeLeft: number)
	local refs = self._hudRefs

	local clampedA = math.max(0, scoreA)
	local clampedB = math.max(0, scoreB)

	local objectiveScore = math.max(1, GameConfig.WinScoreLimit or 1)
	_setHorizontalFill(refs.teamABarFill, clampedA / objectiveScore)
	_setHorizontalFill(refs.teamBBarFill, clampedB / objectiveScore)
	_setTeamBarValue(refs.teamABarValue, clampedA, objectiveScore)
	_setTeamBarValue(refs.teamBBarValue, clampedB, objectiveScore)

	self:_setWinningTeam(
		if clampedA > clampedB then "A"
		elseif clampedB > clampedA then "B"
		else nil
	)

	if refs.timer then
		local text, totalSeconds = _formatMatchTime(timeLeft)
		refs.timer.Text = text
		self:_updateTimerEffects(refs.timer, totalSeconds)
	end
end

export type MasteryProgress = MatchNotificationsQueue.MasteryProgress
export type DailyTaskProgress = MatchNotificationsQueue.DailyTaskProgress

function MatchHud:playLevelUpAnimation(newLevel: number)
	if self._notificationsQueue then
		self._notificationsQueue:playLevelUpAnimation(newLevel)
	end
end

function MatchHud:playBattlePassLevelUpAnimation(newLevel: number)
	if self._notificationsQueue then
		self._notificationsQueue:playBattlePassLevelUpAnimation(newLevel)
	end
end

function MatchHud:playMasteryAnimation(progress: MasteryProgress)
	if self._notificationsQueue then
		self._notificationsQueue:playMasteryAnimation(progress)
	end
end

function MatchHud:playDailyTaskAnimation(progress: DailyTaskProgress)
	if self._notificationsQueue then
		self._notificationsQueue:playDailyTaskAnimation(progress)
	end
end

--- Aparta `amount` de la próxima subida de cash: no lo anima Stats, lo entrega el
--- popup del desafío con sus monedas (_deliverChallengeCash).
function MatchHud:reserveChallengeCash(amount: number)
	local reserved = math.max(0, math.floor(if type(amount) == "number" then amount else 0))
	if reserved <= 0 then
		return
	end
	self._reservedChallengeCash += reserved
end

--- Devuelve la duración del vuelo.
function MatchHud:_deliverChallengeCash(spawnNode: ImageLabel, amount: number): number
	local popup = self._statsCoinsPopup
	if not popup then
		return 0
	end
	local claimed = math.max(0, math.floor(if type(amount) == "number" then amount else 0))
	self._reservedChallengeCash = math.max(0, self._reservedChallengeCash - claimed)

	local cash = self._lastCashSeen or 0
	local visibleCash = math.max(0, cash - self._reservedChallengeCash)
	local previousVisible = self._lastVisibleCash or visibleCash
	self._lastVisibleCash = visibleCash
	-- Si el cash aún no llegó, se vuela el importe igual: el popup satura en su total.
	local delta = if visibleCash > previousVisible then visibleCash - previousVisible else claimed
	return popup:addCashFrom(delta, visibleCash, spawnNode)
end

function MatchHud:updateCashLevel(stats: any)
	local refs = self._hudRefs

	local cash = if stats and type(stats.Cash) == "number" then math.max(0, math.floor(stats.Cash)) else 0
	if refs.cashValue then
		refs.cashValue.Text = UIUtils.formatCashAmount(cash)
	end

	self._pendingCash = cash
	self:_scheduleCashFlush()

	if refs.levelValue then
		local level = if stats and type(stats.Level) == "number" then math.max(0, math.floor(stats.Level)) else 0
		refs.levelValue.Text = "Lvl. " .. tostring(level)
	end

	if refs.levelBarFill then
		local currentXP = if stats and type(stats.XP) == "number" then math.max(0, math.floor(stats.XP)) else 0
		local xpToNext = if stats and type(stats.XPToNextLevel) == "number" then math.max(0, math.floor(stats.XPToNextLevel)) else 0
		local fillRatio = if xpToNext > 0 then math.min(1, math.max(0, currentXP / xpToNext)) else 0
		_setHorizontalFill(refs.levelBarFill, fillRatio)
	end
end

-- Cash y estado de desafíos llegan en el MISMO BatchUpdate sin orden definido entre
-- listeners: se difiere para que las reservas de esa tanda ya estén registradas.
function MatchHud:_scheduleCashFlush()
	if self._cashFlushQueued or self._destroyed then
		return
	end
	self._cashFlushQueued = true
	task.defer(function()
		self._cashFlushQueued = false
		if not self._destroyed then
			self:_flushCash()
		end
	end)
end

function MatchHud:_flushCash()
	local popup = self._statsCoinsPopup
	if not popup then
		return
	end

	local cash = self._pendingCash
	self._lastCashSeen = cash
	-- El total visible nunca baja por una reserva hecha antes de que llegue su cash.
	local previousVisible = self._lastVisibleCash
	local visibleCash = math.max(0, cash - self._reservedChallengeCash)
	if previousVisible and visibleCash < previousVisible and cash >= previousVisible then
		visibleCash = previousVisible
	end
	self._lastVisibleCash = visibleCash

	if previousVisible and visibleCash > previousVisible and self._hudEnabled then
		popup:addCash(visibleCash - previousVisible, visibleCash)
	else
		popup:setCash(visibleCash)
	end
end

function MatchHud:resetMatchState()
	table.clear(self._killsByUserId)
	table.clear(self._deathsByUserId)
	table.clear(self._assistsByUserId)
	table.clear(self._playerCosmeticsByUserId)
	-- _botRoster no se limpia: Network.Match.BotRoster puede llegar antes de
	-- JoinMatchSpawned, y cada envío lo reemplaza entero.
	self._killsByUserId[self._localUserId] = 0
	self._deathsByUserId[self._localUserId] = 0
	self._assistsByUserId[self._localUserId] = 0
	self:_clearTimerEffects()
	self:queuePlayerRowsUpdate()
end

function MatchHud:applyPlayerState(userId: number, kills: number, deaths: number, assists: number)
	local oldKills = self._killsByUserId[userId] or 0
	local newKills = math.max(0, kills)
	self._killsByUserId[userId] = newKills
	-- Las deaths del local las lleva incrementLocalDeaths (inmediato en DeathScreenShow):
	-- evita doble conteo y latencia.
	if userId ~= self._localUserId then
		self._deathsByUserId[userId] = math.max(0, deaths)
	end
	self._assistsByUserId[userId] = math.max(0, assists)

	-- Fast paths para no reordenar todas las filas en cada kill: la fila solo muestra
	-- kills, y si no hay reorder basta con actualizar esa fila.
	if oldKills == newKills then
		return
	end
	if self:_tryIncrementalKillUpdate(userId, oldKills, newKills) then
		return
	end
	self:queuePlayerRowsUpdate()
end

function MatchHud:incrementLocalDeaths()
	self._deathsByUserId[self._localUserId] = (self._deathsByUserId[self._localUserId] or 0) + 1
end

function MatchHud:setBotRoster(roster: { [number]: BotRosterEntry })
	self._botRoster = roster
	self:queuePlayerRowsUpdate()
end

function MatchHud:setPlayerCosmetics(byUserId: { [number]: PlayerCosmetics })
	self._playerCosmeticsByUserId = byUserId
end

function MatchHud:onPlayerRemoved(userId: number)
	self._killsByUserId[userId] = nil
	self:queuePlayerRowsUpdate()
end

--- Llamar antes de resetear el roster.
function MatchHud:captureEndResultsData(): (string, { EndResultsPlayerEntry })
	-- Al acabar la ronda el Character puede no existir o no tener Team: se cae a
	-- Player.Team, al atributo TeamName y por último al equipo cacheado en partida.
	local function resolveSide(player: Player): string?
		local side = TeamUtils.getSide(player.Character)
		if not side and player.Team then
			side = TeamUtils.normalize(player.Team.Name)
		end
		if not side then
			local attr = player:GetAttribute("TeamName")
			if typeof(attr) == "string" then
				side = TeamUtils.normalize(attr)
			end
		end
		if not side and player == Players.LocalPlayer then
			side = self._lastKnownLocalSide
		end
		return side
	end

	local localTeam = resolveSide(Players.LocalPlayer) or ""
	local entries = {} :: { EndResultsPlayerEntry }

	for _, player in Players:GetPlayers() do
		local side = resolveSide(player) or ""
		if side == "" then
			continue
		end

		local level = 0
		local leaderstats = player:FindFirstChild("leaderstats")
		if leaderstats then
			local levelNode = leaderstats:FindFirstChild("Level")
			if levelNode and (levelNode:IsA("IntValue") or levelNode:IsA("NumberValue")) then
				level = (levelNode :: IntValue).Value
			end
		end

		local cos = self._playerCosmeticsByUserId[player.UserId]

		table.insert(entries, {
			userId = player.UserId,
			name = player.Name,
			team = side :: "A" | "B",
			kills = self._killsByUserId[player.UserId] or 0,
			deaths = self._deathsByUserId[player.UserId] or 0,
			assists = self._assistsByUserId[player.UserId] or 0,
			level = level,
			isBot = false,
			outfitId = if cos then cos.outfitId else "",
			faceId = if cos then cos.faceId else "",
			hatId = if cos then cos.hatId else "",
		})
	end

	for fakeUserId, entry in pairs(self._botRoster) do
		table.insert(entries, {
			userId = fakeUserId,
			name = entry.displayName,
			team = entry.team :: "A" | "B",
			kills = self._killsByUserId[fakeUserId] or 0,
			deaths = self._deathsByUserId[fakeUserId] or 0,
			assists = self._assistsByUserId[fakeUserId] or 0,
			level = entry.level,
			isBot = true,
			outfitId = entry.outfitId,
			faceId = entry.faceId,
			hatId = entry.hatId,
		})
	end

	return localTeam, entries
end

-- El clon nace invisible y con nombre neutro: el Name de puesto lo escribe _updatePlayerRows.
function MatchHud:_acquireRow(side: string, index: number): HudPlayerRowRefs?
	local pool = self._playerRows[side]
	local existing = pool[index]
	if existing then
		return existing
	end

	local refs = self._hudRefs
	local template = if side == "A" then refs.teamATemplate else refs.teamBTemplate
	local parent = if side == "A" then refs.teamAPlayersFrame else refs.teamBPlayersFrame
	if not (template and parent) then
		return nil
	end

	local clone = template:Clone()
	clone.Name = "Row"
	clone.Visible = false
	clone.Parent = parent
	self._janitor:Add(clone, "Destroy")

	-- El Template es la ImageLabel de perfil, o un Frame que la contiene.
	local profileNode: Instance? = if clone:IsA("ImageLabel")
		then clone
		else clone:FindFirstChildWhichIsA("ImageLabel", true)
	local killsNode = clone:FindFirstChild("Value", true)

	local row: HudPlayerRowRefs = {
		root = clone,
		profile = if profileNode and profileNode:IsA("ImageLabel") then profileNode else nil,
		killsValue = if killsNode and killsNode:IsA("TextLabel") then killsNode else nil,
	}
	pool[index] = row
	return row
end

-- `isLocalPlayer` nil = no tocar el color.
function MatchHud:_setRowStats(rowRef: HudPlayerRowRefs, totalKills: number, isLocalPlayer: boolean?)
	local label = rowRef.killsValue
	if not label then
		return
	end
	label.Text = tostring(math.max(0, totalKills))
	if isLocalPlayer ~= nil then
		label.TextColor3 = if isLocalPlayer then LOCAL_PLAYER_KILLS_COLOR else OTHER_PLAYER_KILLS_COLOR
	end
end

function MatchHud:_clearRow(rowRef: HudPlayerRowRefs, rowKey: string)
	rowRef.root.Visible = false
	self._rowUserIdByKey[rowKey] = nil
	if rowRef.profile then
		rowRef.profile.Image = ""
	end
	self:_setRowStats(rowRef, 0)
end

function MatchHud:_applyCachedOrFetchThumbnail(rowKey: string, userId: number, profileRef: ImageLabel)
	local cached = self._thumbnailByUserId[userId]
	if cached then
		profileRef.Image = cached
		return
	end

	profileRef.Image = ""
	if self._thumbnailRequestInFlight[userId] then
		return
	end

	self._thumbnailRequestInFlight[userId] = true
	-- Si GetUserThumbnailAsync se cuelga, libera el flag para permitir reintentos.
	task.delay(30, function()
		if self._destroyed then
			return
		end
		self._thumbnailRequestInFlight[userId] = nil
	end)
	task.spawn(function()
		-- Jitter para no lanzar todas las peticiones del roster en el mismo frame
		-- (en móvil con mala conexión se encadenan bloqueos).
		task.wait(math.random() * 0.4)
		if self._destroyed then
			self._thumbnailRequestInFlight[userId] = nil
			return
		end
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		end)
		if self._destroyed then
			return
		end
		self._thumbnailRequestInFlight[userId] = nil
		if not ok or type(content) ~= "string" or content == "" then
			return
		end
		self._thumbnailByUserId[userId] = content
		if self._rowUserIdByKey[rowKey] ~= userId or not profileRef.Parent then
			return
		end
		profileRef.Image = content
	end)
end

function MatchHud:_applyRowEntry(
	rowRef: HudPlayerRowRefs,
	rowKey: string,
	entry: { userId: number, image: string?, isBot: boolean, team: string? }
)
	rowRef.root.Visible = true
	self._rowUserIdByKey[rowKey] = entry.userId
	if rowRef.profile then
		if entry.isBot then
			rowRef.profile.Image = entry.image or ""
		else
			self:_applyCachedOrFetchThumbnail(rowKey, entry.userId, rowRef.profile)
		end
	end
	self:_setRowStats(rowRef, self._killsByUserId[entry.userId] or 0, entry.userId == self._localUserId)
end

function MatchHud:_findRowForUserId(userId: number): (HudPlayerRowRefs?, string?)
	for rowKey, rowUserId in pairs(self._rowUserIdByKey) do
		if rowUserId == userId then
			local team = string.sub(rowKey, 1, 1)
			local idx = tonumber(string.sub(rowKey, 2)) :: number
			return self._playerRows[team][idx], team
		end
	end
	return nil, nil
end

-- false → el caller debe hacer el rebuild completo (queuePlayerRowsUpdate).
function MatchHud:_tryIncrementalKillUpdate(userId: number, oldKills: number, newKills: number): boolean
	if self._updateQueued then
		return false
	end
	local rowRef, team = self:_findRowForUserId(userId)
	if not rowRef or not team then
		return false
	end

	local lo = math.min(oldKills, newKills)
	local hi = math.max(oldKills, newKills)

	for rowKey, rowUserId in pairs(self._rowUserIdByKey) do
		if rowUserId == userId then continue end
		if string.sub(rowKey, 1, 1) ~= team then continue end
		local pk = self._killsByUserId[rowUserId] or 0
		if pk >= lo and pk <= hi then
			return false
		end
	end

	self:_setRowStats(rowRef, newKills)
	return true
end

function MatchHud:_setTeamPlayersHidden(hidden: boolean)
	local refs = self._hudRefs
	if refs.teamAPlayersFrame then
		refs.teamAPlayersFrame.Visible = not hidden
	end
	if refs.teamBPlayersFrame then
		refs.teamBPlayersFrame.Visible = not hidden
	end
end

function MatchHud:_updatePlayerRows()
	type RowEntry = { userId: number, name: string, image: string?, isBot: boolean, team: string? }
	local entriesByTeam = {
		A = {} :: { RowEntry },
		B = {} :: { RowEntry },
	}

	for _, p in Players:GetPlayers() do
		local side = TeamUtils.getSide(p.Character)
		if not side and p.Team then
			side = TeamUtils.normalize(p.Team.Name)
		end
		if side == "A" or side == "B" then
			if p == Players.LocalPlayer then
				self._lastKnownLocalSide = side
			end
			table.insert(entriesByTeam[side], { userId = p.UserId, name = p.Name, image = nil, isBot = false, team = side })
		end
	end

	for fakeUserId, entry in pairs(self._botRoster) do
		if entry.team == "A" or entry.team == "B" then
			table.insert(entriesByTeam[entry.team], { userId = fakeUserId, name = entry.displayName, image = entry.image, isBot = true, team = entry.team })
		end
	end

	local function sortEntries(entries: { RowEntry })
		table.sort(entries, function(a, b)
			local killsA = self._killsByUserId[a.userId] or 0
			local killsB = self._killsByUserId[b.userId] or 0
			if killsA ~= killsB then
				return killsA > killsB
			end
			if a.name ~= b.name then
				return a.name < b.name
			end
			return a.userId < b.userId
		end)
	end

	sortEntries(entriesByTeam.A)
	sortEntries(entriesByTeam.B)

	for _, side in { "A", "B" } do
		local entries = entriesByTeam[side]
		local total = #entries
		for rank, entry in ipairs(entries) do
			local rowRef = self:_acquireRow(side, rank)
			if not rowRef then
				break
			end
			rowRef.root.Name = _rowSortName(side, rank, total)
			self:_applyRowEntry(rowRef, string.format("%s%d", side, rank), entry)
		end

		local pool = self._playerRows[side]
		for index = total + 1, #pool do
			self:_clearRow(pool[index], string.format("%s%d", side, index))
		end
	end
end

function MatchHud:queuePlayerRowsUpdate()
	if self._updateQueued then
		return
	end
	self._updateQueued = true
	task.defer(function()
		self._updateQueued = false
		self:_updatePlayerRows()
	end)
end

function MatchHud:destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self:_clearTimerEffects()
	self._indicatorToken += 1
	if self._notificationsQueue then
		self._notificationsQueue:destroy()
		self._notificationsQueue = nil
	end
	if self._statsCoinsPopup then
		self._statsCoinsPopup:destroy()
		self._statsCoinsPopup = nil
	end
	if self._janitor then
		self._janitor:Destroy()
		self._janitor = nil
	end
end

return MatchHud
