--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network   = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

local M = NetGuards.MAX

local RewardsService = {}
RewardsService.__index = RewardsService

local _dataService: DataService = nil :: any
local _started = false

local COOLDOWN = 0.3
local CLAIM_CASH_REWARD = {
	LikeJoin = 100,
	Notifications = 100,
}

--CODIGOS
local CODE_REWARDS: { [string]: number } = {
	WELCOME = 100,
	REWARDS = 100,
}

-- Sanity cap: ningún código puede recompensar más que esto, sin importar la
-- entrada en CODE_REWARDS. Defensa contra typos / valores inflados accidentales.
local MAX_CODE_REWARD = 10000

local _cooldowns: { [number]: { [string]: number } } = {}

local function _currentGroupId(): number
	if game.CreatorType == Enum.CreatorType.Group then
		return game.CreatorId
	end

	return 0
end

local function _isPlayerInGameGroup(player: Player): boolean
	local groupId = _currentGroupId()
	if groupId <= 0 then
		return false
	end

	local ok, inGroup = pcall(function()
		return player:IsInGroup(groupId)
	end)

	return ok and inGroup == true
end

local function _checkCooldown(player: Player, action: string): boolean
	local playerCooldowns = _cooldowns[player.UserId]
	if not playerCooldowns then
		playerCooldowns = {}
		_cooldowns[player.UserId] = playerCooldowns
	end

	local last = playerCooldowns[action] or 0
	if time() - last < COOLDOWN then
		return false
	end

	playerCooldowns[action] = time()
	return true
end

local function _trim(value: string): string
	return (value:gsub("^%s*(.-)%s*$", "%1"))
end

local function _send(player: Player, success: boolean, message: string, claimType: string, rewardCash: number?)
	Network.Rewards.Response.SendTo({
		success = success,
		message = message,
		claimType = claimType,
		rewardCash = rewardCash or 0,
	}, player)
end

--[[
	Like&Join: source of truth = `Rewards.GroupClaimed` (boolean persistente).

	Flujo simplificado (C4):
	  1. Cooldown.
	  2. Profile cargado.
	  3. Ya reclamado (GroupClaimed=true) → reject.
	  4. _isPlayerInGameGroup → false: mensaje instructivo, sin grabar nada.
	  5. _isPlayerInGameGroup → true: BatchUpdate atómico + GroupClaimed=true.

	Por qué se eliminó la state machine LikeState/LikePendingSessionToken:
	  - Bypassable por reconnects (sessionTokens rotaban en cada Start).
	  - Roblox no expone Like-state vía API → no podíamos verificar el "Like";
	    la state machine era teatro (delay-tactic, no enforcement).
	  - Idempotencia + validación de grupo son suficientes anti-exploit.

	Los fields legacy LikeState/LikePendingSessionToken siguen en DataTemplate
	por compat de profiles antiguos pero ya no se leen ni escriben aquí.
]]
local function _onClaimLikeJoin(_: {}, player: Player): ()
	if not _checkCooldown(player, "likeJoin") then
		_send(player, false, "Demasiadas peticiones.", "LikeJoin", 0)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		_send(player, false, "Perfil no disponible.", "LikeJoin", 0)
		return
	end

	if profile.Data.Rewards.GroupClaimed == true then
		_send(player, false, "Like&Join ya reclamado.", "LikeJoin", 0)
		return
	end

	if not _isPlayerInGameGroup(player) then
		_send(player, false, "Debes unirte al grupo para reclamar esta recompensa.", "LikeJoin", 0)
		return
	end

	local rewardCash = CLAIM_CASH_REWARD.LikeJoin
	local ok = _dataService:BatchUpdate(player, {
		{ path = { "Stats", "Cash" }, delta = rewardCash },
		{ path = { "Rewards", "GroupClaimed" }, value = true },
	})

	if ok then
		_send(player, true, "Like&Join reclamado. +" .. tostring(rewardCash) .. " Cash.", "LikeJoin", rewardCash)
	else
		_send(player, false, "No se pudo completar el claim.", "LikeJoin", 0)
	end
end

local function _onClaimNotifications(_: {}, player: Player): ()
	if not _checkCooldown(player, "notifications") then
		_send(player, false, "Demasiadas peticiones.", "Notifications", 0)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		_send(player, false, "Perfil no disponible.", "Notifications", 0)
		return
	end

	if profile.Data.Rewards.NotificationsClaimed then
		_send(player, false, "Recompensa de notificaciones ya reclamada.", "Notifications", 0)
		return
	end

	local rewardCash = CLAIM_CASH_REWARD.Notifications
	local ok = _dataService:BatchUpdate(player, {
		{ path = { "Stats", "Cash" }, delta = rewardCash },
		{ path = { "Rewards", "NotificationsClaimed" }, value = true },
	})

	if ok then
		_send(player, true, "Notificaciones reclamadas. +" .. tostring(rewardCash) .. " Cash.", "Notifications", rewardCash)
	else
		_send(player, false, "No se pudo completar el claim.", "Notifications", 0)
	end
end

local function _onRedeemCode(data: { code: string }, player: Player): ()
	-- Cap longitud antes de gsub/upper para evitar DoS asimétrico (cliente
	-- podría mandar un code de cientos de KB que el server procesaría O(n)).
	if not NetGuards.validate(data, { code = M.Code }) then
		_send(player, false, "Codigo invalido.", "Code", 0)
		return
	end

	if not _checkCooldown(player, "code") then
		_send(player, false, "Demasiadas peticiones.", "Code", 0)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		_send(player, false, "Perfil no disponible.", "Code", 0)
		return
	end

	local normalizedCode = string.upper(_trim(data.code))
	if normalizedCode == "" then
		_send(player, false, "Debes escribir un codigo.", "Code", 0)
		return
	end

	local rewardCash = CODE_REWARDS[normalizedCode]
	if not rewardCash then
		_send(player, false, "Codigo invalido.", "Code", 0)
		return
	end

	-- Sanity cap por si CODE_REWARDS tiene un valor inflado.
	if rewardCash > MAX_CODE_REWARD then
		warn(("[RewardsService] Code %s exceeds MAX_CODE_REWARD (%d > %d) — capping."):format(normalizedCode, rewardCash, MAX_CODE_REWARD))
		rewardCash = MAX_CODE_REWARD
	end

	if profile.Data.Rewards.ClaimedCodes[normalizedCode] then
		_send(player, false, "Ese codigo ya fue reclamado.", "Code", 0)
		return
	end

	local ok = _dataService:BatchUpdate(player, {
		{ path = { "Stats", "Cash" }, delta = rewardCash },
		{ path = { "Rewards", "ClaimedCodes", normalizedCode }, value = true },
	})

	if ok then
		_send(player, true, "Codigo reclamado. +" .. tostring(rewardCash) .. " Cash.", "Code", rewardCash)
	else
		_send(player, false, "No se pudo canjear el codigo.", "Code", 0)
	end
end

function RewardsService:Start(dataService: DataService): ()
	if _started then
		return
	end

	_started = true
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
	end)

	Network.Rewards.ClaimLikeJoin.Listen(_onClaimLikeJoin)
	Network.Rewards.ClaimNotifications.Listen(_onClaimNotifications)
	Network.Rewards.RedeemCode.Listen(_onRedeemCode)
end

return RewardsService
