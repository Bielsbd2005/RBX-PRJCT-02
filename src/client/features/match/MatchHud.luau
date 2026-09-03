--!strict
--[[
	MatchHud.luau
	Gestión del HUD de partida: timer, barras de equipo, indicador del equipo que
	va ganando, fichas de jugadores, cash/level, y tracking de kills/deaths/bots.

	Estructura esperada, toda bajo el frame `MatchHud.Container`:
		GlobalKillFeedContainer.Template
		(Cash.Value y Level.{Value, Bar.Fill} son opcionales: ya no están en el
		 asset, el cash in-match se ve en el popup Stats)
		MainFrame.Timer
		MainFrame.{ATeamBar, BTeamBar}.{Fill, Value}
		MainFrame.{ATeamIndicator, BTeamIndicator}   (spritesheet 2x2)
		MainFrame.{ATeamPlayers, BTeamPlayers}.Template.Value
	Los popups (LevelUp, Maestry) los resuelve MatchNotificationsQueue, también
	bajo Container; el de ganancias (Stats.{CoinsFrame.Value, CoinsSpawn}), que
	entra y sale por la izquierda en cada kill, lo lleva StatsCoinsPopup.
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

-- ── Colores ──────────────────────────────────────────────────
-- Las kills del jugador local se resaltan en dorado; el resto del roster va en
-- blanco para que se localice de un vistazo cuál de las fichas es la suya.
local LOCAL_PLAYER_KILLS_COLOR = Color3.fromRGB(255, 194, 0)
local OTHER_PLAYER_KILLS_COLOR = Color3.fromRGB(255, 255, 255)

-- ── Indicador de equipo ganador ──────────────────────────────
-- ATeamIndicator/BTeamIndicator son spritesheets 2x2 de 512x512 (4 frames).
local TEAM_INDICATOR_SHEET_SIZE = Vector2.new(512, 512)
local TEAM_INDICATOR_COLUMNS = 2
local TEAM_INDICATOR_ROWS = 2
local TEAM_INDICATOR_TOTAL_FRAMES = TEAM_INDICATOR_COLUMNS * TEAM_INDICATOR_ROWS
local TEAM_INDICATOR_TILE_SIZE = Vector2.new(
	TEAM_INDICATOR_SHEET_SIZE.X / TEAM_INDICATOR_COLUMNS,
	TEAM_INDICATOR_SHEET_SIZE.Y / TEAM_INDICATOR_ROWS
)
local TEAM_INDICATOR_FRAME_TIME = 1 / 13

-- ── Timer efectos ────────────────────────────────────────────
local TIMER_ALERT_THRESHOLD = 20         -- ≤ este valor: naranja + escala grande
local TIMER_CRITICAL_THRESHOLD = 10      -- ≤ este valor: rojo + blink + pulso
local TIMER_NORMAL_COLOR = Color3.fromRGB(255, 255, 255)
local TIMER_ALERT_COLOR = Color3.fromRGB(255, 140, 0)
local TIMER_CRITICAL_COLOR = Color3.fromRGB(255, 50, 50)
local TIMER_BLINK_TWEEN_INFO = TweenInfo.new(
	0.35,
	Enum.EasingStyle.Sine,
	Enum.EasingDirection.InOut,
	-1,    -- repeat infinitely
	true   -- reverse
)
local TIMER_PULSE_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TIMER_BASE_SCALE_TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TIMER_BASE_SCALE = 1
local TIMER_LARGE_SCALE = 1.4
local TIMER_PULSE_FACTOR = 1.2  -- multiplicador sobre la escala base
local TIMER_BLINK_FLASH_COLOR = Color3.fromRGB(255, 255, 255)

-- ── Tipos ────────────────────────────────────────────────────

-- Una ficha de jugador clonada de `Template`: la raíz es la ImageLabel con la
-- foto de perfil y `Value` el TextLabel con sus kills.
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
	historicalKills: number,
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
	-- Apariencia para la réplica de Resultados. Para bots viene del roster; para
	-- jugadores reales queda vacía (la réplica usa el loadout local si es el local).
	outfitId: string,
	faceId: string,
	hatId: string,
}

-- ── Helpers de llenado de barras ─────────────────────────────

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

-- "XX:XX" para el label del timer, más los segundos totales para los efectos.
local function _formatMatchTime(timeLeft: number): (string, number)
	local totalSeconds = math.max(0, math.floor(timeLeft))
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds % 60
	return string.format("%02d:%02d", minutes, seconds), totalSeconds
end

-- Value de ATeamBar/BTeamBar: puntos actuales sobre el objetivo de la partida.
local function _setTeamBarValue(valueLabel: TextLabel?, score: number, objective: number)
	if not valueLabel then
		return
	end
	valueLabel.RichText = true
	valueLabel.Text = UIUtils.formatProgressValue(score, objective)
end

-- Devuelve (color, isCritical) según el segundo restante.
local function _resolveTimerColor(totalSeconds: number): (Color3, boolean)
	if totalSeconds <= TIMER_CRITICAL_THRESHOLD then
		return TIMER_CRITICAL_COLOR, true
	elseif totalSeconds <= TIMER_ALERT_THRESHOLD then
		return TIMER_ALERT_COLOR, false
	end
	return TIMER_NORMAL_COLOR, false
end

-- Deja el ImageLabel del indicador recortado al primer tile del spritesheet y
-- oculto; el bucle de animación solo mueve el ImageRectOffset.
local function _initTeamIndicator(indicator: ImageLabel?)
	if not indicator then
		return
	end
	indicator.ImageRectSize = TEAM_INDICATOR_TILE_SIZE
	indicator.ImageRectOffset = Vector2.zero
	indicator.Visible = false
end

-- Devuelve un UIScale hijo del label (creándolo si no existe).
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

-- ── Resolución de filas de jugadores ─────────────────────────

-- Cada contenedor de equipo trae un único `Template` (la ficha) que clonamos por
-- jugador. Lo ocultamos al resolverlo: el UIListLayout del contenedor ignora los
-- hijos invisibles, así que la plantilla no ocupa hueco en la fila.
local function _resolveRowTemplate(playersFrame: GuiObject?): GuiObject?
	if not playersFrame then
		return nil
	end
	local template = playersFrame:WaitForChild("Template") :: GuiObject
	template.Visible = false
	return template
end

-- El UIListLayout ordena por Name, así que el nombre del clon codifica el puesto.
-- En el equipo A el mejor va a la derecha (nombre más alto) y en el B a la
-- izquierda (nombre más bajo); `rank` llega 1 = mejor.
local function _rowSortName(side: string, rank: number, total: number): string
	local position = if side == "A" then (total - rank + 1) else rank
	return string.format("%02d", position)
end

-- ── Resolución de HUD refs ───────────────────────────────────

local function _resolveHudRefs(matchHudGui: ScreenGui?): HudRefs
	if not matchHudGui then
		return {
			timer = nil,
			teamABarFill = nil, teamBBarFill = nil,
			teamABarValue = nil, teamBBarValue = nil,
			teamAIndicator = nil, teamBIndicator = nil,
			cashValue = nil, levelValue = nil, levelBarFill = nil,
			version = nil,
			teamAPlayersFrame = nil, teamBPlayersFrame = nil,
			teamATemplate = nil, teamBTemplate = nil,
		}
	end

	local container = matchHudGui:WaitForChild("Container") :: Frame
	local mainFrame = container:WaitForChild("MainFrame") :: Frame
	-- Cash y Level ya no están en el HUD de partida (el cash in-match se ve en el
	-- popup Stats). Se resuelven opcionalmente: si el asset los trae, se siguen
	-- pintando; si no, updateCashLevel salta esos campos.
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

-- ── Módulo MatchHud (OOP) ────────────────────────────────────

local MatchHud = {}
MatchHud.__index = MatchHud

function MatchHud.new(matchHudGui: ScreenGui?): any
	local self = setmetatable({}, MatchHud)
	self._gui = matchHudGui
	self._hudRefs = _resolveHudRefs(matchHudGui)
	self._localUserId = Players.LocalPlayer.UserId
	self._destroyed = false
	self._janitor = Janitor.new()
	-- Indicador del equipo que va ganando: un único bucle de spritesheet vivo
	-- mientras hay indicador visible, invalidado por token en cada cambio.
	_initTeamIndicator(self._hudRefs.teamAIndicator)
	_initTeamIndicator(self._hudRefs.teamBIndicator)
	self._indicatorSide = nil :: string?
	self._indicatorToken = 0
	-- Queue de animaciones in-match (level up / BP level up / challenge done).
	-- Extraído a su propio módulo para que MatchHud no orqueste tweens y
	-- confetti; los callers siguen usando `hud:playXxxAnimation(...)`.
	self._notificationsQueue = MatchNotificationsQueue.new(matchHudGui)
	-- Mientras hay una notificación in-match en pantalla, ocultamos las filas de
	-- jugadores (ATeamPlayers/BTeamPlayers); reaparecen al vaciarse la cola.
	self._notificationsQueue:setOnNotifyingChanged(function(notifying)
		self:_setTeamPlayersHidden(notifying)
	end)
	-- Popup de ganancias (Container.Stats): lo dispara updateCashLevel cuando el
	-- cash sube durante la partida (kill / headshot / asistencia).
	self._statsCoinsPopup = StatsCoinsPopup.new(matchHudGui)
	-- Último cash visto en DataController; nil hasta la primera lectura para no
	-- animar el total inicial como si fuera una ganancia.
	self._lastCashSeen = nil :: number?
	-- Total que el popup tiene pintado ahora mismo = cash real − lo reservado por
	-- desafíos aún sin entregar (ver reserveChallengeCash).
	self._lastVisibleCash = nil :: number?
	self._reservedChallengeCash = 0
	self._pendingCash = 0
	self._cashFlushQueued = false
	self._hudEnabled = false
	-- El popup del desafío completado suelta sus monedas hacia Stats; devolvemos
	-- lo que tarda el vuelo para que no se retire antes de que aterricen.
	self._notificationsQueue:setOnChallengeReward(function(spawnNode: ImageLabel, amount: number): number?
		return self:_deliverChallengeCash(spawnNode, amount)
	end)

	if matchHudGui then
		self._globalKillFeed = GlobalKillFeed.new(matchHudGui, self)
		self._janitor:Add(self._globalKillFeed, "Destroy")
	end

	-- Stats overlay: "vX | Yms[ | Zfps]" en Container.Version cada 1s.
	-- En producción NO conectamos RenderStepped (cada conexión tiene overhead
	-- fijo y este FPS counter solo es útil en dev). En Studio sí contamos
	-- frames para mostrar el campo "Zfps". Trackeamos la RenderStepped + el
	-- loop de versión en el janitor para que un destroy() no apile listeners
	-- ni deje task.spawn infinitos escribiendo en un label cuyo padre fue
	-- destruido.
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

	-- Tracking de partida
	self._killsByUserId = {} :: { [number]: number }
	self._deathsByUserId = {} :: { [number]: number }
	self._assistsByUserId = {} :: { [number]: number }
	self._botRoster = {} :: { [number]: BotRosterEntry }
	-- Último equipo ("A"/"B") conocido del jugador local, cacheado durante la
	-- partida. Al acabar la ronda su Character puede desaparecer/quedar sin Team,
	-- así que esto es el fallback fiable para los Resultados.
	self._lastKnownLocalSide = nil :: string?
	-- Cosméticos de compañeros reales (outfit/face/hat) para sus réplicas en
	-- Resultados. Lo llena el packet TeamCosmetics.
	self._playerCosmeticsByUserId = {} :: { [number]: PlayerCosmetics }

	-- Thumbnails
	self._thumbnailByUserId = {} :: { [number]: string }
	self._thumbnailRequestInFlight = {} :: { [number]: boolean }

	-- Filas del HUD: pool de clones de `Template` por equipo, creados bajo demanda
	-- y reutilizados entre updates (el rowKey "A1"/"B2" indexa este pool, no el
	-- orden visual, que lo decide el Name del clon).
	self._playerRows = { A = {} :: { HudPlayerRowRefs }, B = {} :: { HudPlayerRowRefs } }
	self._rowUserIdByKey = {} :: { [string]: number? }
	self._updateQueued = false

	-- Timer effects state
	self._timerLastSecond = -1
	self._timerBlinkTween = nil :: Tween?
	self._timerPulseTween = nil :: Tween?
	self._timerBaseScaleTween = nil :: Tween?
	self._timerCurrentBaseScale = TIMER_BASE_SCALE
	self._timerScale = nil :: UIScale?

	if matchHudGui then
		matchHudGui.Enabled = false
	end

	self:resetMatchState()

	return self
end

-- ── API pública ──────────────────────────────────────────────

function MatchHud:setEnabled(enabled: boolean)
	self._hudEnabled = enabled
	if self._gui then
		self._gui.Enabled = enabled
	end
	if not enabled then
		self:_clearTimerEffects()
		-- Corta el bucle del spritesheet mientras el HUD no está en pantalla.
		self:_setWinningTeam(nil)
		-- Sin partida no hay ganancias que enseñar: corta monedas en vuelo y deja
		-- el frame fuera de pantalla para la siguiente. Las reservas de premios que
		-- se hayan quedado sin entregar (popup cortado a medias) se liberan aquí
		-- para que el label vuelva a cuadrar con el cash real.
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

-- Muestra el indicador del equipo que va ganando ("A"/"B"), o ninguno si empatan.
-- Anima el spritesheet 2x2 a 13fps con un único bucle: cada cambio invalida el
-- anterior vía token, así que nunca hay dos corriendo a la vez.
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

-- Cancela los tweens del timer y resetea visuals (color blanco, escala 1, sin transparencia).
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

-- Aplica color, blink, formato y pulso al label del timer según los segundos restantes.
-- El pulso se dispara solo cuando cambia el segundo (no cada frame), reduciendo coste en móvil.
function MatchHud:_updateTimerEffects(timerLabel: TextLabel, totalSeconds: number)
	local color, isCritical = _resolveTimerColor(totalSeconds)

	-- Blink: alterna entre rojo y blanco. Solo activo en estado crítico.
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

	-- Escala base: > 20s = 1.0; ≤ 20s = más grande.
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
		-- Solo animamos la transición si NO estamos en crítico (en crítico el pulso se encarga).
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

	-- Pulso: solo en crítico y al cambiar el segundo. Pulse_factor multiplica la escala base.
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
		-- Saliendo de crítico (pero sigue en alerta o normal): cancelar pulso.
		self._timerPulseTween:Cancel()
		self._timerPulseTween = nil
	end

	self._timerLastSecond = totalSeconds
end

function MatchHud:setScores(scoreA: number, scoreB: number, timeLeft: number)
	local refs = self._hudRefs

	local clampedA = math.max(0, scoreA)
	local clampedB = math.max(0, scoreB)

	-- Barras por equipo: el Fill avanza con el score respecto al objetivo de la
	-- partida (WinScoreLimit) y el Value muestra "score/objetivo".
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

-- Tipos públicos exportados desde MatchNotificationsQueue. Se re-exportan
-- aquí para mantener la API estable de MatchHud (callers usan estos tipos).
export type MasteryProgress = MatchNotificationsQueue.MasteryProgress
export type DailyTaskProgress = MatchNotificationsQueue.DailyTaskProgress

-- Las animaciones de notificación (LevelUp / BPLevelUp / Maestry + confetti
-- + slide context) viven en MatchNotificationsQueue. Mantenemos delegadores
-- en MatchHud para no romper callers existentes.

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

--- Aparta `amount` de la próxima subida de cash: ese dinero NO lo anima el popup
--- de Stats por su cuenta, lo entrega el popup del desafío volando sus monedas
--- (ver _deliverChallengeCash). Se llama al detectar el desafío completado, en la
--- misma tanda de datos en la que llega el cash.
function MatchHud:reserveChallengeCash(amount: number)
	local reserved = math.max(0, math.floor(if type(amount) == "number" then amount else 0))
	if reserved <= 0 then
		return
	end
	self._reservedChallengeCash += reserved
end

--- Entrega un premio reservado: las monedas salen de `spawnNode` (el CoinsSpawn
--- del popup del desafío) y al aterrizar suben el total de Stats. Devuelve la
--- duración del vuelo.
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
	-- Si el cash del premio todavía no llegó (o nunca se reservó), volamos igual
	-- las monedas del importe: el popup satura en su total y no se pasa de largo.
	local delta = if visibleCash > previousVisible then visibleCash - previousVisible else claimed
	return popup:addCashFrom(delta, visibleCash, spawnNode)
end

function MatchHud:updateCashLevel(stats: any)
	local refs = self._hudRefs

	local cash = if stats and type(stats.Cash) == "number" then math.max(0, math.floor(stats.Cash)) else 0
	if refs.cashValue then
		refs.cashValue.Text = UIUtils.formatCashAmount(cash)
	end

	-- Ganancias in-match: cualquier subida de cash con el HUD en pantalla entra
	-- por el popup Stats. El disparo se difiere (ver _flushCash) porque el premio
	-- de un desafío llega en la misma tanda que su reserva.
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

-- El cash y el estado de los desafíos llegan en el MISMO BatchUpdate del server, y
-- no está definido cuál de los dos listeners corre antes. Por eso no animamos en el
-- acto: diferimos al final del ciclo, cuando las reservas de premios de esta misma
-- tanda ya están registradas y sabemos qué parte de la subida entrega el popup del
-- desafío y qué parte anima Stats por su cuenta.
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
	-- Lo reservado aún sin entregar no cuenta como visible; y el total visible
	-- nunca baja por una reserva (si el premio se reserva antes de que llegue su
	-- cash, el label se queda quieto en vez de descontar).
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
	-- NOTE: _botRoster no se limpia aquí porque el servidor lo envía
	-- de forma asíncrona vía Network.Match.BotRoster y puede llegar
	-- antes de JoinMatchSpawned. Se reemplaza completamente cada vez
	-- que llega un BotRoster nuevo desde el servidor.
	self._killsByUserId[self._localUserId] = 0
	self._deathsByUserId[self._localUserId] = 0
	self._assistsByUserId[self._localUserId] = 0
	self:_clearTimerEffects()
	self:queuePlayerRowsUpdate()
end

function MatchHud:applyPlayerState(userId: number, kills: number, deaths: number?, assists: number?)
	local oldKills = self._killsByUserId[userId] or 0
	local newKills = math.max(0, kills)
	self._killsByUserId[userId] = newKills
	if deaths ~= nil then
		-- El servidor envía deaths para TODOS los userIds. Antes la guarda
		-- `userId < 0` solo guardaba bots, así que los demás jugadores reales
		-- aparecían con 0 deaths en el marcador/Resultados. Guardamos a todos
		-- EXCEPTO el jugador local, cuyas deaths las lleva incrementLocalDeaths
		-- (inmediato en DeathScreenShow) — evita doble conteo y latencia.
		if userId ~= self._localUserId then
			self._deathsByUserId[userId] = math.max(0, deaths)
		end
	end
	if assists ~= nil then
		self._assistsByUserId[userId] = math.max(0, assists)
	end

	-- Fast paths para evitar reconstruir + ordenar las 12 filas en cada kill:
	-- 1) Si los kills no cambiaron, no hay nada que refrescar en la fila (el
	--    row sólo muestra totalKills; deaths no aparecen ahí).
	-- 2) Si los kills cambiaron pero el cambio no cruza el kill-count de ningún
	--    teammate (no hay reorder), actualizamos solo la fila del userId
	--    afectado y evitamos el rebuild + sort completo.
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

