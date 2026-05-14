--!strict
--[[
	DataController.luau  (Client)
	Puente entre ReplicaService y el sistema de UI reactivo (Fusion 0.3).

	Responsabilidades:
	  1. Pedir datos al servidor con ReplicaController.RequestData().
	  2. Al recibir la Replica "PlayerProfile", sembrar los Fusion Values con
	     los datos iniciales y suscribir listeners de cambio por sección.
	  3. Exponer Values de Fusion para que los componentes de UI los observen.
	  4. Exponer WhenReady() como una Promise que otros sistemas pueden awaitar.
	  5. Gestionar el ciclo de vida del scope de Fusion con Janitor.

	Patrón Fusion 0.3 (scoped):
	  - Todos los objetos Fusion se crean dentro de un scope.
	  - Al limpiar el Janitor, Fusion.doCleanup(scope) destruye todos los objetos.
	  - Evita memory leaks si el sistema se reinicia (e.g. en UI-Labs).

	Por qué un Value por sección y no por campo:
	  - ReplicaService propaga deltas a nivel de sección (SetValue({"Stats"}, newTable)).
	  - Fusion actualiza sólo los Computed que dependen de la sección afectada.
	  - Trade-off aceptable: Stats tiene ~9 campos; actualizar el Value de Stats al
	    cambiar Kills es barato comparado con 9 Values individuales.

	Uso en UI:
	  local stats = DataController.Stats   -- Fusion.Value<Stats>
	  local textLabel = scope:New "TextLabel" {
	      Text = scope:Computed(function(use)
	          return "Kills: " .. tostring(use(stats).Kills)
	      end),
	  }

	  -- Esperar datos antes de construir UI:
	  DataController:WhenReady():andThen(function()
	      -- Aquí ya hay datos válidos en los Values
	  end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared   = ReplicatedStorage:WaitForChild("Shared")

local ReplicaController = require(Packages.replicaservice) :: any
local Fusion            = require(Packages.fusion)         :: any
local Janitor           = require(Packages.janitor)        :: any
local Promise           = require(Packages["typed-promise"]) :: any

local DataTemplate = require(Shared.constants.DataTemplate) :: any

-- Deep-copy local: el template está `table.freeze`d. Si sembramos un Value de
-- Fusion con la referencia directa, cualquier mutación accidental por algún
-- componente lanza error en runtime. Sembramos copias para aislar.
local function _deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, nested in value do
		copy[key] = _deepCopy(nested)
	end
	return copy
end

-- ────────────────────────────────────────────────────────────
-- ESTADO PRIVADO
-- ────────────────────────────────────────────────────────────

local _janitor: any = nil
local _scope: any = nil
local _replica: any = nil
local _started = false

-- Promise que se resuelve cuando llega la primera Replica.
-- Otros controladores pueden hacer: DataController:WhenReady():andThen(fn)
local _readyPromise:  any = nil
local _readyResolve:  ((any) -> ())? = nil

-- ────────────────────────────────────────────────────────────
-- VALORES REACTIVOS (expuestos como API pública)
-- Inicializados a los defaults del template para que la UI
-- nunca reciba nil aunque los datos aún no hayan llegado.
-- ────────────────────────────────────────────────────────────

-- Se definen como `any` porque el scope se crea en Start().
-- El tipo real es Fusion.Value<T>; los consumidores pueden castear si lo desean.
local DataController = {}

DataController.Stats         = nil :: any
DataController.Inventory     = nil :: any
DataController.InventoryMeta = nil :: any
DataController.Loadout       = nil :: any
DataController.WeaponKills   = nil :: any
DataController.Settings      = nil :: any
DataController.Rewards       = nil :: any
DataController.Cases         = nil :: any
DataController.LoginStreak   = nil :: any
DataController.NewItemFlags  = nil :: any
DataController.DailyTasks    = nil :: any
DataController.BattlePass    = nil :: any
DataController.Metadata      = nil :: any

-- ────────────────────────────────────────────────────────────
-- API PÚBLICA
-- ────────────────────────────────────────────────────────────

--[[
	Inicia el controlador:
	  1. Crea el scope de Fusion e inicializa los Values con los defaults.
	  2. Crea la Promise de ready.
	  3. Llama a RequestData() para que el servidor empiece a replicar.
	  4. Registra el handler de ReplicaOfClassCreated.
]]
function DataController:Start(): ()
	if _started then
		return
	end

	_started = true
	_janitor = Janitor.new()

	-- Crear scope de Fusion con todos los constructores disponibles
	_scope = Fusion.scoped(Fusion)

	-- Limpiar scope al destruir el Janitor
	_janitor:Add(function()
		Fusion.doCleanup(_scope)
	end, true)

	-- Inicializar Values con copias profundas del template (template está
	-- congelado; las copias permiten mutación segura por consumidores).
	DataController.Stats         = _scope:Value(_deepCopy(DataTemplate.Stats))
	DataController.Inventory     = _scope:Value(_deepCopy(DataTemplate.Inventory))
	DataController.InventoryMeta = _scope:Value(_deepCopy(DataTemplate.InventoryMeta))
	DataController.Loadout       = _scope:Value(_deepCopy(DataTemplate.Loadout))
	DataController.WeaponKills   = _scope:Value(_deepCopy(DataTemplate.WeaponKills))
	DataController.Settings      = _scope:Value(_deepCopy(DataTemplate.Settings))
	DataController.Rewards       = _scope:Value(_deepCopy(DataTemplate.Rewards))
	DataController.Cases         = _scope:Value(_deepCopy(DataTemplate.Cases))
	DataController.LoginStreak   = _scope:Value(_deepCopy(DataTemplate.LoginStreak))
	DataController.NewItemFlags  = _scope:Value(_deepCopy(DataTemplate.NewItemFlags))
	DataController.DailyTasks    = _scope:Value(_deepCopy(DataTemplate.DailyTasks))
	DataController.BattlePass    = _scope:Value(_deepCopy(DataTemplate.BattlePass))
	DataController.Metadata      = _scope:Value(_deepCopy(DataTemplate.Metadata))

	-- Promise que se resuelve cuando llega la Replica del servidor
	_readyPromise = Promise.new(function(resolve: (any) -> ())
		_readyResolve = resolve
	end)

	-- Solicitar datos al servidor (envía RemoteEvent interno de ReplicaService)
	ReplicaController.RequestData()

	-- Registrarse para recibir la Replica "PlayerProfile"
	local connection = ReplicaController.ReplicaOfClassCreated("PlayerProfile", function(replica: any)
		-- Guard: el servidor solo crea UNA replica PlayerProfile por jugador
		-- (Replication = player). Si llega una segunda (server bug, hot reload),
		-- duplicaríamos los listeners y _replica quedaría inconsistente.
		if _replica ~= nil then
			warn("[DataController] Segunda replica PlayerProfile ignorada")
			return
		end

		_replica = replica

		-- ── Sembrar Values con snapshot inicial ──────────
		DataController.Stats:set(replica.Data.Stats)
		DataController.Inventory:set(replica.Data.Inventory)
		DataController.InventoryMeta:set(replica.Data.InventoryMeta)
		DataController.Loadout:set(replica.Data.Loadout)
		DataController.WeaponKills:set(replica.Data.WeaponKills)
		DataController.Settings:set(replica.Data.Settings)
		DataController.Rewards:set(replica.Data.Rewards)
		DataController.Cases:set(replica.Data.Cases)
		DataController.LoginStreak:set(replica.Data.LoginStreak)
		DataController.NewItemFlags:set(replica.Data.NewItemFlags)
		DataController.DailyTasks:set(replica.Data.DailyTasks)
		DataController.BattlePass:set(replica.Data.BattlePass)
		DataController.Metadata:set(replica.Data.Metadata)

		-- ── Suscribir listeners de cambio por sección ────
		-- Cada listener recibe la NUEVA tabla de sección (nueva referencia
		-- gracias a Sift en el servidor), garantizando que Value:set dispare
		-- incluso si los valores internos son iguales.
		replica:AddCleanupTask(
			replica:ListenToChange({ "Stats" }, function(newStats: any)
				DataController.Stats:set(newStats)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "Inventory" }, function(newInventory: any)
				DataController.Inventory:set(newInventory)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "Loadout" }, function(newLoadout: any)
				DataController.Loadout:set(newLoadout)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "WeaponKills" }, function(newWeaponKills: any)
				DataController.WeaponKills:set(newWeaponKills)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "Settings" }, function(newSettings: any)
				DataController.Settings:set(newSettings)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "Rewards" }, function(newRewards: any)
				DataController.Rewards:set(newRewards)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "Cases" }, function(newCases: any)
				DataController.Cases:set(newCases)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "InventoryMeta" }, function(newInventoryMeta: any)
				DataController.InventoryMeta:set(newInventoryMeta)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "LoginStreak" }, function(newLoginStreak: any)
				DataController.LoginStreak:set(newLoginStreak)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "NewItemFlags" }, function(newNewItemFlags: any)
				DataController.NewItemFlags:set(newNewItemFlags)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "DailyTasks" }, function(newDailyTasks: any)
				DataController.DailyTasks:set(newDailyTasks)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "BattlePass" }, function(newBattlePass: any)
				DataController.BattlePass:set(newBattlePass)
			end)
		)

		replica:AddCleanupTask(
			replica:ListenToChange({ "Metadata" }, function(newMetadata: any)
				DataController.Metadata:set(newMetadata)
			end)
		)

		-- ── Resolver la Promise de ready ─────────────────
		if _readyResolve then
			_readyResolve(nil)
			_readyResolve = nil
		end
	end)

	_janitor:Add(connection, "Disconnect")
