--!strict
-- Escopeta recortada: letal a bocajarro, nula a media distancia. Fuente de verdad de
-- los stats. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 2,
		BeamWidth0 = 0.2,
		BeamWidth1 = 0.3,
		FullDamageDistance = 15,
		HitDamage = 17,
		HitMarkEffect = "Pellet",
		IsShotgun = true,
		MaxSpread = 4.5,
		MinSpread = 4.5,
		NumProjectiles = 6,
		RecoilDecay = 0.95,
		RecoilMax = 2,
		RecoilMin = 1.6,
		ReloadTime = 1.4,
		ShotCooldown = 0.6,
		ZeroDamageDistance = 90,
	},
} :: Types.WeaponDefinition
