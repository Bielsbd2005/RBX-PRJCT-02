--!strict
-- Special/Laser. Este fichero es la fuente de verdad de sus stats; claves y defaults: Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 20,
		BeamWidth0 = 0.5,
		BeamWidth1 = 0.5,
		BulletSpeed = 2000,
		FireMode = "Automatic",
		HitDamage = 25,
		HitMarkEffect = "Scorch",
		MaxSpread = 0.2,
		MuzzleFlashSize0 = 0.9,
		MuzzleFlashSize1 = 1.1,
		RecoilDecay = 0.8,
		RecoilMax = 0.2,
		RecoilMin = 0.1,
		ReloadTime = 2.2,
		ShotCooldown = 0.17,
		ShotEffect = "Plasma",
		TracerFadeTime = 0.15,
	},
} :: Types.WeaponDefinition
