--!strict
--[[
	Perfiles con ProfileStore (session locking), replicados con ReplicaService.

	Toda mutación crea una nueva referencia de tabla en su sección: sin
	eso ReplicaService no detecta el cambio ni Fusion dispara observers en el cliente.
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

local DataTemplateModule = require(Shared.constants.DataTemplate)
local WeaponCategory = require(Shared.constants.WeaponCategory)
local DataTemplate = DataTemplateModule :: any
local LevelingConfig = require(Shared.constants.LevelingConfig)
local DataMigrations = require(script.Parent.DataMigrations)

export type PlayerProfile = DataTemplateModule.PlayerProfile

-- Shape mínima garantizada; los objetos reales tienen más métodos.
export type Profile = { Data: PlayerProfile }
export type Replica = { Data: PlayerProfile }

-- Signal SÍNCRONO para ProfileUnloading; ver `_newProfileSignal`.
export type ProfileConnection = {
	Disconnect: (self: ProfileConnection) -> (),
}

export type ProfileSignal = {
	Connect: (self: ProfileSignal, handler: (player: Player) -> ()) -> ProfileConnection,
	Fire: (self: ProfileSignal, player: Player) -> (),
}

-- Arma que recibe un wrap: la posesión de wraps es por arma (Inventory.WeaponWrapsByWeapon).
export type WrapTarget = { category: string, weaponId: string }

-- `value` o `delta`, no ambos.
export type BatchUpdateEntry = {
	path: { string },
	value: any?,
	delta: number?,
}

-- Los consumidores tipan `_dataService: DataServiceModule` en vez de `:: any`.
export type DataServiceModule = {
	Start: (self: DataServiceModule) -> (),
	GetProfile: (self: DataServiceModule, player: Player) -> Profile?,
	GetReplica: (self: DataServiceModule, player: Player) -> Replica?,
	SetValue: (self: DataServiceModule, player: Player, path: { string }, value: any) -> boolean,
	Increment: (self: DataServiceModule, player: Player, path: { string }, amount: number) -> (boolean, number),
	IncrementWeaponKills: (self: DataServiceModule, player: Player, weaponCategory: string, weaponId: string, amount: number?) -> (boolean, number),
	AddXP: (self: DataServiceModule, player: Player, amount: number, source: string?) -> (boolean, number, number, number),
	BatchUpdate: (self: DataServiceModule, player: Player, updates: { BatchUpdateEntry }) -> boolean,
	IsReceiptProcessed: (self: DataServiceModule, player: Player, purchaseId: string) -> boolean,
	MarkReceiptProcessed: (self: DataServiceModule, player: Player, purchaseId: string) -> boolean,
	GrantItem: (self: DataServiceModule, player: Player, category: string, itemId: string, source: string) -> boolean,
	GrantItemUpdates: (self: DataServiceModule, category: string, itemId: string, source: string) -> { BatchUpdateEntry },
	GrantWeaponWrapUpdates: (self: DataServiceModule, wrapId: string, targets: { WrapTarget }, source: string) -> { BatchUpdateEntry },
	ResetProfile: (self: DataServiceModule, player: Player) -> boolean,
	ForceSave: (self: DataServiceModule, player: Player) -> boolean,
	SaveAndConfirm: (self: DataServiceModule, player: Player, isPersisted: (lastSavedData: any) -> boolean, timeoutSeconds: number?) -> boolean,
	SaveReceipt: (self: DataServiceModule, player: Player, purchaseId: string) -> boolean,
	MessageProfile: (self: DataServiceModule, userId: number, message: any, timeoutSeconds: number?) -> boolean,
	ViewProfileAsync: (self: DataServiceModule, userId: number, timeoutSeconds: number?) -> (any, boolean),
	Destroy: (self: DataServiceModule) -> (),
	ProfileLoaded: RBXScriptSignal,
	ProfileUnloading: ProfileSignal,
	LeveledUp: RBXScriptSignal,
}

local AUTO_SAVE_INTERVAL_SECONDS = 30
local MAX_SAVES_PER_CYCLE = 8

-- Tope para Increment/delta: evita que un bug o exploit rompa la serialización o la UI.
local NUMERIC_CAP = 1e12

-- Topes contra bucles infinitos en AddXP si LevelingConfig degenera.
local MAX_LEVEL = 1000

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

-- Cambiar la key ABANDONA el datastore anterior: todos los perfiles arrancan de cero.
local _PlayerStore = ProfileStore.New("PlayerData_v2", DataTemplate)

local _ProfileToken = ReplicaService.NewClassToken("PlayerProfile")

-- Indexadas por UserId.
local _profiles: { [number]: any } = {}
local _replicas:  { [number]: any } = {}
local _janitors:  { [number]: any } = {}
-- userId → os.clock() de la primera marca desde el último guardado.
local _dirtyProfiles: { [number]: number } = {}
-- Para acumular TimePlayedSeconds también en BindToClose.
local _sessionStartByUserId: { [number]: number } = {}
local _loadTokens: { [number]: number } = {}
local _started = false
local _serviceJanitor: any = nil
local _serviceGeneration = 0

-- Diferido a propósito: sus handlers pueden yieldear, el perfil sigue cargado.
local _profileLoadedBindable = Instance.new("BindableEvent")

-- Signal y no llamada directa a TelemetryService: este no puede requerirlo
-- (TelemetryService ya requiere este módulo). Diferido: fuera de la ruta de escritura.
local _leveledUpBindable = Instance.new("BindableEvent")

--[[
	Signal que ejecuta sus handlers EN EL ACTO. No es BindableEvent porque con
	SignalBehavior = Deferred los handlers correrían DESPUÉS de EndSession y de
	`_profiles[userId] = nil`, y GetProfile devolvería nil en silencio.

	Contrato: los handlers corren inline justo antes de EndSession y NO deben
	yieldear (retrasan el guardado); para trabajo con yield, snapshot síncrono y
	task.spawn. Cada handler va en pcall para no tumbar el guardado.
]]
local function _newProfileSignal(signalName: string): ProfileSignal
	local handlers: { [number]: (player: Player) -> () } = {}
	local nextHandlerId = 0

	return {
		Connect = function(_self, handler): ProfileConnection
			nextHandlerId += 1
			local id = nextHandlerId
			handlers[id] = handler
			return {
				Disconnect = function(_selfConnection)
					handlers[id] = nil
				end,
			}
		end,

		Fire = function(_self, player)
			-- Snapshot: un handler puede (des)conectar durante el Fire.
			local snapshot: { (player: Player) -> () } = {}
			for _, handler in handlers do
				table.insert(snapshot, handler)
			end
			for _, handler in snapshot do
				local ok, err = pcall(handler, player)
				if not ok then
					warn(("[DataService] Handler de %s falló: %s"):format(signalName, tostring(err)))
				end
			end
		end,
	}
end

local _profileUnloadingSignal = _newProfileSignal("ProfileUnloading")

--[[
	Crea nuevas referencias en cada nivel de path[depth..#path].
	_immutableUpdate(profile.Data.Inventory, {"Inventory","Main","Weapon2"}, 2, true)
	→ nuevo Inventory con Main.Weapon2 = true
]]
local MAX_PATH_DEPTH = 32

-- Copia superficial: la nueva referencia es lo que ReplicaService y Fusion usan para detectar cambios.
local function _setKey(tbl: { [string]: any }, key: string, value: any): { [string]: any }
	local copy = table.clone(tbl)
	copy[key] = value
	return copy
end

local function _immutableUpdate(tbl: { [string]: any }, path: { string }, depth: number, value: any): { [string]: any }
	if depth > MAX_PATH_DEPTH then
		error(("[DataService] _immutableUpdate path depth excede %d (probable bug)"):format(MAX_PATH_DEPTH))
	end
	local key = path[depth]
	if depth == #path then
		return _setKey(tbl, key, value)
	else
		local child: { [string]: any } = tbl[key] or {}
		local newChild = _immutableUpdate(child, path, depth + 1, value)
		return _setKey(tbl, key, newChild)
	end
end

--[[
	Ledgers de idempotencia (ProcessedReceipts, GiftDeliveries, ClaimedGifts). Roblox no
	caduca los receipts sin resolver: podar por edad dejaría conceder dos veces una compra
	que se resuelve tarde. Solo se recortan por número, las marcas más antiguas primero.
]]
local MAX_LEDGER_ENTRIES = 1000

local function _capLedger(ledger: { [string]: any }, stampOf: (entry: any) -> any)
	local keys: { string } = {}
	for key in ledger do
		table.insert(keys, key)
	end
	if #keys <= MAX_LEDGER_ENTRIES then
		return
	end
	local function stamp(key: string): number
		local value = stampOf(ledger[key])
		return if type(value) == "number" then value else 0
	end
	table.sort(keys, function(a, b)
		return stamp(a) < stamp(b)
	end)
	for i = 1, #keys - MAX_LEDGER_ENTRIES do
		ledger[keys[i]] = nil
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

local DataService = {}
DataService.__index = DataService

--   ProfileLoaded(player)    — tras crear la Replica.
--   ProfileUnloading(player) — ANTES de destruir la Replica y cerrar sesión; el
--                              perfil aún es modificable. SÍNCRONO, no yieldear.
DataService.ProfileLoaded = _profileLoadedBindable.Event
DataService.ProfileUnloading = _profileUnloadingSignal
--   LeveledUp(player, from, to, xpGained, source?) — subidas ya persistidas.
DataService.LeveledUp = _leveledUpBindable.Event

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
	if _dirtyProfiles[userId] == nil then
		_dirtyProfiles[userId] = os.clock()
	end
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

		-- Los más antiguos primero: el orden de iteración del hash no rota, y con más de
		-- MAX_SAVES_PER_CYCLE jugadores activos siempre saldrían los mismos.
		local toSave: { number } = {}
		for userId in _dirtyProfiles do
			table.insert(toSave, userId)
		end
		table.sort(toSave, function(a, b)
			return _dirtyProfiles[a] < _dirtyProfiles[b]
		end)

		-- Profile:Save() no yieldea: lanza el write en segundo plano. Se limpia antes
		-- para que lo que cambie a partir de aquí vuelva a marcar el perfil.
		for i = 1, math.min(#toSave, MAX_SAVES_PER_CYCLE) do
			local userId = toSave[i]
			_dirtyProfiles[userId] = nil
			local profile = _profiles[userId]
			if profile ~= nil and profile:IsActive() then
				local ok, err = pcall(function()
					profile:Save()
				end)
				if not ok then
					warn(("[DataService] Autosave falló para user %d: %s"):format(userId, tostring(err)))
				end
			end
		end
	end
end

-- ProfileStore devuelve nil con el DataStore inaccesible: backoff exponencial y,
-- agotados los reintentos, se rechaza para kickear al jugador.
local function _loadWithRetry(player: Player, attempt: number): any
	return Promise.new(function(resolve: (any) -> (), reject: (any) -> ())
		local profile = _PlayerStore:StartSessionAsync(
			"Player_" .. player.UserId,
			{
				Cancel = function()
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
			return Promise.delay(2 ^ attempt):andThen(function()
				return _loadWithRetry(player, attempt + 1)
			end)
		end
		return Promise.reject(err)
	end)
end

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

			profile:Reconcile()

			-- Reconcile cubre lo aditivo; las migraciones (forward-only), renames y derivados.
			DataMigrations.migrate(profile.Data)

			-- ⚠ Hasta crear la Replica se puede mutar `profile.Data` in-place. Después comparte
			-- referencia con replica.Data y toda mutación DEBE ir por SetValue/BatchUpdate.

			local data = profile.Data :: any
			local function stampOfValue(value: any): any
				return value
			end
			for _, ledgerName in { "ProcessedReceipts", "ClaimedGifts" } do
				if type(data[ledgerName]) == "table" then
					_capLedger(data[ledgerName], stampOfValue)
				else
					data[ledgerName] = {}
				end
			end
			if type(data.GiftDeliveries) == "table" then
				_capLedger(data.GiftDeliveries, function(delivery: any): any
					return if type(delivery) == "table" then delivery.At else nil
				end)
			else
				data.GiftDeliveries = {}
			end

			-- GDPR.
			profile:AddUserId(player.UserId)

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
			-- En paralelo para no bloquear el load; llega tras la Replica, así que va por SetValue.
			if meta.Country == "" then
				task.spawn(function()
					local ok, code = pcall(function()
						return LocalizationService:GetCountryRegionForPlayerAsync(player)
					end)
					if not ok or type(code) ~= "string" or code == "" then
						return
					end
					local stillLoaded = _profiles[player.UserId]
					if stillLoaded == profile then
						DataService:SetValue(player, { "Metadata", "Country" }, code)
					end
				end)
			end

			-- LoginStreak por día UTC, independiente de la zona horaria del servidor.
			local todayKey = os.date("!%Y-%m-%d", now) :: string
			local streak = profile.Data.LoginStreak
			if streak.LastLoginDateKey ~= todayKey then
				local newCurrent: number? = nil
				if streak.LastLoginDateKey == "" then
					newCurrent = 1
				else
					-- Key corrupta: no resetear ni avanzar, borraría progreso del jugador.
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
							newCurrent = 1
						elseif dayDelta == 0 then
							newCurrent = streak.Current or 1
						else
							-- Fecha futura: reloj desincronizado o key manipulada.
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

			local replica = ReplicaService.NewReplica({
				ClassToken  = _ProfileToken,
				Tags        = { Player = player },
				Data        = profile.Data,
				Replication = player,
			})

			local janitor = Janitor.new()

			_profiles[userId] = profile
			_replicas[userId] = replica
			_janitors[userId] = janitor
			_markDirty(userId)

			-- Otro servidor tomó la sesión: kick para evitar estado corrupto. En el cierre del
			-- servidor también se dispara (EndSession de BindToClose) y no es ese caso.
			local connection = profile.OnSessionEnd:Connect(function()
				if ProfileStore.IsClosing or not _started or player.Parent ~= Players then
					return
				end
				player:Kick(
					"Tu sesión de datos fue terminada externamente. "
						.. "Por favor, vuelve a conectarte."
				)
			end)
			janitor:Add(connection, "Disconnect")

			-- Orden de limpieza importante: TimePlayedSeconds → ProfileUnloading (perfil aún
			-- vivo) → destruir Replica → EndSession (guarda y libera el lock).
			local sessionStart = os.time()
			_sessionStartByUserId[userId] = sessionStart
			janitor:Add(function()
				local sessionSeconds = math.max(0, os.time() - sessionStart)
				if sessionSeconds > 0 then
					DataService:Increment(player, { "Stats", "TimePlayedSeconds" }, sessionSeconds)
				end

				_profileUnloadingSignal:Fire(player)

				replica:Destroy()
				profile:EndSession()
				_dirtyProfiles[userId] = nil
				_profiles[userId] = nil
				_replicas[userId] = nil
				_janitors[userId] = nil
				_sessionStartByUserId[userId] = nil
				if _loadTokens[userId] == loadToken then
					_loadTokens[userId] = nil
				end
			end, true)

			-- Tras poblar las tablas: los handlers pueden llamar a GetProfile de inmediato.
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
		-- ~30s antes de matar el servidor: destruir los janitors haría los EndSession en
		-- serie y podría perder writes. Se hacen en paralelo con deadline.
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
				-- Mismo flujo que _unloadPlayer (TimePlayedSeconds + ProfileUnloading).
				local sessionStart = _sessionStartByUserId[userId]
				if sessionStart then
					local sessionSeconds = math.max(0, os.time() - sessionStart)
					if sessionSeconds > 0 then
						pcall(function()
							local player = Players:GetPlayerByUserId(userId)
							if player then
								DataService:Increment(player, { "Stats", "TimePlayedSeconds" }, sessionSeconds)
							end
						end)
					end
					_sessionStartByUserId[userId] = nil
				end
				pcall(function()
					local player = Players:GetPlayerByUserId(userId)
					if player then
						_profileUnloadingSignal:Fire(player)
					end
				end)
				pcall(function()
					profile:EndSession()
				end)
				_dirtyProfiles[userId] = nil
				pending -= 1
			end)
		end

		-- Deadline por debajo de los ~30s de Roblox.
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end

		if pending > 0 then
			warn(("[DataService] BindToClose: %d perfiles no terminaron a tiempo"):format(pending))
		end
	end)

	-- Jugadores que ya estaban antes de Start (Studio).
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

function DataService:GetProfile(player: Player): any
	return _profiles[player.UserId]
end

function DataService:GetReplica(player: Player): any
	return _replicas[player.UserId]
end

--[[
	path: {"Stats", "Cash"}, {"Inventory", "Main", "Weapon2"}… Crea una nueva
	referencia en path[1], que dispara ListenToChange({"<section>"}) en el cliente.
]]
function DataService:SetValue(player: Player, path: { string }, value: any): boolean
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false
	end

	if type(path) ~= "table" or #path == 0 or type(path[1]) ~= "string" then
		warn(("[DataService] SetValue: path inválido para user %d"):format(player.UserId))
		return false
	end

	if type(value) == "number" then
		value = _clampNumeric(value)
	end

	local section = path[1]
	local newSection = _immutableUpdate(profile.Data[section] :: { [string]: any }, path, 2, value)

	-- replica.Data ES profile.Data: esto actualiza también el perfil.
	local ok, err = pcall(replica.SetValue, replica, { section }, newSection)
	if not ok then
		warn(("[DataService] replica:SetValue failed for user %d, section %s: %s"):format(player.UserId, tostring(section), tostring(err)))
		return false
	end
	_markDirty(player.UserId)

	return true
end

-- Clamp a [0, NUMERIC_CAP].
function DataService:Increment(player: Player, path: { string }, amount: number): (boolean, number)
	local profile = _profiles[player.UserId]
	if not profile then
		return false, 0
	end

	local pointer: any = profile.Data
	for i = 1, #path - 1 do
		if type(pointer) ~= "table" then
			return false, 0
		end
		pointer = pointer[path[i]]
	end
	if type(pointer) ~= "table" then
		return false, 0
	end
	local current: number = pointer[path[#path]] or 0
	if type(amount) ~= "number" or amount ~= amount then
		return false, current
	end
	local newValue = _clampNumeric(current + amount)

	local ok = self:SetValue(player, path, newValue)
	return ok, newValue
end

function DataService:IncrementWeaponKills(player: Player, weaponCategory: string, weaponId: string, amount: number?): (boolean, number)
	if not WeaponCategory.isValid(weaponCategory) then
		return false, 0
	end
	if type(weaponId) ~= "string" or weaponId == "" then
		return false, 0
	end
	local delta = math.max(0, math.floor(amount or 1))
	if delta <= 0 then
		return false, 0
	end
	return self:Increment(player, { "WeaponKills", weaponCategory, weaponId }, delta)
end

function DataService:AddXP(player: Player, amount: number, source: string?): (boolean, number, number, number)
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
	local startingLevel = level
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

	-- Solo después de persistir.
	if level > startingLevel then
		_leveledUpBindable:Fire(player, startingLevel, level, math.floor(amount), source)
	end

	return true, level, xp, xpToNext
end

--[[
	Un mensaje de red por sección modificada. `delta` se resuelve contra la sección
	acumulada al aplicar (sin TOCTOU con la lectura del caller) y se clampa a ≥ 0.
	{ { path = {"Stats", "Cash"}, delta = -100 }, { path = {"Inventory", "Main", "Weapon2"}, value = true } }
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

	local accumulated: { [string]: { [string]: any } } = {}

	for i, update in updates do
		local path = update.path
		if type(path) ~= "table" or #path == 0 or type(path[1]) ~= "string" then
			warn(("[DataService] BatchUpdate update[%d]: path inválido"):format(i))
			continue
		end

		-- Sin esto, value=nil borraría el campo del schema y replicaría el delete.
		if update.delta == nil and update.value == nil then
			warn(("[DataService] BatchUpdate update[%d]: falta value/delta"):format(i))
			continue
		end

		local section = path[1]
		local base: { [string]: any } = accumulated[section] or (profile.Data[section] :: { [string]: any })

		local newValue: any
		if update.delta ~= nil then
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
			if type(newValue) == "number" then
				newValue = _clampNumeric(newValue)
			end
		end

		accumulated[section] = _immutableUpdate(base, path, 2, newValue)
	end

	-- Atomicidad best-effort: al primer fallo, rollback de las secciones ya escritas
	-- (una compra no debe quedar con Cash descontado y sin ítem). El propio rollback
	-- podría fallar.
	local prevSections: { [string]: any } = {}
	for section in accumulated do
		prevSections[section] = profile.Data[section]
	end

	local applied: { string } = {}
	local allOk = true
	local failedSection: string? = nil
	local failedErr: any = nil
	for section, newSection in accumulated do
		local ok, err = pcall(replica.SetValue, replica, { section }, newSection)
		if ok then
			table.insert(applied, section)
		else
			allOk = false
			failedSection = section
			failedErr = err
			break
		end
	end

	if not allOk then
		warn(("[DataService] BatchUpdate SetValue failed for user %d, section %s: %s — rollback de %d sección(es)"):format(
			player.UserId, tostring(failedSection), tostring(failedErr), #applied))
		for _, section in applied do
			local rbOk, rbErr = pcall(replica.SetValue, replica, { section }, prevSections[section])
			if not rbOk then
				warn(("[DataService] BatchUpdate rollback falló para user %d, section %s: %s (perfil posiblemente mixto)"):format(
					player.UserId, tostring(section), tostring(rbErr)))
			end
		end
	end

	_markDirty(player.UserId)

	return allOk
end

--[[
	Idempotencia de ProcessReceipt: Roblox puede reinvocarlo con el mismo PurchaseId.
	Si IsReceiptProcessed → PurchaseGranted sin conceder; si no, conceder y MarkReceiptProcessed.
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

-- Entries de GrantItem, para componerlas en el mismo BatchUpdate que otra escritura
-- (p. ej. marcar un tier reclamado): así el grant y su marca no pueden quedar a medias.
-- source: etiqueta para analytics ("Shop", "Reward", "Default", "Code", "Gift"…).
function DataService:GrantItemUpdates(category: string, itemId: string, source: string): { BatchUpdateEntry }
	local effectiveSource = if type(source) == "string" and source ~= "" then source else "Unknown"
	return {
		{ path = { "Inventory", category, itemId }, value = true },
		{ path = { "InventoryMeta", category, itemId }, value = {
			AcquiredAt = os.time(),
			Source = effectiveSource,
		} },
	}
end

-- Único escritor de wraps concedidos (tienda, pase, maestría): posesión en cada arma
-- de `targets` más metadatos, que son por wrap.
function DataService:GrantWeaponWrapUpdates(wrapId: string, targets: { WrapTarget }, source: string): { BatchUpdateEntry }
	local updates: { BatchUpdateEntry } = {}
	for _, target in targets do
		table.insert(updates, {
			path = { "Inventory", "WeaponWrapsByWeapon", target.category, target.weaponId, wrapId },
			value = true,
		})
	end
	table.insert(updates, { path = { "InventoryMeta", "WeaponWraps", wrapId }, value = {
		AcquiredAt = os.time(),
		Source = if type(source) == "string" and source ~= "" then source else "Unknown",
	} })
	return updates
end

function DataService:GrantItem(player: Player, category: string, itemId: string, source: string): boolean
	if type(category) ~= "string" or category == "" then
		return false
	end
	if type(itemId) ~= "string" or itemId == "" then
		return false
	end
	return self:BatchUpdate(player, self:GrantItemUpdates(category, itemId, source))
end

--[[
	Para comandos de testing (/clear). No guarda en el acto: lo persiste el autosave.
	Ojo: ProfileStore :Save() no expone el éxito del write al backend (el pcall solo
	captura errores Lua).
]]
function DataService:ResetProfile(player: Player): boolean
	local profile = _profiles[player.UserId]
	local replica = _replicas[player.UserId]
	if not profile or not replica then
		return false
	end

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

	-- Dirty incluso con fallo parcial: el siguiente login debe reflejar la realidad.
	_markDirty(player.UserId)

	return allOk
end

-- Pide un Save sin esperarlo: `Profile:Save()` no yieldea ni expone si el write llegó
-- al DataStore. Para ProcessReceipt usar SaveReceipt.
function DataService:ForceSave(player: Player): boolean
	local profile = _profiles[player.UserId]
	if not profile or not profile:IsActive() then
		return false
	end

	local ok, err = pcall(function()
		profile:Save()
	end)
	if not ok then
		warn(("[DataService] ForceSave falló para user %d: %s"):format(player.UserId, tostring(err)))
		return false
	end

	-- Dirty sin limpiar a propósito: el autosave es una segunda red de seguridad.
	return true
end

local SAVE_CONFIRM_TIMEOUT = 15

--[[
	Guarda y espera a que el DataStore confirme que `isPersisted(LastSavedData)` se cumple.
	Un Save que no es de fin de sesión NO se reintenta si falla, así que solo cuenta lo
	que llega en OnAfterSave; se mira el dato y no la señal porque puede llegar antes el
	de un Save que ya estaba en vuelo sin nuestros cambios. Si el jugador sale mientras
	espera, el EndSession (que sí reintenta) también dispara OnAfterSave.
]]
function DataService:SaveAndConfirm(player: Player, isPersisted: (lastSavedData: any) -> boolean, timeoutSeconds: number?): boolean
	local profile = _profiles[player.UserId]
	if not profile then
		return false
	end

	local function check(lastSaved: any): boolean
		if type(lastSaved) ~= "table" then
			return false
		end
		local ok, result = pcall(isPersisted, lastSaved)
		return ok and result == true
	end

	if check(profile.LastSavedData) then
		return true
	end
	if not profile:IsActive() then
		return false
	end

	local confirmed = false
	local conn = profile.OnAfterSave:Connect(function(lastSaved: any)
		if check(lastSaved) then
			confirmed = true
		end
	end)

	local ok, err = pcall(function()
		profile:Save()
	end)
	if not ok then
		conn:Disconnect()
		warn(("[DataService] SaveAndConfirm: Save falló para user %d: %s"):format(player.UserId, tostring(err)))
		return false
	end

	local deadline = os.clock() + (timeoutSeconds or SAVE_CONFIRM_TIMEOUT)
	while not confirmed and os.clock() < deadline do
		task.wait()
	end
	conn:Disconnect()

	if not confirmed then
		warn(("[DataService] SaveAndConfirm: sin confirmación del DataStore para user %d"):format(player.UserId))
	end
	return confirmed
end

--[[
	Durabilidad de ProcessReceipt: Roblox da el receipt por CONSUMIDO al devolver
	PurchaseGranted. Patrón: conceder + ProcessedReceipts[purchaseId] → SaveReceipt →
	PurchaseGranted solo si devolvió true; si no, NotProcessedYet (la idempotencia por
	ProcessedReceipts evita el doble grant en la reentrega).
]]
function DataService:SaveReceipt(player: Player, purchaseId: string): boolean
	return self:SaveAndConfirm(player, function(lastSaved: any): boolean
		local processed = lastSaved.ProcessedReceipts
		return type(processed) == "table" and processed[purchaseId] ~= nil
	end)
end

--[[
	ProfileStore (MessageAsync/GetAsync) reintenta INDEFINIDAMENTE si el DataStore
	falla; un caller como ProcessReceipt no puede colgarse.
	Con finished=false el thread sigue vivo y puede completar tarde: las operaciones
	que pasan por aquí deben ser idempotentes.
]]
local function _runBounded(timeoutSeconds: number, fn: () -> any): (boolean, boolean, any)
	local finished = false
	local ok = false
	local result: any = nil
	task.spawn(function()
		local callOk, callResult = pcall(fn)
		ok = callOk
		result = callResult
		finished = true
	end)
	local deadline = os.clock() + timeoutSeconds
	while not finished and os.clock() < deadline do
		task.wait()
	end
	return finished, ok, result
end

--[[
	Para usuarios offline o en otro servidor. Lo consume el MessageHandler que el
	servicio interesado registre en ProfileLoaded. Un false por timeout puede entregar
	tarde: el consumidor debe deduplicar (los regalos, por PurchaseId + ClaimedGifts).
]]
function DataService:MessageProfile(userId: number, message: any, timeoutSeconds: number?): boolean
	local finished, ok, result = _runBounded(timeoutSeconds or 10, function()
		return _PlayerStore:MessageAsync("Player_" .. userId, message)
	end)
	if not finished then
		warn(("[DataService] MessageProfile: timeout para user %d (DataStore lento/caído)"):format(userId))
		return false
	end
	if not ok then
		warn(("[DataService] MessageProfile falló para user %d: %s"):format(userId, tostring(result)))
		return false
	end
	return result == true
end

--[[
	READ-ONLY, para usuarios sin sesión en este servidor. apiOk=false = timeout o error.
	Una key inexistente devuelve nil (también con ProfileStore cerrando); una key con solo
	messages (MessageAsync) devuelve una vista con SessionLoadCount == 0.
]]
function DataService:ViewProfileAsync(userId: number, timeoutSeconds: number?): (any, boolean)
	local finished, ok, view = _runBounded(timeoutSeconds or 10, function()
		return _PlayerStore:GetAsync("Player_" .. userId)
	end)
	if not finished then
		warn(("[DataService] ViewProfileAsync: timeout para user %d (DataStore lento/caído)"):format(userId))
		return nil, false
	end
	if not ok then
		warn(("[DataService] ViewProfileAsync falló para user %d: %s"):format(userId, tostring(view)))
		return nil, false
	end
	return view, true
end

return DataService
