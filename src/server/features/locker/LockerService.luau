--!strict
--[[
	LockerService.luau (Server)
	Endpoints server-side para acciones de UX del Locker.

	Por ahora:
	  • MarkItemSeen — el cliente avisa que el jugador vio un ítem nuevo;
	    server limpia el flag de NewItemFlags para que el badge desaparezca
	    en futuras sesiones.

	Validación:
	  • Rate limit: 0.05s para evitar spam.
	  • category/itemId tipados; sin whitelist específica (cualquier flag
	    presente puede limpiarse — no hay riesgo de abuso porque MarkItemSeen
	    solo BORRA, nunca crea ownership).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network = require(Shared.networking.Network)

local LockerService = {}
LockerService.__index = LockerService

local _dataService: any = nil
local _started = false

local RATE_LIMIT_SECONDS = 0.05
local _lastSeenAt: { [number]: number } = {}

local function _onMarkItemSeen(data: { category: string, itemId: string }, player: Player): ()
	if type(data) ~= "table"
		or type(data.category) ~= "string" or data.category == ""
		or type(data.itemId) ~= "string" or data.itemId == ""
	then
		return
	end

	local last = _lastSeenAt[player.UserId] or 0
	if time() - last < RATE_LIMIT_SECONDS then
		return
	end
	_lastSeenAt[player.UserId] = time()

	if not _dataService then
		return
	end

	_dataService:MarkItemSeen(player, data.category, data.itemId)
end

function LockerService:Start(dataService: any): ()
	if _started then
		return
	end
	_started = true
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player: Player)
		_lastSeenAt[player.UserId] = nil
	end)

	Network.Locker.MarkItemSeen.Listen(_onMarkItemSeen)
end

return LockerService
