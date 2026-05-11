--!strict
--[[
	LobbyMusicFeature  (Client)
	Reproduce SoundService.LobbyMusic con tres estados:
	  PLAY     — volumen normal, EQ plano                  (lobby sin paneles)
	  MUFFLED  — volumen bajo + low-pass agresivo (EQ)     (panel abierto sobre lobby)
	  STOP     — volumen 0 (sigue sonando en background)   (durante el match)

	El efecto MUFFLED es "tras una pared": solo EqualizerSoundEffect con cut
	fuerte en HighGain y medio en MidGain. Sin reverb — la canción no se colorea
	espacialmente, solo se "tapa".

	El estado se deriva de MenuController. OJO con el orden de los checks:
	abrir un panel también llama a menuController:hide() para esconder los
	containers del menú detrás, así que isHidden=true por sí solo NO implica
	"en match". El panel se chequea primero.
	  hasOpenPanel() == true             → MUFFLED  (panel abierto en lobby)
	  isHidden() && !hasOpenPanel        → STOP     (en match)
	  resto                              → PLAY     (lobby idle)

	Si el Sound no existe en SoundService se crea vacío (SoundId=""). Configura
	el AssetId desde Studio.
]]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

local SOUND_NAME = "LobbyMusic"
local BASE_VOLUME = 0.5
local MUFFLE_VOLUME = 0.3
local FADE_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STATE_TWEEN_INFO = TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- "Tras una pera": cut fuerte en agudos, cut medio en mids, graves intactos.
-- La canción pierde brillo y queda como sonando detrás de algo sólido.
local MUFFLE_HIGH_GAIN = -20
local MUFFLE_MID_GAIN = -6

local function ensureSound(): Sound
	local existing = SoundService:FindFirstChild(SOUND_NAME)
	if existing and existing:IsA("Sound") then
		return existing
	end
	local sound = Instance.new("Sound")
	sound.Name = SOUND_NAME
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	return sound
end

local function ensureEqualizer(sound: Sound): EqualizerSoundEffect
	local existing = sound:FindFirstChildOfClass("EqualizerSoundEffect")
	if existing then return existing end
	local eq = Instance.new("EqualizerSoundEffect")
	eq.Name = "MuffleEQ"
	eq.LowGain = 0
	eq.MidGain = 0
	eq.HighGain = 0
	eq.Parent = sound
	return eq
end

-- Limpia el ReverbSoundEffect "CaveReverb" que añadía la versión anterior
-- (efecto cueva). Solo se elimina si tiene ese Name exacto, así no tocamos
-- una reverb que el dev haya añadido a mano en Studio.
local function removeLegacyCaveReverb(sound: Sound)
	for _, child in sound:GetChildren() do
		if child:IsA("ReverbSoundEffect") and child.Name == "CaveReverb" then
			child:Destroy()
		end
	end
end

local LobbyMusicFeature = {}

function LobbyMusicFeature.start(menuController: any): any
	local janitor = Janitor.new()
	local sound = ensureSound()
	removeLegacyCaveReverb(sound)
	local equalizer = ensureEqualizer(sound)

	-- Arranca silencioso; applyState() abajo hace el primer tween al estado real.
	sound.Volume = 0
	if not sound.Playing then
		sound:Play()
	end
	janitor:Add(function()
		sound:Stop()
	end, true)

	local activeTweens: { Tween } = {}

	local function tweenTo(volume: number, highGain: number, midGain: number, info: TweenInfo)
		for _, tween in activeTweens do
			tween:Cancel()
		end
		table.clear(activeTweens)

		local volumeTween = TweenService:Create(sound, info, { Volume = volume })
		local highTween = TweenService:Create(equalizer, info, { HighGain = highGain })
		local midTween = TweenService:Create(equalizer, info, { MidGain = midGain })

		table.insert(activeTweens, volumeTween)
		table.insert(activeTweens, highTween)
		table.insert(activeTweens, midTween)

		volumeTween:Play()
		highTween:Play()
		midTween:Play()
	end

	janitor:Add(function()
		for _, tween in activeTweens do
			tween:Cancel()
		end
		table.clear(activeTweens)
	end, true)

	local function applyState()
		local hasPanel = menuController:hasOpenPanel()
		local isHidden = menuController:isHidden()

		if hasPanel then
			tweenTo(MUFFLE_VOLUME, MUFFLE_HIGH_GAIN, MUFFLE_MID_GAIN, STATE_TWEEN_INFO)
		elseif isHidden then
			tweenTo(0, 0, 0, FADE_TWEEN_INFO)
		else
			tweenTo(BASE_VOLUME, 0, 0, STATE_TWEEN_INFO)
		end
	end

	janitor:Add(menuController:onStateChanged(applyState), true)
	applyState()

	return janitor
end

return LobbyMusicFeature
