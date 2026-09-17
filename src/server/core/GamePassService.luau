--!strict
--[[
	Caché de posesión de `StoreProducts.GamePasses` para consultarla SIN yield
	(`UserOwnsGamePassAsync` es una llamada web). Prefetch en PlayerAdded, se
	actualiza con PromptGamePassPurchaseFinished y se tira en PlayerRemoving.

	La presencia de la entrada por jugador significa "sigue conectado": un fetch
	tardío no puede repoblar el mapa tras irse.

	`OnOwnershipGained` existe porque el prefetch es asíncrono y quien pregunta al
	spawnear (el holster) suele hacerlo antes de que resuelva.

	No se persiste en el profile: la posesión la sirve Roblox y guardarla dejaría
	beneficios activos tras un refund. La compra sí va a telemetría (kind "GamePass").
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StoreProducts = require(Shared.constants.StoreProducts)

local TelemetryService = require(script.Parent.TelemetryService)

--[[
	Override SÓLO de Studio (en un local server nadie posee nada ni se puede comprar):
	  true  → todos poseen todos los passes.
	  false → nadie posee nada.
	  nil   → comportamiento real.
	Fuera de Studio se ignora (ver _override).
]]
local STUDIO_OWNERSHIP_OVERRIDE: boolean? = true

local GamePassService = {}

local _override: boolean? = if RunService:IsStudio() then STUDIO_OWNERSHIP_OVERRIDE else nil

local _started = false

-- userId → passId → posee. Sin tabla de jugador = desconectado; sin entrada de
-- pass = sin resolver (un fetch fallido no se cachea).
local _ownedByUserId: { [number]: { [number]: boolean } } = {}

local _pendingByUserId: { [number]: { [number]: boolean } } = {}

local _gainedListeners: { (player: Player, passId: number) -> () } = {}

local function _fire(player: Player, passId: number)
	for _, listener in _gainedListeners do
		-- Por listener: uno que reviente no debe impedir los demás.
		task.spawn(listener, player, passId)
	end
end

-- Avisa solo en false→true. No-op si el jugador ya se fue.
local function _store(player: Player, passId: number, owns: boolean)
	local owned = _ownedByUserId[player.UserId]
	if not owned then
		return
	end

	local had = owned[passId]
	owned[passId] = owns

	if owns and had ~= true then
		_fire(player, passId)
	end
end

local function _resolve(player: Player, passId: number)
	-- Con override, la llamada web fallaría con los userId falsos de un local server.
	if _override ~= nil or passId <= 0 then
		return
	end

	local userId = player.UserId
	local owned = _ownedByUserId[userId]
	if not owned or owned[passId] ~= nil then
		return
	end

	local pending = _pendingByUserId[userId]
	if not pending then
		pending = {}
		_pendingByUserId[userId] = pending
	end
	if pending[passId] then
		return
	end
	pending[passId] = true

	task.spawn(function()
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
		end)

		local stillPending = _pendingByUserId[userId]
		if stillPending then
			stillPending[passId] = nil
		end

		if not ok then
			warn(`[GamePassService] UserOwnsGamePassAsync falló para {userId}/{passId}: {result}`)
			return
		end

		_store(player, passId, result == true)
	end)
end

-- Roblox no entrega receipt en este evento: userId+passId es clave de idempotencia
-- exacta (un pass no se compra dos veces). cashGranted = 0 es correcto.
local function _recordPurchase(player: Player, passId: number)
	local pass = StoreProducts.GamePasses.ByPassId[passId]
	if not pass then
		warn(`[GamePassService] compra de un pass fuera del catálogo ({passId}) — se registra sin precio`)
	end

	TelemetryService.RecordPurchase({
		userId = player.UserId,
		purchaseId = `gamepass-{player.UserId}-{passId}`,
		productId = passId,
		sku = if pass then pass.Name else tostring(passId),
		robuxPrice = if pass then pass.RobuxPrice else 0,
		cashGranted = 0,
		kind = "GamePass",
	})
end

local function _track(player: Player)
	if _ownedByUserId[player.UserId] == nil then
		_ownedByUserId[player.UserId] = {}
	end
	for _, pass in StoreProducts.GamePasses.InOrder do
		_resolve(player, pass.PassId)
	end
end

-- Síncrono. Un pass sin resolver devuelve `false` y lanza el fetch: quien dependa
-- del resultado debe suscribirse con `OnOwnershipGained`.
function GamePassService.Owns(player: Player, passId: number): boolean
	-- Antes del chequeo de id: así también desbloquea passes aún sin id.
	if _override ~= nil then
		return _override
	end

	if passId <= 0 then
		return false
	end

	local owned = _ownedByUserId[player.UserId]
	if not owned then
		return false
	end

	if owned[passId] == nil then
		_resolve(player, passId)
		return false
	end

	return owned[passId] == true
end

-- Compra o prefetch confirmado; thread propio. Sin unsubscribe: los consumidores
-- son services que se registran una vez.
function GamePassService.OnOwnershipGained(listener: (player: Player, passId: number) -> ())
	table.insert(_gainedListeners, listener)
end

function GamePassService.Start()
	if _started then
		return
	end
	_started = true

	if _override ~= nil then
		warn(string.format(
			"[GamePassService] Override de Studio ACTIVO: todos los gamepasses %s. En producción no se aplica.",
			if _override then "desbloqueados" else "bloqueados"
		))
	end

	for _, player in Players:GetPlayers() do
		_track(player)
	end

	Players.PlayerAdded:Connect(_track)

	Players.PlayerRemoving:Connect(function(player)
		_ownedByUserId[player.UserId] = nil
		_pendingByUserId[player.UserId] = nil
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		if wasPurchased then
			_store(player, passId, true)
			_recordPurchase(player, passId)
		end
	end)
end

return GamePassService
