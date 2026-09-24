--!strict
--[[
	Puente entre ReplicaService y Fusion 0.3: siembra un Value por sección de la Replica
	"PlayerProfile" y los actualiza con listeners de cambio. WhenReady() se resuelve al
	llegar la primera Replica. Todo vive en un scope de Fusion que limpia el Janitor.

	Un Value por sección y no por campo: ReplicaService propaga deltas por sección y
	Fusion solo recalcula los Computed que dependen de ella.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared   = ReplicatedStorage:WaitForChild("Shared")

local ReplicaController = require(Packages.replicaservice) :: any
local Fusion            = require(Packages.fusion)         :: any
local Janitor           = require(Packages.janitor)        :: any
local Promise           = require(Packages["typed-promise"]) :: any

local DataTemplate = require(Shared.constants.DataTemplate) :: any

-- El template está congelado: sembrar Values con la referencia directa haría que
-- cualquier mutación de un componente lanzara error en runtime.
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

local _janitor: any = nil
local _scope: any = nil
local _replica: any = nil
local _started = false

local _readyPromise:  any = nil
local _readyResolve:  ((any) -> ())? = nil

-- Inicializados en Start() a los defaults del template para que la UI nunca reciba nil.
-- Tipados `any` porque el scope se crea en Start(); el tipo real es Fusion.Value<T>.
local DataController = {}

DataController.Stats         = nil :: any
DataController.Inventory     = nil :: any
DataController.InventoryMeta = nil :: any
DataController.Loadout       = nil :: any
DataController.WeaponKills   = nil :: any
DataController.Settings      = nil :: any
DataController.Rewards       = nil :: any
DataController.LoginStreak   = nil :: any
DataController.DailyTasks    = nil :: any
DataController.BattlePass    = nil :: any
DataController.Metadata      = nil :: any
DataController.PendingGifts  = nil :: any

-- Equipados optimistas del Locker: Loadout publica la Replica con estos valores
-- encima hasta que la Replica trae el mismo valor (o se retiran). Clave = path unido.
local _realLoadout: any = nil
local _loadoutOverrides: { [string]: { path: { string }, value: any } } = {}

local function _getAtPath(root: any, path: { string }): any
	local node = root
	for _, key in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return node
end

-- Copia solo la rama que se toca: el resto sigue compartiendo tablas con la Replica.
local function _withValueAtPath(root: any, path: { string }, index: number, value: any): any
	local copy = if type(root) == "table" then table.clone(root) else {}
	local key = path[index]
	if index == #path then
		copy[key] = value
	else
		copy[key] = _withValueAtPath(copy[key], path, index + 1, value)
	end
	return copy
end

local function _publishLoadout()
	for key, override in _loadoutOverrides do
		if _getAtPath(_realLoadout, override.path) == override.value then
			_loadoutOverrides[key] = nil
		end
	end

	local loadout = _realLoadout
	for _, override in _loadoutOverrides do
		loadout = _withValueAtPath(loadout, override.path, 1, override.value)
	end
	DataController.Loadout:set(loadout)
end

function DataController:Start(): ()
	if _started then
		return
	end

	_started = true
	_janitor = Janitor.new()

	_scope = Fusion.scoped(Fusion)

	_janitor:Add(function()
		Fusion.doCleanup(_scope)
	end, true)

	DataController.Stats         = _scope:Value(_deepCopy(DataTemplate.Stats))
	DataController.Inventory     = _scope:Value(_deepCopy(DataTemplate.Inventory))
	DataController.InventoryMeta = _scope:Value(_deepCopy(DataTemplate.InventoryMeta))
	_realLoadout = _deepCopy(DataTemplate.Loadout)
	DataController.Loadout       = _scope:Value(_realLoadout)
	DataController.WeaponKills   = _scope:Value(_deepCopy(DataTemplate.WeaponKills))
	DataController.Settings      = _scope:Value(_deepCopy(DataTemplate.Settings))
	DataController.Rewards       = _scope:Value(_deepCopy(DataTemplate.Rewards))
	DataController.LoginStreak   = _scope:Value(_deepCopy(DataTemplate.LoginStreak))
	DataController.DailyTasks    = _scope:Value(_deepCopy(DataTemplate.DailyTasks))
	DataController.BattlePass    = _scope:Value(_deepCopy(DataTemplate.BattlePass))
	DataController.Metadata      = _scope:Value(_deepCopy(DataTemplate.Metadata))
	DataController.PendingGifts  = _scope:Value(_deepCopy(DataTemplate.PendingGifts))

	_readyPromise = Promise.new(function(resolve: (any) -> ())
		_readyResolve = resolve
	end)

	ReplicaController.RequestData()

	local connection = ReplicaController.ReplicaOfClassCreated("PlayerProfile", function(replica: any)
		-- Solo debe haber UNA replica PlayerProfile por jugador; una segunda (bug, hot reload)
		-- duplicaría los listeners.
		if _replica ~= nil then
			warn("[DataController] Segunda replica PlayerProfile ignorada")
			return
		end

		_replica = replica

		DataController.Stats:set(replica.Data.Stats)
		DataController.Inventory:set(replica.Data.Inventory)
		DataController.InventoryMeta:set(replica.Data.InventoryMeta)
		_realLoadout = replica.Data.Loadout
		_publishLoadout()
		DataController.WeaponKills:set(replica.Data.WeaponKills)
		DataController.Settings:set(replica.Data.Settings)
		DataController.Rewards:set(replica.Data.Rewards)
		DataController.LoginStreak:set(replica.Data.LoginStreak)
		DataController.DailyTasks:set(replica.Data.DailyTasks)
		DataController.BattlePass:set(replica.Data.BattlePass)
		DataController.Metadata:set(replica.Data.Metadata)
		DataController.PendingGifts:set(replica.Data.PendingGifts)

		-- Cada listener recibe una tabla de sección con referencia nueva (Sift en el
		-- servidor), así Value:set dispara aunque los valores internos sean iguales.
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
				_realLoadout = newLoadout
				_publishLoadout()
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

		replica:AddCleanupTask(
			replica:ListenToChange({ "PendingGifts" }, function(newPendingGifts: any)
				DataController.PendingGifts:set(newPendingGifts)
			end)
		)

		if _readyResolve then
			_readyResolve(nil)
			_readyResolve = nil
		end
	end)

	_janitor:Add(connection, "Disconnect")
end

function DataController:WhenReady(): any
	return _readyPromise
end

--- Loadout muestra `value` en `path` (relativo a Loadout) antes de que el servidor
--- lo confirme. Se retira solo cuando la Replica trae ese mismo valor.
function DataController:setLoadoutOverride(path: { string }, value: any)
	_loadoutOverrides[table.concat(path, "/")] = { path = table.clone(path), value = value }
	_publishLoadout()
end

function DataController:clearLoadoutOverride(path: { string })
	local key = table.concat(path, "/")
	if _loadoutOverrides[key] then
		_loadoutOverrides[key] = nil
		_publishLoadout()
	end
end

return DataController
