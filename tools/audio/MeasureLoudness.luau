--!nocheck
--[[
	MeasureLoudness.luau
	SCRIPT DE CONSOLA — pégalo en la Command Bar de Studio.

	El problema que resuelve
	------------------------
	`Volume` no es sonoridad: es un multiplicador sobre lo fuerte que se grabó
	el asset. Dos sonidos a 0.40 pueden llevarse 20 dB. Por eso la tabla de
	roles de SetupSoundService reparte bien sobre el papel y aun así unos tapan
	a otros: no sabe lo que trae dentro cada archivo.

	Este script lo MIDE. Monta un medidor temporal con el API nuevo de audio
	(AudioPlayer → AudioAnalyzer → AudioDeviceOutput), reproduce cada asset a
	ganancia 1, muestrea su nivel RMS y calcula el `Volume` que iguala a todos a
	una misma sonoridad de referencia. Encima aplica el nivel de ROL, así que la
	tabla vuelve a significar lo que dice.

	    gain = referencia / sonoridad medida
	    volume = role × gain      ← lo calcula SetupSoundService

	Lo que sale de aquí es el `gain` de cada sonido, no su volumen final: en la
	tabla LAYOUT el reparto por rol y la compensación del archivo viven en
	columnas separadas, para que puedas tocar el reparto sin volver a medir.

	Cómo se define "sonoridad" aquí
	-------------------------------
	La media de los 400 ms MÁS FUERTES del asset, que es la ventana de sonoridad
	momentánea que usan los medidores de verdad.

	Es importante que sea una ventana de TIEMPO FIJO y no una fracción del
	archivo. Con una fracción (p. ej. "el 20% de frames más altos") el resultado
	depende de la duración: en un sonido de 0.1 s ese 20% es un solo frame —el
	pico— y en uno de 3.5 s son cuarenta frames que arrastran toda la cola
	silenciosa. Acabas midiendo duración disfrazada de volumen.

	LA COLUMNA QUE IMPORTA ES "disp"
	--------------------------------
	Es la dispersión entre las pasadas de un mismo sonido: máximo dividido entre
	mínimo. Cerca de ×1.0 significa que las tres pasadas coincidieron y la cifra
	es de fiar. Si sube de ×2 no te creas ese sonido, y por encima de
	MAX_SPREAD se marca FALLIDA sola.

	Fiabilidad
	----------
	Solo se puede muestrear una vez por frame (~60 Hz), así que un one-shot
	corto da pocas muestras. Para que el número sea de fiar:
	  • Se espera al ARRANQUE real antes de medir (el motor tiene latencia; sin
	    esto, en un sonido corto se mide sobre todo silencio).
	  • Se mide con margen tras el final, y nunca menos de MIN_MEASURE_SECONDS.
	  • Se descarta una reproducción de calentamiento y se miden REPEATS pasadas,
	    quedándose con la mediana.
	  • Si las pasadas no se parecen entre sí, o el nivel es absurdamente bajo,
	    la medida se marca FALLIDA y ese sonido se queda en su nivel de rol en
	    vez de generar una corrección disparatada.

	Qué esperar
	-----------
	  • Uno o dos minutos. VAS A OÍR cada sonido varias veces: el analizador solo
	    recibe señal si la cadena llega hasta la salida.
	  • Al acabar imprime la tabla lista para pegar en `LAYOUT` de
	    SetupSoundService.luau. PÉGALA: si no, la próxima pasada de ese script
	    revierte los volúmenes.
	  • El medidor temporal se destruye siempre, incluso si algo falla.

	El RMS no es sonoridad percibida (eso sería LUFS, con ponderación de
	frecuencia). Esto elimina las diferencias gordas; el retoque fino final sigue
	siendo de oído con AuditMix.
]]

local SoundService = game:GetService("SoundService")

