--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ClearDataCommandService = {}
ClearDataCommandService.__index = ClearDataCommandService

local _dataService: any = nil
local _started = false

local ENABLE_CLEAR_COMMAND = RunService:IsStudio()
local COMMAND = "/clear"

-- Si OPEN_TO_ALL_IN_STUDIO=true, cualquier player en Studio (team test, team
-- create) puede ejecutar /clear sobre su propio profile. Útil en dev local.
-- En cualquier otro caso, solo userIds en ALLOWED_USER_IDS pueden hacerlo.
-- IMPORTANTE: la semántica es opt-in (no "vacío = todos") — evita el footgun
-- de que un copy-paste de este servicio a un endpoint no-Studio quede abierto.
local OPEN_TO_ALL_IN_STUDIO = true
local ALLOWED_USER_IDS: { [number]: boolean } = {
	-- [123456789] = true,
}

local function _isAuthorized(player: Player): boolean
	if ALLOWED_USER_IDS[player.UserId] == true then
		return true
	end

	return OPEN_TO_ALL_IN_STUDIO and RunService:IsStudio()
end

local function _normalizeMessage(message: string): string
	return string.lower((message:gsub("^%s*(.-)%s*$", "%1")))
end

local function _onPlayerChatted(player: Player, message: string): ()
	if not ENABLE_CLEAR_COMMAND then
		return
	end

	if _normalizeMessage(message) ~= COMMAND then
		return
	end

	if not _isAuthorized(player) then
		return
	end

	local success = _dataService:ResetProfile(player)
	if not success then
		player:Kick("No se pudieron borrar tus datos. Vuelve a intentar.")
		return
	end

	player:Kick("Tus datos fueron borrados para testing. Vuelve a entrar.")
end

function ClearDataCommandService:Start(dataService: any): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	Players.PlayerAdded:Connect(function(player: Player)
		player.Chatted:Connect(function(message: string)
			_onPlayerChatted(player, message)
		end)
	end)

	for _, player in Players:GetPlayers() do
		player.Chatted:Connect(function(message: string)
			_onPlayerChatted(player, message)
		end)
	end
end

return ClearDataCommandService
