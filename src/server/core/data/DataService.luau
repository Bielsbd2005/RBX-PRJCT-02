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

local LocalizationService = game:GetService("LocalizationService")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared   = ReplicatedStorage:WaitForChild("Shared")

local ProfileStore    = require(Packages.profilestore)   :: any
local ReplicaService  = require(Packages.replicaservice) :: any
local Janitor         = require(Packages.janitor)        :: any
local Promise         = require(Packages["typed-promise"]) :: any
local Sift            = require(Packages.sift)           :: any

local DataTemplate = require(Shared.constants.DataTemplate) :: any
local LevelingConfig = require(Shared.constants.LevelingConfig)
local DataMigrations = require(script.Parent.DataMigrations)
type PlayerProfile = typeof(DataTemplate)

local AUTO_SAVE_INTERVAL_SECONDS = 30
local MAX_SAVES_PER_CYCLE = 8

-- Cap superior para cualquier campo numérico actualizado vía Increment / delta.
-- Defensa contra exploits o bugs que podrían inflar Cash/XP a infinito y romper
-- serialización JSON de ProfileStore o UI numérica del cliente.
local NUMERIC_CAP = 1e12

-- Cap absoluto de nivel para AddXP. Defensa contra loops infinitos si
-- LevelingConfig devuelve valores degenerados o si llega un amount enorme.
local MAX_LEVEL = 1000

-- Iteraciones máximas en el bucle de level-up de AddXP.
local MAX_LEVELUP_ITERATIONS = 1000

local function _clampNumeric(value: number): number
	if value ~= value then -- NaN
		return 0
	end
	if value > NUMERIC_CAP then
		return NUMERIC_CAP
	end
	if value < 0 then
		return 0
	end
	return value
end

-- ────────────────────────────────────────────────────────────
-- ESTADO DEL MÓDULO
-- ────────────────────────────────────────────────────────────

-- ProfileStore key: bumpear cuando haya cambios destructivos del schema que
-- no puedan resolverse con Reconcile (campo renombrado/eliminado, semántica
-- cambiada). Cambiar la key abandona el datastore anterior y los perfiles
-- arrancan limpios desde DataTemplate.
local _PlayerStore = ProfileStore.New("PlayerData_v2", DataTemplate)

-- ClassToken: identificador único del tipo de Replica para este juego.
local _ProfileToken = ReplicaService.NewClassToken("PlayerProfile")

-- Tablas de estado indexadas por UserId
local _profiles: { [number]: any } = {}
local _replicas:  { [number]: any } = {}
local _janitors:  { [number]: any } = {}
local _dirtyProfiles: { [number]: boolean } = {}
local _loadTokens: { [number]: number } = {}
local _started = false
local _serviceJanitor: any = nil
local _serviceGeneration = 0

-- Signals públicos. Otros servicios se suscriben para reaccionar a eventos
-- del ciclo de vida del perfil sin tener que polling-ear GetProfile.
local _profileLoadedBindable = Instance.new("BindableEvent")
local _profileUnloadingBindable = Instance.new("BindableEvent")

-- ────────────────────────────────────────────────────────────
-- HELPERS DE MUTACIÓN INMUTABLE
-- ────────────────────────────────────────────────────────────

--[[
	Actualiza de forma inmutable una sub-tabla en profundidad arbitraria.
	Recorre path desde depth hasta #path creando nuevas referencias en cada nivel.

	Ejemplo:
	  _immutableUpdate(profile.Data.Inventory, {"Inventory","Main","Weapon2"}, 2, true)
	  →  nuevo Inventory con Inventory.Main.Weapon2 = true

	Sanity cap de profundidad: nuestros paths reales nunca superan ~5 niveles
	(WeaponSkinsByWeapon → Main → weaponId → skinId). Un path > 32 indica un
	bug del caller; mejor abortar que stack-overflow.
]]
local MAX_PATH_DEPTH = 32

local function _immutableUpdate(tbl: { [string]: any }, path: { string }, depth: number, value: any): { [string]: any }
	if depth > MAX_PATH_DEPTH then
		error(("[DataService] _immutableUpdate path depth excede %d (probable bug)"):format(MAX_PATH_DEPTH))
	end
	local key = path[depth]
	if depth == #path then
		return Sift.Dictionary.set(tbl, key, value)
	else
		local child: { [string]: any } = tbl[key] or {}
		local newChild = _immutableUpdate(child, path, depth + 1, value)
		return Sift.Dictionary.set(tbl, key, newChild)
	end
