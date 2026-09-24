--!strict
--[[
	Acceso a los sonidos de Studio bajo `SoundService.Audio.<folder>.<name>`, que
	monta `tools/audio/SetupSoundService.luau` (ver docs/AUDIO.md). SPECS es el
	contrato con ese script. El `Volume` de cada Sound NO vive aquí: lo escribe la
	tabla LAYOUT de ese script; aquí solo rutas y `minInterval`.

	Los Sound se resuelven en cada llamada (sin caché) para poder editarlos en Studio
	en caliente. Si faltan o no tienen SoundId, no-op con un único warn por sonido.
	Los sonidos de Gameplay se listan para tener un solo inventario, pero los
	reproduce el WeaponsSystem con su propio pool (no puede requerir este módulo).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local AudioRuntime = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("AudioRuntime")
)

local AUDIO_FOLDER_NAME = "Audio"

type SoundSpec = {
	folder: string,
	name: string,
	looped: boolean?,
	-- Segundos mínimos entre dos disparos del mismo sonido. Red contra el apilado en
	-- amplitud, no adelgazador de ráfagas: cada valor va justo por debajo del ritmo
	-- natural del sonido para que solo se corte el caso patológico (doble disparo).
	minInterval: number?,
}

local SPECS: { [string]: SoundSpec } = {
	Click = { folder = "UI", name = "Click", minInterval = 0.05 },
	Open = { folder = "UI", name = "Open", minInterval = 0.12 },
	OpenStore = { folder = "UI", name = "OpenStore", minInterval = 0.12 },
	Close = { folder = "UI", name = "Close", minInterval = 0.12 },
	Error = { folder = "UI", name = "Error", minInterval = 0.20 },
	-- Los toggles de Settings llevan `NoClickSound`: este sustituye al click, no se suma.
	Toggle = { folder = "UI", name = "Toggle", minInterval = 0.08 },
	Notification = { folder = "UI", name = "Notification", minInterval = 0.30 },
	Purchase = { folder = "UI", name = "Purchase", minInterval = 0.25 },
	LevelUp = { folder = "UI", name = "LevelUp", minInterval = 0.30 },
	FamePassUp = { folder = "UI", name = "FamePassUp", minInterval = 0.30 },
	-- Por debajo del stagger entre monedas (0.05) para no cortar la ráfaga.
	Coin = { folder = "UI", name = "Coin", minInterval = 0.04 },
	Hit = { folder = "Gameplay", name = "Hit" },
	Headshot = { folder = "Gameplay", name = "Headshot" },
	Elimination = { folder = "Gameplay", name = "Elimination" },
	Health = { folder = "Gameplay", name = "Health" },
	-- Los de kill effects los reproducen visuals/killEffects/* en 3D (no pasan por `play`).
	BalloonPop = { folder = "Gameplay", name = "BalloonPop" },
	XpOrb = { folder = "Gameplay", name = "XpOrb" },
	Confetti = { folder = "Gameplay", name = "Confetti" },
	Electrocution = { folder = "Gameplay", name = "Electrocution" },
	LobbyMusic = { folder = "Music", name = "Lobby", looped = true },
}

local GameSounds = {}

-- Usa `GameSounds.Click`, no el string suelto: un typo da nil en el call site.
GameSounds.Click = "Click"
GameSounds.Open = "Open"
GameSounds.OpenStore = "OpenStore"
GameSounds.Close = "Close"
GameSounds.Error = "Error"
GameSounds.Toggle = "Toggle"
GameSounds.Notification = "Notification"
GameSounds.Purchase = "Purchase"
GameSounds.LevelUp = "LevelUp"
GameSounds.FamePassUp = "FamePassUp"
GameSounds.Coin = "Coin"
GameSounds.Hit = "Hit"
GameSounds.Headshot = "Headshot"
GameSounds.Elimination = "Elimination"
GameSounds.Health = "Health"
GameSounds.BalloonPop = "BalloonPop"
GameSounds.XpOrb = "XpOrb"
GameSounds.Confetti = "Confetti"
GameSounds.Electrocution = "Electrocution"
GameSounds.LobbyMusic = "LobbyMusic"

local _warned: { [string]: boolean } = {}
local _lastPlayedAt: { [string]: number } = {}

local function pathOf(spec: SoundSpec): string
	return `SoundService.{AUDIO_FOLDER_NAME}.{spec.folder}.{spec.name}`
end

local function warnOnce(key: string, message: string)
	if _warned[key] then
		return
	end
	_warned[key] = true
	warn(`[GameSounds] {message}`)
end

function GameSounds.resolve(key: string): Sound?
	local spec = SPECS[key]
	if not spec then
		warnOnce(key, `clave desconocida "{key}" (revisa GameSounds.SPECS)`)
		return nil
	end

	local audio = SoundService:FindFirstChild(AUDIO_FOLDER_NAME)
	local folder = if audio then audio:FindFirstChild(spec.folder) else nil
	local sound = AudioRuntime.findSound(folder, spec.name)
	if sound then
		return sound
	end

	warnOnce(key, `falta {pathOf(spec)} — ejecuta tools/audio/SetupSoundService.luau`)
	return nil
end

function GameSounds.play(key: string)
	local spec = SPECS[key]
	if spec and spec.minInterval then
		local now = os.clock()
		local last = _lastPlayedAt[key]
		if last and (now - last) < spec.minInterval then
			return
		end
		_lastPlayedAt[key] = now
	end

	local sound = GameSounds.resolve(key)
	if not sound then
		return
	end
	if sound.SoundId == "" then
		warnOnce(`{key}:id`, `{pathOf(spec)} no tiene SoundId (no sonará)`)
		return
	end
	SoundService:PlayLocalSound(sound)
end

--- Clona `key` dentro de `parent` y lo reproduce: 3D si `parent` es una parte o un
--- Attachment, y se va con él. Para sonidos de mundo (kill effects); no-op sin SoundId.
function GameSounds.playAt(key: string, parent: Instance, playbackSpeed: number?): Sound?
	local template = GameSounds.resolve(key)
	if not template or template.SoundId == "" then
		return nil
	end
	local sound = template:Clone()
	if playbackSpeed then
		sound.PlaybackSpeed = playbackSpeed
	end
	sound.Parent = parent
	sound:Play()
	return sound
end

--- Nivel autorado de `key` (atributo MixVolume de la tabla de mezcla), no el Volume
--- actual: para código que tweenea `Volume` y necesita saber a qué nivel volver.
function GameSounds.baseVolume(key: string, fallback: number): number
	local sound = GameSounds.resolve(key)
	if not sound then
		return fallback
	end
	local authored = sound:GetAttribute("MixVolume")
	if typeof(authored) == "number" and authored > 0 then
		return authored
	end
	-- Sin atributo, el Volume actual solo es fiable si aún nadie lo ha tweeneado.
	if sound.Volume > 0 then
		return sound.Volume
	end
	return fallback
end

--- Como `resolve`, pero crea el Sound vacío (y sus carpetas) si no existe. Solo para
--- sonidos que se necesitan como instancia persistente (la música); el resto usa `play`.
function GameSounds.ensure(key: string): Sound
	local existing = GameSounds.resolve(key)
	if existing then
		return existing
	end

	local spec = SPECS[key]
	assert(spec, `GameSounds.ensure: clave desconocida "{key}"`)

	local audio = SoundService:FindFirstChild(AUDIO_FOLDER_NAME)
	if not (audio and audio:IsA("Folder")) then
		audio = Instance.new("Folder")
		;(audio :: Folder).Name = AUDIO_FOLDER_NAME
		;(audio :: Folder).Parent = SoundService
	end

	local folder = (audio :: Folder):FindFirstChild(spec.folder)
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		;(folder :: Folder).Name = spec.folder
		;(folder :: Folder).Parent = audio
	end

	local sound = Instance.new("Sound")
	sound.Name = spec.name
	sound.Looped = spec.looped == true
	sound.Volume = 0
	sound.Parent = folder
	return sound
end

return GameSounds
