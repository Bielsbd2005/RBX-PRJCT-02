--!strict
--[[
	Música del lobby (SoundService.Audio.Music.Lobby) con tres estados:
	  PLAY     — volumen normal, EQ plano                  (lobby sin paneles)
	  MUFFLED  — volumen bajo + low-pass agresivo (EQ)     (panel abierto sobre lobby)
	  STOP     — volumen 0 (sigue sonando en background)   (durante el match)

	MUFFLED es solo EqualizerSoundEffect (cut fuerte en HighGain, medio en MidGain),
	sin reverb: la canción se "tapa" sin colorearse espacialmente.

	El estado se deriva de MenuController. OJO con el orden de los checks:
	abrir un panel también llama a menuController:hide(), así que isHidden=true
	por sí solo NO implica "en match". El panel se chequea primero.
	  hasOpenPanel() == true             → MUFFLED  (panel abierto en lobby)
	  isHidden() && !hasOpenPanel        → STOP     (en match)
	  resto                              → PLAY     (lobby idle)

	El Sound lo monta tools/audio/SetupSoundService.luau; si falta se crea vacío
	(SoundId="") y el AssetId se configura desde Studio.
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Janitor = require(Packages.janitor) :: any

local GameSounds = require(script.Parent.Parent.core.ui.GameSounds)

-- El nivel base lo manda la tabla de mezcla (LAYOUT en tools/audio/SetupSoundService.luau);
-- aquí solo se decide la proporción entre estados.
local MUFFLE_RATIO = 0.6
-- Suelo por si la tabla no se ha aplicado nunca en este place (sin él, un Sound
-- recién creado a Volume 0 dejaría la música muda para siempre).
local FALLBACK_VOLUME = 0.1
local FADE_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STATE_TWEEN_INFO = TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local MUFFLE_HIGH_GAIN = -20
local MUFFLE_MID_GAIN = -6

local function ensureSound(): Sound
	return GameSounds.ensure(GameSounds.LobbyMusic)
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

-- Borra la reverb "CaveReverb" que añadía una versión anterior. Solo por Name exacto,
-- para no tocar una reverb añadida a mano en Studio.
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

	local function cancelActiveTweens()
		for _, tween in activeTweens do
			tween:Cancel()
		end
		table.clear(activeTweens)
	end

	local function tweenTo(volume: number, highGain: number, midGain: number, info: TweenInfo)
		cancelActiveTweens()

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

	janitor:Add(cancelActiveTweens, true)

	-- Se lee UNA vez al arrancar: a partir de aquí `sound.Volume` es un valor
	-- vivo que tweeneamos nosotros, así que releerlo daría el estado actual en
	-- vez del nivel de referencia.
	local baseVolume = GameSounds.baseVolume(GameSounds.LobbyMusic, FALLBACK_VOLUME)
	local muffleVolume = baseVolume * MUFFLE_RATIO

	-- Al soltar el feature, devolver el Sound a su nivel autorado: si se queda
	-- donde lo dejó el último tween, un hot-reload en partida lo capturaría a 0.
	janitor:Add(function()
		sound.Volume = baseVolume
	end, true)

	local function getVolumeMultiplier(): number
		return math.clamp(sound:GetAttribute("VolumeMultiplier") or 1, 0, 1)
	end

	local function applyState()
		local hasPanel = menuController:hasOpenPanel()
		local isHidden = menuController:isHidden()
		local mult = getVolumeMultiplier()

		if hasPanel then
			tweenTo(muffleVolume * mult, MUFFLE_HIGH_GAIN, MUFFLE_MID_GAIN, STATE_TWEEN_INFO)
		elseif isHidden then
			tweenTo(0, 0, 0, FADE_TWEEN_INFO)
		else
			tweenTo(baseVolume * mult, 0, 0, STATE_TWEEN_INFO)
		end
	end

	janitor:Add(menuController:onStateChanged(applyState), true)
	janitor:Add(sound:GetAttributeChangedSignal("VolumeMultiplier"):Connect(function()
		local mult = getVolumeMultiplier()
		local hasPanel = menuController:hasOpenPanel()
		local isHidden = menuController:isHidden()
		if isHidden and not hasPanel then return end
		-- Cancelar tweens en vuelo antes de fijar el valor: si no, siguen sobrescribiéndolo
		-- frame a frame y el slider parece no responder.
		cancelActiveTweens()
		sound.Volume = (if hasPanel then muffleVolume else baseVolume) * mult
	end), "Disconnect")
	applyState()

	return janitor
end

return LobbyMusicFeature
