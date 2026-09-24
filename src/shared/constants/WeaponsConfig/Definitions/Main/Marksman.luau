--!strict
-- Fuente de verdad de la config (el Tool no lleva Configuration). Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 1,
		CrosshairHideTop = true,
		CrosshairAimSpread = 4,
		CrosshairSpread = 40,
		GravityFactor = 0.5,
		HipFireSpread = 3,
		HitDamage = 100,
		RecoilDecay = 0.75,
		RecoilMax = 1.5,
		RecoilMin = 1,
		ReloadTime = 3,
		ShotCooldown = 1.5,
	},
} :: Types.WeaponDefinition
