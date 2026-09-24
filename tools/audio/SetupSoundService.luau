--!nocheck
--[[
	SetupSoundService.luau
	SCRIPT DE CONSOLA — pégalo entero en la Command Bar de Roblox Studio y pulsa
	Enter. NO es parte del juego (vive en tools/, fuera de los paths de Rojo).

	Qué hace
	--------
	Deja SoundService con esta estructura y te dice qué falta por rellenar:

	    SoundService
	    ├─ Master (SoundGroup)        ← bus de mezcla; baja este y baja todo
	    │   ├─ Music    (SoundGroup)
	    │   ├─ UI       (SoundGroup)
	    │   └─ Gameplay (SoundGroup)
	    ├─ Audio (Folder)             ← ÚNICO sitio donde autorar sonidos
	    │   ├─ Music/     Lobby
	    │   ├─ UI/        Click · Open · Close · Error · Purchase · Coin
	    │   └─ Gameplay/  Hit · Headshot · Elimination · Health · BalloonPop · XpOrb · Confetti · Electrocution · Explosion
	    └─ Runtime (Folder)           ← clones que crea el juego; no tocar

	El juego usa `Sound` + `SoundGroup`, no el API nuevo de audio
	(AudioPlayer/Wire/AudioFader). Si encuentra un montaje de ese API:
	  • Le COPIA el AssetId al `Sound` que le corresponde por nombre, para no
	    perder ninguna ID que ya hubieras pegado.
	  • Aparca el montaje entero en `Audio/_Unsorted/AudioAPI`, con los Script
	    desactivados. No lo borra: lo revisas y lo borras tú.

	Además es idempotente y no destructivo:
	  • Si el sonido ya existe (aunque esté en la ruta vieja) lo MUEVE y lo
	    renombra conservando SoundId, Volume y efectos hijos.
	  • Si no existe lo CREA vacío (SoundId = "") para que solo pegues la ID.
	  • Lo único que borra son `Sound` SIN SoundId que sobran fuera de la
	    estructura: no contienen nada que perder.

	Se puede volver a ejecutar las veces que haga falta. Ctrl+Z lo deshace.
]]

