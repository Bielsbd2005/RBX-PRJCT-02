--!strict
--[[
	HitVFX/Config.luau — Ajustes del sistema de VFX de impacto de balas.

	Sólo hay DOS efectos: "Body" (impacto en cuerpo) y "Headshot" (impacto en
	cabeza). Los impactos contra el mundo (suelo, metal, ...) no producen nada.

	Los efectos viven SIEMPRE en una carpeta de Studio, nunca en código:

	    ReplicatedStorage/HitVFX/
	        Body        ← Attachment (o Part) con tus ParticleEmitters + Sounds
	        Headshot    ← idem

	Cada plantilla (nombrada EXACTO "Body" / "Headshot") contiene:
	    · uno o varios ParticleEmitter  → atributo opcional "EmitCount" (number,
	        nº de partículas por ráfaga; def. 15). En móvil se multiplica por
	        Config.MobileScale.
	    · uno o varios Sound            → se elige uno al azar por impacto.

	El motor clona la plantilla, la orienta a la normal del impacto (las
	partículas salen "hacia arriba" del Attachment → EmissionDirection = Top) y
	la reusa en pool. Tuneas todo en Studio en vivo, sin tocar código.
]]

local Config = {}

-- Interruptor maestro. Si false, BulletWeapon usa su VFX heredado.
Config.Enabled = true

-- Cada cliente sólo ve los impactos de SUS disparos (lo más ligero). false =
-- ver también los de otros jugadores.
Config.LocalPlayerOnly = true

-- Multiplicador del "EmitCount" en dispositivos táctiles (1 = igual que PC).
Config.MobileScale = 0.5

-- Techo de efectos simultáneos en el pool; los extra se descartan.
Config.MaxConcurrent = 16

-- Carpeta de plantillas (hijo directo de ReplicatedStorage).
Config.FolderName = "HitVFX"

-- Nombres de las dos plantillas dentro de la carpeta.
Config.BodyCategory = "Body"
Config.HeadshotCategory = "Headshot"

return Config
