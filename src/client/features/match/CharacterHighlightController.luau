--!strict
-- CharacterHighlightController: aplica un Highlight client-side a cada
-- character (player o bot) distinto del LocalPlayer, coloreado según si
-- es aliado (verde) o enemigo (rojo) desde la perspectiva local.
--
-- Diseño:
-- - El Highlight se crea EN CLIENTE — no se replica al servidor ni a otros
--   clientes. Esto evita Z-fighting con cualquier Highlight baked-in en los
--   templates de body/NPC y centraliza la lógica visual en un solo lugar.
-- - Cubre tanto jugadores reales como bots con una única pasada de detección
--   sobre workspace.DescendantAdded + Players.PlayerAdded.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local HIGHLIGHT_NAME = "CharacterHighlight"
local COLOR_ALLY   = Color3.fromRGB(0, 210, 80)
local COLOR_ENEMY  = Color3.fromRGB(220, 40, 40)
local FILL_ALPHA   = 0.65
local OUTLINE_ALPHA = 0.1

local localPlayer = Players.LocalPlayer

local CharacterHighlightController = {}

-- D2: tracking explícito de listeners. Sin esto, cada Start() (e.g. hot
-- reload de MatchFeature) duplicaba conexiones DescendantAdded y Team.
local _moduleConns: { RBXScriptConnection } = {}
local _trackedHighlights: { [Model]: Highlight } = {}
local _trackedConns: { [Model]: { RBXScriptConnection } } = {}
local _started = false

-- ────────────────────────────────────────────────────────────────
-- Helpers
-- ────────────────────────────────────────────────────────────────

local function _isBotModel(model: Model): boolean
	-- AIService stampea `BotTeam` antes de parentar al workspace, así que
	-- en DescendantAdded ya está disponible. Más fiable que el name match.
	return model:GetAttribute("BotTeam") ~= nil
end

local function _shouldTrack(model: Model): boolean
	local owner = Players:GetPlayerFromCharacter(model)
	if owner == localPlayer then
		-- LocalPlayer nunca se trackea a sí mismo.
		return false
	end
	if owner then
		return true
	end
	return _isBotModel(model)
end

local function _refreshColor(model: Model)
	local highlight = _trackedHighlights[model]
	if not highlight then
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

	-- Players reales pueden cambiar de team mid-match. Bots no (su attribute
	-- BotTeam se setea al spawn y no muta), así que solo conectamos para players.
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		table.insert(conns, player:GetPropertyChangedSignal("Team"):Connect(function()
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

local function _onDescendantAdded(instance: Instance)
	if instance:IsA("Model") then
		_attach(instance :: Model)
	end
end

local function _wirePlayer(player: Player)
	if player == localPlayer then
		return
	end
	local function onChar(char: Model)
		_attach(char)
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
	if prescannedModels then
		for _, model in prescannedModels do
			_attach(model)
		end
	else
		for _, desc in workspace:GetDescendants() do
			if desc:IsA("Model") then
				_attach(desc :: Model)
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
end

return CharacterHighlightController
