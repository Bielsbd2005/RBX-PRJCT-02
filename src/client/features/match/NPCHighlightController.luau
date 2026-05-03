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

local function _scanExisting()
	-- Una pasada al arrancar / al cambiar el equipo local. El coste es
	-- aceptable porque ya no se ejecuta en bucle (el rescan periódico cada 2s
	-- fue eliminado).
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

function NPCHighlightController:Start()
	_scanExisting()

	-- DescendantAdded: filtro IsA("Model") + name match descarta de inmediato
	-- la mayoría de adds (BaseParts, attachments, partículas, beams, etc.).
	workspace.DescendantAdded:Connect(_onDescendantAdded)

	-- Cuando el jugador local cambia de equipo, re-evaluar todos los bots
	-- (sustituye el rescan periódico que corría cada 2s).
	localPlayer:GetPropertyChangedSignal("Team"):Connect(_onTeamChanged)
end

return NPCHighlightController