local SoundService = game:GetService("SoundService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

-- ── Contrato con el código ───────────────────────────────────────────────────
-- Estos nombres los leen: GameSounds.luau (cliente), DamageBillboardHandler,
-- NetworkingCallbacks y PickupDropEffect. Si renombras algo aquí, renómbralo
-- también allí o el sonido deja de sonar.
--
-- `legacy` = rutas donde pudo quedar el sonido antes (relativas a SoundService).
-- `players` = nombres de AudioPlayer del API nuevo de los que heredar el AssetId.
--
-- ── LA TABLA DE MEZCLA ──────────────────────────────────────────────────────
-- El volumen que se escribe en Studio es el producto de DOS factores separados:
--
--     volume = role × gain
--
-- `role` — cuánto DEBE sonar ese efecto dentro del juego. Lo decides tú.
--   La regla: cuanto más suena algo, más bajo va. Un click que dispara en cada
--   botón no puede estar al nivel de una eliminación que ocurre cada medio
--   minuto, o el click se come todo lo demás.
--
--     0.20-0.30  continuo   música de fondo, click, hit por bala, moneda
--     0.40-0.50  ocasional  abrir/cerrar panel, pickup de vida, headshot
--     0.50-0.60  puntual    error, compra, eliminación
--
-- `gain` — cuánto hay que compensar ESTE archivo. Sale de medir, no de opinar:
--   lo calcula tools/audio/MeasureLoudness.luau. Mayor que 1 = el asset está
--   grabado flojo; menor que 1 = está grabado fuerte.
--
-- Están separados a propósito. Si fundes ambos en un solo número, cambiar el
-- reparto del juego te obliga a volver a medir, y al revés. Así puedes tocar
-- `role` libremente y `gain` solo cuando cambies el archivo.
--
-- Los `gain` de Gameplay y Music están medidos (2026-09-12, 3 pasadas por
-- sonido, dispersión entre x1.03 y x1.40). Los de UI están a 1.00 SIN MEDIR:
-- son assets nuevos, distintos de los que se midieron entonces. Ejecuta
-- tools/audio/MeasureLoudness.luau y actualízalos.
--
-- Para respetar un volumen tuyo en un Sound concreto, ponle el atributo
-- `MixLocked = true` en Studio y este script no lo tocará.
local LAYOUT = {
	{
		folder = "Music",
		group = "Music",
		sounds = {
			{ name = "Lobby", role = 0.30, gain = 0.32, looped = true,
			  legacy = { "LobbyMusic", "Music/Lobby" },
			  players = { "Lobby", "LobbyMusic", "Music" } },
		},
	},
	{
		folder = "UI",
		group = "UI",
		sounds = {
			{ name = "Click",       role = 0.25, gain = 1.00,
				legacy = { "Audio/UI/UI_ButtonClick", "Audio/Gameplay/Click", "UI/Click" },
				players = { "UI_ButtonClick", "Click" } },
			{ name = "Open",        role = 0.40, gain = 1.00,
				legacy = { "Audio/UI/UI_MenuOpen", "Audio/Gameplay/Open", "UI/Open" },
				players = { "UI_MenuOpen", "Open" } },
			{ name = "Close",       role = 0.40, gain = 1.00,
				legacy = { "Audio/UI/UI_MenuClose", "Audio/Gameplay/Close", "UI/Close" },
				players = { "UI_MenuClose", "Close" } },
			-- Apertura EXCLUSIVA de la tienda; el resto de paneles usan `Open`.
			{ name = "OpenStore",   role = 0.40, gain = 1.00,
				legacy = { "Audio/UI/UI_OpenStore" },
				players = { "UI_OpenStore", "OpenStore" } },
			{ name = "Error",       role = 0.50, gain = 1.00,
				legacy = { "Audio/UI/UI_Error", "Audio/Gameplay/Error", "UI/Error" },
				players = { "UI_Error", "Error" } },
			{ name = "Toggle",      role = 0.30, gain = 1.00,
				legacy = { "Audio/UI/UI_ToggleSwitch" },
				players = { "UI_ToggleSwitch" } },
			{ name = "Notification", role = 0.45, gain = 1.00,
				legacy = { "Audio/UI/UI_MatchNotification" },
				players = { "UI_MatchNotification" } },
			{ name = "Purchase",    role = 0.55, gain = 1.00,
				legacy = { "Audio/UI/Shop_PurchaseSuccess", "Audio/Gameplay/PurchaseLocker", "UI/PurchaseLocker" },
				players = { "Shop_PurchaseSuccess", "PurchaseLocker" } },
			{ name = "Coin",        role = 0.22, gain = 1.00,
				legacy = { "Audio/UI/Reward_CoinPickup", "Audio/Gameplay/Coin", "UI/Coin" },
				players = { "Reward_CoinPickup", "Coin" } },
			-- OJO: en Studio conviven "Reward_LevelUP" y "Reward_LevelUp", que para
			-- Roblox son dos instancias distintas. Gana la que tenga SoundId; la otra
			-- acaba en _Unsorted para que la borres.
			{ name = "LevelUp",     role = 0.55, gain = 1.00,
				legacy = { "Audio/UI/Reward_LevelUP", "Audio/UI/Reward_LevelUp" },
				players = { "Reward_LevelUP", "Reward_LevelUp" } },
			{ name = "FamePassUp",  role = 0.55, gain = 1.00,
				legacy = { "Audio/UI/Reward_FamePassUP", "Audio/UI/Reward_FamePassUp" },
				players = { "Reward_FamePassUP", "Reward_FamePassUp" } },
		},
	},
	{
		folder = "Gameplay",
		group = "Gameplay",
		sounds = {
			{ name = "Hit",         role = 0.30, gain = 0.43,
			  legacy = { "Audio/Gameplay/HitSound" },
			  players = { "HitSound", "Hit" } },
			{ name = "Headshot",    role = 0.45, gain = 2.16,
			  legacy = { "Audio/Gameplay/Headshot" },
			  players = { "Headshot" } },
			{ name = "Elimination", role = 0.60, gain = 0.88,
			  legacy = { "Audio/Gameplay/EliminatedPlayer" },
			  players = { "EliminatedPlayer", "Elimination" } },
			{ name = "Health",      role = 0.40, gain = 1.51,
			  legacy = { "Audio/Gameplay/Health", "Audio/Gameplay/Pickup" },
			  players = { "Health", "Pickup" } },
			{ name = "BalloonPop",  role = 0.35, gain = 1.00,
			  legacy = {},
			  players = { "BalloonPop" } },
			{ name = "XpOrb",       role = 0.30, gain = 1.00,
			  legacy = {},
			  players = { "XpOrb" } },
			{ name = "Confetti",    role = 0.40, gain = 1.00,
			  legacy = {},
			  players = { "Confetti" } },
			{ name = "Electrocution", role = 0.40, gain = 1.00,
			  legacy = {},
			  players = { "Electrocution" } },
			-- 3D en el punto de impacto (NetworkingCallbacks.PlayExplosionVFX).
			{ name = "Explosion",   role = 0.55, gain = 1.00,
			  legacy = {},
			  players = { "Explosion" } },
		},
	},
}

local AUDIO_FOLDER_NAME = "Audio"
local RUNTIME_FOLDER_NAME = "Runtime"
local UNSORTED_FOLDER_NAME = "_Unsorted"
local PARKED_RIG_FOLDER_NAME = "AudioAPI"
local MASTER_GROUP_NAME = "Master"
local MIN_VOLUME, MAX_VOLUME = 0.02, 2.5

-- Clases del API nuevo de audio. El juego no las usa: se aparcan enteras.
local RIG_CLASSES = {
	AudioPlayer = true, AudioDeviceOutput = true, AudioDeviceInput = true,
	AudioListener = true, AudioEmitter = true, AudioFader = true,
	AudioEqualizer = true, AudioCompressor = true, AudioLimiter = true,
	AudioDistortion = true, AudioChorus = true, AudioEcho = true,
	AudioFlanger = true, AudioPitchShifter = true, AudioReverb = true,
	AudioTextToSpeech = true, AudioRecorder = true, AudioAnalyzer = true,
	AudioSearchParams = true, Wire = true,
}

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

-- ── Informe ──────────────────────────────────────────────────────────────────

local report = {}
local function log(status: string, detail: string)
	table.insert(report, { status = status, detail = detail })
end

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function getOrCreate(parent: Instance, name: string, className: string): Instance
	for _, child in parent:GetChildren() do
		if child.Name == name and child.ClassName == className then
			return child
		end
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

-- Resuelve "Audio/Gameplay/Click" desde SoundService. Busca por nombre Y clase:
-- con el API nuevo conviven un AudioPlayer y un Sound llamados igual, y un
-- FindFirstChild a secas devuelve el que esté primero.
local function resolveSound(path: string): Sound?
	local node: Instance? = SoundService
	local segments = {}
	for segment in string.gmatch(path, "[^/]+") do
		table.insert(segments, segment)
	end

	for index, segment in segments do
		if not node then
			return nil
		end
		if index == #segments then
			for _, child in node:GetChildren() do
				if child.Name == segment and child:IsA("Sound") then
					return child
				end
			end
			return nil
		end
		node = node:FindFirstChild(segment)
	end
	return nil
end

local function isDescendantOf(inst: Instance, ancestor: Instance?): boolean
	return ancestor ~= nil and inst:IsDescendantOf(ancestor)
end

local function round(value: number): number
	return math.floor(value * 1000 + 0.5) / 1000
end

local recording = nil
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Setup SoundService")
end)