end

local function _deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, nestedValue in value do
		copy[key] = _deepCopy(nestedValue)
	end

	return copy
end

-- ────────────────────────────────────────────────────────────
-- MÓDULO PRINCIPAL
-- ────────────────────────────────────────────────────────────

local DataService = {}
DataService.__index = DataService

-- Signals públicos. Suscribirse vía `DataService.ProfileLoaded:Connect(fn)`.
--   ProfileLoaded(player)    — disparado tras crear la Replica; GetProfile/
--                              GetReplica devuelven valores válidos.
--   ProfileUnloading(player) — disparado ANTES de destruir la Replica y cerrar
--                              la sesión; el perfil aún es modificable.
DataService.ProfileLoaded = _profileLoadedBindable.Event
DataService.ProfileUnloading = _profileUnloadingBindable.Event

local function _isGenerationActive(generation: number): boolean
	return _started and _serviceGeneration == generation
end

local function _nextLoadToken(userId: number): number
	local nextToken = (_loadTokens[userId] or 0) + 1
	_loadTokens[userId] = nextToken
	return nextToken
end

local function _isLoadStillValid(player: Player, loadToken: number, generation: number): boolean
	return player.Parent == Players
		and _loadTokens[player.UserId] == loadToken
		and _isGenerationActive(generation)
end

local function _markDirty(userId: number): ()
	_dirtyProfiles[userId] = true
end

local function _autoSaveDirtyProfiles(generation: number): ()
	while _isGenerationActive(generation) do
		task.wait(AUTO_SAVE_INTERVAL_SECONDS)

		if not _isGenerationActive(generation) then
			break
		end

		if next(_dirtyProfiles) == nil then
			continue
		end

		-- Snapshot de candidatos. Limitamos por ciclo para no saturar el
		-- DataStore en servers con muchos perfiles dirty simultáneamente.
		local toSave: { number } = {}
		for userId in _dirtyProfiles do
			table.insert(toSave, userId)
			if #toSave >= MAX_SAVES_PER_CYCLE then
				break
			end
		end

		-- Guardar en paralelo: cada Save yielda independientemente esperando
		-- al DataStore. En serie con N perfiles podía bloquear N * latencia.
		local pending = #toSave
		for _, userId in toSave do
			task.spawn(function()
				local profile = _profiles[userId]
				if profile ~= nil and profile:IsActive() then
					local ok = pcall(function()
						profile:Save()
					end)
					if ok then
						-- Solo limpiar dirty si el save tuvo éxito; si falló
						-- queremos reintentar en el siguiente ciclo.
						_dirtyProfiles[userId] = nil
					end
				else
					-- Perfil ya no activo: la entrada dirty es huérfana.
					_dirtyProfiles[userId] = nil
				end
				pending -= 1
			end)
		end

		-- Esperar a que termine el batch antes de iniciar el siguiente ciclo.
		-- Deadline duro: si una task se queda colgada (improbable, pero la
		-- alternativa es bloquear el loop entero), continuamos al siguiente
		-- ciclo y dejamos los dirty pendientes para el próximo intento.
		local deadline = os.clock() + (AUTO_SAVE_INTERVAL_SECONDS - 5)
		while pending > 0 and _isGenerationActive(generation) and os.clock() < deadline do
			task.wait(0.1)
		end
		if pending > 0 then
			warn(("[DataService] Autosave: %d saves no completaron en %ds"):format(pending, AUTO_SAVE_INTERVAL_SECONDS - 5))
		end
	end
