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
		-- La dispersión más cerrada del escalón Common: junto al daño, el eje que justifica su precio.
		MaxSpread = 0.45,
		MuzzleFlashSize0 = 1.1,
		MuzzleFlashSize1 = 1.4,
		RecoilDecay = 0.81,
		RecoilMax = 0.1,
		RecoilMin = 0.1,
		-- Más lenta que la Groza a propósito: pega más fuerte, no más rápido, para no dominarla en todo.
		ShotCooldown = 0.135,
	},
} :: Types.WeaponDefinition
