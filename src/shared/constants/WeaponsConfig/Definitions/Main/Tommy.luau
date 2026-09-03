--!strict
-- Main/Tommy (Rare). Subfusil de tambor: más cadencia y cargador que el AK a
-- cambio de menos daño por bala y más dispersión. Stats de partida escritos a
-- mano; este fichero ES la fuente de verdad. Claves y defaults: Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 50,
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 11,
		MaxSpread = 1,
		MuzzleFlashSize0 = 1.1,
		MuzzleFlashSize1 = 1.4,
		RecoilDecay = 0.85,
		RecoilMax = 0.3,
		RecoilMin = 0.15,
		ReloadTime = 2.6,
		ShotCooldown = 0.08,
	},
} :: Types.WeaponDefinition
