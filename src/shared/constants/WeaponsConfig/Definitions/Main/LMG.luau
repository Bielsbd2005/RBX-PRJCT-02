--!strict
-- Ametralladora ligera: el rifle pesado de Main. Cargador enorme y la cadencia más alta
-- de la categoría a cambio de arranque lento (StartupTime), recarga larga y dispersión
-- abierta: domina sosteniendo el fuego y pierde el duelo si empieza tarde. Este fichero
-- es la fuente de verdad de sus stats. Claves y defaults: Schema.luau.
-- PENDIENTE: el Tool ServerStorage.WeaponTools.Main.LMG; su entrada de ItemsConfig
-- sigue comentada hasta que exista.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 80,
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 14,
		MaxSpread = 1.4,
		MinSpread = 0.3,
		RecoilDecay = 0.88,
		RecoilMax = 0.5,
		RecoilMin = 0.2,
		ReloadTime = 4,
		ShotCooldown = 0.085,
		StartupTime = 0.35,
	},
} :: Types.WeaponDefinition
