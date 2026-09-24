--!strict
-- Fuente de verdad de la config (el Tool ServerStorage.WeaponTools.Main.Default no
-- lleva Configuration). Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 14,
		MaxSpread = 0.8,
		RecoilDecay = 0.81,
		RecoilMax = 0.1,
		RecoilMin = 0.1,
		ShotCooldown = 0.13,
	},
} :: Types.WeaponDefinition
