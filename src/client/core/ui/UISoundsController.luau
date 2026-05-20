--!strict
--[[
	UISoundsController
	Wirea click sounds sobre todos los GuiButton en PlayerGui.
	Escanea descendientes una vez y se suscribe a DescendantAdded para cubrir
	botones creados en runtime (slots de battlepass, cards del store, etc.).

	Convención de assets — Roblox Studio:
	  SoundService
	  └── UI (Folder)
	      ├── Click (Sound)   — click de cualquier botón
	      └── Close (Sound)   — click de botones con Name == "CloseBtn"

	Los Sound se resuelven en cada evento (no se cachean), así que el author
	puede editar SoundId en Studio sin reiniciar. Si el Sound no existe o tiene
	SoundId vacío, el evento es no-op.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

local SOUND_FOLDER_NAME = "UI"
local CLICK_SOUND_NAME = "Click"
local CLOSE_SOUND_NAME = "Close"
-- Convención del proyecto: cualquier botón cuyo `Name` empiece por "CloseBtn"
-- es un botón de cerrar panel (store/locker/battlepass usan exactamente este
-- nombre). Para esos usamos el sonido `Close` en lugar de `Click`.
local CLOSE_BUTTON_NAME = "CloseBtn"

local UISoundsController = {}

local function resolveSound(name: string): Sound?
	local folder = SoundService:FindFirstChild(SOUND_FOLDER_NAME)
	if not folder then return nil end
	local sound = folder:FindFirstChild(name)
	if sound and sound:IsA("Sound") then
		return sound
	end
	return nil
end

local function playSound(name: string)
	local sound = resolveSound(name)
	if not sound then return end
	if sound.SoundId == "" then return end
	-- PlayLocalSound permite overlap (clicks rápidos no se cortan entre sí)
	-- y no requiere que el Sound esté parentado a un BasePart/PlayerGui.
	SoundService:PlayLocalSound(sound)
end

local function bindButton(boundSet: { [GuiButton]: boolean }, janitor: any, button: GuiButton)
	-- Idempotencia via tabla en memoria. No usamos attribute porque los
	-- attributes se copian con Instance:Clone(), y eso rompe el flow del
	-- locker grid: el `Template` del grid existe en PlayerGui desde el
	-- arranque → se bindea → sus clones heredan el attribute → DescendantAdded
	-- los ve como "ya bindeados" y no les pone sonido.
	if boundSet[button] then return end
	boundSet[button] = true

	janitor:Add(button.Activated:Connect(function()
		if not button.Active then return end
		-- Opt-out por botón. Lo usan los controles móviles (Fire/Aim/Reload/Jump)
		-- porque Activated puede dispararse al deslizar el dedo desde fuera y
		-- soltar encima, lo que provocaba un click sound espurio al girar la cámara.
		if button:GetAttribute("NoClickSound") then return end
		local soundName = if button.Name == CLOSE_BUTTON_NAME then CLOSE_SOUND_NAME else CLICK_SOUND_NAME
		playSound(soundName)
	end), "Disconnect")
end

function UISoundsController.start(): any
	local janitor = Janitor.new()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local boundSet: { [GuiButton]: boolean } = {}
	janitor:Add(function()
		table.clear(boundSet)
	end, true)

	local function tryBind(inst: Instance)
		if inst:IsA("GuiButton") then
			bindButton(boundSet, janitor, inst :: GuiButton)
		end
	end

	for _, inst in playerGui:GetDescendants() do
		tryBind(inst)
	end

	janitor:Add(playerGui.DescendantAdded:Connect(tryBind), "Disconnect")

	return janitor
end

return UISoundsController
