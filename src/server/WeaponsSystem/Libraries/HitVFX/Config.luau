--!strict
--[[
	VFX de impacto de bala; solo cuerpo y cabeza (los impactos contra el mundo no
	producen nada). Ver docs/HIT-VFX.md.

	Requisito de Studio: ReplicatedStorage/Templates/HitVFX/{Body,Headshot}, cada
	uno Attachment o Part con ParticleEmitters (atributo opcional "EmitCount",
	def. 15). Se orienta a la normal del impacto: usar EmissionDirection = Top.
	Los Sound de la plantilla se ignoran: el sonido lo dispara DamageBillboardHandler
	desde SoundService.Audio.Gameplay.
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

Config.FolderName = "HitVFX"

Config.BodyCategory = "Body"
Config.HeadshotCategory = "Headshot"

return Config