-- ── Config ───────────────────────────────────────────────────────────────────
-- Arranca en false A PROPÓSITO: primero miras la columna "disp" del informe y
-- decides si te fías. Ponlo en true y reejecuta cuando las cifras sean estables.
local APPLY_TO_STUDIO = false
local REPEATS = 3                 -- pasadas por sonido (se usa la mediana)
local LOUDNESS_WINDOW = 0.4       -- s de contenido más fuerte que definen la sonoridad
local LOAD_TIMEOUT = 6            -- s de espera a que cargue el asset
local ONESHOT_MAX_SECONDS = 2.0   -- tope de ventana para un one-shot
local MUSIC_SECONDS = 3           -- cuánto medir de un sonido en bucle
local TAIL_PADDING = 0.35         -- margen tras el final, para la latencia del motor
local MIN_MEASURE_SECONDS = 0.9   -- suelo de ventana, para juntar frames suficientes
local ONSET_TIMEOUT = 0.6         -- s esperando a que arranque de verdad
local ONSET_THRESHOLD = 0.0005    -- nivel que cuenta como "ya está sonando"
-- Calentamiento LARGO a propósito. La causa más probable de una medida a cero
-- es que el motor todavía estuviera bufferizando el asset: TimeLength llega con
-- los metadatos, pero el audio puede tardar más. Esta reproducción descartada
-- fuerza el buffer antes de medir en serio.
local WARMUP_SECONDS = 0.6

-- Criterios de medida fallida.
local FAILURE_FLOOR = 0.002       -- por debajo de esto, no se midió nada real
local MAX_SPREAD = 3.0            -- máx/mín entre repeticiones antes de desconfiar

local MIN_VOLUME, MAX_VOLUME = 0.02, 2.5

-- Niveles de ROL. DEBEN coincidir con la tabla LAYOUT de SetupSoundService.luau:
-- este script solo corrige la sonoridad del asset; el reparto por rol lo decides
-- tú allí.
local ROLES = {
	{ folder = "Music",    name = "Lobby",       role = 0.30, looped = true },
	{ folder = "UI",       name = "Click",        role = 0.25 },
	{ folder = "UI",       name = "Open",         role = 0.40 },
	{ folder = "UI",       name = "OpenStore",    role = 0.40 },
	{ folder = "UI",       name = "Close",        role = 0.40 },
	{ folder = "UI",       name = "Error",        role = 0.50 },
	{ folder = "UI",       name = "Toggle",       role = 0.30 },
	{ folder = "UI",       name = "Notification", role = 0.45 },
	{ folder = "UI",       name = "Purchase",     role = 0.55 },
	{ folder = "UI",       name = "Coin",         role = 0.22 },
	{ folder = "UI",       name = "LevelUp",      role = 0.55 },
	{ folder = "UI",       name = "FamePassUp",   role = 0.55 },
	{ folder = "Gameplay", name = "Hit",         role = 0.30 },
	{ folder = "Gameplay", name = "Headshot",    role = 0.45 },
	{ folder = "Gameplay", name = "Elimination", role = 0.60 },
	{ folder = "Gameplay", name = "Health",      role = 0.40 },
}

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function findSound(folderName: string, name: string): Sound?
	local audio = SoundService:FindFirstChild("Audio")
	local folder = audio and audio:FindFirstChild(folderName)
	if not folder then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child.Name == name and child:IsA("Sound") then
			return child
		end
	end
	return nil
end

local function round(value: number, places: number): number
	local factor = 10 ^ places
	return math.floor(value * factor + 0.5) / factor
end

