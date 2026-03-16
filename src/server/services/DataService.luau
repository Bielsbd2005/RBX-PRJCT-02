--!strict
--[[
	DataService.luau  (Server)
	Capa central de datos. Responsabilidades:
	  1. Cargar / persistir perfiles con ProfileStore (session locking).
	  2. Replicar datos al cliente con ReplicaService.
	  3. Exponer mutaciones inmutables via Sift (nuevas referencias de tabla).
	  4. Gestionar el ciclo de vida de cada sesión con Janitor.

	Garantía de inmutabilidad:
	  Toda mutación genera una nueva referencia de tabla en el nivel de sección
	  (Stats, Inventory, Loadout, Settings, Metadata). Esto garantiza que:
	    - ReplicaService detecte el cambio y lo replique.
	    - Fusion dispare sus observers en el cliente.

	Política de reintentos:
	  3 reintentos con backoff exponencial (1s → 2s → 4s) antes de kick.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared   = ReplicatedStorage:WaitForChild("Shared")

local ProfileStore    = require(Packages.profilestore)   :: any
local ReplicaService  = require(Packages.replicaservice) :: any
local Janitor         = require(Packages.janitor)        :: any
local Promise         = require(Packages["typed-promise"]) :: any
local Sift            = require(Packages.sift)           :: any

local DataTemplate = require(Shared.constants.DataTemplate) :: any
type PlayerProfile = typeof(DataTemplate)

-- ────────────────────────────────────────────────────────────
-- ESTADO DEL MÓDULO
-- ────────────────────────────────────────────────────────────

-- ProfileStore: clave "PlayerData_v1" — incrementar la versión solo si se requiere
-- una migración de datos destructiva (Reconcile cubre cambios aditivos).
local _PlayerStore = ProfileStore.New("PlayerData_v1", DataTemplate)

-- ClassToken: identificador único del tipo de Replica para este juego.
local _ProfileToken = ReplicaService.NewClassToken("PlayerProfile")

-- Tablas de estado indexadas por UserId
local _profiles: { [number]: any } = {}
local _replicas:  { [number]: any } = {}
local _janitors:  { [number]: any } = {}

-- ────────────────────────────────────────────────────────────
-- HELPERS DE MUTACIÓN INMUTABLE
-- ────────────────────────────────────────────────────────────

--[[
	Actualiza de forma inmutable una sub-tabla en profundidad arbitraria.
	Recorre path desde depth hasta #path creando nuevas referencias en cada nivel.

	Ejemplo:
	  _immutableUpdate(profile.Data.Inventory, {"Inventory","Weapons","Weapon2"}, 2, true)
	  →  nuevo Inventory con Inventory.Weapons.Weapon2 = true
]]
local function _immutableUpdate(tbl: { [string]: any }, path: { string }, depth: number, value: any): { [string]: any }
	local key = path[depth]
	if depth == #path then
		return Sift.Dictionary.set(tbl, key, value)
	else
		local child: { [string]: any } = tbl[key] or {}
		local newChild = _immutableUpdate(child, path, depth + 1, value)
		return Sift.Dictionary.set(tbl, key, newChild)
	end
end

-- ────────────────────────────────────────────────────────────
-- MÓDULO PRINCIPAL
-- ────────────────────────────────────────────────────────────

local DataService = {}
DataService.__index = DataService

-- ─── CARGA CON REINTENTOS ───────────────────────────────────

--[[
	Intenta cargar el perfil del jugador.
	Si ProfileStore devuelve nil (DataStore temporalmente inaccesible),
	reintenta con backoff exponencial: 2^attempt segundos (1s, 2s, 4s).
	Tras 3 intentos fallidos rechaza la Promise para que el jugador sea kickeado.
]]
local function _loadWithRetry(player: Player, attempt: number): any
	return Promise.new(function(resolve: (any) -> (), reject: (any) -> ())
		local profile = _PlayerStore:StartSessionAsync(
			"Player_" .. player.UserId,
			{
				Cancel = function()
					-- Cancela si el jugador ya abandonó el servidor
					return player.Parent ~= Players
				end,
			}
		)
		if profile then
			resolve(profile)
		else
			reject("ProfileStore devolvió nil en intento " .. attempt)
		end
	end):catch(function(err: string)
		if attempt < 3 then
			-- Backoff exponencial: 1s, 2s, 4s
			return Promise.delay(2 ^ attempt):andThen(function()
				return _loadWithRetry(player, attempt + 1)
			end)
		end
		return Promise.reject(err)
	end)
end

-- ─── CICLO DE VIDA DEL JUGADOR ──────────────────────────────

local function _loadPlayer(player: Player): ()
	_loadWithRetry(player, 0)
		:andThen(function(profile: any)
			-- Reconcile: rellena claves faltantes del template sin tocar valores existentes.
			-- Si en el futuro añadimos un campo nuevo a DataTemplate, los jugadores
			-- existentes recibirán el valor por defecto automáticamente.
			profile:Reconcile()

			-- GDPR: asociar UserId para cumplimiento de políticas de privacidad.
			profile:AddUserId(player.UserId)

			-- Crear Replica: ReplicaService envía profile.Data al cliente al conectarse.
			-- Replication = player  →  solo este jugador recibe esta réplica.
			local replica = ReplicaService.NewReplica({
				ClassToken  = _ProfileToken,
				Tags        = { Player = player },
				Data        = profile.Data,
				Replication = player,
			})

			-- Janitor por jugador: garantiza limpieza de memoria al salir.
			local janitor = Janitor.new()

			_profiles[player.UserId] = profile
			_replicas[player.UserId] = replica
			_janitors[player.UserId] = janitor

			-- ── Auto-save cada 60 segundos ──
			-- ProfileStore ya guarda automáticamente cada 300s;
			-- el loop de 60s reduce la ventana de pérdida de datos.
			local running = true
			janitor:Add(function()
				running = false
			end, true)

			task.spawn(function()
				while running do
					task.wait(60)
					if running and profile:IsActive() then
						profile:Save()
					end
				end
			end)

			-- ── Metadata: registrar LastSeen y TotalPlaytime ──
			profile.Data.Metadata.LastSeen = os.time()
			if profile.Data.Metadata.CreatedAt == 0 then
				profile.Data.Metadata.CreatedAt = os.time()
			end

			-- ── Guardia de sesión robada (session steal) ──
			-- Si otro servidor toma la sesión, OnSessionEnd dispara.
			-- Kickeamos al jugador para evitar estado corrupto.
			local connection = profile.OnSessionEnd:Connect(function()
				player:Kick(
					"Tu sesión de datos fue terminada externamente. "
						.. "Por favor, vuelve a conectarte."
				)
			end)
			janitor:Add(connection, "Disconnect")

			-- ── Orden de limpieza al salir ──
			-- 1. Destruir Replica (desreplica al cliente)
			-- 2. Finalizar sesión de ProfileStore (guarda y libera lock)
			janitor:Add(function()
				replica:Destroy()
				profile:EndSession()
				_profiles[player.UserId] = nil
				_replicas[player.UserId] = nil
				_janitors[player.UserId] = nil
			end, true)
		end)
		:catch(function(err: string)
			warn("[DataService]: No se pudo cargar perfil de " .. player.Name .. ": " .. tostring(err))
			player:Kick(
				"No se pudo cargar tu perfil tras varios intentos. "
					.. "Por favor, vuelve a conectarte."
			)
		end)
end

local function _unloadPlayer(player: Player): ()
	local janitor = _janitors[player.UserId]
	if janitor then
		janitor:Destroy()
	end
end

-- ─── API PÚBLICA ─────────────────────────────────────────────

--[[
	Inicia el servicio: conecta eventos de jugadores y carga los ya presentes.
]]
function DataService:Start(): ()
	Players.PlayerAdded:Connect(_loadPlayer)
	Players.PlayerRemoving:Connect(_unloadPlayer)

	-- Jugadores que ya estaban en el servidor al cargar este script (en Studio)
	for _, player in Players:GetPlayers() do
		task.spawn(_loadPlayer, player)
	end
end

--[[
	Devuelve el Profile de ProfileStore de un jugador, o nil si no está cargado.
]]
function DataService:GetProfile(player: Player): any
	return _profiles[player.UserId]
end

--[[
	Devuelve la Replica de ReplicaService de un jugador, o nil.
]]
function DataService:GetReplica(player: Player): any
	return _replicas[player.UserId]
end

--[[
	Establece un valor en el perfil usando una ruta de claves.

	Garantía de inmutabilidad:
	  Crea una nueva referencia en el nivel de sección (path[1]),
	  lo que dispara ListenToChange({"<section>"}) en el cliente.

	path    {string}  — e.g. {"Stats", "Cash"} o {"Inventory", "Weapons", "Weapon2"}
	value   any       — valor nuevo

	Devuelve true si tuvo éxito, false si el jugador no está cargado.
]]
function DataService:SetValue(player: Player, path: { string }, value: any): boolean
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false
	end

	local section = path[1]
	-- _immutableUpdate construye una nueva tabla desde depth=2 hasta el leaf.
	local newSection = _immutableUpdate(profile.Data[section] :: { [string]: any }, path, 2, value)

	-- SetValue({section}, newSection) en ReplicaService:
	--   1. Establece replica.Data[section] = newSection  (nueva referencia)
	--   2. Envía el cambio al cliente vía RemoteEvent
	-- Como replica.Data ES profile.Data (mismo reference), profile.Data[section]
	-- también queda actualizado.
	replica:SetValue({ section }, newSection)

	return true
end

--[[
	Incrementa un campo numérico del perfil.
	Nunca baja de 0 (ideal para Cash, XP, etc.).

	Devuelve (success, newValue).
]]
function DataService:Increment(player: Player, path: { string }, amount: number): (boolean, number)
	local profile = _profiles[player.UserId]
	if not profile then
		return false, 0
	end

	-- Navegar hasta el valor actual
	local pointer: any = profile.Data
	for i = 1, #path - 1 do
		pointer = pointer[path[i]]
	end
	local current: number = pointer[path[#path]] or 0
	local newValue = math.max(0, current + amount)

	local ok = self:SetValue(player, path, newValue)
	return ok, newValue
end

--[[
	Aplica múltiples actualizaciones atómicamente, generando exactamente
	1 mensaje de red por sección modificada (vs N mensajes individuales).

	updates  {{ path: {string}, value: any }}

	Algoritmo:
	  1. Por cada update, acumula los cambios en un mapa de secciones.
	  2. Cada sección acumulada es inmutable (Sift merge en cadena).
	  3. Al final, un solo SetValue por sección.

	Ejemplo (comprar un arma):
	  {
	    { path = {"Stats",     "Cash"},              value = 0    },
	    { path = {"Inventory", "Weapons", "Weapon2"}, value = true },
	  }
	  → 2 SetValue calls:  replica:SetValue({"Stats"}, newStats)
	                        replica:SetValue({"Inventory"}, newInventory)
]]
function DataService:BatchUpdate(
	player: Player,
	updates: { { path: { string }, value: any } }
): boolean
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false
	end

	-- Mapa: section → nueva tabla inmutable acumulada
	local accumulated: { [string]: { [string]: any } } = {}

	for _, update in updates do
		local section = update.path[1]
		-- Usar la versión acumulada como base si ya procesamos esta sección
		local base: { [string]: any } = accumulated[section] or (profile.Data[section] :: { [string]: any })
		accumulated[section] = _immutableUpdate(base, update.path, 2, update.value)
	end

	-- Aplicar: un SetValue por sección modificada
	for section, newSection in accumulated do
		replica:SetValue({ section }, newSection)
	end

	return true
end

return DataService
