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
local LevelingConfig = require(Shared.constants.LevelingConfig)
type PlayerProfile = typeof(DataTemplate)

local AUTO_SAVE_INTERVAL_SECONDS = 30
local MAX_SAVES_PER_CYCLE = 8

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
local _dirtyProfiles: { [number]: boolean } = {}
local _loadTokens: { [number]: number } = {}
local _started = false
local _serviceJanitor: any = nil
local _serviceGeneration = 0

-- ────────────────────────────────────────────────────────────
-- HELPERS DE MUTACIÓN INMUTABLE
-- ────────────────────────────────────────────────────────────

--[[
	Actualiza de forma inmutable una sub-tabla en profundidad arbitraria.
	Recorre path desde depth hasta #path creando nuevas referencias en cada nivel.

	Ejemplo:
	  _immutableUpdate(profile.Data.Inventory, {"Inventory","Main","Weapon2"}, 2, true)
	  →  nuevo Inventory con Inventory.Main.Weapon2 = true
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

		local savedThisCycle = 0
		for userId in _dirtyProfiles do
			if not _isGenerationActive(generation) then
				return
			end

			local profile = _profiles[userId]
			local canSave = profile ~= nil and profile:IsActive()
			local clearedDirty: boolean
			if canSave then
				clearedDirty = pcall(function()
					profile:Save()
				end)
			else
				clearedDirty = true
			end

			if clearedDirty then
				_dirtyProfiles[userId] = nil
				savedThisCycle += 1
			end

			if savedThisCycle >= MAX_SAVES_PER_CYCLE then
				break
			end
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

			-- Migración legacy: separa inventario/loadout de Weapons a Main y Special.
			local inventory = profile.Data.Inventory
			if type(inventory.Main) ~= "table" then
				inventory.Main = {}
			end

			if type(inventory.Special) ~= "table" then
				inventory.Special = {}
			end

			local legacyWeapons = inventory.Weapons
			if type(legacyWeapons) == "table" then
				for itemId, owned in legacyWeapons do
					if owned == true then
						inventory.Main[itemId] = true
						inventory.Special[itemId] = true
					end
				end
			end

			if inventory.Main.Default ~= true then
				inventory.Main.Default = true
			end

			if inventory.Special.Default ~= true then
				inventory.Special.Default = true
			end

			if type(inventory.WeaponSkins) ~= "table" then
				inventory.WeaponSkins = { Default = true }
			end

			if type(inventory.WeaponSkinsByWeapon) ~= "table" then
				inventory.WeaponSkinsByWeapon = {}
			end

			local wrapsOwnership = inventory.WeaponSkinsByWeapon
			if type(wrapsOwnership.Main) ~= "table" then
				wrapsOwnership.Main = {}
			end

			if type(wrapsOwnership.Special) ~= "table" then
				wrapsOwnership.Special = {}
			end

			local legacyOwnedSkins = {} :: { [string]: boolean }
			for skinId, owned in inventory.WeaponSkins do
				if owned == true then
					legacyOwnedSkins[skinId] = true
				end
			end

			legacyOwnedSkins.Default = true

			local function ensureWrapOwnership(categoryKey: string, weaponId: string)
				local categoryOwnership = wrapsOwnership[categoryKey]
				if type(categoryOwnership) ~= "table" then
					categoryOwnership = {}
					wrapsOwnership[categoryKey] = categoryOwnership
				end

				local weaponOwnership = categoryOwnership[weaponId]
				local createdWeaponOwnership = false
				if type(weaponOwnership) ~= "table" then
					weaponOwnership = {}
					categoryOwnership[weaponId] = weaponOwnership
					createdWeaponOwnership = true
				end

				if createdWeaponOwnership then
					for skinId, owned in legacyOwnedSkins do
						if owned == true and weaponOwnership[skinId] ~= true then
							weaponOwnership[skinId] = true
						end
					end
				end
			end

			for weaponId, owned in inventory.Main do
				if owned == true then
					ensureWrapOwnership("Main", tostring(weaponId))
				end
			end

			for weaponId, owned in inventory.Special do
				if owned == true then
					ensureWrapOwnership("Special", tostring(weaponId))
				end
			end

			local loadout = profile.Data.Loadout
			if (type(loadout.MainWeapon) ~= "string" or loadout.MainWeapon == "")
				and type(loadout.PrimaryWeapon) == "string"
				and loadout.PrimaryWeapon ~= ""
			then
				loadout.MainWeapon = loadout.PrimaryWeapon
			end

			if type(loadout.SpecialWeapon) ~= "string" or loadout.SpecialWeapon == "" then
				loadout.SpecialWeapon = "Default"
			end

			if type(loadout.MainWeaponWraps) ~= "table" then
				loadout.MainWeaponWraps = {}
			end

			if type(loadout.SpecialWeaponWraps) ~= "table" then
				loadout.SpecialWeaponWraps = {}
			end

			local legacySkin = if type(loadout.ActiveSkin) == "string" and loadout.ActiveSkin ~= "" then loadout.ActiveSkin else "Default"

			local mainWeaponKey = if type(loadout.MainWeapon) == "string" and loadout.MainWeapon ~= "" then loadout.MainWeapon else "Default"
			local specialWeaponKey = if type(loadout.SpecialWeapon) == "string" and loadout.SpecialWeapon ~= "" then loadout.SpecialWeapon else "Default"

			local mainWraps = loadout.MainWeaponWraps :: { [string]: string }
			local specialWraps = loadout.SpecialWeaponWraps :: { [string]: string }

			if type(mainWraps.Default) ~= "string" or mainWraps.Default == "" then
				mainWraps.Default = "Default"
			end

			if type(specialWraps.Default) ~= "string" or specialWraps.Default == "" then
				specialWraps.Default = "Default"
			end

			if type(mainWraps[mainWeaponKey]) ~= "string" or mainWraps[mainWeaponKey] == "" then
				mainWraps[mainWeaponKey] = legacySkin
			end

			if type(specialWraps[specialWeaponKey]) ~= "string" or specialWraps[specialWeaponKey] == "" then
				specialWraps[specialWeaponKey] = legacySkin
			end

			-- GDPR: asociar UserId para cumplimiento de políticas de privacidad.
			profile:AddUserId(player.UserId)

			-- Metadata se actualiza antes de crear la Replica para no romper el
			-- contrato de inmutabilidad del estado ya replicado.
			local now = os.time()
			profile.Data.Metadata.LastSeen = now
			if profile.Data.Metadata.CreatedAt == 0 then
				profile.Data.Metadata.CreatedAt = now
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
			-- 1. Destruir Replica (desreplica al cliente)
			-- 2. Finalizar sesión de ProfileStore (guarda y libera lock)
			janitor:Add(function()
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
		local janitor = _serviceJanitor
		if janitor then
			janitor:Destroy()
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

	local section = path[1]
	-- _immutableUpdate construye una nueva tabla desde depth=2 hasta el leaf.
	local newSection = _immutableUpdate(profile.Data[section] :: { [string]: any }, path, 2, value)

	-- SetValue({section}, newSection) en ReplicaService:
	--   1. Establece replica.Data[section] = newSection  (nueva referencia)
	--   2. Envía el cambio al cliente vía RemoteEvent
	-- Como replica.Data ES profile.Data (mismo reference), profile.Data[section]
	-- también queda actualizado.
	replica:SetValue({ section }, newSection)
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
	local newValue = math.max(0, current + amount)

	local ok = self:SetValue(player, path, newValue)
	return ok, newValue
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

	while xp >= xpToNext do
		xp -= xpToNext
		level += 1
		xpToNext = math.max(1, LevelingConfig.GetXPToNextLevel(level))
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

	updates  {{ path: {string}, value: any }}

	Algoritmo:
	  1. Por cada update, acumula los cambios en un mapa de secciones.
	  2. Cada sección acumulada es inmutable (Sift merge en cadena).
	  3. Al final, un solo SetValue por sección.

	Ejemplo (comprar un arma):
	  {
	    { path = {"Stats",     "Cash"},              value = 0    },
	    { path = {"Inventory", "Main", "Weapon2"}, value = true },
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
	_markDirty(player.UserId)

	return true
end

--[[
	Resetea TODO el perfil del jugador a los defaults del DataTemplate.
	Útil para comandos de testing como /clear.

	Devuelve true si pudo resetear y guardar, false si el perfil no está cargado
	o el save falla.
]]
function DataService:ResetProfile(player: Player): boolean
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false
	end

	for section, defaultSectionValue in DataTemplate do
		replica:SetValue({ section }, _deepCopy(defaultSectionValue))
	end

	local saved = pcall(function()
		profile:Save()
	end)

	if saved then
		_dirtyProfiles[player.UserId] = nil
	else
		_markDirty(player.UserId)
	end

	return saved
end

return DataService
