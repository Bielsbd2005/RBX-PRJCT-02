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
	for _, desc in workspace:GetDescendants() do
		if _isBotModel(desc) then
			_colorBotHighlight(desc :: Model)
		end
	end
end

local function _onDescendantAdded(instance: Instance)
	if not _isBotModel(instance) then
		return
	end
	local model = instance :: Model

	-- Esperar a que el Highlight exista (puede añadirse justo después del modelo)
	local highlight = model:FindFirstChild("BotHighlight")
	if highlight then
		_colorBotHighlight(model)
	else
		task.defer(function()
			if model.Parent == nil then
				return
			end
			_colorBotHighlight(model)
		end)
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

	workspace.DescendantAdded:Connect(_onDescendantAdded)

	localPlayer:GetPropertyChangedSignal("Team"):Connect(_onTeamChanged)

	-- Re-scan ligero cada 2s para capturar cambios tardíos de color
	-- (ej. si el equipo del jugador se asigna después del spawn de bots)
	task.spawn(function()
		while true do
			task.wait(2)
			_scanExisting()
		end
	end)
end

return NPCHighlightController
