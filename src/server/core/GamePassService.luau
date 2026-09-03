--!strict
--[[
	GamePassService.luau  (Server)

	Caché de posesión de los gamepasses de `StoreProducts.GamePasses`, para que
	cualquier beneficio (bonus VIP de resultados, arma a la espalda…) pueda
	preguntarlo SIN bloquear: `UserOwnsGamePassAsync` es una llamada web y
	consultarla en caliente metería un yield en medio del spawn o del cierre de
	ronda.

	Cómo se mantiene el caché:
	  · prefetch en PlayerAdded de todos los passes declarados;
	  · `PromptGamePassPurchaseFinished` lo actualiza al comprar en la sesión;
	  · PlayerRemoving lo tira entero (un re-join lo repuebla con el prefetch).

	La entrada por jugador se crea en PlayerAdded y se borra en PlayerRemoving,
	así que su presencia es la señal de "sigue conectado": un fetch que resuelve
	tarde (o una compra confirmada después de irse) no puede repoblar el mapa y
	dejar una entrada huérfana por userId para siempre.

	`OnOwnershipGained` existe porque el prefetch es asíncrono: el beneficio que
	se aplica al spawnear (el holster) suele preguntar ANTES de que el fetch
	resuelva, así que necesita enterarse del false→true en lugar de sondear. La
	compra a mitad de sesión entra por el mismo camino.

	Nada de esto se persiste en el profile: la posesión de un gamepass la sirve
	Roblox y guardarla sólo abriría la puerta a que un beneficio siguiera activo
	tras un refund.

	En Studio hay un override para poder probar (ver STUDIO_OWNERSHIP_OVERRIDE):
	ni las cuentas simuladas de un local server poseen nada, ni Studio deja
	completar una compra real.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StoreProducts = require(Shared.constants.StoreProducts)

--[[
	Override SÓLO de Studio, para poder probar los dos lados del gate sin una
	cuenta alt: en un local server ("Server & Clients") los jugadores son
	identidades simuladas que no poseen nada, y Studio tampoco deja completar una
	compra real, así que sin esto el beneficio no se puede ver.

	  true  → todo el mundo posee todos los passes (probar el beneficio).
	  false → nadie posee nada (probar la cara bloqueada y el botón de la tienda).
	  nil   → comportamiento real: se consulta a Roblox, igual que en producción.

	No hay forma de que esto se cuele en el juego publicado: la constante de
	abajo sólo se mira si `RunService:IsStudio()`, que en un servidor de Roblox
	es false. Mismo patrón que ENABLE_CLEAR_COMMAND en ClearDataCommandService.
]]
local STUDIO_OWNERSHIP_OVERRIDE: boolean? = true

local GamePassService = {}

-- Resuelto una vez: nil fuera de Studio pase lo que pase en la constante.
local _override: boolean? = if RunService:IsStudio() then STUDIO_OWNERSHIP_OVERRIDE else nil

local _started = false

-- userId → passId → posee. Sin tabla de jugador = desconectado; sin entrada de
-- pass = todavía sin resolver (nunca se cachea el "no" de un fetch fallido:
-- volverá a intentarse en la siguiente consulta).
local _ownedByUserId: { [number]: { [number]: boolean } } = {}

-- Fetches en vuelo, para no lanzar N llamadas web del mismo pass mientras la
-- primera sigue esperando respuesta.
local _pendingByUserId: { [number]: { [number]: boolean } } = {}

local _gainedListeners: { (player: Player, passId: number) -> () } = {}

-- ── Helpers internos ─────────────────────────────────────────

local function _fire(player: Player, passId: number)
	for _, listener in _gainedListeners do
		-- task.spawn por listener: un beneficio que reviente no debe impedir que
		-- se apliquen los demás.
		task.spawn(listener, player, passId)
	end
end

--[[
	Guarda el resultado y avisa si el jugador NO lo tenía y ahora sí.
	No-op si el jugador ya se fue (ver cabecera).
]]
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
	-- Con el override puesto la respuesta ya está decidida: la llamada web sólo
	-- gastaría tiempo y, con los userId falsos de un local server, además fallaría
	-- y llenaría el Output de warnings que no significan nada.
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

local function _track(player: Player)
	if _ownedByUserId[player.UserId] == nil then
		_ownedByUserId[player.UserId] = {}
	end
	for _, pass in StoreProducts.GamePasses.InOrder do
		_resolve(player, pass.PassId)
	end
end

-- ── API pública ──────────────────────────────────────────────

--[[
	¿El jugador tiene el pass? Lectura síncrona del caché.

	Un pass sin resolver (o sin id configurado) devuelve `false` y lanza el fetch
	en segundo plano: quien dependa del resultado debe suscribirse con
	`OnOwnershipGained` en vez de asumir que este `false` es definitivo.
]]
function GamePassService.Owns(player: Player, passId: number): boolean
	-- El override va antes que el chequeo de id: así también desbloquea los
	-- passes que todavía no tienen id en el panel, que es justo cuando más falta
	-- hace poder probar el beneficio.
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

--[[
	Registra un callback para cuando un jugador pasa a tener un pass (lo compra,
	o el prefetch confirma que ya lo tenía). Se llama en un thread propio.

	Sin unsubscribe a propósito: los consumidores son services de vida infinita
	que se registran una sola vez al arrancar.
]]
function GamePassService.OnOwnershipGained(listener: (player: Player, passId: number) -> ())
	table.insert(_gainedListeners, listener)
end

function GamePassService.Start()
	if _started then
		return
	end
	_started = true

	-- Ruidoso a propósito: con el override puesto, todo lo que dependa de un
	-- pass miente, y eso tiene que verse en el Output antes de sacar conclusiones
	-- de una prueba en Studio.
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
		end
	end)
end

return GamePassService
