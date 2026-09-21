--!strict
--[[
	EmoteController.luau
	Tecla E en partida → reproduce el emote equipado (Loadout.Emote) sobre el
	personaje local. La animación se replica sola al resto de clientes (el
	Animator del personaje local es del cliente), así que no hay remote.

	El emote se corta al moverse, saltar, disparar, pulsar E otra vez, morir o
	salir de la partida. Los emotes no-Looped terminan solos.
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

local EMOTE_KEY = Enum.KeyCode.E
local EMOTE_COOLDOWN = 0.5
-- Por debajo de esto el MoveDirection es ruido del stick, no un paso real.
local MOVE_CANCEL_THRESHOLD = 0.1
local FIRE_INPUTS = {
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.KeyCode.ButtonR2] = true,
}

local EmoteController = {}

-- Arranca el listener. Devuelve la función de limpieza.
function EmoteController.start(): () -> ()
	local localPlayer = Players.LocalPlayer
	local connections: { RBXScriptConnection } = {}
	local activeTrack: AnimationTrack? = nil
	local activeCharacter: Model? = nil
	local nextAllowedAt = 0

	local function stopEmote()
		if activeTrack and activeCharacter then
			EmotePlayer.stop(activeCharacter)
		end
		activeTrack = nil
		activeCharacter = nil
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
		activeTrack = EmotePlayer.play(character, emoteId)
		activeCharacter = if activeTrack then character else nil
	end

	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.KeyCode == EMOTE_KEY then
			if gameProcessed or UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			tryPlayEmote()
		elseif activeTrack and (FIRE_INPUTS[input.UserInputType] or FIRE_INPUTS[input.KeyCode]) then
			stopEmote()
		end
	end))

	-- Cancelar al moverse/saltar/morir o si la partida deja de estar activa.
	table.insert(connections, RunService.Heartbeat:Connect(function()
		local track = activeTrack
		if not track then
			return
		end
		if not track.IsPlaying then
			activeTrack = nil
			activeCharacter = nil
			return
		end
		local character = activeCharacter
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or character ~= localPlayer.Character or not humanoid or humanoid.Health <= 0
			or humanoid.MoveDirection.Magnitude > MOVE_CANCEL_THRESHOLD
			or humanoid.Jump
			or MatchState.getPhase() ~= "InMatch"
		then
			stopEmote()
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
