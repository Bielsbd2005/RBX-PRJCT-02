--!strict
-- Fuente de verdad de la AK (el Tool ServerStorage.WeaponTools.Main.AK no lleva Configuration).
-- Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

-- Papel: rifle de golpe y puntería frente a la Groza (rifle de entrada, cadencia alta y daño bajo).
-- El DPS del arsenal principal debe crecer con el precio para que la tienda sea legible.
return {
	WeaponType = "BulletWeapon",
	Config = {
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 17,
		MaxSpread = 0.45,
		RecoilDecay = 0.81,
		RecoilMax = 0.1,
		RecoilMin = 0.1,
		ShotCooldown = 0.135,
	},
} :: Types.WeaponDefinition
