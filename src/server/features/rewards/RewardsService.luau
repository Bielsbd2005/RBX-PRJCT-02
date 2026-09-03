--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network   = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule
local RewardService = require(script.Parent.Parent.Parent.core.RewardService)
local ActionRewards = require(Shared:WaitForChild("constants"):WaitForChild("ActionRewards"))

local M = NetGuards.MAX

local RewardsService = {}
RewardsService.__index = RewardsService

local _dataService: DataService = nil :: any
local _started = false

local COOLDOWN = 0.3

-- Mapeo "código en input" → clave de ActionRewards. Para añadir un código nuevo:
--   1. Añadir entry en ActionRewards.Amounts (server/shared single source of truth).
--   2. Añadir entry aquí mapeando el string que el jugador escribe a esa clave.
local CODE_TO_ACTION: { [string]: string } = {
	WELCOME = "CodeWelcome",
	REWARDS = "CodeRewards",
}

-- Sanity cap: ningún código puede recompensar más que esto, sin importar la
-- entrada en ActionRewards. Defensa contra typos / valores inflados accidentales.
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
		_send(player, false, "Too many requests. Slow down.", "LikeJoin", 0)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		_send(player, false, "Your data isn't loaded yet.", "LikeJoin", 0)
		return
	end

	if profile.Data.Rewards.GroupClaimed == true then
		_send(player, false, "Like & Join reward already claimed.", "LikeJoin", 0)
		return
	end

	if not _isPlayerInGameGroup(player) then
		_send(player, false, "Join the group to claim this reward.", "LikeJoin", 0)
		return
	end

	local ok, _xp, rewardCash = RewardService.Award(player, "ClaimLikeJoin", {
		{ path = { "Rewards", "GroupClaimed" }, value = true },
	}, "LikeJoin")

	if ok then
		_send(player, true, "Like & Join claimed. +" .. tostring(rewardCash) .. " Cash.", "LikeJoin", rewardCash)
	else
		_send(player, false, "Couldn't complete the claim. Try again.", "LikeJoin", 0)
	end
end

local function _onClaimNotifications(_: {}, player: Player): ()
	if not _checkCooldown(player, "notifications") then
		_send(player, false, "Too many requests. Slow down.", "Notifications", 0)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		_send(player, false, "Your data isn't loaded yet.", "Notifications", 0)
		return
	end

	if profile.Data.Rewards.NotificationsClaimed then
		_send(player, false, "Notifications reward already claimed.", "Notifications", 0)
		return
	end

	local ok, _xp, rewardCash = RewardService.Award(player, "ClaimNotifications", {
		{ path = { "Rewards", "NotificationsClaimed" }, value = true },
	}, "Notifications")

	if ok then
		_send(player, true, "Notifications reward claimed. +" .. tostring(rewardCash) .. " Cash.", "Notifications", rewardCash)
	else
		_send(player, false, "Couldn't complete the claim. Try again.", "Notifications", 0)
	end
end

local function _onRedeemCode(data: { code: string }, player: Player): ()
	-- Cap longitud antes de gsub/upper para evitar DoS asimétrico (cliente
	-- podría mandar un code de cientos de KB que el server procesaría O(n)).
	if not NetGuards.validate(data, { code = M.Code }) then
		_send(player, false, "That code isn't valid.", "Code", 0)
		return
	end

	if not _checkCooldown(player, "code") then
		_send(player, false, "Too many requests. Slow down.", "Code", 0)
		return
	end

	local profile = _dataService:GetProfile(player)
	if not profile then
		_send(player, false, "Your data isn't loaded yet.", "Code", 0)
		return
	end

	local normalizedCode = string.upper(_trim(data.code))
	if normalizedCode == "" then
		_send(player, false, "Enter a code to redeem.", "Code", 0)
		return
	end

	local actionKey = CODE_TO_ACTION[normalizedCode]
	if not actionKey or not ActionRewards.Has(actionKey) then
		_send(player, false, "That code isn't valid.", "Code", 0)
		return
	end

	-- Sanity cap por si la entry en ActionRewards tiene un valor inflado.
	local cashFromCatalog = ActionRewards.GetCash(actionKey)
	if cashFromCatalog > MAX_CODE_REWARD then
		warn(("[RewardsService] Code %s (%s) excede MAX_CODE_REWARD (%d > %d) — bloqueando claim"):format(
			normalizedCode, actionKey, cashFromCatalog, MAX_CODE_REWARD))
		_send(player, false, "That code isn't valid.", "Code", 0)
		return
	end

	if profile.Data.Rewards.ClaimedCodes[normalizedCode] then
		_send(player, false, "You already redeemed that code.", "Code", 0)
		return
	end

	local ok, _xp, rewardCash = RewardService.Award(player, actionKey, {
		{ path = { "Rewards", "ClaimedCodes", normalizedCode }, value = true },
	}, normalizedCode)

	if ok then
		_send(player, true, "Code redeemed. +" .. tostring(rewardCash) .. " Cash.", "Code", rewardCash)
	else
		_send(player, false, "Couldn't redeem that code. Try again.", "Code", 0)
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
