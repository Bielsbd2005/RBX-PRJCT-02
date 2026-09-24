--!strict
-- Arma especial de inicio: pistola semiautomática, referencia inferior del resto de especiales.
-- Este fichero es la fuente de verdad. Claves y defaults: Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 12,
		GravityFactor = 0.5,
		HitDamage = 20,
		MaxSpread = 0.4,
		RecoilDecay = 0.85,
		RecoilMin = 0.3,
		ReloadTime = 1.6,
		ShotCooldown = 0.2,
	},
} :: Types.WeaponDefinition
