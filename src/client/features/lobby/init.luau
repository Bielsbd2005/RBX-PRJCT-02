--!strict
--[[
	Mantiene el preview del jugador local (Workspace.Lobby.Spawners.P1) sincronizado
	con el loadout equipado. El preview lo posee LobbyCharacterPreview (compartido con
	el Locker); mientras el Locker lo tiene tomado, syncToEquippedIfIdle es no-op.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local LobbyCharacterPreview = require(Client.core.character.LobbyCharacterPreview)
local DataController = require(Client.core.data.DataController)

local LobbyFeature = {}

function LobbyFeature.start(_menuController: any): any
	local janitor = Janitor.new()
	local preview = LobbyCharacterPreview.get()

	DataController:WhenReady():andThen(function()
		preview:syncToEquippedIfIdle()

		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)

		local obs = scope:Observer(DataController.Loadout :: any)
		janitor:Add(obs:onBind(function()
			preview:syncToEquippedIfIdle()
		end), true)
	end)

	return janitor
end

return LobbyFeature