end

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
	local userId = player.UserId
	local loadToken = _nextLoadToken(userId)
	local generation = _serviceGeneration

	_loadWithRetry(player, 0)
		:andThen(function(profile: any)
			if not _isLoadStillValid(player, loadToken, generation) then
				pcall(function()
					profile:EndSession()
				end)
				return
			end

			-- Reconcile: rellena claves faltantes del template sin tocar valores existentes.
			-- Si en el futuro añadimos un campo nuevo a DataTemplate, los jugadores
			-- existentes recibirán el valor por defecto automáticamente.
			profile:Reconcile()

			-- Migraciones forward-only. Reconcile cubre cambios aditivos; las
			-- migraciones cubren transformaciones (renames, splits, derivados).
			-- Ver DataMigrations.luau para añadir una nueva.
			DataMigrations.migrate(profile.Data)

			-- ⚠ Contrato de mutación in-place:
			-- Todo lo siguiente muta `profile.Data` directamente. Es seguro porque
			-- todavía no se ha creado la Replica: no hay cliente ni observers. Una
			-- vez creada (`replica = ReplicaService.NewReplica{...}` más abajo),
			-- `replica.Data` y `profile.Data` comparten referencia, así que toda
			-- mutación posterior DEBE ir por SetValue/BatchUpdate para replicarse
			-- y disparar ListenToChange en el cliente.

			-- Prune de ProcessedReceipts antiguos. Roblox mantiene receipts
			-- válidos ~3 días; mantenemos 7 días por seguridad. Sin prune,
			-- esta tabla crecería indefinidamente.
			if type(profile.Data.ProcessedReceipts) == "table" then
				local cutoff = os.time() - (7 * 24 * 3600)
				for purchaseId, processedAt in profile.Data.ProcessedReceipts do
					if type(processedAt) ~= "number" or processedAt < cutoff then
						profile.Data.ProcessedReceipts[purchaseId] = nil
					end
				end
			else
				profile.Data.ProcessedReceipts = {}
			end

			-- GDPR: asociar UserId para cumplimiento de políticas de privacidad.
			profile:AddUserId(player.UserId)

			-- ── Tracking de sesión ────────────────────────────────────
			-- Metadata se actualiza antes de crear la Replica (mutación in-place
			-- segura — ver contrato arriba).
			local now = os.time()
			local meta = profile.Data.Metadata
			meta.LastSeen = now
			if meta.CreatedAt == 0 then
				meta.CreatedAt = now
			end
			meta.JoinCount = (meta.JoinCount or 0) + 1
			local placeVersion = tostring(game.PlaceVersion)
			meta.LastClientVersion = placeVersion
			if meta.FirstSessionVersion == "" then
				meta.FirstSessionVersion = placeVersion
			end
			-- Country: GetCountryRegionForPlayerAsync yielda y puede tardar.
			-- Lo lanzamos en paralelo y escribimos via SetValue cuando llegue,
			-- así el load del perfil no se bloquea por el API de localización.
			if meta.Country == "" then
				task.spawn(function()
					local ok, code = pcall(function()
						return LocalizationService:GetCountryRegionForPlayerAsync(player)
					end)
					if not ok or type(code) ~= "string" or code == "" then
						return
					end
					-- Verificar que el perfil sigue cargado (jugador no se fue).
					local stillLoaded = _profiles[player.UserId]
					if stillLoaded == profile then
						DataService:SetValue(player, { "Metadata", "Country" }, code)
					end
				end)
			end

			-- ── LoginStreak ───────────────────────────────────────────
			-- Resolución por día UTC consecutivo. Definir la "fecha de hoy"
			-- en UTC evita saltos por timezone del servidor.
			local todayKey = os.date("!%Y-%m-%d", now) :: string
			local streak = profile.Data.LoginStreak
			if streak.LastLoginDateKey ~= todayKey then
				local newCurrent: number? = nil
				if streak.LastLoginDateKey == "" then
					-- Primera sesión registrada.
					newCurrent = 1
				else
					-- Parsear LastLoginDateKey con guard estricto. Si está
					-- corrupto (formato distinto de YYYY-MM-DD), NO reseteamos
					-- ni avanzamos: warn y dejamos el streak intacto. Resetear
					-- silenciosamente borraría progreso del jugador.
					local y, m, d = string.match(streak.LastLoginDateKey, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
					if y and m and d then
						local lastTime = os.time({
							year = tonumber(y) :: number,
							month = tonumber(m) :: number,
							day = tonumber(d) :: number,
							hour = 12,
						})
						local todayTime = os.time({
							year = tonumber(string.sub(todayKey, 1, 4)) :: number,
							month = tonumber(string.sub(todayKey, 6, 7)) :: number,
							day = tonumber(string.sub(todayKey, 9, 10)) :: number,
							hour = 12,
						})
						local dayDelta = math.floor((todayTime - lastTime) / 86400 + 0.5)
						if dayDelta == 1 then
							newCurrent = (streak.Current or 0) + 1
						elseif dayDelta > 1 then
							-- Gap > 1 día → reset.
							newCurrent = 1
						elseif dayDelta == 0 then
							-- Mismo día UTC pese a key distinta → no-op
							-- (puede ocurrir si la key se escribió raro).
							newCurrent = streak.Current or 1
						else
							-- dayDelta < 0 → fecha futura. Server con clock
							-- desincronizado o key manipulada. No tocamos.
							warn(("[DataService] LoginStreak: dayDelta negativo (%d) para user %d, key=%s"):format(dayDelta, player.UserId, streak.LastLoginDateKey))
						end
					else
						warn(("[DataService] LoginStreak: LastLoginDateKey corrupto para user %d: '%s' — streak intacto"):format(player.UserId, tostring(streak.LastLoginDateKey)))
					end
				end

				if newCurrent ~= nil then
					streak.Current = newCurrent
					streak.LastLoginDateKey = todayKey
					if streak.Current > (streak.Best or 0) then
						streak.Best = streak.Current
					end
				end
			end

			if not _isLoadStillValid(player, loadToken, generation) then
				pcall(function()
					profile:EndSession()
				end)
				return
			end

			local existingJanitor = _janitors[userId]
			if existingJanitor then
				existingJanitor:Destroy()
			end

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

			_profiles[userId] = profile
			_replicas[userId] = replica
			_janitors[userId] = janitor
			_markDirty(userId)

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
			-- 1. Acumular TimePlayedSeconds vía Increment (atómico, marca dirty,
			--    se replica al cliente — útil si hay UI mostrándolo en tiempo
			--    real al final de partida).
			-- 2. Disparar ProfileUnloading (consumidores con yield NO bloquean
			--    el TimePlayed write, ya está hecho).
			-- 3. Destruir Replica (desreplica al cliente).
			-- 4. Finalizar sesión de ProfileStore (guarda y libera lock).
			local sessionStart = os.time()
			janitor:Add(function()
				local sessionSeconds = math.max(0, os.time() - sessionStart)
				if sessionSeconds > 0 then
					-- Increment es síncrono y no yielda; pasa por SetValue
					-- → marca dirty → autosave / EndSession lo persiste.
					DataService:Increment(player, { "Stats", "TimePlayedSeconds" }, sessionSeconds)
				end

				_profileUnloadingBindable:Fire(player)

				replica:Destroy()
				profile:EndSession()
				_dirtyProfiles[userId] = nil
				_profiles[userId] = nil
				_replicas[userId] = nil
				_janitors[userId] = nil
				if _loadTokens[userId] == loadToken then
					_loadTokens[userId] = nil
				end
			end, true)

			-- Disparar el signal público después de poblar las tablas y
			-- registrar el cleanup; los consumidores pueden llamar a
			-- GetProfile/GetReplica de inmediato. task.spawn aísla yields
			-- de subscribers para que no bloqueen el load.
			task.spawn(function()
				_profileLoadedBindable:Fire(player)
			end)
		end)
		:catch(function(err: string)
			if not _isLoadStillValid(player, loadToken, generation) then
				if _loadTokens[userId] == loadToken then
					_loadTokens[userId] = nil
				end
				return
			end

			if _loadTokens[userId] == loadToken then
				_loadTokens[userId] = nil
			end

			warn("[DataService]: No se pudo cargar perfil de " .. player.Name .. ": " .. tostring(err))
			player:Kick(
				"No se pudo cargar tu perfil tras varios intentos. "
					.. "Por favor, vuelve a conectarte."
			)
		end)
end

local function _unloadPlayer(player: Player): ()
	local userId = player.UserId

	-- Invalida cualquier carga async en curso para este UserId.
	_nextLoadToken(userId)

	local janitor = _janitors[userId]
	if janitor then
		janitor:Destroy()
	else
		_dirtyProfiles[userId] = nil
		_profiles[userId] = nil
		_replicas[userId] = nil
		_janitors[userId] = nil
	end

	_loadTokens[userId] = nil
end

-- ─── API PÚBLICA ─────────────────────────────────────────────

--[[
	Inicia el servicio: conecta eventos de jugadores y carga los ya presentes.
]]
function DataService:Start(): ()
	if _started then
		return
	end

	local previousJanitor = _serviceJanitor
	if previousJanitor then
		pcall(function()
			previousJanitor:Destroy()
		end)
	end

	_serviceGeneration += 1
	_serviceJanitor = Janitor.new()

	_started = true

	local generation = _serviceGeneration
	_serviceJanitor:Add(function()
		_started = false

		local janitorsToDestroy = {}
		for _, playerJanitor in _janitors do
			table.insert(janitorsToDestroy, playerJanitor)
		end

		for _, playerJanitor in janitorsToDestroy do
			playerJanitor:Destroy()
		end

		table.clear(_profiles)
		table.clear(_replicas)
		table.clear(_janitors)

		table.clear(_dirtyProfiles)
		table.clear(_loadTokens)

		_serviceGeneration += 1

		_serviceJanitor = nil
	end, true)

	task.spawn(_autoSaveDirtyProfiles, generation)

	_serviceJanitor:Add(Players.PlayerAdded:Connect(function(player: Player)
		if not _isGenerationActive(generation) then
			return
		end

		_loadPlayer(player)
	end), "Disconnect")

	_serviceJanitor:Add(Players.PlayerRemoving:Connect(function(player: Player)
		if not _isGenerationActive(generation) then
			return
		end

		_unloadPlayer(player)
	end), "Disconnect")

	game:BindToClose(function()
		-- Roblox da ~30s antes de matar el servidor. Si destruimos el janitor
		-- de forma normal, los EndSession() corren secuencialmente (cada uno
		-- yielda esperando al DataStore). Con muchos jugadores eso puede exceder
		-- el presupuesto y perder writes. En su lugar:
		--   1. Snapshot de profiles activos.
		--   2. EndSession en paralelo (cada uno yielda independientemente).
		--   3. Esperar hasta que todos hayan finalizado o se agote el tiempo.
		_started = false

		local profilesToEnd = {}
		for userId, profile in _profiles do
			profilesToEnd[userId] = profile
		end

		local pending = 0
		for _, _ in profilesToEnd do
			pending += 1
		end

		if pending == 0 then
			return
		end

		for userId, profile in profilesToEnd do
			task.spawn(function()
				pcall(function()
					-- EndSession yielda hasta confirmar el save y liberar el lock.
					profile:EndSession()
				end)
				_dirtyProfiles[userId] = nil
				pending -= 1
			end)
		end

		-- Esperar con timeout duro (25s) para dejar margen al cierre de Roblox.
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end

		if pending > 0 then
			warn(("[DataService] BindToClose: %d perfiles no terminaron a tiempo"):format(pending))
		end
	end)

	-- Jugadores que ya estaban en el servidor al cargar este script (en Studio)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			if not _isGenerationActive(generation) then
				return
			end

			_loadPlayer(player)
		end)
	end