-- ── Estructura base ──────────────────────────────────────────────────────────

-- Buses de mezcla. Cada `Sound` apunta a su bus por la propiedad `SoundGroup`,
-- y los buses se anidan bajo Master PARENTEÁNDOLOS: un SoundGroup no tiene
-- propiedad `SoundGroup` con la que rutearse a otro.
local master = getOrCreate(SoundService, MASTER_GROUP_NAME, "SoundGroup") :: SoundGroup
local groups: { [string]: SoundGroup } = {}
for _, category in LAYOUT do
	local group = getOrCreate(master, category.group, "SoundGroup") :: SoundGroup
	groups[category.group] = group
end

local audioFolder = getOrCreate(SoundService, AUDIO_FOLDER_NAME, "Folder")
local runtimeFolder = getOrCreate(SoundService, RUNTIME_FOLDER_NAME, "Folder")

-- ── Censo de AudioPlayers (API nuevo) antes de tocar nada ────────────────────
-- Se indexan por nombre para poder heredarles el AssetId. Los que no acaben
-- cediendo su ID a ningún Sound se reportan aparte, para que no se pierdan.

local playersByName: { [string]: { Instance } } = {}
local rigInstances: { Instance } = {}

for _, descendant in SoundService:GetDescendants() do
	if RIG_CLASSES[descendant.ClassName] then
		table.insert(rigInstances, descendant)
		if descendant.ClassName == "AudioPlayer" then
			local bucket = playersByName[descendant.Name]
			if not bucket then
				bucket = {}
				playersByName[descendant.Name] = bucket
			end
			table.insert(bucket, descendant)
		end
	end
