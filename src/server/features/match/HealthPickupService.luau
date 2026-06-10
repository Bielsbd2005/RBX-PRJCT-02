--!strict
--[[
	HealthPickupService.luau
	Maneja Network.Match.RequestPickup → aplica regen de health al jugador
	si está vivo, in-match y dentro de cooldown.

	Extraído de MatchService como primer ejemplo del split sugerido por la
	auditoría AAA (god module 2114 LOC). Patrón de extracción a seguir:
	  • Estado interno propio (cooldowns, constantes).
	  • Predicates inyectados (`isRoundActive`, `isPlayerInMenu`) en lugar
	    de hard-acoplarse a state de MatchService — facilita testing y
	    reduce import cycles.
	  • Cleanup en PlayerRemoving propio.

	Si en el futuro hay más kinds de pickup (Bullet, Armor, etc.), añadir
	dispatcher por `data.kind` en _onRequestPickup; los handlers concretos
	pueden seguir aquí o moverse a sub-modules según crezca el feature.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)

local HealthPickupService = {}

-- Tuneables del feature.
local PICKUP_HEAL_AMOUNT = 30
local PICKUP_REQUEST_COOLDOWN = 0.2

-- Predicates inyectados desde MatchService — ver Start().
-- Nil hasta Start() pero los call sites (handler de network) corren después.
type Predicates = {
	isRoundActive: () -> boolean,
	isPlayerInMenu: (userId: number) -> boolean,
	-- S2: consume un crédito de elegibilidad de pickup (una kill reciente no
	-- reclamada). Devuelve true si había uno disponible dentro de la ventana.
	-- Los health pickups son client-visuales (no hay entidad server-side que
	-- validar), así que exigimos al menos una kill real reciente por heal —
	-- esto recorta el exploit de "+30 HP cada 0.2s ilimitado" a "1 heal por kill".
	consumePickupEligibility: (userId: number) -> boolean,
}

local _started = false
local _predicates: Predicates = nil :: any
local _cooldowns: { [number]: number } = {}
local _playerRemovingConn: RBXScriptConnection? = nil

local function _applyHealthPickup(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + PICKUP_HEAL_AMOUNT)
	return true
end

local function _onRequestPickup(data: { kind: string }, player: Player): ()
	-- Whitelist estricta + cap longitud. Solo "Health" se dropea actualmente;
	-- cualquier otro kind se ignora (no consume cooldown, no expone la API).
	if not NetGuards.validate(data, { kind = NetGuards.MAX.Kind }) or data.kind ~= "Health" then
		return
	end

	if not _predicates.isRoundActive() or _predicates.isPlayerInMenu(player.UserId) then
		return
	end

	local now = time()
	local cooldownAt = _cooldowns[player.UserId] or 0
	if now < cooldownAt then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	-- S2: validación server-authoritative. No existe entidad de pickup en el
	-- servidor (PickupDropEffect corre client-side), así que exigimos que el
	-- jugador tenga una kill reciente NO reclamada antes de curar. Si no hay
	-- crédito, ignoramos sin tocar el cooldown (no penalizamos requests
	-- legítimos que llegan sin crédito por desync de timing). Sólo consumimos
	-- el cooldown cuando de verdad vamos a intentar curar.
	if not _predicates.consumePickupEligibility(player.UserId) then
		return
	end

	_cooldowns[player.UserId] = now + PICKUP_REQUEST_COOLDOWN

	_applyHealthPickup(character)
end

--- Inicia el servicio. Idempotente.
--- predicates.isRoundActive: devuelve true si hay una ronda activa (regen
---   solo aplica in-match — pickups en lobby se ignoran).
--- predicates.isPlayerInMenu: devuelve true si el jugador está en menu
---   (death screen, end results, etc.) — no debe poder regenerarse.
function HealthPickupService:Start(predicates: Predicates): ()
	if _started then
		return
	end
	_started = true
	_predicates = predicates

	_playerRemovingConn = Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
	end)

	Network.Match.RequestPickup.Listen(_onRequestPickup)
end

function HealthPickupService:Stop(): ()
	if not _started then
		return
	end
	_started = false
	if _playerRemovingConn then
		_playerRemovingConn:Disconnect()
		_playerRemovingConn = nil
	end
	table.clear(_cooldowns)
end

return HealthPickupService
