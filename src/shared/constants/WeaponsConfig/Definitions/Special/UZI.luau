--!strict
-- Special/UZI. Este fichero es la fuente de verdad de sus stats (el Tool no lleva
-- Configuration); claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 7,
		MaxSpread = 1.2,
		RecoilDecay = 0.87,
		RecoilMax = 0.55,
		RecoilMin = 0.5,
		ShotCooldown = 0.05,
	},
} :: Types.WeaponDefinition