--- Captura datos (kills/assists/deaths/level/equipo) para la pantalla de
--- Resultados antes de resetear el roster.
function MatchHud:captureEndResultsData(): (string, { EndResultsPlayerEntry })
	-- Resolución robusta del equipo: al acabar la ronda el Character del jugador
	-- local puede haber desaparecido o quedado sin Team, dejando localTeam="" (→
	-- Resultados filtraba a un equipo vacío: ni frames ni réplicas). Caemos a
	-- Player.Team, al atributo TeamName, y por último al equipo cacheado en partida.
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

		-- Cosméticos de compañeros reales (del packet TeamCosmetics). El jugador
		-- local queda vacío: su réplica usa el loadout local en ResultsView.
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

-- ── Player rows internos ─────────────────────────────────────

-- Devuelve la ficha `index` del equipo, clonando `Template` la primera vez. El
-- clon nace invisible y con nombre neutro: el puesto real (que decide el orden
-- del UIListLayout) lo escribe _updatePlayerRows.
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

	-- La ficha es la propia ImageLabel (la foto de perfil); toleramos que el
	-- asset la anide por si el Template pasa a ser un Frame contenedor.
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

-- `isLocalPlayer` nil = no tocar el color (lo usa el fast path incremental, que
-- solo refresca el número).
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
	-- Safety timeout: si GetUserThumbnailAsync se cuelga, liberamos el flag tras
	-- 30s para que un siguiente intento pueda volver a pedir.
	task.delay(30, function()
		if self._destroyed then
			return
		end
		if self._thumbnailRequestInFlight[userId] then
			self._thumbnailRequestInFlight[userId] = nil
		end
	end)
	task.spawn(function()
		-- Audit mobile: jitter inicial 0-0.4s para desfasar el batch de
		-- 6+ thumbnails que se piden en el mismo frame al entrar al match.
		-- GetUserThumbnailAsync hace yield real (request al backend Roblox);
		-- en conexiones flaky de móvil, 6 fires simultáneos pueden bloquear
		-- task scheduler slots en cascada. Los thumbnails son cosméticos —
		-- 0-400ms de retraso es invisible.
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
		-- Guard: si el row ya muestra otro userId o el ImageLabel perdió parent
		-- (HUD destruido en cascada), no escribimos en una referencia muerta.
		if self._rowUserIdByKey[rowKey] ~= userId or not profileRef.Parent then
			return
		end
		profileRef.Image = content
	end)
