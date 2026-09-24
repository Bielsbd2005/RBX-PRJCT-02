--!strict
-- Fuente de verdad de los stats. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 5,
		BeamWidth0 = 0.2,
		BeamWidth1 = 0.3,
		FullDamageDistance = 15,
		HitDamage = 20,
		HitMarkEffect = "Pellet",
		IsShotgun = true,
		MaxSpread = 4.5,
		MinSpread = 4.5,
		NumProjectiles = 5,
		OptimalRange = 30,
		RecoilDecay = 0.95,
		RecoilMax = 1.6,
		RecoilMin = 1.5,
		ReloadTime = 2.4,
		ShotCooldown = 0.6,
		ZeroDamageDistance = 110,
	},
} :: Types.WeaponDefinition