end

local function assetIdOf(player: Instance): string
	local ok, value = pcall(function()
		return (player :: any).AssetId
	end)
	if ok and typeof(value) == "string" then
		return value
	end
	return ""
end

local donatedPlayers: { [Instance]: boolean } = {}

--- Busca entre los AudioPlayer con esos nombres el primero que tenga AssetId.
local function inheritAssetId(names: { string }?): (string?, string?)
	if not names then
		return nil, nil
	end
	for _, name in names do
		for _, player in playersByName[name] or {} do
			if not donatedPlayers[player] then
				local assetId = assetIdOf(player)
				if assetId ~= "" then
					donatedPlayers[player] = true
					return assetId, name
				end
			end
		end
	end
	return nil, nil
end

-- ── Migración sonido a sonido ────────────────────────────────────────────────

local claimed: { [Instance]: boolean } = {}
local missingIds = 0

for _, category in LAYOUT do
	local categoryFolder = getOrCreate(audioFolder, category.folder, "Folder")
	local group = groups[category.group]

	for _, spec in category.sounds do
		local targetPath = `{AUDIO_FOLDER_NAME}/{category.folder}/{spec.name}`

		-- Candidatos por orden de preferencia: primero la ruta definitiva, luego
		-- las viejas. Pero GANA EL PRIMERO QUE TENGA SoundId: si una pasada
		-- anterior dejó un placeholder vacío en la ruta buena y el sonido de
		-- verdad sigue en la ruta vieja, queremos el de verdad.
		local candidates = { targetPath }
		for _, legacyPath in spec.legacy do
			table.insert(candidates, legacyPath)
		end

		local sound: Sound? = nil
		local fallback: Sound? = nil
		for _, path in candidates do
			local found = resolveSound(path)
			if found and not claimed[found] then
				if found.SoundId ~= "" then
					sound = found
					break
				end
				fallback = fallback or found
			end
		end
		sound = sound or fallback

		local status = "OK"
		if sound then
			if sound.Parent ~= categoryFolder or sound.Name ~= spec.name then
				status = "MIGRADO"
			end
			if sound.Parent ~= categoryFolder then
				sound.Parent = categoryFolder
			end
			if sound.Name ~= spec.name then
				sound.Name = spec.name
			end
		else
			-- Nuevo: se crea vacío para que solo pegues la ID.
			local created = Instance.new("Sound")
			created.Name = spec.name
			created.SoundId = ""
			created.Volume = math.clamp(spec.role * (spec.gain or 1), MIN_VOLUME, MAX_VOLUME)
			created.Parent = categoryFolder
			sound = created
			status = "CREADO"
		end

		-- Si sigue sin ID, heredarla del AudioPlayer equivalente del API nuevo.
		local inheritedFrom: string? = nil
		if sound.SoundId == "" then
			local assetId, sourceName = inheritAssetId(spec.players)
			if assetId then
				sound.SoundId = assetId
				inheritedFrom = sourceName
				status = "ADOPTADO"
			end
		end

		claimed[sound] = true
		sound.SoundGroup = group
		-- `Looped` es parte del contrato: la música tiene que repetirse y un
		-- one-shot en bucle no se calla nunca. Se fuerza siempre.
		sound.Looped = spec.looped == true

		-- El volumen viene de la tabla de mezcla, no de lo que hubiera en Studio:
		-- es lo que mantiene el balance entre sonidos. `MixLocked` es la salida
		-- de emergencia para un sonido que quieras ajustar a mano.
		local targetVolume = math.clamp(spec.role * (spec.gain or 1), MIN_VOLUME, MAX_VOLUME)
		local previousVolume = sound.Volume

		-- `Volume` es un valor VIVO: la música lo tweenea entre sus estados y un
		-- pool puede tocarlo. El atributo guarda el nivel AUTORADO, que es el
		-- único al que puede volver el código en runtime. Sin él, la música que
		-- lee su nivel de referencia al arrancar leería lo que dejó el último
		-- tween (a veces 0, en partida) y se quedaría muda.
		sound:SetAttribute("MixVolume", targetVolume)
		local volumeNote = ""
		if sound:GetAttribute("MixLocked") then
			volumeNote = `  · vol {round(previousVolume)} (MixLocked, sin tocar)`
		elseif math.abs(previousVolume - targetVolume) > 0.001 then
			sound.Volume = targetVolume
			volumeNote = `  · vol {round(previousVolume)} → {round(targetVolume)}`
		end

		local detail = `{AUDIO_FOLDER_NAME}/{category.folder}/{spec.name}`
		if inheritedFrom then
			log(status, `{detail}  ← AssetId de AudioPlayer "{inheritedFrom}"{volumeNote}`)
		elseif sound.SoundId == "" then
			missingIds += 1
			log(status, `{detail}  ← FALTA ID{volumeNote}`)
		else
			log(status, `{detail}{volumeNote}`)
		end
	end