end

function DataService:Destroy(): ()
	local janitor = _serviceJanitor
	if janitor then
		janitor:Destroy()
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

	path    {string}  — e.g. {"Stats", "Cash"} o {"Inventory", "Main", "Weapon2"}
	value   any       — valor nuevo

	Devuelve true si tuvo éxito, false si el jugador no está cargado.
]]
function DataService:SetValue(player: Player, path: { string }, value: any): boolean
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false
	end

	-- Validar path: debe ser tabla no vacía con primer elemento string.
	if type(path) ~= "table" or #path == 0 or type(path[1]) ~= "string" then
		warn(("[DataService] SetValue: path inválido para user %d"):format(player.UserId))
		return false
	end

	-- Clamp consistente para valores numéricos (mismo cap que Increment / delta).
	if type(value) == "number" then
		value = _clampNumeric(value)
	end

	local section = path[1]
	-- _immutableUpdate construye una nueva tabla desde depth=2 hasta el leaf.
	local newSection = _immutableUpdate(profile.Data[section] :: { [string]: any }, path, 2, value)

	-- SetValue({section}, newSection) en ReplicaService:
	--   1. Establece replica.Data[section] = newSection  (nueva referencia)
	--   2. Envía el cambio al cliente vía RemoteEvent
	-- Como replica.Data ES profile.Data (mismo reference), profile.Data[section]
	-- también queda actualizado.
	local ok, err = pcall(replica.SetValue, replica, { section }, newSection)
	if not ok then
		warn(("[DataService] replica:SetValue failed for user %d, section %s: %s"):format(player.UserId, tostring(section), tostring(err)))
		return false
	end
	_markDirty(player.UserId)

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
	if type(amount) ~= "number" or amount ~= amount then
		return false, current
	end
	local newValue = _clampNumeric(current + amount)

	local ok = self:SetValue(player, path, newValue)
	return ok, newValue
