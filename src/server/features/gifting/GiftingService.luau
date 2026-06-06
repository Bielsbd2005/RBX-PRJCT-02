--!strict
--[[
	GiftingService.luau  (Server)

	Resuelve y valida el destinatario de un regalo. El cliente (Store ▸ Gifting)
	manda un nombre de usuario; el servidor:
	  1. Lo resuelve a un UserId con Players:GetUserIdFromNameAsync (existencia).
	  2. Filtra el nombre con TextService:FilterStringAsync (compliance).
	  3. Responde con el UserId + nombre canónico filtrado, o un error.

	Server-authoritative: el cliente nunca decide la existencia del usuario; solo
	muestra el estado que devuelve este servicio. La validación es el único paso
	de red del flujo de selección — la entrega del regalo es un flujo aparte.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Network = require(Shared.networking.Network)
local NetGuards = require(Shared.networking.NetGuards)

local DataServiceMod = require(script.Parent.Parent.Parent.core.data.DataService)
type DataService = DataServiceMod.DataServiceModule

-- Rate-limit anti-spam: cada validación hace 2-3 web-calls (GetUserIdFromName +
-- GetNameFromUserId + FilterString), todas con presupuesto de la API de Roblox.
-- 0.5s por player es generoso para UX (un click manual) y frena el spam.
local ACTION_COOLDOWN = 0.5
local _cooldowns: { [number]: number } = {}

local function _checkCooldown(player: Player): boolean
	local last = _cooldowns[player.UserId] or 0
	if time() - last < ACTION_COOLDOWN then
		return false
	end
	_cooldowns[player.UserId] = time()
	return true
end

local GiftingService = {}

local _dataService: DataService = nil :: any
local _started = false

-- ────────────────────────────────────────────────────────────
-- HELPERS
-- ────────────────────────────────────────────────────────────

local function _respond(player: Player, success: boolean, message: string, userId: string?, username: string?): ()
	Network.Gifting.Response.SendTo({
		success = success,
		message = message,
		userId = userId or "",
		username = username or "",
	}, player)
end

-- Recorta espacios al inicio/fin sin tocar el medio.
local function _trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Filtra un nombre para mostrarlo en la UI de otro jugador (broadcast). Los
-- nombres de usuario de Roblox ya están pre-moderados, así que esto es defensa
-- en profundidad: ante cualquier fallo de la API devolvemos el nombre original.
local function _filterForDisplay(player: Player, text: string): string
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, player.UserId)
	end)
	if not ok or not result then
		return text
	end
	local broadcastOk, broadcast = pcall(function()
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if broadcastOk and broadcast and broadcast ~= "" then
		return broadcast
	end
	return text
end

-- ────────────────────────────────────────────────────────────
-- API
-- ────────────────────────────────────────────────────────────

function GiftingService:ValidateUser(player: Player, rawUsername: string): ()
	local username = _trim(rawUsername)
	if username == "" then
		_respond(player, false, "Enter a username.")
		return
	end

	-- Existencia: GetUserIdFromNameAsync lanza si el nombre no corresponde a
	-- ninguna cuenta. pcall → error visual en el cliente, sin reventar el thread.
	local ok, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(username)
	end)
	if not ok or type(userId) ~= "number" then
		_respond(player, false, "That user doesn't exist.")
		return
	end

	if userId == player.UserId then
		_respond(player, false, "You can't gift yourself.")
		return
	end

	-- Nombre canónico (capitalización real) desde el UserId; si falla, usamos el
	-- que escribió el jugador.
	local nameOk, canonical = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local displayName = if nameOk and type(canonical) == "string" then canonical else username

	local filtered = _filterForDisplay(player, displayName)
	_respond(player, true, "", tostring(userId), filtered)
end

function GiftingService:Start(dataService: DataService): ()
	if _started then return end
	_started = true
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player: Player)
		_cooldowns[player.UserId] = nil
	end)

	-- Validación es bloqueante (web-calls): la corremos en un thread aparte para
	-- no congelar el dispatcher de ByteNet mientras esperamos a Roblox.
	Network.Gifting.ValidateUser.Listen(function(data: any, player: Player)
		if not NetGuards.validate(data, { username = NetGuards.MAX.Username }) then
			return
		end
		if not _checkCooldown(player) then
			return
		end
		task.spawn(function()
			GiftingService:ValidateUser(player, data.username)
		end)
	end)
end

return GiftingService