end

-- ── Aparcar el montaje del API nuevo ─────────────────────────────────────────

local unsortedFolder: Instance? = audioFolder:FindFirstChild(UNSORTED_FOLDER_NAME)
local function ensureUnsorted(): Instance
	unsortedFolder = getOrCreate(audioFolder, UNSORTED_FOLDER_NAME, "Folder")
	return unsortedFolder :: Instance
end

-- Solo se mueven las raíces: los Wire y efectos hijos viajan con su padre.
local function insideAnotherRig(inst: Instance): boolean
	local parent = inst.Parent
	while parent and parent ~= SoundService do
		if RIG_CLASSES[parent.ClassName] then
			return true
		end
		parent = parent.Parent
	end
	return false
end

local parkedRig = 0
local orphanPlayers: { string } = {}
-- Se resuelve la carpeta de pasadas anteriores ANTES del bucle. Si se dejaba en
-- nil, en una reejecución el primer trasto ya aparcado se "movía" otra vez a la
-- carpeta donde ya estaba y el informe cantaba un aparcado que no existía.
local rigFolder: Instance? = if unsortedFolder
	then unsortedFolder:FindFirstChild(PARKED_RIG_FOLDER_NAME)
	else nil

local function parkIntoRigFolder(inst: Instance)
	if not rigFolder then
		rigFolder = getOrCreate(ensureUnsorted(), PARKED_RIG_FOLDER_NAME, "Folder")
	end
	inst.Parent = rigFolder
	parkedRig += 1
end

for _, inst in rigInstances do
	if inst.Parent ~= nil
		and not insideAnotherRig(inst)
		and not isDescendantOf(inst, rigFolder)
	then
		if inst.ClassName == "AudioPlayer" and not donatedPlayers[inst] and assetIdOf(inst) ~= "" then
			table.insert(orphanPlayers, inst.Name)
		end
		parkIntoRigFolder(inst)
	end
end

-- Carpetas que solo contenían montaje del API nuevo (p. ej. "Busses"), y los
-- Script sueltos que lo cableaban. Los Script se desactivan antes de aparcar:
-- si alguno reproducía audio al arrancar, deja de hacerlo.
for _, child in audioFolder:GetChildren() do
	local isLayoutFolder = false
	for _, category in LAYOUT do
		if child.Name == category.folder then
			isLayoutFolder = true
			break
		end
	end

	if SCRIPT_CLASSES[child.ClassName] then
		pcall(function()
			(child :: any).Disabled = true
		end)
		log("APARCADO", `{child.Name} ({child.ClassName}, desactivado)`)
		parkIntoRigFolder(child)
	elseif child:IsA("Folder")
		and not isLayoutFolder
		and child.Name ~= UNSORTED_FOLDER_NAME
	then
		-- Poda en profundidad: aparcar los faders de `Busses/UI` deja `Busses/UI`
		-- y `Busses/World` vacías, y con ellas dentro `Busses` tampoco está
		-- vacía. Hay que vaciar de abajo arriba.
		local function prune(folder: Instance): boolean
			for _, grandchild in folder:GetChildren() do
				if grandchild:IsA("Folder") then
					prune(grandchild)
				end
			end
			if #folder:GetChildren() == 0 then
				folder:Destroy()
				return true
			end
			return false
		end
		if prune(child) then
			log("BORRADO", `{AUDIO_FOLDER_NAME}/{child.Name} (carpeta vacía)`)
		end
	end
end

if parkedRig > 0 then
	log("APARCADO", `{parkedRig} instancia(s) del API nuevo → {UNSORTED_FOLDER_NAME}/{PARKED_RIG_FOLDER_NAME}`)
