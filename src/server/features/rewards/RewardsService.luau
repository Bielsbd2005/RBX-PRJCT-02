--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Network   = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule
local RewardService = require(script.Parent.Parent.Parent.core.RewardService)
local RateLimiter = require(script.Parent.Parent.Parent.utils.RateLimiter)
local ActionRewards = require(Shared:WaitForChild("constants"):WaitForChild("ActionRewards"))

local M = NetGuards.MAX

local RewardsService = {}
RewardsService.__index = RewardsService

local _dataService: DataService = nil :: any
local _started = false

local COOLDOWN = 0.3

-- Código (en mayúsculas) → clave de ActionRewards; un código nuevo necesita entrada en ambos.
local CODE_TO_ACTION: { [string]: string } = {
	WELCOME = "CodeWelcome",
	REWARDS = "CodeRewards",
}

-- Tope contra un valor inflado por error en ActionRewards.
local MAX_CODE_REWARD = 10000

local _limiter = RateLimiter.new(COOLDOWN)

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
	return _limiter:tryConsume(player, action)
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

-- Roblox no expone si el jugador dio Like: solo se verifica el grupo.
local function _onClaimLikeJoin(_: Network.Empty, player: Player): ()
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

	-- IsInGroup yielda (web) y ByteNet corre cada packet en su propio hilo: otro claim
	-- del mismo jugador puede haber cobrado mientras tanto.
	if profile.Data.Rewards.GroupClaimed == true or _dataService:GetProfile(player) ~= profile then
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

local function _onRedeemCode(data: Network.RedeemCodePayload, player: Player): ()
	-- Validar longitud antes de gsub/upper: un code enorme costaría O(n) al server.
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


	Network.Rewards.ClaimLikeJoin.Listen(_onClaimLikeJoin)
	Network.Rewards.RedeemCode.Listen(_onRedeemCode)
end

return RewardsService
