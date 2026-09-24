--!strict
--[[
	EmoteAssetService.luau (Server)
	Resuelve los emotes de catálogo (ItemsConfig.Emotes[*].CatalogEmoteId) a su
	AnimationId real. El id del catálogo no sirve como AnimationId: el asset es un
	contenedor con la Animation dentro, y solo el servidor puede abrirlo con
	InsertService:LoadAsset (permitido para assets creados por Roblox).

	El resultado se publica como atributos de ReplicatedStorage.EmoteAnimations
	(emoteId → "rbxassetid://..."), que EmotePlayer lee en el cliente.
]]

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local EmotePlayer = require(Shared.Locker.emotes.EmotePlayer)

-- Sin tope de intentos: si LoadAsset falla al arrancar (van todos en paralelo), el emote
-- comprado no se reproduciría en todo el servidor. Backoff hasta RETRY_DELAY_MAX.
local RETRY_DELAY_FIRST = 2
local RETRY_DELAY_MAX = 300
local WARN_AFTER_ATTEMPTS = 3

local EmoteAssetService = {}

local _started = false

local function _resolveAnimationId(catalogId: number): string?
	local attempt = 0
	local retryDelay = RETRY_DELAY_FIRST
	while true do
		attempt += 1
		local ok, result = pcall(InsertService.LoadAsset, InsertService, catalogId)
		if ok then
			local animation = result:FindFirstChildWhichIsA("Animation", true)
			local animationId = if animation then animation.AnimationId else nil
			result:Destroy()
			return animationId
		end
		if attempt == WARN_AFTER_ATTEMPTS then
			warn(`[EmoteAssetService] LoadAsset({catalogId}) falló: {result}. Se sigue reintentando.`)
		end
		task.wait(retryDelay)
		retryDelay = math.min(retryDelay * 2, RETRY_DELAY_MAX)
	end
end

function EmoteAssetService:Start(): ()
	if _started then
		return
	end
	_started = true

	local folder = Instance.new("Folder")
	folder.Name = EmotePlayer.ANIMATIONS_FOLDER_NAME
	folder.Parent = ReplicatedStorage

	-- En paralelo: son ~60 LoadAsset y en serie tardarían bastante en llegar.
	for emoteId, config in ItemsConfig.Emotes do
		local catalogId = config.CatalogEmoteId
		if catalogId then
			task.spawn(function()
				local animationId = _resolveAnimationId(catalogId)
				if animationId then
					folder:SetAttribute(emoteId, animationId)
				end
			end)
		end
	end
end

return EmoteAssetService
