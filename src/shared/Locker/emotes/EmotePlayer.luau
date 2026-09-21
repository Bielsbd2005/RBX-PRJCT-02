--!strict
--[[
	EmotePlayer.luau
	Reproduce un emote (ItemsConfig.Emotes[emoteId].AnimationId) sobre un rig.
	Lo comparten el preview del Locker (sobre el dummy) y EmoteController (sobre
	el personaje del jugador en partida).

	Las animaciones cargadas en el Animator del personaje local se replican solas
	al resto de clientes, así que no hace falta ningún remote.
]]

local ItemsConfig = require(script.Parent.Parent.Parent.constants.ItemsConfig)
local ItemDefaults = require(script.Parent.Parent.Parent.constants.ItemDefaults)

local EmotePlayer = {}

-- Nombre del AnimationTrack: sirve para localizar/parar el emote activo.
EmotePlayer.TRACK_NAME = "Emote"

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
	local animationId = config and config.AnimationId
	if type(animationId) ~= "string" then
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
	track.Looped = config.Looped == true
	track:Play(0.15)
	track.Stopped:Once(function()
		track:Destroy()
	end)
	return track
end

return EmotePlayer
