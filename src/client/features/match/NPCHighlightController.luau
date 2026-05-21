--!strict
-- NPCHighlightController: colorea el Highlight de cada bot NPC
-- según si es aliado (verde) o enemigo (rojo) desde la perspectiva
-- del jugador local.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamUtils = require(Shared.utils.TeamUtils)

local COLOR_ALLY   = Color3.fromRGB(0, 210, 80)
local COLOR_ENEMY  = Color3.fromRGB(220, 40, 40)
local FILL_ALPHA   = 0.65
local OUTLINE_ALPHA = 0.1

local localPlayer = Players.LocalPlayer

-- ────────────────────────────────────────────────────────────────
-- Aplicar color a un highlight
-- ────────────────────────────────────────────────────────────────

local function _applyColor(highlight: Highlight, isAlly: boolean)
	local color = if isAlly then COLOR_ALLY else COLOR_ENEMY
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = FILL_ALPHA
	highlight.OutlineTransparency = OUTLINE_ALPHA
end

local function _colorBotHighlight(model: Model)
	local highlight = model:FindFirstChild("BotHighlight")
	if not highlight or not highlight:IsA("Highlight") then
		return
	end

	local localChar = localPlayer.Character
	local isAlly = localChar ~= nil and TeamUtils.isSameTeam(localChar, model)
	_applyColor(highlight :: Highlight, isAlly)
end

-- ────────────────────────────────────────────────────────────────
-- Vigilar nuevos bots en todo workspace (incluye mapRoot/Bots)
-- ────────────────────────────────────────────────────────────────

local function _isBotModel(instance: Instance): boolean
	if not instance:IsA("Model") then
		return false
	end
	local name = instance.Name
	return string.find(name, "^Bot_") ~= nil
end

local function _scanExisting(prescannedModels: { Model }?)
	-- Una pasada al arrancar / al cambiar el equipo local. Si el caller pasa
	-- `prescannedModels` (init.luau hace un solo scan compartido con
	-- HealthBillboard), reusamos esa lista.
	if prescannedModels then
		for _, model in prescannedModels do
			if _isBotModel(model) then
				_colorBotHighlight(model)
			end
		end
		return
	end
	for _, desc in workspace:GetDescendants() do
		if _isBotModel(desc) then
			_colorBotHighlight(desc :: Model)
		end
	end
end

local function _onDescendantAdded(instance: Instance)
	-- Caso 1: el Highlight se replica DESPUÉS que el modelo del bot (el servidor
	-- crea el highlight en BotAI:Start, que corre tras parentar el modelo). Esto
	-- es lo que provoca el bug del highlight "blanco": cuando dispara
	-- DescendantAdded para el Model, el Highlight aún no existe en el cliente.
	-- Por eso reaccionamos también al añadirse el propio Highlight.
	if instance:IsA("Highlight") and instance.Name == "BotHighlight" then
		local parent = instance.Parent
		if parent and _isBotModel(parent) then
			_colorBotHighlight(parent :: Model)
		end
		return
	end

	-- Caso 2: el Model aparece (por si el Highlight ya viene incluido).
	if _isBotModel(instance) then
		_colorBotHighlight(instance :: Model)
	end
end

-- Re-colorear cuando cambia el equipo del jugador local (ej. al unirse al match)
local function _onTeamChanged()
	_scanExisting()
end

-- ────────────────────────────────────────────────────────────────
-- Inicialización
-- ────────────────────────────────────────────────────────────────

local NPCHighlightController = {}

-- D2: tracking explícito de listeners. Sin esto, cada Start() (e.g. hot
-- reload de MatchFeature) duplicaba conexiones DescendantAdded y Team.
local _moduleConns: { RBXScriptConnection } = {}
local _started = false

function NPCHighlightController:Start(prescannedModels: { Model }?)
	if _started then
		return
	end
	_started = true

	_scanExisting(prescannedModels)

	-- DescendantAdded: filtro IsA("Model") + name match descarta de inmediato
	-- la mayoría de adds (BaseParts, attachments, partículas, beams, etc.).
	table.insert(_moduleConns, workspace.DescendantAdded:Connect(_onDescendantAdded))

	-- Cuando el jugador local cambia de equipo, re-evaluar todos los bots
	-- (sustituye el rescan periódico que corría cada 2s).
	table.insert(_moduleConns, localPlayer:GetPropertyChangedSignal("Team"):Connect(_onTeamChanged))
end

function NPCHighlightController:Stop()
	if not _started then
		return
	end
	_started = false

	for _, conn in _moduleConns do
		conn:Disconnect()
	end
	table.clear(_moduleConns)
end

return NPCHighlightController
