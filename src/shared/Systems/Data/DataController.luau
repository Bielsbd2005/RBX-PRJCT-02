--[[
	DataController
	Módulo cliente para acceder a los datos del jugador replicados por el servidor.
	Recibe la Réplica de ReplicaService y expone una API reactiva para la UI.

	Ruta: ReplicatedStorage.Shared.Modules.DataController

	API:
		DataController:Start()                         — Inicializa (llamar una vez desde el cliente)
		DataController:Get(path?)                      — Obtiene un valor (o toda la tabla si no se pasa path)
		DataController:OnChanged(path, callback)       — Escucha cambios en una ruta específica → callback(newValue, oldValue)
		DataController:IsReady()                       — true si la Réplica ya fue recibida
		DataController:OnReady(callback)               — callback() se ejecuta cuando los datos estén listos
]]

--!native
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local ReplicaController = require(ReplicatedStorage.Packages.replicaservice)

----- Estado del Módulo -----
local DataController = {}
local PlayerReplica = nil
local IsDataReady = false
local HasStarted = false

-- Cola de espera para scripts que piden datos antes de cargar
local OnReadyTasks: { () -> () } = {}

--------------------------------------------------------------------------------
-- Utilidades Internas
--------------------------------------------------------------------------------

local function _getValueFromPath(data: any, path: string | {string}): any
	if not data then return nil end
	local keys = if type(path) == "string" then string.split(path, ".") else path
	local pointer = data
	for _, key in ipairs(keys) do
		if type(pointer) == "table" then
			pointer = pointer[key]
		else
			return nil
		end
	end
	return pointer
end

--------------------------------------------------------------------------------
-- API Pública
--------------------------------------------------------------------------------

function DataController:Start()
	if HasStarted then return end
	HasStarted = true

	ReplicaController.RequestData()

	ReplicaController.ReplicaOfClassCreated("PlayerData", function(replica)
		local replicaPlayer = replica.Tags.Player
		if replicaPlayer ~= LocalPlayer then return end

		PlayerReplica = replica
		IsDataReady = true

		print("[DataController] Datos cargados correctamente.")

		for _, taskFunc in ipairs(OnReadyTasks) do
			task.spawn(taskFunc)
		end
		table.clear(OnReadyTasks)

		replica:AddCleanupTask(function()
			PlayerReplica = nil
			IsDataReady = false
			print("[DataController] Datos descargados/destruidos.")
		end)
	end)
end

function DataController:Get(path: string?)
	if not PlayerReplica then return nil end
	if not path then return PlayerReplica.Data end
	return _getValueFromPath(PlayerReplica.Data, path)
end

function DataController:OnChanged(path: string, callback: (newVal: any, oldVal: any) -> ())
	if IsDataReady and PlayerReplica then
		return PlayerReplica:ListenToChange(path, callback)
	end

	local connectionInfo = { IsConnected = true, RealConnection = nil :: any }

	table.insert(OnReadyTasks, function()
		if not connectionInfo.IsConnected or not PlayerReplica then return end
		connectionInfo.RealConnection = PlayerReplica:ListenToChange(path, callback)
	end)

	return {
		Disconnect = function()
			connectionInfo.IsConnected = false
			if connectionInfo.RealConnection then connectionInfo.RealConnection:Disconnect() end
		end
	}
end

-- ESTA ES LA FUNCIÓN QUE FALTABA Y CAUSABA EL ERROR
function DataController:OnRawChange(callback: (action: string, path: {string}, ...any) -> ())
	if IsDataReady and PlayerReplica then
		return PlayerReplica:ListenToRaw(callback)
	end

	local connectionInfo = { IsConnected = true, RealConnection = nil :: any }

	table.insert(OnReadyTasks, function()
		if not connectionInfo.IsConnected or not PlayerReplica then return end
		connectionInfo.RealConnection = PlayerReplica:ListenToRaw(callback)
	end)

	return {
		Disconnect = function()
			connectionInfo.IsConnected = false
			if connectionInfo.RealConnection then connectionInfo.RealConnection:Disconnect() end
		end
	}
end

function DataController:OnReady(callback: () -> ())
	if IsDataReady then
		task.spawn(callback)
	else
		table.insert(OnReadyTasks, callback)
	end
end

function DataController:IsReady()
	return IsDataReady
end

return DataController
