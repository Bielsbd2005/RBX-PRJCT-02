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

-- ────────────────────────────────────────────────────────────
-- ESTADO PRIVADO
-- ────────────────────────────────────────────────────────────

local _janitor: any  = Janitor.new()
local _scope:   any  = nil   -- Fusion scope; creado en Start()
local _replica: any  = nil   -- ReplicaService Replica; asignado al recibir datos

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

DataController.Stats     = nil :: any
DataController.Inventory = nil :: any
DataController.Loadout   = nil :: any
DataController.Settings  = nil :: any

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
	-- Crear scope de Fusion con todos los constructores disponibles
	_scope = Fusion.scoped(Fusion)

	-- Limpiar scope al destruir el Janitor
	_janitor:Add(function()
		Fusion.doCleanup(_scope)
	end, true)

	-- Inicializar Values con los datos por defecto del template
	DataController.Stats     = _scope:Value(DataTemplate.Stats)
	DataController.Inventory = _scope:Value(DataTemplate.Inventory)
	DataController.Loadout   = _scope:Value(DataTemplate.Loadout)
	DataController.Settings  = _scope:Value(DataTemplate.Settings)

	-- Promise que se resuelve cuando llega la Replica del servidor
	_readyPromise = Promise.new(function(resolve: (any) -> ())
		_readyResolve = resolve
	end)

	-- Solicitar datos al servidor (envía RemoteEvent interno de ReplicaService)
	ReplicaController.RequestData()

	-- Registrarse para recibir la Replica "PlayerProfile"
	local connection = ReplicaController.ReplicaOfClassCreated("PlayerProfile", function(replica: any)
		_replica = replica

		-- ── Sembrar Values con snapshot inicial ──────────
		DataController.Stats:set(replica.Data.Stats)
		DataController.Inventory:set(replica.Data.Inventory)
		DataController.Loadout:set(replica.Data.Loadout)
		DataController.Settings:set(replica.Data.Settings)

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
			replica:ListenToChange({ "Settings" }, function(newSettings: any)
				DataController.Settings:set(newSettings)
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
	Devuelve true si la Replica ha llegado y los Values están sembrados.
]]
function DataController:IsReady(): boolean
	return _replica ~= nil
end

--[[
	Lectura directa del dato (sin reactividad).
	  path  nil      → devuelve toda la tabla de datos (replica.Data)
	  path  {string} → navega por la ruta y devuelve el valor en la hoja

	Útil para lógica de negocio en controladores (no en UI reactiva).
]]
function DataController:Get(path: { string }?): any
	if not _replica then
		return nil
	end

	if path == nil then
		return _replica.Data
	end

	local pointer: any = _replica.Data
	for _, key in path :: { string } do
		if type(pointer) ~= "table" then
			return nil
		end
		pointer = pointer[key]
	end
	return pointer
end

--[[
	Limpia el controlador. Llama a esto si necesitas reiniciar el sistema
	(útil en UI-Labs o testing). Destruye el scope de Fusion y el Janitor.
]]
function DataController:Destroy(): ()
	_janitor:Destroy()
	_replica = nil
	_readyResolve = nil
end

return DataController
