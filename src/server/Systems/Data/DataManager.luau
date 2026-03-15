--[[
	DataManager
	Módulo servidor para gestionar datos de jugadores.
	Usa ProfileStore para persistencia y ReplicaService para replicación al cliente.

	Ruta: ServerStorage.Modules.DataManager

	API:
		DataManager:Start()                           — Inicializa todo (llamar una vez)
		DataManager:Get(player)                       — Devuelve profile.Data o nil
		DataManager:Update(player, path, value)       — Actualiza valor anidado (ej: "stats.kills")
		DataManager:Increment(player, path, amount)   — Incrementa un valor numérico
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local _RunService = game:GetService("RunService")

-- Asegúrate de que los types estén bien definidos en tus módulos
local ProfileStore = require(ReplicatedStorage.Packages.profilestore)
local ReplicaService = require(ReplicatedStorage.Packages.replicaservice)
local DataTemplate = require(ReplicatedStorage.Shared.Systems.Data.DataTemplate)

----- Configuración -----
local STORE_NAME = "PlayerData"
local PROFILE_KEY_PREFIX = "Player_"

local PlayerDataStore = ProfileStore.New(STORE_NAME, DataTemplate)
local PlayerClassToken = ReplicaService.NewClassToken("PlayerData")

-- Tipado básico para autocompletado interno
type Profile = {
	Data: any,
	Release: (self: any) -> (),
	Reconcile: (self: any) -> (),
	AddUserId: (self: any, id: number) -> (),
	OnSessionEnd: RBXScriptSignal,
	EndSession: (self: any) -> ()
}

local Profiles: { [Player]: Profile } = {}
local Replicas: { [Player]: any } = {}

----- Módulo -----
local DataManager = {}
DataManager.IsInited = false

--------------------------------------------------------------------------------
-- Utilidades privadas
--------------------------------------------------------------------------------

-- Obtiene el valor actual para operaciones matemáticas (Increment)
local function _getValueFromPath(data: any, keys: {string}): any
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

-- Modificador centralizado optimizado
local function _applyChange(player: Player, path: string, newValue: any, isIncrement: boolean, incrementAmount: number?)
	local profile = Profiles[player]
	local replica = Replicas[player]

	if not profile then return nil end

	-- string.split es rápido en Luau, no hace falta cachear a menos que sean miles/frame
	local keys = string.split(path, ".")
	local finalValue = newValue

	-- Lógica para Increment
	if isIncrement and incrementAmount then
		local currentValue = _getValueFromPath(profile.Data, keys)
		if type(currentValue) == "number" then
			finalValue = currentValue + incrementAmount
		else
			finalValue = incrementAmount -- Fallback si el valor anterior era nil
		end
	end

	-- APLICACIÓN DEL CAMBIO
	if replica then
		-- ReplicaService actualiza profile.Data internamente (por referencia)
		-- y gestiona la replicación.
		replica:SetValue(keys, finalValue)
	else
		-- Fallback: Si la réplica no está lista (ej. durante carga/descarga),
		-- aplicamos el cambio manualmente a profile.Data
		local pointer = profile.Data
		local success = true
		for i = 1, #keys - 1 do
			local key = keys[i]
			if type(pointer[key]) ~= "table" then
				-- Si el camino no existe, intentamos crearlo (opcional, pero seguro)
				-- pointer[key] = {}
				-- O simplemente fallamos:
				success = false; break
			end
			pointer = pointer[key]
		end

		if success then
			pointer[keys[#keys]] = finalValue
		end
	end

	return finalValue
end

--------------------------------------------------------------------------------
-- Gestión de Perfiles
--------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	local profileKey = PROFILE_KEY_PREFIX .. player.UserId

	local profile = PlayerDataStore:StartSessionAsync(profileKey, {
		Cancel = function() return player.Parent ~= Players end,
	})

	if not profile then
		-- Si falla el Session Lock, kickeamos
		player:Kick("No se pudieron cargar tus datos. Por favor, reintenta.")
		return
	end

	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	profile:Reconcile() -- Rellena datos faltantes desde el Template
	profile:AddUserId(player.UserId) -- Cumplimiento GDPR

	-- Metadatos de creación
	if profile.Data.meta and profile.Data.meta.createdAt == 0 then
		profile.Data.meta.createdAt = os.time()
	end

	profile.OnSessionEnd:Connect(function()
		Profiles[player] = nil
		if Replicas[player] then
			Replicas[player]:Destroy()
			Replicas[player] = nil
		end

		if player.Parent == Players then
			player:Kick("Sesión de datos finalizada (Posible duplicación).")
		end
	end)

	Profiles[player] = profile

	-- Creamos la Réplica
	-- Pasamos 'profile.Data' por referencia. ReplicaService modificará esta tabla directamente.
	Replicas[player] = ReplicaService.NewReplica({
		ClassToken = PlayerClassToken,
		Tags = { Player = player },
		Data = profile.Data,
		Replication = player,
	})
end

--------------------------------------------------------------------------------
-- API Pública
--------------------------------------------------------------------------------

function DataManager:Start()
	if self.IsInited then return end
	self.IsInited = true

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)

	Players.PlayerRemoving:Connect(function(player)
		local profile = Profiles[player]
		if profile then
			profile:EndSession()
		end
	end)
end

function DataManager:Get(player: Player)
	local profile = Profiles[player]
	return profile and profile.Data or nil
end

function DataManager:Update(player: Player, path: string, value: any)
	return _applyChange(player, path, value, false)
end

function DataManager:Increment(player: Player, path: string, amount: number)
	return _applyChange(player, path, nil, true, amount)
end

--[[
    BatchUpdate Optimizado:
    ReplicaService agrupa automáticamente todos los cambios ocurridos en un mismo frame
    en un solo paquete de red. No necesitamos usar 'SetValues' manualmente.
    Iteramos y usamos _applyChange para garantizar que los paths con puntos ("stats.gold")
    se resuelvan correctamente.
]]
function DataManager:BatchUpdate(player: Player, updates: { [string]: any })
	local profile = Profiles[player]
	if not profile then return false end

	local allOk = true
	for path, value in pairs(updates) do
		local result = _applyChange(player, path, value, false)
		if result == nil then
			allOk = false
			warn(string.format("[DataManager] BatchUpdate: failed to apply path '%s' for %s", path, player.Name))
		end
	end

	return allOk
end

function DataManager:GetReplica(player: Player)
	return Replicas[player]
end

return DataManager
