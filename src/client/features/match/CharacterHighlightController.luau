--!strict
-- CharacterHighlightController: aplica un Highlight client-side a cada
-- character (player o bot), coloreado según relación con el LocalPlayer:
--   · aliado → verde (fill semi-transparente)
--   · enemigo → rojo  (fill semi-transparente)
--   · self    → outline negro, sin fill
--
-- Diseño:
-- - El Highlight se crea EN CLIENTE — no se replica al servidor ni a otros
--   clientes. Esto evita Z-fighting con cualquier Highlight baked-in en los
--   templates de body/NPC y centraliza la lógica visual en un solo lugar.
-- - Cubre tanto jugadores reales como bots con una única pasada de detección
--   sobre workspace.DescendantAdded + Players.PlayerAdded.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local HIGHLIGHT_NAME = "CharacterHighlight"
local COLOR_ALLY   = Color3.fromRGB(0, 210, 80)
local COLOR_ENEMY  = Color3.fromRGB(220, 40, 40)
local COLOR_LOCAL  = Color3.fromRGB(0, 0, 0)
local FILL_ALPHA   = 0.65
local OUTLINE_ALPHA = 0.1

-- Flash verde sobre el highlight del jugador local al absorber un orbe de vida:
-- entra rápido a verde con fill visible y vuelve suave al estado base (contorno
-- negro, sin fill). Umbral igual al de HealthBarController para no flashear con
-- la regen de 1 HP/s.
local HEAL_FLASH_COLOR = Color3.fromRGB(60, 255, 120)
local HEAL_FLASH_FILL_ALPHA = 0.4
local HEAL_FLASH_THRESHOLD = 5
local HEAL_FLASH_HOLD = 0.45 -- segundos que el verde se mantiene antes de desvanecerse
local TI_HEAL_FLASH_IN  = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_HEAL_FLASH_OUT = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Atributos que indican team — mismos que TeamUtils.getSide consulta. Cuando
-- cualquiera de estos cambia (incluido el primer set vía replicación tardía
-- desde el server), re-evaluamos el color del highlight.
local TEAM_ATTRS_TO_WATCH = { "Team", "TeamSide", "BotTeam", "Side", "TeamAffinity" }

local localPlayer = Players.LocalPlayer

local CharacterHighlightController = {}

-- D2: tracking explícito de listeners. Sin esto, cada Start() (e.g. hot
-- reload de MatchFeature) duplicaba conexiones DescendantAdded y Team.
local _moduleConns: { RBXScriptConnection } = {}
local _trackedHighlights: { [Model]: Highlight } = {}
local _trackedConns: { [Model]: { RBXScriptConnection } } = {}
local _started = false

-- Flash de heal del jugador local
local _healFlashToken = 0
local _healFlashTweens: { Tween } = {}
local _localLastHealth: number? = nil

-- ────────────────────────────────────────────────────────────────
-- Helpers
-- ────────────────────────────────────────────────────────────────

local function _hasAnyTeamAttribute(model: Model): boolean
	for _, attrName in TEAM_ATTRS_TO_WATCH do
		if model:GetAttribute(attrName) ~= nil then
			return true
		end
	end
	return false
end

local function _shouldTrack(model: Model): boolean
	if not model:FindFirstChildOfClass("Humanoid") then
		return false
	end
	local owner = Players:GetPlayerFromCharacter(model)
	-- Players reales (incluido localPlayer): trackear siempre.
	if owner then
		return true
	end
	-- NPCs/bots: requerir algún atributo de team. Esto distingue chars de
	-- gameplay (siempre llevan team) de dummies de UI (locker preview, kill
	-- effect dummy, menu) que tienen Humanoid pero no team. Si el atributo aún
	-- no replicó, _onDescendantAdded reintenta vía GetAttributeChangedSignal.
	return _hasAnyTeamAttribute(model)
end

