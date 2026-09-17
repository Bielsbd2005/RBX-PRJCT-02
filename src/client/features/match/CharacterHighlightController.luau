--!strict
-- Highlight local (no replicado) en cada character, player o bot, coloreado según
-- su relación con el LocalPlayer.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local HIGHLIGHT_NAME = "CharacterHighlight"
-- Debe coincidir con el literal del server (RagdollCleanup.fadeAndDestroy); valor =
-- duración del fundido del cadáver.
local FADE_OUT_ATTR = "KillEffectFadeOut"
local COLOR_ALLY   = Color3.fromRGB(0, 210, 80)
local COLOR_ENEMY  = Color3.fromRGB(220, 40, 40)
local COLOR_LOCAL  = Color3.fromRGB(0, 0, 0)
local FILL_ALPHA   = 0.65
local OUTLINE_ALPHA = 0.1

-- Flash de heal del jugador local. Umbral igual al de HealthBarController, para
-- ignorar la regen. El fill queda casi transparente a propósito: el peso lo lleva
-- el contorno para no tapar la viñeta de HealthBarController ni HealEffect.
local HEAL_FLASH_COLOR = Color3.fromRGB(60, 255, 120)
local HEAL_FLASH_FILL_ALPHA = 0.82
local HEAL_FLASH_OUTLINE_ALPHA = 0
local HEAL_FLASH_THRESHOLD = 5
local HEAL_FLASH_HOLD = 0.45 -- s
local TI_HEAL_FLASH_IN  = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_HEAL_FLASH_OUT = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Deben ser los mismos que consulta TeamUtils.getSide.
local TEAM_ATTRS_TO_WATCH = { "Team", "TeamSide", "BotTeam", "Side", "TeamAffinity" }

local localPlayer = Players.LocalPlayer

local CharacterHighlightController = {}

local _moduleConns: { RBXScriptConnection } = {}
local _trackedHighlights: { [Model]: Highlight } = {}
local _trackedConns: { [Model]: { RBXScriptConnection } } = {}
local _started = false

local _healFlashToken = 0
local _healFlashTweens: { Tween } = {}
local _localLastHealth: number? = nil

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
	if owner then
		return true
	end
	-- Sin team = dummy de UI (preview del locker, menú), no se trackea.
	return _hasAnyTeamAttribute(model)
end

local function _refreshColor(model: Model)
	local highlight = _trackedHighlights[model]
	if not highlight then
		return
	end
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

-- El token invalida un flash previo si llega otro heal antes de terminar.
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
		OutlineTransparency = HEAL_FLASH_OUTLINE_ALPHA,
	})
	_healFlashTweens[#_healFlashTweens + 1] = tweenIn
	tweenIn.Completed:Once(function(state)
		if state ~= Enum.PlaybackState.Completed or _healFlashToken ~= token then
			return
		end
		task.delay(HEAL_FLASH_HOLD, function()
			if _healFlashToken ~= token then
				return
			end
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

-- Lineal para casar con el tween del cuerpo en RagdollCleanup.
local function _fadeOutHighlight(model: Model, fadeTime: number)
	local highlight = _trackedHighlights[model]
	if not highlight then
		return
	end
	local info = TweenInfo.new(fadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	TweenService:Create(highlight, info, {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()
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

	local player = Players:GetPlayerFromCharacter(model)
	if player then
		table.insert(conns, player:GetPropertyChangedSignal("Team"):Connect(function()
			_refreshColor(model)
		end))
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid

	if player == localPlayer then
		_localLastHealth = humanoid.Health
		table.insert(conns, humanoid.HealthChanged:Connect(function(newHealth: number)
			if _localLastHealth ~= nil and newHealth - _localLastHealth >= HEAL_FLASH_THRESHOLD then
				_flashLocalHeal()
			end
			_localLastHealth = newHealth
		end))
	end

	-- Se oculta de golpe al morir; el respawn crea un char nuevo con highlight propio.
	table.insert(conns, humanoid.Died:Connect(function()
		highlight.Enabled = false
	end))

	-- Los atributos de team pueden replicar después del _attach (sin team = rojo).
	for _, attrName in TEAM_ATTRS_TO_WATCH do
		table.insert(conns, model:GetAttributeChangedSignal(attrName):Connect(function()
			_refreshColor(model)
		end))
	end

	table.insert(conns, model:GetAttributeChangedSignal(FADE_OUT_ATTR):Connect(function()
		local fadeTime = model:GetAttribute(FADE_OUT_ATTR)
		if type(fadeTime) == "number" and fadeTime > 0 then
			_fadeOutHighlight(model, fadeTime)
		end
	end))

	table.insert(conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			_detach(model)
		end
	end))

	_trackedConns[model] = conns
	_refreshColor(model)

	local pendingFade = model:GetAttribute(FADE_OUT_ATTR)
	if type(pendingFade) == "number" and pendingFade > 0 then
		_fadeOutHighlight(model, pendingFade)
	end
end

local function _refreshAll()
	for model in _trackedHighlights do
		_refreshColor(model)
	end
end

local _pendingRetryConns: { [Model]: { RBXScriptConnection } } = {}
-- Se cancelan al limpiar para no retener el model hasta que venzan los delays.
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
			-- pcall: el thread que ejecuta este cleanup no es cancelable.
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

	-- Filtro barato para no enganchar retries a cada prop del mapa.
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

	-- Humanoid o atributos de team pueden llegar tarde por replicación.
	local conns: { RBXScriptConnection } = {}
	_pendingRetryConns[model] = conns

	local function tryRetry()
		_attach(model)
		if _trackedHighlights[model] then
			_cleanupRetry(model)
		end
	end

	if not hasHumanoid then
		table.insert(conns, model.ChildAdded:Connect(function(child)
			if child:IsA("Humanoid") then
				tryRetry()
			end
		end))
	end

	for _, attrName in TEAM_ATTRS_TO_WATCH do
		table.insert(conns, model:GetAttributeChangedSignal(attrName):Connect(tryRetry))
	end

	table.insert(conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			_cleanupRetry(model)
		end
	end))

	-- GetAttributeChangedSignal no siempre dispara con la replicación inicial de un
	-- atributo: reintentos puntuales como red de seguridad.
	_pendingRetryThreads[model] = {
		task.delay(0.1, tryRetry),
		task.delay(0.5, tryRetry),
		task.delay(2.0, tryRetry),
	}
end

local function _wirePlayer(player: Player)
	local function onChar(char: Model)
		_attach(char)
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

	-- prescannedModels: GetDescendants compartido desde match/init.luau. Pasan por
	-- _onDescendantAdded (no _attach) para tener retries si aún no replicó el team.
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

	table.insert(_moduleConns, workspace.DescendantAdded:Connect(_onDescendantAdded))

	table.insert(_moduleConns, localPlayer:GetPropertyChangedSignal("Team"):Connect(_refreshAll))

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

	local toDetach: { Model } = {}
	for model in _trackedHighlights do
		table.insert(toDetach, model)
	end
	for _, model in toDetach do
		_detach(model)
	end

	local pendingModels: { Model } = {}
	for model in _pendingRetryConns do
		table.insert(pendingModels, model)
	end
	for _, model in pendingModels do
		_cleanupRetry(model)
	end
end

return CharacterHighlightController