end

--[[
	Incrementa el contador de kills del jugador para un arma concreta.
	Devuelve (success, newValue).
]]
function DataService:IncrementWeaponKills(player: Player, weaponCategory: string, weaponKey: string, amount: number?): (boolean, number)
	if weaponCategory ~= "Main" and weaponCategory ~= "Special" then
		return false, 0
	end
	if type(weaponKey) ~= "string" or weaponKey == "" then
		return false, 0
	end
	local delta = math.max(0, math.floor(amount or 1))
	if delta <= 0 then
		return false, 0
	end
	return self:Increment(player, { "WeaponKills", weaponCategory, weaponKey }, delta)
end

--[[
	Añade XP al jugador y procesa subidas de nivel en cascada.
	Mantiene consistentes: Stats.XP, Stats.Level y Stats.XPToNextLevel.

	Devuelve (success, newLevel, newXP, newXPToNextLevel).
]]
function DataService:AddXP(player: Player, amount: number): (boolean, number, number, number)
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false, 0, 0, 0
	end

	if amount <= 0 then
		local currentStats = profile.Data.Stats
		return true, currentStats.Level, currentStats.XP, currentStats.XPToNextLevel
	end

	local stats = profile.Data.Stats
	local level = math.max(0, math.floor(stats.Level or 0))
	local xp = math.max(0, math.floor(stats.XP or 0))
	local xpToNext = math.max(1, math.floor(stats.XPToNextLevel or LevelingConfig.GetXPToNextLevel(level)))

	xp += math.floor(amount)

	local iterations = 0
	while xp >= xpToNext and level < MAX_LEVEL and iterations < MAX_LEVELUP_ITERATIONS do
		xp -= xpToNext
		level += 1
		xpToNext = math.max(1, LevelingConfig.GetXPToNextLevel(level))
		iterations += 1
	end

	-- Si llegamos al cap de nivel, descartar XP sobrante para evitar acumular
	-- progreso "fantasma" hacia un nivel inalcanzable.
	if level >= MAX_LEVEL then
		level = MAX_LEVEL
		xp = 0
	end

	if iterations >= MAX_LEVELUP_ITERATIONS then
		warn(("[DataService] AddXP: alcanzado MAX_LEVELUP_ITERATIONS para user %d (amount=%d)"):format(player.UserId, amount))
	end

	local ok = self:BatchUpdate(player, {
		{ path = { "Stats", "XP" }, value = xp },
		{ path = { "Stats", "Level" }, value = level },
		{ path = { "Stats", "XPToNextLevel" }, value = xpToNext },
	})

	if not ok then
		return false, 0, 0, 0
	end

	return true, level, xp, xpToNext
