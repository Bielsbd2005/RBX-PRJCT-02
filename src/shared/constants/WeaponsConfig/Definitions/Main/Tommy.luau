--!strict
-- Subfusil de tambor: más cadencia y cargador que el AK a cambio de menos daño por
-- bala y más dispersión. Este fichero es la fuente de verdad de sus stats.
-- Claves y defaults: Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 50,
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 12,
		MaxSpread = 1,
		RecoilDecay = 0.85,
		RecoilMax = 0.3,
		RecoilMin = 0.15,
		ReloadTime = 2.6,
		ShotCooldown = 0.08,
	},
} :: Types.WeaponDefinition
