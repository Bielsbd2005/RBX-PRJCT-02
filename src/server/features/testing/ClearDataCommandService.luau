--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local TelemetryService = require(script.Parent.Parent.Parent.core.TelemetryService)

local ClearDataCommandService = {}
ClearDataCommandService.__index = ClearDataCommandService

local _dataService: DataService = nil :: any
local _started = false

local ENABLE_CLEAR_COMMAND = RunService:IsStudio()
local COMMAND = "/resetdata"

-- Si OPEN_TO_ALL_IN_STUDIO=true, cualquier player en Studio (team test, team
-- create) puede ejecutar /clear sobre su propio profile. Útil en dev local.
-- En cualquier otro caso, solo userIds en ALLOWED_USER_IDS pueden hacerlo.
-- IMPORTANTE: la semántica es opt-in (no "vacío = todos") — evita el footgun
-- de que un copy-paste de este servicio a un endpoint no-Studio quede abierto.
local OPEN_TO_ALL_IN_STUDIO = true
local ALLOWED_USER_IDS: { [number]: boolean } = {
	[286176976] = true,
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

-- Saldo destruido por el borrado, como sink con etiqueta propia para que se
-- pueda excluir del balance de una sola consulta.
local function _recordReset(player: Player)
	local profile = _dataService and _dataService:GetProfile(player)
	local data = profile and profile.Data
	local stats = data and data.Stats
	if not stats then
		return
	end

	local cash = stats.Cash
	if type(cash) == "number" and cash > 0 then
		TelemetryService.RecordFlow(player, "sink", "AdminReset", cash, nil, "Cash")
	end
	local gems = stats.Gems
	if type(gems) == "number" and gems > 0 then
		TelemetryService.RecordFlow(player, "sink", "AdminReset", gems, nil, "Gems")
	end
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

	--[[
		El borrado es un movimiento de moneda como cualquier otro y hasta ahora
		no dejaba rastro: destruía el saldo entero del jugador y reinyectaba el
		Cash de plantilla sin un solo evento. En el dashboard eso era un salto
		en la masa monetaria sin causa visible — y con `/resetdata` usado a
		diario en pruebas, ruido suficiente para desmentir cualquier cuadre.

		Se registra ANTES del reset, que es cuando el saldo todavía existe. El
		grant de bienvenida que llega después lo registra TelemetryService al
		siguiente login (el reset pone JoinCount a cero, así que la próxima
		sesión vuelve a ser la primera).
	]]
	_recordReset(player)

	local success = _dataService:ResetProfile(player)
	if not success then
		player:Kick("No se pudieron borrar tus datos. Vuelve a intentar.")
		return
	end

	player:Kick("Tus datos fueron borrados para testing. Vuelve a entrar.")
end

function ClearDataCommandService:Start(dataService: DataService): ()
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