end

function MatchHud:_applyRowEntry(
	rowRef: HudPlayerRowRefs,
	rowKey: string,
	entry: { userId: number, image: string?, isBot: boolean, team: string? }?
)
	rowRef.root.Visible = entry ~= nil
	if not entry then
		self:_clearRow(rowRef, rowKey)
		return
	end

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

-- Devuelve el team ("A"/"B") del userId si está visible en alguna fila, leyendo
-- el rowKey ya cacheado en `_rowUserIdByKey`. Más barato que resolver el team
-- por Players.GetPlayerByUserId + TeamUtils en el hot path de cada kill.
function MatchHud:_findRowForUserId(userId: number): (HudPlayerRowRefs?, string?)
	for rowKey, rowUserId in pairs(self._rowUserIdByKey) do
		if rowUserId == userId then
			local team = string.sub(rowKey, 1, 1)
			local idx = tonumber(string.sub(rowKey, 2))
			if not idx then
				return nil, nil
			end
			local pool = self._playerRows[team]
			return if pool then pool[idx] else nil, team
		end
	end
	return nil, nil
end

-- Si el cambio de kills no altera el orden relativo del team, actualizamos solo
-- la fila del userId afectado. Devuelve true si se hizo el fast path; false si
-- el caller debe caer al full rebuild via queuePlayerRowsUpdate().
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

-- Oculta/muestra los contenedores de filas de jugadores (no toca las filas
-- individuales, así conservan su estado al reaparecer). Lo dispara la cola de
-- notificaciones para que un popup no se solape con el roster.
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
				-- Cache para Resultados (ver captureEndResultsData).
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

	-- `entries` viene mejor-primero; el puesto visual lo pone el Name del clon
	-- (_rowSortName), así que aquí solo emparejamos ficha ↔ jugador por ranking.
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

		-- Fichas sobrantes del pool: ocultas y libres para el siguiente update.
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
	-- Invalida el bucle del spritesheet del indicador (el janitor destruye las
	-- fichas clonadas, pero el task.spawn se corta por token).
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
