--!strict
--[[
	Pone `Click` + háptico a todos los GuiButton de PlayerGui (incluidos los creados
	en runtime). Opt-outs: atributo `NoClickSound`, y los botones llamados "CloseBtn"
	(el panel que cierran ya reproduce `Close`; ambos suenan a doble click).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

local GameSounds = require(script.Parent.GameSounds)
local Haptics = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("Haptics"))

local CLOSE_BUTTON_NAME = "CloseBtn"

local UISoundsController = {}

local function bindButton(boundSet: { [GuiButton]: boolean }, button: GuiButton)
	-- Idempotencia con tabla y no con attribute: los attributes se copian en Clone(),
	-- y los clones de un Template ya bindeado se saltarían.
	if boundSet[button] then return end
	boundSet[button] = true

	-- Cada botón se limpia en su Destroying; en el janitor del módulo las conexiones
	-- crecerían sin tope al reconstruir grids.
	local activatedConn = button.Activated:Connect(function()
		if not button.Active then return end
		-- Los controles móviles lo usan: Activated salta al soltar un dedo que entró
		-- deslizando (p. ej. girando la cámara).
		if button:GetAttribute("NoClickSound") then return end
		if button.Name == CLOSE_BUTTON_NAME then return end
		GameSounds.play(GameSounds.Click)
		Haptics.play("UITap")
	end)

	local destroyingConn: RBXScriptConnection
	destroyingConn = button.Destroying:Connect(function()
		activatedConn:Disconnect()
		destroyingConn:Disconnect()
		boundSet[button] = nil
	end)
end

function UISoundsController.start(): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local boundSet: { [GuiButton]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	janitor:Add(function()
		table.clear(boundSet)
	end, true)

	local function tryBind(inst: Instance)
		if inst:IsA("GuiButton") then
			bindButton(boundSet, inst :: GuiButton)
		end
	end

	for _, inst in playerGui:GetDescendants() do
		tryBind(inst)
	end

	janitor:Add(playerGui.DescendantAdded:Connect(tryBind), "Disconnect")

	return janitor
end

return UISoundsController
