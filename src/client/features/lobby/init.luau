--!strict
--[[
	LobbyFeature  (Client)
	Mantiene el preview del personaje del jugador local en
	Workspace.Lobby.Spawners.P1 sincronizado con el loadout equipado.

	El preview en sí lo posee LobbyCharacterPreview (singleton compartido con el
	Locker): aquí solo observamos DataController.Loadout y le pedimos que se
	sincronice con lo equipado. Mientras el Locker tiene el preview tomado para
	previsualizar una selección, syncToEquippedIfIdle es no-op y no lo pisa.
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
