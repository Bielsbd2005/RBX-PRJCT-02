--!strict
--[[
	EmoteController.luau
	Tecla E (o EmoteButton en táctil) en partida → reproduce el emote equipado
	(Loadout.Emote) sobre el personaje local. La animación se replica sola al resto de clientes (el
	Animator del personaje local es del cliente), así que no hay remote.

	Al empezar, el personaje se para en seco aunque se siga pulsando moverse. El
	emote lo corta un movimiento nuevo (soltar y volver a pulsar), saltar,
	disparar, pulsar E o el botón otra vez, equipar un arma, morir o salir de la partida.
	En partida suenan una sola vez aunque el ítem sea Looped. Durante el emote
	el arma se guarda en la mochila y al acabar se vuelve a equipar la misma.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Fusion = require(ReplicatedStorage:WaitForChild("Packages").fusion)
local EmotePlayer = require(Shared.Locker.emotes.EmotePlayer)
local DataController = require(Client.core.data.DataController)
local MatchState = require(script.Parent.MatchState)
local MatchWeapons = require(script.Parent.MatchWeapons)

local EMOTE_KEY = Enum.KeyCode.E
local EMOTE_COOLDOWN = 0.5
-- Por debajo de esto el MoveDirection es ruido del stick, no un paso real.
local MOVE_CANCEL_THRESHOLD = 0.1
-- Con el arma guardada la GUI de armas no escucha 1/2: se atienden aquí.
local SLOT_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
}
local FIRE_INPUTS = {
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.KeyCode.ButtonR2] = true,
}
-- Studio: botón "EmoteButton" (GuiButton) dentro de SmallTouchscreen/LargeTouchscreen
-- de WeaponSystemInsets. Esas GUIs las clona WeaponsGui, a veces después de start().
local EMOTE_BUTTON_NAME = "EmoteButton"
local TOUCH_FRAME_NAMES = {
	SmallTouchscreen = true,
	LargeTouchscreen = true,
}

local EmoteController = {}

-- Arranca el listener. Devuelve la función de limpieza.
function EmoteController.start(): () -> ()
	local localPlayer = Players.LocalPlayer
	local connections: { RBXScriptConnection } = {}
	local activeTrack: AnimationTrack? = nil
	local activeCharacter: Model? = nil
	local holsteredTool: Tool? = nil
	local savedWalkSpeed: number? = nil
	-- Evita que el input de movimiento que venía de antes del emote lo cancele.
	local moveReleased = false
	local nextAllowedAt = 0

	local function stopEmote(skipReequip: boolean?)
		local character = activeCharacter
		if activeTrack and character then
			EmotePlayer.stop(character)
		end
		activeTrack = nil
		activeCharacter = nil

		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and savedWalkSpeed then
			humanoid.WalkSpeed = savedWalkSpeed
		end
		savedWalkSpeed = nil

		local tool = holsteredTool
		holsteredTool = nil
		MatchWeapons.setHolstered(false)
		if
			not skipReequip
			and tool
			and humanoid
			and humanoid.Health > 0
			and character == localPlayer.Character
			and tool.Parent == localPlayer:FindFirstChildOfClass("Backpack")
			and not (character :: Model):FindFirstChildOfClass("Tool")
		then
			humanoid:EquipTool(tool)
		end
	end

	local function tryPlayEmote()
		if MatchState.getPhase() ~= "InMatch" then
			return
		end
		local character = localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not humanoid or humanoid.Health <= 0 then
			return
		end

		-- E con un emote sonando = cancelarlo.
		if activeTrack and activeTrack.IsPlaying then
			stopEmote()
			return
		end

		local now = os.clock()
		if now < nextAllowedAt then
			return
		end
		nextAllowedAt = now + EMOTE_COOLDOWN

		local loadout = Fusion.peek(DataController.Loadout) :: any
		local emoteId = if type(loadout) == "table" then loadout.Emote else nil
		if not EmotePlayer.getAnimationId(emoteId) then
			return
		end

		-- El holster va antes de desequipar: si no, WeaponsSystem re-equipa otra arma.
		holsteredTool = character:FindFirstChildOfClass("Tool")
		if holsteredTool then
			MatchWeapons.setHolstered(true)
			humanoid:UnequipTools()
		end
		activeCharacter = character
		activeTrack = EmotePlayer.play(character, emoteId, false)
		if not activeTrack then
			stopEmote()
			return
		end
		savedWalkSpeed = humanoid.WalkSpeed
		humanoid.WalkSpeed = 0
		moveReleased = humanoid.MoveDirection.Magnitude <= MOVE_CANCEL_THRESHOLD
	end

	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.KeyCode == EMOTE_KEY then
			if gameProcessed or UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			tryPlayEmote()
		elseif activeTrack and SLOT_KEYS[input.KeyCode] and not gameProcessed then
			stopEmote(true)
			MatchWeapons.equipSlot(SLOT_KEYS[input.KeyCode])
		elseif activeTrack and (FIRE_INPUTS[input.UserInputType] or FIRE_INPUTS[input.KeyCode]) then
			stopEmote()
		end
	end))

	local boundButtons: { [Instance]: boolean } = {}
	local function bindEmoteButton(node: Instance)
		if node.Name ~= EMOTE_BUTTON_NAME or not node:IsA("GuiButton") or boundButtons[node] then
			return
		end
		local parent = node.Parent
		if not (parent and TOUCH_FRAME_NAMES[parent.Name]) then
			return
		end
		boundButtons[node] = true
		node:SetAttribute("NoClickSound", true)
		table.insert(connections, node.Activated:Connect(tryPlayEmote))
		table.insert(connections, node.Destroying:Connect(function()
			boundButtons[node] = nil
		end))
	end

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	for _, node in playerGui:GetDescendants() do
		bindEmoteButton(node)
	end
	table.insert(connections, playerGui.DescendantAdded:Connect(bindEmoteButton))

	-- Cancelar al moverse/saltar/morir o si la partida deja de estar activa.
	table.insert(connections, RunService.Heartbeat:Connect(function()
		local track = activeTrack
		if not track then
			return
		end
		local character = activeCharacter
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local moving = humanoid ~= nil and humanoid.MoveDirection.Magnitude > MOVE_CANCEL_THRESHOLD
		if not moving then
			moveReleased = true
		end
		if not track.IsPlaying or not character or character ~= localPlayer.Character or not humanoid or humanoid.Health <= 0
			or character:FindFirstChildOfClass("Tool") ~= nil
			or (moving and moveReleased)
			or humanoid.Jump
			or MatchState.getPhase() ~= "InMatch"
		then
			stopEmote()
		elseif humanoid.WalkSpeed ~= 0 then
			-- El sprint de ShoulderCamera anima WalkSpeed con un spring que puede seguir vivo.
			humanoid.WalkSpeed = 0
		end
	end))

	return function()
		stopEmote()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
end

return EmoteController
