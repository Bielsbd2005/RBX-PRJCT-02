--!native
--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

-- Asumimos que DataManager está en esta ruta según tu script anterior
local DataManager = require(ServerScriptService.Server.Systems.Data.DataManager)
local DataTemplate = require(ReplicatedStorage.Shared.Systems.Data.DataTemplate)

----- Configuración -----

-- OPTIMIZACIÓN: Usar un diccionario para búsqueda O(1)
-- [UserId] = true
local ADMIN_IDS: { [number]: boolean } = {
	[286176976] = true,
}

-- ⚠️  Set to false before publishing to live game!
local STUDIO_ADMIN_ENABLED = true

----- Utilidades -----

-- Verificación instantánea sin bucles
local function isAdmin(player: Player): boolean
	if STUDIO_ADMIN_ENABLED and (RunService:IsStudio() or player.UserId < 0) then
		return true
	end
	return ADMIN_IDS[player.UserId] == true
end

-- Solo necesitamos deepCopy para clonar el Template en ResetData.
-- Para enviar datos al cliente, Roblox ya hace la serialización.
local function deepCopy(t: any): any
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = deepCopy(v)
	end
	return copy
end

----- Inicialización de Remotes -----

local adminFolder = Instance.new("Folder")
adminFolder.Name = "AdminConsole"
adminFolder.Parent = ReplicatedStorage

local function createRemoteFunc(name: string): RemoteFunction
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = adminFolder
	return rf
end

local isAdminRF = createRemoteFunc("IsAdmin")
local getPlayersRF = createRemoteFunc("GetPlayers")
local getPlayerDataRF = createRemoteFunc("GetPlayerData")
local updateDataRF = createRemoteFunc("UpdateData")
local resetDataRF = createRemoteFunc("ResetData")

----- Handlers -----

isAdminRF.OnServerInvoke = function(player: Player)
	return isAdmin(player)
end

getPlayersRF.OnServerInvoke = function(player: Player)
	if not isAdmin(player) then return {} end

	local result = {}
	-- GetPlayers devuelve un array, iteración estándar es necesaria aquí
	for _, p in ipairs(Players:GetPlayers()) do
		-- Solo verificamos si tiene datos cargados, no leemos todo el perfil aquí para ahorrar memoria
		local hasProfile = DataManager:Get(p) ~= nil

		table.insert(result, {
			UserId = p.UserId,
			Name = p.Name,
			DisplayName = p.DisplayName,
			HasData = hasProfile,
		})
	end
	return result
end

getPlayerDataRF.OnServerInvoke = function(player: Player, targetUserId: number)
	if not isAdmin(player) then return nil end

	-- OPTIMIZACIÓN: Búsqueda nativa directa
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer then return nil end

	local data = DataManager:Get(targetPlayer)

	-- No necesitamos deepCopy aquí; RemoteFunction serializa automáticamente al enviar al cliente
	return data
end

updateDataRF.OnServerInvoke = function(player: Player, targetUserId: number, path: string, newValue: any)
	if not isAdmin(player) then return false, "Acceso denegado" end

	if type(targetUserId) ~= "number" then return false, "UserId inválido" end
	if type(path) ~= "string" or path == "" then return false, "Path inválido" end

	-- Block writes to protected data paths
	local BLOCKED_PATHS = { "meta.isBanned", "activeFusion", "meta.createdAt" }
	for _, blocked in ipairs(BLOCKED_PATHS) do
		if string.find(path, blocked, 1, true) then
			return false, "Path protegido: " .. blocked
		end
	end

	-- OPTIMIZACIÓN: Búsqueda nativa
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer then return false, "Jugador no encontrado u offline" end

	-- Validar que no intenten inyectar funciones o metatablas (seguridad básica)
	if type(newValue) == "function" or type(newValue) == "userdata" then
		return false, "Tipo de dato no soportado"
	end

	-- Llamamos a la versión optimizada de DataManager
	local finalVal = DataManager:Update(targetPlayer, path, newValue)

	if finalVal ~= nil then
		-- Logging with trust source
		local trust = (RunService:IsStudio() or player.UserId < 0) and "[ADMIN-STUDIO]" or "[ADMIN-TRUSTED]"
		print(string.format("%s %s updated %s's path '%s'", trust, player.Name, targetPlayer.Name, path))
		return true, "OK"
	else
		return false, "Error al actualizar (Path inválido?)"
	end
end

resetDataRF.OnServerInvoke = function(player: Player, targetUserId: number)
	if not isAdmin(player) then return false, "Acceso denegado" end

	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer then return false, "Jugador no encontrado" end

	-- Iterar y resetear cada clave principal
	for key, defaultValue in pairs(DataTemplate) do
		-- AQUÍ sí usamos deepCopy para no asignar la referencia del Template
		DataManager:Update(targetPlayer, key, deepCopy(defaultValue))
	end

	print(string.format("[ADMIN] %s RESET DATA for %s", player.Name, targetPlayer.Name))
	return true, "Datos reseteados al default"
end

print("[AdminService] Sistema de administración optimizado cargado")
