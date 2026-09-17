--!nocheck
--[[
	AuditMix.luau
	SCRIPT DE CONSOLA — pégalo en la Command Bar de Studio para OÍR el balance.

	La tabla de mezcla de SetupSoundService reparte los niveles por rol (cuanto
	más suena algo, más bajo va), pero eso no puede corregir que un asset esté
	grabado más fuerte que otro: eso solo se arregla escuchándolos seguidos.
	Este script los reproduce en fila, te dice cuál suena y en qué nivel, y
	opcionalmente pone la música por debajo para que oigas qué tapa a qué.

	Cómo usarlo
	-----------
	1. Ejecútalo y escucha. Apunta el que se salga (demasiado alto o que
	   desaparece).
	2. Corrige su `volume` en la tabla LAYOUT de `SetupSoundService.luau`.
	3. Vuelve a ejecutar SetupSoundService y luego este. Repite.

	Ajusta los flags de abajo según lo que quieras probar.
]]

-- ── Qué probar ───────────────────────────────────────────────────────────────
local WITH_MUSIC = true     -- música de fondo mientras suenan los efectos
local GAP_SECONDS = 1.1     -- silencio entre sonido y sonido
local TEST_BURSTS = true    -- además, los peores casos de solapamiento

local SoundService = game:GetService("SoundService")

local ORDER = {
	{ folder = "Music", name = "Lobby", skipInSequence = true },
	{ folder = "UI", name = "Click" },
	{ folder = "UI", name = "Open" },
	{ folder = "UI", name = "Close" },
	{ folder = "UI", name = "Error" },
	{ folder = "UI", name = "Purchase" },
	{ folder = "UI", name = "Coin" },
	{ folder = "Gameplay", name = "Hit" },
	{ folder = "Gameplay", name = "Headshot" },
	{ folder = "Gameplay", name = "Elimination" },
	{ folder = "Gameplay", name = "Health" },
}

-- Peores casos reales de solapamiento del juego. Si algo se convierte en un
-- muro de ruido, es aquí donde se oye.
local BURSTS = {
	{ folder = "UI", name = "Coin", count = 10, gap = 0.05,
	  why = "multi-kill: hasta 10 monedas aterrizando en el HUD" },
	{ folder = "Gameplay", name = "Hit", count = 5, gap = 0.08,
	  why = "ráfaga de un arma automática a bocajarro" },
}

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

-- Un SoundGroup NO tiene propiedad `SoundGroup`: se anida PARENTEÁNDOLO dentro
-- de otro. Así que la cadena de ganancia se recorre hacia arriba por `Parent`
-- mientras el padre siga siendo un SoundGroup.
local function effectiveVolume(sound: Sound): number
	local gain = sound.Volume
	local node: Instance? = sound.SoundGroup
	while node and node:IsA("SoundGroup") do
		gain *= (node :: SoundGroup).Volume
		node = node.Parent
	end
	return math.floor(gain * 1000 + 0.5) / 1000
end

local music: Sound? = nil

-- Si el script muere a mitad, la música se queda sonando en Studio para
-- siempre y hay que pararla a mano. Se para pase lo que pase.
local function stopMusic()
	if music and music.IsPlaying then
		music:Stop()
	end
end

local function run()
	print("────────────────────────────────────────────────────────────")
	print("  Audición del mix")
	print("────────────────────────────────────────────────────────────")

	if WITH_MUSIC then
		music = findSound("Music", "Lobby")
		if music and music.SoundId ~= "" then
			music:Play()
			print(`  [cama] Music/Lobby a {effectiveVolume(music)} — todo lo demás debe oírse por encima`)
			task.wait(1.5)
		end
	end

	for _, entry in ORDER do
		if not entry.skipInSequence then
			local sound = findSound(entry.folder, entry.name)
			if not sound then
				print(string.format("  %-22s FALTA en SoundService.Audio", `{entry.folder}/{entry.name}`))
			elseif sound.SoundId == "" then
				print(string.format("  %-22s sin SoundId", `{entry.folder}/{entry.name}`))
			else
				print(string.format("  %-22s vol %.2f  → efectivo %.3f",
					`{entry.folder}/{entry.name}`, sound.Volume, effectiveVolume(sound)))
				SoundService:PlayLocalSound(sound)
				task.wait(GAP_SECONDS)
			end
		end
	end

	if TEST_BURSTS then
		print("────────────────────────────────────────────────────────────")
		print("  Peores casos de solapamiento")
		print("────────────────────────────────────────────────────────────")
		for _, burst in BURSTS do
			local sound = findSound(burst.folder, burst.name)
			if sound and sound.SoundId ~= "" then
				print(`  {burst.folder}/{burst.name} ×{burst.count} — {burst.why}`)
				for _ = 1, burst.count do
					SoundService:PlayLocalSound(sound)
					task.wait(burst.gap)
				end
				task.wait(1.2)
			end
		end
	end

	print("────────────────────────────────────────────────────────────")
	print("  Ajusta los que se salgan en LAYOUT de SetupSoundService.luau")
	print("  y vuelve a ejecutar ese script.")
	print("────────────────────────────────────────────────────────────")
end

task.spawn(function()
	local ok, err = pcall(run)
	stopMusic()
	if not ok then
		warn(`[AuditMix] {err}`)
	end
end)
