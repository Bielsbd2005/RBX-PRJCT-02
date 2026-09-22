--!strict
--[[
	EmotePlayer.luau
	Reproduce un emote (ItemsConfig.Emotes[emoteId].AnimationId) sobre un rig.
	Lo comparten el preview del Locker (sobre el dummy) y EmoteController (sobre
	el personaje del jugador en partida).

	Las animaciones cargadas en el Animator del personaje local se replican solas
	al resto de clientes, así que no hace falta ningún remote.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemsConfig = require(script.Parent.Parent.Parent.constants.ItemsConfig)
local ItemDefaults = require(script.Parent.Parent.Parent.constants.ItemDefaults)

local EmotePlayer = {}

-- Nombre del AnimationTrack: sirve para localizar/parar el emote activo.
EmotePlayer.TRACK_NAME = "Emote"
-- Folder de ReplicatedStorage donde EmoteAssetService publica, como atributos,
-- las AnimationId resueltas de los emotes de catálogo (emoteId → AnimationId).
EmotePlayer.ANIMATIONS_FOLDER_NAME = "EmoteAnimations"

-- Una Animation por AnimationId: se reutiliza entre reproducciones.
local _animationCache: { [string]: Animation } = {}

local function _getAnimation(animationId: string): Animation
	local cached = _animationCache[animationId]
	if cached then
		return cached
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	_animationCache[animationId] = animation
	return animation
end

local function _getAnimator(rig: Model): Animator?
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

-- Config del emote; cae al Default si el id no existe (p. ej. ítem retirado).
function EmotePlayer.getConfig(emoteId: string?): any
	local emotes = ItemsConfig.Emotes
	return (emoteId and emotes[emoteId]) or emotes[ItemDefaults.ITEM_ID]
end

-- AnimationId del emote: directa en ItemsConfig o, para los de catálogo, la que
-- haya resuelto el servidor. nil si aún no está resuelta (o falló la carga).
function EmotePlayer.getAnimationId(emoteId: string?): string?
	local config = EmotePlayer.getConfig(emoteId)
	if not config then
		return nil
	end
	if type(config.AnimationId) == "string" then
		return config.AnimationId
	end
	local folder = ReplicatedStorage:FindFirstChild(EmotePlayer.ANIMATIONS_FOLDER_NAME)
	-- Clave = id del ítem; si emoteId no existía, getConfig cayó al Default.
	local key = if emoteId and ItemsConfig.Emotes[emoteId] then emoteId else ItemDefaults.ITEM_ID
	local resolved = folder and folder:GetAttribute(key)
	return if type(resolved) == "string" then resolved else nil
end

-- Para cualquier emote que esté sonando en el rig.
function EmotePlayer.stop(rig: Model, fadeTime: number?)
	local animator = _getAnimator(rig)
	if not animator then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		if track.Name == EmotePlayer.TRACK_NAME then
			track:Stop(fadeTime or 0.2)
		end
	end
end

-- Reproduce el emote y devuelve su track (o nil si el rig no puede animarse).
function EmotePlayer.play(rig: Model, emoteId: string?): AnimationTrack?
	local config = EmotePlayer.getConfig(emoteId)
	local animationId = EmotePlayer.getAnimationId(emoteId)
	if not animationId then
		return nil
	end

	local animator = _getAnimator(rig)
	if not animator then
		return nil
	end

	EmotePlayer.stop(rig, 0.1)

	local track = animator:LoadAnimation(_getAnimation(animationId))
	track.Name = EmotePlayer.TRACK_NAME
	-- Action4: por encima de las animaciones de sostener el arma, que si no
	-- se comen los brazos del emote.
	track.Priority = Enum.AnimationPriority.Action4
	-- Solo si el ítem lo fuerza: los de catálogo traen el loop en la animación.
	if config.Looped ~= nil then
		track.Looped = config.Looped == true
	end
	track:Play(0.15)
	track.Stopped:Once(function()
		track:Destroy()
	end)
	return track
end

return EmotePlayer