end

--[[
	Aplica múltiples actualizaciones atómicamente, generando exactamente
	1 mensaje de red por sección modificada (vs N mensajes individuales).

	updates  {{ path: {string}, value: any?, delta: number? }}

	Cada entry usa `value` (set absoluto) o `delta` (incremento numérico
	relativo al valor actual, clamp a ≥ 0). Los `delta` se resuelven contra
	la sección acumulada en el momento de aplicar — eliminando TOCTOU entre
	el read del caller y el write final.

	Algoritmo:
	  1. Por cada update, acumula los cambios en un mapa de secciones.
	  2. Cada sección acumulada es inmutable (Sift merge en cadena).
	  3. Si todas las secciones se construyen sin error, aplica los SetValue.
	     Si algún SetValue falla, devuelve false (estado parcialmente aplicado;
	     ReplicaService.SetValue no debería fallar en condiciones normales).

	Ejemplo (comprar un arma con delta):
	  {
	    { path = {"Stats",     "Cash"},              delta = -100 },
	    { path = {"Inventory", "Main", "Weapon2"}, value = true },
	  }
]]
function DataService:BatchUpdate(
	player: Player,
	updates: { { path: { string }, value: any?, delta: number? } }
): boolean
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false
	end

	-- Mapa: section → nueva tabla inmutable acumulada
	local accumulated: { [string]: { [string]: any } } = {}

	for i, update in updates do
		local path = update.path
		-- Validar path: debe ser tabla no vacía con primer elemento string.
		-- Sin guard, _immutableUpdate o profile.Data[nil] crashearían y se
		-- abortaría el batch entero (con secciones previas ya aplicadas).
		if type(path) ~= "table" or #path == 0 or type(path[1]) ~= "string" then
			warn(("[DataService] BatchUpdate update[%d]: path inválido"):format(i))
			continue
		end

		-- Validar payload: debe traer value o delta (no ambos nil). Sin esto,
		-- un caller que olvide el campo sobrescribe la clave con nil y borra
		-- el campo del schema, replicando el delete al cliente.
		if update.delta == nil and update.value == nil then
			warn(("[DataService] BatchUpdate update[%d]: falta value/delta"):format(i))
			continue
		end

		local section = path[1]
		-- Usar la versión acumulada como base si ya procesamos esta sección,
		-- así los deltas posteriores ven los efectos de los anteriores.
		local base: { [string]: any } = accumulated[section] or (profile.Data[section] :: { [string]: any })

		local newValue: any
		if update.delta ~= nil then
			-- Resolver el valor actual desde la base acumulada.
			local pointer: any = base
			for j = 2, #path - 1 do
				pointer = if type(pointer) == "table" then pointer[path[j]] else nil
			end
			local current: any = if type(pointer) == "table" then pointer[path[#path]] else nil
			if type(current) ~= "number" then
				current = 0
			end
			local delta = update.delta
			if type(delta) ~= "number" or delta ~= delta then
				delta = 0
			end
			newValue = _clampNumeric(current + delta)
		else
			newValue = update.value
			-- Si el caller pasa un número vía `value=`, aplicar el mismo cap
			-- que aplicamos en deltas/Increment para garantizar consistencia.
			-- No-op para strings/booleans/tablas.
			if type(newValue) == "number" then
				newValue = _clampNumeric(newValue)
			end
		end

		accumulated[section] = _immutableUpdate(base, path, 2, newValue)
	end

	-- Aplicar: un SetValue por sección modificada. Devolver false si alguno
	-- falla para que el caller pueda reaccionar (responder error al cliente,
	-- compensar, etc.) en vez de creer que la transacción tuvo éxito.
	local allOk = true
	for section, newSection in accumulated do
		local ok, err = pcall(replica.SetValue, replica, { section }, newSection)
		if not ok then
			allOk = false
			warn(("[DataService] BatchUpdate SetValue failed for user %d, section %s: %s"):format(player.UserId, tostring(section), tostring(err)))
		end
	end
	_markDirty(player.UserId)

	return allOk
end

--[[
	Idempotencia de MarketplaceService.ProcessReceipt.

	Roblox puede invocar ProcessReceipt varias veces para el mismo PurchaseId
	si: el server crashea entre Increment y PurchaseGranted, o el Decision
	devuelto fue NotProcessedYet. Sin idempotencia se otorga la recompensa
	múltiples veces (duping de Cash via DevProducts).

	Patrón en el caller:
	    if DataService:IsReceiptProcessed(player, receiptInfo.PurchaseId) then
	        return Enum.ProductPurchaseDecision.PurchaseGranted
	    end
	    -- otorgar recompensa (Increment, etc.)
	    DataService:MarkReceiptProcessed(player, receiptInfo.PurchaseId)
	    return Enum.ProductPurchaseDecision.PurchaseGranted
]]
function DataService:IsReceiptProcessed(player: Player, purchaseId: string): boolean
	local profile = _profiles[player.UserId]
	if not profile then
		return false
	end
	local processed = profile.Data.ProcessedReceipts
	if type(processed) ~= "table" then
		return false
	end
	return processed[purchaseId] ~= nil
end

function DataService:MarkReceiptProcessed(player: Player, purchaseId: string): boolean
	if type(purchaseId) ~= "string" or purchaseId == "" then
		return false
	end
	return self:SetValue(player, { "ProcessedReceipts", purchaseId }, os.time())
end

--[[
	Otorga un ítem de inventario en una transacción atómica:
	  1. Inventory[category][itemId] = true (ownership boolean).
	  2. InventoryMeta[category][itemId] = { AcquiredAt, Source }.
	  3. NewItemFlags[category][itemId] = true (badge "NEW!" en UI).

	Source: una etiqueta corta para analytics ("Shop", "Case", "Reward",
	"Default", "Code", "Gift", etc.).

	Devuelve true si todas las escrituras tuvieron éxito.
]]
function DataService:GrantItem(player: Player, category: string, itemId: string, source: string): boolean
	if type(category) ~= "string" or category == "" then
		return false
	end
	if type(itemId) ~= "string" or itemId == "" then
		return false
	end
	local effectiveSource = if type(source) == "string" and source ~= "" then source else "Unknown"

	return self:BatchUpdate(player, {
		{ path = { "Inventory", category, itemId }, value = true },
		{ path = { "InventoryMeta", category, itemId }, value = {
			AcquiredAt = os.time(),
			Source = effectiveSource,
		} },
		{ path = { "NewItemFlags", category, itemId }, value = true },
	})
end

--[[
	Marca un ítem como visto por el jugador (UI quita el badge NEW!).
	Idempotente: llamarlo múltiples veces no causa problema.

	Implementación: SetValue con path al leaf y value=nil. _immutableUpdate
	usa Sift.Dictionary.set, que con nil borra la clave. Esto evita la race
	de "construir copia parcial del padre y reescribirla" que clobberaría
	limpiezas concurrentes para items distintos en la misma categoría.
]]
function DataService:MarkItemSeen(player: Player, category: string, itemId: string): boolean
	if type(category) ~= "string" or category == "" then
		return false
	end
	if type(itemId) ~= "string" or itemId == "" then
		return false
	end
	local profile = _profiles[player.UserId]
	if not profile then
		return false
	end
	-- Early-return si no estaba marcado (evita writes redundantes).
	local flags = profile.Data.NewItemFlags
	if type(flags) ~= "table" then
		return true
	end
	local categoryFlags = flags[category]
	if type(categoryFlags) ~= "table" or categoryFlags[itemId] == nil then
		return true
	end

	-- SetValue al leaf con nil. _immutableUpdate solo toca la clave del item;
	-- otros writes concurrentes (otros items en la misma categoría) afectan
	-- claves distintas y no se pisan.
	return self:SetValue(player, { "NewItemFlags", category, itemId }, nil)
end

--[[
	Resetea TODO el perfil del jugador a los defaults del DataTemplate.
	Útil para comandos de testing como /clear.

	Devuelve true si pudo aplicar todos los SetValue (replicación al cliente).
	El save al DataStore es asíncrono — el autosave loop persiste el cambio en
	el siguiente ciclo (≤30s). Para forzar persistencia inmediata, llama a
	`profile:Save()` desde el caller (rara vez necesario).

	Por qué NO llamamos `profile:Save()` aquí:
	  ProfileStore's `:Save()` no expone éxito/fallo del DataStore write — el
	  pcall solo captura errores Lua, no rejects del backend. Confiar en su
	  retorno para limpiar el dirty flag puede ocultar saves que ProfileStore
	  reintentará silenciosamente. Mejor: marcamos dirty y dejamos que el loop
	  oficial maneje persistencia + retries.
]]
function DataService:ResetProfile(player: Player): boolean
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false
	end

	-- Pre-construir todas las secciones nuevas antes de aplicar ningún SetValue,
	-- para que un fallo intermedio no deje al cliente con perfil mixto.
	local newSections: { { section: string, value: any } } = {}
	for section, defaultSectionValue in DataTemplate do
		table.insert(newSections, { section = section, value = _deepCopy(defaultSectionValue) })
	end

	local allOk = true
	for _, entry in newSections do
		local ok, err = pcall(replica.SetValue, replica, { entry.section }, entry.value)
		if not ok then
			allOk = false
			warn(("[DataService] ResetProfile SetValue failed for user %d, section %s: %s"):format(player.UserId, tostring(entry.section), tostring(err)))
		end
	end

	-- Sea éxito o fallo parcial, marcamos dirty para que el autosave persista
	-- el estado actual (incluso si quedó mixto, queremos guardarlo para que
	-- el siguiente login refleje la realidad).
	_markDirty(player.UserId)

	return allOk
end

return DataService