end
for _, name in orphanPlayers do
	log("AVISO", `AudioPlayer "{name}" tiene AssetId y no lo usa nadie — está en {UNSORTED_FOLDER_NAME}/{PARKED_RIG_FOLDER_NAME}`)
end

-- ── Barrido: Sounds sueltos ──────────────────────────────────────────────────
-- Los que no tienen SoundId no contienen nada que perder: se borran. Los que sí
-- tienen ID se aparcan para que los revises.

local parked = 0
local deletedEmpty = 0
local strays: { Sound } = {}

for _, descendant in SoundService:GetDescendants() do
	if descendant:IsA("Sound")
		and not claimed[descendant]
		and not isDescendantOf(descendant, runtimeFolder)
	then
		table.insert(strays, descendant)
	end
end

for _, stray in strays do
	if stray.SoundId == "" then
		log("BORRADO", `{stray.Name} (Sound sin SoundId, fuera de la estructura)`)
		stray:Destroy()
		deletedEmpty += 1
	elseif not isDescendantOf(stray, unsortedFolder) then
		local origin = stray:GetFullName()
		stray.Parent = ensureUnsorted()
		log("APARCADO", `{origin}`)
		parked += 1
	else
		parked += 1
	end
end

-- ── Buses a ganancia unidad ──────────────────────────────────────────────────
-- Con Master 0.5 × bus 0.5 todo sale al 25%, y se acaba compensando a lo bruto
-- subiendo Sound.Volume a 5. Eso destruye el balance: cada sonido acaba con un
-- factor distinto y ya no se sabe cuál está alto de verdad. Los buses se quedan
-- a 1 y TODO el balance vive en la tabla de mezcla; los buses son solo para que
-- el jugador baje música o efectos por separado.

local busesChanged = false
for _, category in LAYOUT do
	local group = groups[category.group]
	if group.Volume ~= 1 then
		busesChanged = true
		group.Volume = 1
	end
end
if master.Volume ~= 1 then
	busesChanged = true
	master.Volume = 1
end
if busesChanged then
	log("MEZCLA", "buses Master/Music/UI/Gameplay puestos a 1.0 (ganancia unidad)")
end

-- Los clones de runtime se regeneran solos en cada sesión; vaciarlos evita que
-- se acumulen en el archivo del place.
local runtimeLeftovers = #runtimeFolder:GetChildren()
if runtimeLeftovers > 0 then
	runtimeFolder:ClearAllChildren()
	log("BORRADO", `{RUNTIME_FOLDER_NAME}: {runtimeLeftovers} clone(s) de sesiones previas`)
end

-- Carpetas sueltas de la estructura vieja que ya no contienen nada.
for _, child in SoundService:GetChildren() do
	if child:IsA("Folder")
		and child ~= audioFolder
		and child ~= runtimeFolder
		and #child:GetChildren() == 0
	then
		log("BORRADO", `{child.Name} (carpeta vacía)`)
		child:Destroy()
	end
end

pcall(function()
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
end)

-- ── Informe ──────────────────────────────────────────────────────────────────

local ORDER = {
	ADOPTADO = 1, CREADO = 2, MIGRADO = 3, MEZCLA = 4,
	APARCADO = 5, BORRADO = 6, AVISO = 7, OK = 8,
}
table.sort(report, function(a, b)
	if a.status ~= b.status then
		return (ORDER[a.status] or 9) < (ORDER[b.status] or 9)
	end
	return a.detail < b.detail
end)

print("────────────────────────────────────────────────────────────")
print("  SoundService ordenado")
print("────────────────────────────────────────────────────────────")
for _, entry in report do
	print(string.format("  %-9s %s", entry.status, entry.detail))
end
print("────────────────────────────────────────────────────────────")
if missingIds > 0 then
	print(`  Faltan {missingIds} SoundId. Rellénalos en {AUDIO_FOLDER_NAME}/ y listo.`)
else
	print("  Todos los sonidos tienen SoundId.")
end
if parked > 0 or parkedRig > 0 then
	print(`  Revisa {AUDIO_FOLDER_NAME}/{UNSORTED_FOLDER_NAME}: cuando confirmes que todo suena, bórralo entero.`)
end
if deletedEmpty > 0 then
	print(`  Borrados {deletedEmpty} Sound vacíos que sobraban.`)
end
print("────────────────────────────────────────────────────────────")