local function _refreshColor(model: Model)
	local highlight = _trackedHighlights[model]
	if not highlight then
		return
	end
	-- LocalPlayer's own char: outline negro, sin fill.
	if model == localPlayer.Character then
		highlight.FillColor = COLOR_LOCAL
		highlight.OutlineColor = COLOR_LOCAL
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = OUTLINE_ALPHA
		return
	end
	local localChar = localPlayer.Character
	local isAlly = localChar ~= nil and TeamUtils.isSameTeam(localChar, model)
	local color = if isAlly then COLOR_ALLY else COLOR_ENEMY
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = FILL_ALPHA
	highlight.OutlineTransparency = OUTLINE_ALPHA
end

-- Pulso verde breve sobre el highlight del jugador local (orbe de vida). Entra a
-- verde con fill visible y vuelve al estado base. El token invalida un flash
-- previo si llega otro heal antes de terminar.
local function _flashLocalHeal()
	local char = localPlayer.Character
	if not char then
		return
	end
	local highlight = _trackedHighlights[char]
	if not highlight then
		return
	end

	_healFlashToken += 1
	local token = _healFlashToken
	for _, t in _healFlashTweens do
		t:Cancel()
	end
	table.clear(_healFlashTweens)

	local tweenIn = TweenService:Create(highlight, TI_HEAL_FLASH_IN, {
		FillColor = HEAL_FLASH_COLOR,
		OutlineColor = HEAL_FLASH_COLOR,
		FillTransparency = HEAL_FLASH_FILL_ALPHA,
		OutlineTransparency = 0,
	})
	_healFlashTweens[#_healFlashTweens + 1] = tweenIn
	tweenIn.Completed:Once(function(state)
		if state ~= Enum.PlaybackState.Completed or _healFlashToken ~= token then
			return
		end
		-- Mantener el verde un instante (HEAL_FLASH_HOLD) antes de desvanecer, para
		-- que dure un poco más. El token invalida el hold si llega otro heal.
		task.delay(HEAL_FLASH_HOLD, function()
			if _healFlashToken ~= token then
				return
			end
			-- Vuelta al estado base del self (contorno negro, sin fill).
			local tweenOut = TweenService:Create(highlight, TI_HEAL_FLASH_OUT, {
				FillColor = COLOR_LOCAL,
				OutlineColor = COLOR_LOCAL,
				FillTransparency = 1,
				OutlineTransparency = OUTLINE_ALPHA,
			})
			_healFlashTweens[#_healFlashTweens + 1] = tweenOut
			tweenOut:Play()
		end)
	end)
	tweenIn:Play()
end

local function _detach(model: Model)
	local highlight = _trackedHighlights[model]
	if highlight then
		_trackedHighlights[model] = nil
		if highlight.Parent then
			highlight:Destroy()
		end
	end
	local conns = _trackedConns[model]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		_trackedConns[model] = nil
	end
end

local function _attach(model: Model)
	if _trackedHighlights[model] then
		return
	end
	if not _shouldTrack(model) then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = HIGHLIGHT_NAME
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model
	_trackedHighlights[model] = highlight

	local conns: { RBXScriptConnection } = {}

	-- Players reales pueden cambiar de team mid-match.
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		table.insert(conns, player:GetPropertyChangedSignal("Team"):Connect(function()
			_refreshColor(model)
		end))
	end

	-- Char del jugador local: detectar heals discretos (orbe de vida, etc.) para
	-- el flash verde. Umbral filtra la regen lenta. lastHealth se reinicia por
	-- char (respawn) y se compara solo cuando ya hay baseline.
	if player == localPlayer then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			_localLastHealth = humanoid.Health
			table.insert(conns, humanoid.HealthChanged:Connect(function(newHealth: number)
				if _localLastHealth ~= nil and newHealth - _localLastHealth >= HEAL_FLASH_THRESHOLD then
					_flashLocalHeal()
				end
				_localLastHealth = newHealth
			end))
		end
	end

	-- Re-evaluar color cuando llegue/cambie cualquier atributo de team. Para
	-- bots los atributos no mutan, pero el primer set vía replicación puede
	-- llegar después del _attach inicial — sin este listener el color quedaría
	-- rojo (default cuando getSide devuelve nil).
	for _, attrName in TEAM_ATTRS_TO_WATCH do
		table.insert(conns, model:GetAttributeChangedSignal(attrName):Connect(function()
			_refreshColor(model)
		end))
	end

	-- Cleanup cuando el char sale del workspace (death/despawn/removal).
	-- AncestryChanged cubre tanto Destroy() como reparenteo.
	table.insert(conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			_detach(model)
		end
	end))

	_trackedConns[model] = conns
	_refreshColor(model)
end

local function _refreshAll()
	for model in _trackedHighlights do
		_refreshColor(model)
	end
end

-- ────────────────────────────────────────────────────────────────
-- Wiring
-- ────────────────────────────────────────────────────────────────

-- Pending retries para Models que entraron al workspace sin Humanoid aún.
-- Mantenemos las conns para limpiarlas cuando el model sale o se attacha.
local _pendingRetryConns: { [Model]: { RBXScriptConnection } } = {}
-- Threads de los task.delay de retry: sin cancelarlos mantenían viva la
-- referencia al model hasta 2s tras salir del workspace (retraso de GC).
local _pendingRetryThreads: { [Model]: { thread } } = {}

local function _cleanupRetry(model: Model)
	local conns = _pendingRetryConns[model]
	if conns then
		for _, c in conns do
			c:Disconnect()
		end
		_pendingRetryConns[model] = nil
	end
	local threads = _pendingRetryThreads[model]
	if threads then
		for _, t in threads do
			-- pcall: el thread que ejecuta este cleanup (o uno ya terminado) no
			-- es cancelable; los pendientes sí, liberando la referencia al model.
			pcall(task.cancel, t)
		end
		_pendingRetryThreads[model] = nil
	end
end

local function _onDescendantAdded(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance :: Model

	-- Audit mobile: filter heurística. Sin esto, _attach + 7 conns + 3
	-- task.delay se enganchaban a CADA Model que entra al workspace
	-- (props decorativos del mapa incluidos). Solo nos interesan
	-- characters de gameplay (player chars o bots en workspace.Bots).
	local parent = model.Parent
	local isBotChild = parent ~= nil and parent.Name == "Bots"
	local hasHumanoid = model:FindFirstChildOfClass("Humanoid") ~= nil
	local isPlayerChar = Players:GetPlayerFromCharacter(model) ~= nil
	if not (isBotChild or hasHumanoid or isPlayerChar) then
		return
	end

	_attach(model)
	if _trackedHighlights[model] then
		return
	end
	if _pendingRetryConns[model] then
		return
	end

	-- Casos que NO requieren retry:
	-- 1. Ya tiene Humanoid + algún team attr + owner check ya falló → no es un
	--    target válido (dummy del locker/menu, NPC sin team, etc.). Skip.
	-- 2. Es local player char (filtrado en _shouldTrack).
	-- En cualquier otro caso quedan dos posibles deltas: Humanoid o team attr
	-- llegando tarde por replicación. Conectamos ambos retries.
	-- (reutilizamos `hasHumanoid` calculado arriba en lugar de re-declararlo)
	local hasTeamAttr = _hasAnyTeamAttribute(model)
	if hasHumanoid and hasTeamAttr then
		-- Tiene todo lo que necesita pero _shouldTrack lo descartó (e.g. owner ==
		-- localPlayer). No reintentar.
		return
	end

	local conns: { RBXScriptConnection } = {}
	_pendingRetryConns[model] = conns

	local function tryRetry()
		_attach(model)
		if _trackedHighlights[model] then
			_cleanupRetry(model)
		end
	end

	-- Humanoid llegando tarde
	if not hasHumanoid then
		table.insert(conns, model.ChildAdded:Connect(function(child)
			if child:IsA("Humanoid") then
				tryRetry()
			end
		end))
	end

	-- Atributos de team llegando tarde (típico en bots: el Model replica antes
	-- que BotTeam/Team/TeamSide). Conectar a los 5 attrs que TeamUtils consulta.
	for _, attrName in TEAM_ATTRS_TO_WATCH do
		table.insert(conns, model:GetAttributeChangedSignal(attrName):Connect(tryRetry))
	end

	table.insert(conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			_cleanupRetry(model)
		end
	end))

	-- Fallback temporal: GetAttributeChangedSignal a veces NO dispara cuando un
	-- atributo se "establece" por replicación inicial (vs cuando muta en runtime).
	-- Reintentamos a 100ms, 500ms y 2s para cubrir replicación lenta sin polling
	-- continuo. Si ya se attachó, los retries son no-ops.
	_pendingRetryThreads[model] = {
		task.delay(0.1, tryRetry),
		task.delay(0.5, tryRetry),
		task.delay(2.0, tryRetry),
	}
end

local function _wirePlayer(player: Player)
	local function onChar(char: Model)
		_attach(char)
		-- Si es el LocalPlayer, refrescar TODOS los highlights porque cambió la
		-- referencia local — los enemigos/aliados pueden necesitar re-color.
		if player == localPlayer then
			_refreshAll()
		end
	end
	if player.Character then
		onChar(player.Character)
	end
	table.insert(_moduleConns, player.CharacterAdded:Connect(onChar))
end

function CharacterHighlightController:Start(prescannedModels: { Model }?)
	if _started then
		return
	end
	_started = true

	-- Scan compartido inicial (Models del workspace en el momento del Start).
	-- prescannedModels viene de match/init.luau para evitar un GetDescendants
	-- propio (compartido con HealthBillboardController).
	--
	-- Usamos _onDescendantAdded en vez de _attach directo: el pre-scan recoge
	-- models que pueden tener attrs aún no replicados (cliente entra a un match
	-- con bots ya spawneados). _attach fallaría silenciosamente; _onDescendantAdded
	-- conecta retries para volver a intentar cuando llegue Humanoid/team attr.
	if prescannedModels then
		for _, model in prescannedModels do
			_onDescendantAdded(model)
		end
	else
		for _, desc in workspace:GetDescendants() do
			if desc:IsA("Model") then
				_onDescendantAdded(desc :: Model)
			end
		end
	end

	-- DescendantAdded: filtro IsA("Model") descarta de inmediato la mayoría
	-- de adds (BaseParts, attachments, partículas, beams, etc.).
	table.insert(_moduleConns, workspace.DescendantAdded:Connect(_onDescendantAdded))

	-- Cuando el jugador local cambia de equipo, re-evaluar todos los chars.
	table.insert(_moduleConns, localPlayer:GetPropertyChangedSignal("Team"):Connect(_refreshAll))

	-- Players reales: cubrir altas (PlayerAdded) y las que ya están conectadas.
	table.insert(_moduleConns, Players.PlayerAdded:Connect(_wirePlayer))
	for _, p in Players:GetPlayers() do
		_wirePlayer(p)
	end
end

function CharacterHighlightController:Stop()
	if not _started then
		return
	end
	_started = false

	for _, conn in _moduleConns do
		conn:Disconnect()
	end
	table.clear(_moduleConns)

	-- Limpiar tracked: copiamos las keys porque _detach muta _trackedHighlights.
	local toDetach: { Model } = {}
	for model in _trackedHighlights do
		table.insert(toDetach, model)
	end
	for _, model in toDetach do
		_detach(model)
	end

	-- Limpiar también los retries pendientes (chars que entraron sin Humanoid
	-- y aún no lo recibieron).
	local pendingModels: { Model } = {}
	for model in _pendingRetryConns do
		table.insert(pendingModels, model)
	end
	for _, model in pendingModels do
		_cleanupRetry(model)
	end
end

return CharacterHighlightController
