--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)
local RateLimiter = require(script.Parent.Parent.Parent.utils.RateLimiter)

local HealthPickupService = {}

local PICKUP_HEAL_AMOUNT = 30
local PICKUP_REQUEST_COOLDOWN = 0.2

-- Inyectados desde MatchService en Start(); los handlers de red corren después.
type Predicates = {
	isRoundActive: () -> boolean,
	isPlayerInMenu: (userId: number) -> boolean,
		-- Los pickups son solo visuales en cliente (sin entidad server-side que
		-- validar): cada heal consume una kill reciente no reclamada.
	consumePickupEligibility: (userId: number) -> boolean,
}

local _started = false
local _predicates: Predicates = nil :: any
-- Se marca solo tras un heal concedido.
local _limiter = RateLimiter.new(PICKUP_REQUEST_COOLDOWN)

local function _applyHealthPickup(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + PICKUP_HEAL_AMOUNT)
	return true
end

local function _onRequestPickup(data: Network.RequestPickupPayload, player: Player): ()
	-- Solo "Health" existe; otros kinds se ignoran sin consumir cooldown.
	if not NetGuards.validate(data, { kind = NetGuards.MAX.Kind }) or data.kind ~= "Health" then
		return
	end

	if not _predicates.isRoundActive() or _predicates.isPlayerInMenu(player.UserId) then
		return
	end

	if not _limiter:isReady(player) then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	-- Sin crédito no se toca el cooldown: no penaliza requests legítimos que
	-- llegan antes que el crédito por desync de timing.
	if not _predicates.consumePickupEligibility(player.UserId) then
		return
	end

	_limiter:mark(player)

	_applyHealthPickup(character)
end

function HealthPickupService:Start(predicates: Predicates): ()
	if _started then
		return
	end
	_started = true
	_predicates = predicates

	Network.Match.RequestPickup.Listen(_onRequestPickup)
end

function HealthPickupService:Stop(): ()
	if not _started then
		return
	end
	_started = false
	_limiter:clearAll()
end

return HealthPickupService
