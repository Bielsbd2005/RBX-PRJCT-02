--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network = require(Shared.networking.Network)
local PrestigeConfig = require(Shared.constants.PrestigeConfig)

local PrestigeService = {}
PrestigeService.__index = PrestigeService

local _dataService: any = nil
local _started = false
local _cooldowns: { [number]: number } = {}

local RATE_LIMIT_SECONDS = 0.4

local function _checkCooldown(player: Player): boolean
	local userId = player.UserId
	local lastRequest = _cooldowns[userId] or 0
	if time() - lastRequest < RATE_LIMIT_SECONDS then
		return false
	end

	_cooldowns[userId] = time()
	return true
end

local function _sendResponse(player: Player, success: boolean, message: string, newPrestige: number)
	Network.Prestige.Response.SendTo({
		success = success,
		message = message,
		newPrestige = newPrestige,
	}, player)
end

local function _getStatValue(stats: { [string]: any }, statKey: string): number
	local value = stats[statKey]
	if type(value) ~= "number" then
		return 0
	end

	return math.max(0, math.floor(value))
end

local function _onRequest(_: {}, player: Player)
	if not _checkCooldown(player) then
		_sendResponse(player, false, "Demasiadas peticiones.", 0)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		_sendResponse(player, false, "Perfil no disponible.", 0)
		return
	end

	local stats = profile.Data.Stats :: { [string]: any }
	local prestige = profile.Data.Prestige :: { [string]: any }
	local currentPrestige = math.max(0, math.floor(prestige.Current or 0))
	local nextPrestige = currentPrestige + 1

	local nextDefinition = PrestigeConfig.GetNextDefinition(currentPrestige)
	if not nextDefinition then
		_sendResponse(player, false, "Ya alcanzaste el prestige maximo.", currentPrestige)
		return
	end

	if _getStatValue(stats, "Level") < nextDefinition.UnlockLevel then
		_sendResponse(
			player,
			false,
			"Necesitas nivel " .. tostring(nextDefinition.UnlockLevel) .. ".",
			currentPrestige
		)
		return
	end

	local requirement1 = nextDefinition.Requirement1
	local requirement2 = nextDefinition.Requirement2
	local currentReq1 = _getStatValue(stats, requirement1.StatKey)
	local currentReq2 = _getStatValue(stats, requirement2.StatKey)

	if currentReq1 < requirement1.Required or currentReq2 < requirement2.Required then
		local message = string.format(
			"Requisitos pendientes: %s %d/%d, %s %d/%d",
			requirement1.StatKey,
			currentReq1,
			requirement1.Required,
			requirement2.StatKey,
			currentReq2,
			requirement2.Required
		)
		_sendResponse(player, false, message, currentPrestige)
		return
	end

	local success = _dataService:BatchUpdate(player, {
		{ path = { "Prestige", "Current" }, value = nextPrestige },
		{ path = { "Prestige", "LastPrestigeAt" }, value = os.time() },
		{ path = { "Prestige", "Badges", tostring(nextPrestige) }, value = true },
	})

	if not success then
		_sendResponse(player, false, "No se pudo actualizar prestige.", currentPrestige)
		return
	end

	_sendResponse(player, true, "Prestige " .. tostring(nextPrestige) .. " desbloqueado.", nextPrestige)
end

function PrestigeService:Start(dataService: any)
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
	end)

	Network.Prestige.Request.Listen(_onRequest)
end

return PrestigeService
