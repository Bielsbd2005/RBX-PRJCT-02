--!strict
--[[
	Caché de posesión de `StoreProducts.GamePasses` para consultarla SIN yield
	(`UserOwnsGamePassAsync` es una llamada web). Prefetch en PlayerAdded, se
	actualiza con PromptGamePassPurchaseFinished y se tira en PlayerRemoving.

	La presencia de la entrada por jugador significa "sigue conectado": un fetch
	tardío no puede repoblar el mapa tras irse.

	`OnOwnershipGained` existe porque el prefetch es asíncrono y quien pregunta al
	spawnear (el holster) suele hacerlo antes de que resuelva.

	La posesión del pass real no se persiste en el profile: la sirve Roblox y guardarla
	dejaría beneficios activos tras un refund. La compra sí va a telemetría (kind "GamePass").

	Un pass regalado (profile.GiftedPasses, lo escribe GiftingService) cuenta como
	poseído: Roblox no sabe nada de él, así que se lee del perfil en cada consulta.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StoreProducts = require(Shared.constants.StoreProducts)
local DebugFlags = require(Shared.utils.DebugFlags)

local TelemetryService = require(script.Parent.TelemetryService)
local DataServiceMod = require(script.Parent.data.DataService)
type DataService = DataServiceMod.DataServiceModule

--[[
	En Studio no se pregunta a Roblox (el creador posee sus passes y en un local
	server nadie posee nada): todos los passes desbloqueados, salvo que el
	BoolValue ReplicatedStorage.Debug.NoGamePasses esté marcado, que los bloquea
	todos menos los regalados. Se lee en vivo; la tienda del cliente lee el mismo flag.
]]
local IS_STUDIO = RunService:IsStudio()
local noGamePasses = DebugFlags.bind(ReplicatedStorage, "NoGamePasses")

local GamePassService = {}

local _started = false
local _dataService: DataService = nil :: any

-- userId → passId → posee. Sin tabla de jugador = desconectado; sin entrada de
-- pass = sin resolver (un fetch fallido no se cachea).
local _ownedByUserId: { [number]: { [number]: boolean } } = {}

local _pendingByUserId: { [number]: { [number]: boolean } } = {}

local _gainedListeners: { (player: Player, passId: number) -> () } = {}

local _resolvedListeners: { (player: Player, passId: number, owns: boolean) -> () } = {}

local function _fire(player: Player, passId: number)
	for _, listener in _gainedListeners do
		-- Por listener: uno que reviente no debe impedir los demás.
		task.spawn(listener, player, passId)
	end
end

-- false con el perfil sin cargar: quien dependa del resultado recibe `OnOwnershipGained`
-- cuando carga.
local function _isGifted(player: Player, passId: number): boolean
	local pass = StoreProducts.GamePasses.ByPassId[passId]
	if not pass then
		return false
	end
	local profile = _dataService:GetProfile(player)
	local gifted = profile and (profile.Data :: any).GiftedPasses
	return type(gifted) == "table" and gifted[pass.Name] ~= nil
end

-- Avisa solo en false→true. No-op si el jugador ya se fue.
local function _store(player: Player, passId: number, owns: boolean)
	local owned = _ownedByUserId[player.UserId]
	if not owned then
		return
	end

	local had = owned[passId]
	owned[passId] = owns

	for _, listener in _resolvedListeners do
		task.spawn(listener, player, passId, owns)
	end

	if owns and had ~= true then
		_fire(player, passId)
	end
end

local function _resolve(player: Player, passId: number)
	-- En Studio la llamada web fallaría con los userId falsos de un local server.
	if IS_STUDIO or passId <= 0 then
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
	if IS_STUDIO and not noGamePasses() then
		return true
	end

	if passId <= 0 then
		return false
	end

	if _isGifted(player, passId) then
		return true
	end
	if IS_STUDIO then
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

-- Como Owns pero sin lanzar fetch y distinguiendo "sin resolver" (nil) de "no lo
-- posee": para retirar un beneficio persistido hace falta un "no" confirmado.
function GamePassService.Peek(player: Player, passId: number): boolean?
	if IS_STUDIO and not noGamePasses() then
		return true
	end
	if passId <= 0 then
		return false
	end
	if _isGifted(player, passId) then
		return true
	end
	if IS_STUDIO then
		return false
	end
	local owned = _ownedByUserId[player.UserId]
	return if owned then owned[passId] else nil
end

-- Avisa de un pass recién regalado; llamar DESPUÉS de escribir profile.GiftedPasses.
function GamePassService.NotifyGifted(player: Player, passId: number)
	for _, listener in _resolvedListeners do
		task.spawn(listener, player, passId, true)
	end
	_fire(player, passId)
end

-- Cada resolución (prefetch, compra, regalo), sea sí o no; thread propio. En Studio
-- solo se dispara con los regalos: usar Peek.
function GamePassService.OnOwnershipResolved(listener: (player: Player, passId: number, owns: boolean) -> ())
	table.insert(_resolvedListeners, listener)
end

-- Compra o prefetch confirmado; thread propio. Sin unsubscribe: los consumidores
-- son services que se registran una vez.
function GamePassService.OnOwnershipGained(listener: (player: Player, passId: number) -> ())
	table.insert(_gainedListeners, listener)
end

function GamePassService.Start(dataService: DataService)
	if _started then
		return
	end
	_started = true
	_dataService = dataService

	if IS_STUDIO then
		warn(string.format(
			"[GamePassService] Studio: todos los gamepasses %s (Debug.NoGamePasses). En producción no se aplica.",
			if noGamePasses() then "bloqueados" else "desbloqueados"
		))
	end

	for _, player in Players:GetPlayers() do
		_track(player)
	end

	Players.PlayerAdded:Connect(_track)

	-- Quien preguntó antes de cargar el perfil recibió "no" de un pass regalado. Solo
	-- `gained`: los services que dependen del perfil ya escuchan ProfileLoaded.
	dataService.ProfileLoaded:Connect(function(player: Player)
		for _, pass in StoreProducts.GamePasses.InOrder do
			if _isGifted(player, pass.PassId) then
				_fire(player, pass.PassId)
			end
		end
	end)

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