local function median(values: { number }): number
	local sorted = table.clone(values)
	table.sort(sorted)
	local count = #sorted
	if count == 0 then
		return 0
	end
	if count % 2 == 1 then
		return sorted[(count + 1) // 2]
	end
	return (sorted[count // 2] + sorted[count // 2 + 1]) / 2
end

--- Lee una propiedad sin reventar si no existe en esta versión del motor.
local function readProperty(inst: Instance, property: string): (boolean, any)
	return pcall(function()
		return (inst :: any)[property]
	end)
end

local function writeProperty(inst: Instance, property: string, value: any): boolean
	return (pcall(function()
		(inst :: any)[property] = value
	end))
end

local function levelOf(analyzer: Instance): number
	local ok, value = readProperty(analyzer, "RmsLevel")
	return (ok and tonumber(value)) or 0
end

-- ── Montaje del medidor ──────────────────────────────────────────────────────
-- Cadena: AudioPlayer → Wire → AudioAnalyzer → Wire → AudioDeviceOutput.
-- El analizador solo ve señal si la cadena llega a una salida; por eso se oye.

local probe: Folder? = nil

local function teardown()
	if probe then
		probe:Destroy()
		probe = nil
	end
end

local function buildProbe(): (any?, string?)
	local folder = Instance.new("Folder")
	folder.Name = "_MixProbe"
	probe = folder

	local ok, player = pcall(Instance.new, "AudioPlayer")
	if not ok then
		return nil, "este Studio no tiene AudioPlayer (API nuevo de audio no disponible)"
	end
	local okA, analyzer = pcall(Instance.new, "AudioAnalyzer")
	if not okA then
		return nil, "este Studio no tiene AudioAnalyzer"
	end
	local okO, output = pcall(Instance.new, "AudioDeviceOutput")
	if not okO then
		return nil, "este Studio no tiene AudioDeviceOutput"
	end

	-- Comprobar las propiedades ANTES de medir: más vale un mensaje claro ahora
	-- que un stack trace a mitad de la pasada.
	for inst, property in { [player] = "AssetId", [analyzer] = "RmsLevel" } do
		local exists = readProperty(inst, property)
		if not exists then
			return nil, `{inst.ClassName} no tiene la propiedad "{property}" en esta versión`
		end
	end

	local wireIn = Instance.new("Wire")
	local wireOut = Instance.new("Wire")
	local wired = pcall(function()
		wireIn.SourceInstance = player
		wireIn.TargetInstance = analyzer
		wireOut.SourceInstance = analyzer
		wireOut.TargetInstance = output
	end)
	if not wired then
		return nil, "no se pudo cablear (Wire.SourceInstance / TargetInstance)"
	end

	player.Parent = folder
	analyzer.Parent = folder
	output.Parent = folder
	wireIn.Parent = folder
	wireOut.Parent = folder
	folder.Parent = SoundService

	writeProperty(player, "Volume", 1)

	local hasTimeLength = readProperty(player, "TimeLength")
	if not hasTimeLength then
		print("  Aviso: AudioPlayer no expone TimeLength; se medirá con ventana fija.")
	end

	return { player = player, analyzer = analyzer, hasTimeLength = hasTimeLength }, nil
end

local function stopPlayer(player: Instance)
	pcall(function()
		player:Stop()
	end)
end

local function startPlayer(player: Instance): boolean
	writeProperty(player, "TimePosition", 0)
	return (pcall(function()
		player:Play()
	end))
end

--- Una pasada. Devuelve la sonoridad (media de los LOUDNESS_WINDOW s más
--- fuertes) y el pico observado, o nil si ni siquiera arrancó.
local function measureOnce(rig: any, window: number): (number?, number)
	local player, analyzer = rig.player, rig.analyzer

	if not startPlayer(player) then
		return nil, 0
	end

	-- Esperar al arranque real. El motor tarda en sacar la señal, y en un
	-- one-shot corto empezar a contar antes significa medir silencio.
	local onsetDeadline = os.clock() + ONSET_TIMEOUT
	local started = false
	repeat
		if levelOf(analyzer) > ONSET_THRESHOLD then
			started = true
			break
		end
		task.wait()
	until os.clock() > onsetDeadline

	local samples = {}
	local peak = 0
	local begun = os.clock()
	local stopAt = begun + window
	repeat
		local value = levelOf(analyzer)
		table.insert(samples, value)
		if value > peak then
			peak = value
		end
		task.wait()
	until os.clock() >= stopAt

	stopPlayer(player)

	if not started or #samples == 0 then
		return nil, peak
	end

	-- Primero se descartan los frames MUDOS. La ventana de medición es más larga
	-- que el sonido (lleva margen y un suelo mínimo), así que un one-shot corto
	-- deja un montón de silencio detrás. Sin filtrarlo, "los 400 ms más fuertes"
	-- de un click de 0.12 s serían 0.12 s de sonido y 0.28 s de nada, y saldría
	-- artificialmente bajo: el mismo sesgo por duración de antes, al revés.
	local floorLevel = math.max(peak * 0.05, ONSET_THRESHOLD)
	local active = {}
	for _, value in samples do
		if value >= floorLevel then
			table.insert(active, value)
		end
	end
	if #active < 2 then
		return nil, peak
	end

	-- Ventana de tiempo FIJA sobre lo que suena: la media de los 400 ms más
	-- fuertes, o del sonido entero si dura menos. Así un one-shot de 0.1 s y una
	-- música de 3 s se comparan en igualdad de condiciones.
	local elapsed = math.max(os.clock() - begun, 0.001)
	local framesPerSecond = #samples / elapsed
	local windowFrames = math.max(math.floor(LOUDNESS_WINDOW * framesPerSecond + 0.5), 1)
	local take = math.min(windowFrames, #active)

	table.sort(active, function(a, b)
		return a > b
	end)
	local sum = 0
	for index = 1, take do
		sum += active[index]
	end
	return sum / take, peak
end

--- Mide un asset entero: carga, calentamiento descartado y REPEATS pasadas.
local function measure(rig: any, assetId: string, looped: boolean): any
	local player = rig.player

	stopPlayer(player)
	writeProperty(player, "AssetId", assetId)
	writeProperty(player, "Looping", looped)

	local window
	if rig.hasTimeLength then
		local deadline = os.clock() + LOAD_TIMEOUT
		local length = 0
		repeat
			local ok, value = readProperty(player, "TimeLength")
			length = (ok and tonumber(value)) or 0
			if length > 0 then
				break
			end
			task.wait(0.1)
		until os.clock() > deadline

		if length <= 0 then
			return { failure = "no cargó (asset privado, borrado, o sin permiso)" }
		end
		window = if looped
			then MUSIC_SECONDS
			else math.min(length, ONESHOT_MAX_SECONDS) + TAIL_PADDING
	else
		task.wait(1)
		window = if looped then MUSIC_SECONDS else ONESHOT_MAX_SECONDS + TAIL_PADDING
	end
	window = math.max(window, MIN_MEASURE_SECONDS)

	-- Calentamiento descartado: la primera reproducción tras asignar AssetId
	-- puede arrastrar la decodificación y sale sistemáticamente más baja.
	if startPlayer(player) then
		task.wait(WARMUP_SECONDS)
		stopPlayer(player)
		task.wait(0.1)
	end

	local readings = {}
	local peak = 0
	for _ = 1, REPEATS do
		local loudness, runPeak = measureOnce(rig, window)
		if loudness then
			table.insert(readings, loudness)
		end
		if runPeak > peak then
			peak = runPeak
		end
		task.wait(0.1)
	end

	if #readings == 0 then
		return { failure = "el analizador no devolvió señal" }
	end

	local value = median(readings)
	local low, high = readings[1], readings[1]
	for _, reading in readings do
		low = math.min(low, reading)
		high = math.max(high, reading)
	end
	local spread = if low > 0 then high / low else math.huge

	local failure: string? = nil
	if value < FAILURE_FLOOR then
		failure = `nivel casi nulo ({round(value, 5)}) — medida no fiable`
	elseif spread > MAX_SPREAD then
		failure = `las {#readings} pasadas no coinciden (×{round(spread, 1)} entre sí)`
	end

	return { loudness = value, peak = peak, spread = spread, failure = failure }
end

-- ── Pasada ───────────────────────────────────────────────────────────────────

local function run()
	print("────────────────────────────────────────────────────────────")
	print("  Medición de sonoridad")
	print(`  {REPEATS} pasadas por sonido. Uno o dos minutos, y se oye todo.`)
	print("────────────────────────────────────────────────────────────")

	local rig, buildError = buildProbe()
	if not rig then
		warn(`[MeasureLoudness] {buildError}`)
		print("  No se pudo montar el medidor. Sigue con el método de oído:")
		print("  ejecuta AuditMix y ajusta a ojo en LAYOUT.")
		return
	end

	local results = {}
	local failed = {}

	for _, entry in ROLES do
		local label = `{entry.folder}/{entry.name}`
		local sound = findSound(entry.folder, entry.name)

		if not sound then
			print(string.format("  %-22s no existe en SoundService.Audio", label))
			table.insert(failed, { entry = entry, reason = "no existe" })
		elseif sound.SoundId == "" then
			print(string.format("  %-22s sin SoundId", label))
			table.insert(failed, { entry = entry, reason = "sin SoundId" })
		else
			local measured = measure(rig, sound.SoundId, entry.looped == true)
			if measured.failure then
				print(string.format("  %-22s FALLIDA — %s", label, measured.failure))
				table.insert(failed, { entry = entry, reason = measured.failure })
			else
				print(string.format("  %-22s rms %.4f   pico %.4f   disp ×%.2f",
					label, measured.loudness, measured.peak, measured.spread))
				table.insert(results, {
					entry = entry,
					sound = sound,
					loudness = measured.loudness,
					spread = measured.spread,
				})
			end
		end
	end

	if #results < 2 then
		warn("[MeasureLoudness] no hay suficientes medidas válidas para comparar nada")
		return
	end

	-- Referencia = mediana de lo medido. Así las correcciones se reparten arriba
	-- y abajo y los volúmenes finales se quedan cerca de los niveles de rol.
	local values = {}
	for _, result in results do
		table.insert(values, result.loudness)
	end
	local reference = median(values)

	print("────────────────────────────────────────────────────────────")
	print(string.format("  Referencia (mediana de %d medidas): %.4f", #results, reference))
	print("────────────────────────────────────────────────────────────")
	print(string.format("  %-22s %6s %7s %8s", "sonido", "role", "gain", "volumen"))

	local clamped = {}
	for _, result in results do
		local correction = reference / result.loudness
		local raw = result.entry.role * correction
		local final = math.clamp(raw, MIN_VOLUME, MAX_VOLUME)
		if math.abs(final - raw) > 0.0001 then
			table.insert(clamped, result.entry.name)
		end
		result.volume = round(final, 3)
		result.gain = round(correction, 2)

		print(string.format("  %-22s %6.2f %7.2f %8.3f",
			`{result.entry.folder}/{result.entry.name}`,
			result.entry.role, result.gain, result.volume))

		if APPLY_TO_STUDIO then
			result.sound.Volume = result.volume
		end
	end

	if #failed > 0 then
		print("────────────────────────────────────────────────────────────")
		print("  Sin medida fiable — se quedan en su nivel de rol:")
		for _, item in failed do
			print(string.format("  %-22s %s",
				`{item.entry.folder}/{item.entry.name}`, item.reason))
		end
	end

	print("────────────────────────────────────────────────────────────")
	print("  ACTUALIZA el campo `gain` de cada sonido en LAYOUT de")
	print("  SetupSoundService.luau con estos valores:")
	print("────────────────────────────────────────────────────────────")
	for _, result in results do
		print(string.format("    %-12s gain = %.2f", result.entry.name, result.gain))
	end
	for _, item in failed do
		print(string.format("    %-12s gain = 1.00   -- sin medir", item.entry.name))
	end
	print("────────────────────────────────────────────────────────────")

	-- Un asset que necesita mucho boost está grabado muy por debajo del resto.
	-- Subirlo por software también le sube el ruido de fondo.
	local quiet = {}
	for _, result in results do
		if result.gain >= 2 then
			table.insert(quiet, `{result.entry.name} (×{result.gain})`)
		end
	end
	if #quiet > 0 then
		print("  Grabados MUY por debajo del resto (más de 6 dB):")
		print(`    {table.concat(quiet, ", ")}`)
		print("  Se compensan igual, pero subirlos también sube su ruido de fondo.")
		print("  Si suenan sucios o delgados, cambia el asset en vez de subirlo más.")
		print("────────────────────────────────────────────────────────────")
	end

	local unstable = 0
	for _, result in results do
		if result.spread > 1.5 then
			unstable += 1
		end
	end
	if unstable > 0 then
		print(`  OJO: {unstable} sonido(s) con dispersión > x1.5 entre pasadas.`)
		print("  Esas cifras son flojas aunque no salgan marcadas como fallidas.")
	else
		print("  Las pasadas coinciden en todos: las cifras son de fiar.")
	end

	if APPLY_TO_STUDIO then
		print("  Aplicado en Studio. Ejecuta AuditMix para escucharlo.")
	else
		print("  NO se ha tocado nada en Studio (APPLY_TO_STUDIO = false).")
	end
	if #clamped > 0 then
		warn(`[MeasureLoudness] tope alcanzado en: {table.concat(clamped, ", ")} — `
			.. "ese asset está grabado muy fuera de rango, plantéate sustituirlo")
	end
end

task.spawn(function()
	local ok, err = pcall(run)
	teardown()
	if not ok then
		warn(`[MeasureLoudness] {err}`)
	end
end)