end

--[[
	Devuelve la Promise que se resuelve cuando los datos del jugador están listos.

	Uso:
	  DataController:WhenReady():andThen(function()
	      local stats = Fusion.peek(DataController.Stats)
	      print("Level:", stats.Level)
	  end)
]]
function DataController:WhenReady(): any
	return _readyPromise
end

--[[
	Lectura directa del dato (sin reactividad).
	  path  nil      → devuelve copia profunda de toda la tabla de datos
	  path  {string} → navega por la ruta y devuelve el valor en la hoja
	                   (deep-copy si es tabla, primitivo si no)

	Devuelve copias para evitar que el caller mute el estado replicado por
	accidente — eso desincronizaría el cliente sin notificar listeners.

	Útil para lógica de negocio en controladores (no en UI reactiva).
]]
function DataController:Get(path: { string }?): any
	if not _replica then
		return nil
	end

	if path == nil then
		return _deepCopy(_replica.Data)
	end

	local pointer: any = _replica.Data
	for _, key in path :: { string } do
		if type(pointer) ~= "table" then
			return nil
		end
		pointer = pointer[key]
	end
	return _deepCopy(pointer)
end

--[[
	Limpia el controlador. Llama a esto si necesitas reiniciar el sistema
	(útil en UI-Labs o testing). Destruye el scope de Fusion y el Janitor.
]]
function DataController:Destroy(): ()
	if not _started then
		return
	end

	_started = false
	_janitor:Destroy()
	_janitor = nil
	_scope = nil
	_replica = nil
	_readyPromise = nil
	_readyResolve = nil
end

return DataController
