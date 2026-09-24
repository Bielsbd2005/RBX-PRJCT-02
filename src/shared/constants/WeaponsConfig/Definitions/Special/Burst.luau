--!strict
-- Pistola de ráfagas: tres balas por gatillo (FireMode = "Burst", la única arma que lo
-- usa) con pausa entre ráfagas; dos ráfagas matan. En poder queda entre la Short y la
-- Laser, y es la especial de media distancia. Este fichero es la fuente de verdad de
-- sus stats. Claves y defaults: Schema.luau.
-- PENDIENTE: el Tool ServerStorage.WeaponTools.Special.Burst; su entrada de ItemsConfig
-- sigue comentada hasta que exista.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 24,
		BurstShotCooldown = 0.06,
		FireMode = "Burst",
		GravityFactor = 0.5,
		HitDamage = 19,
		MaxSpread = 0.45,
		RecoilDecay = 0.85,
		RecoilMax = 0.6,
		RecoilMin = 0.25,
		ShotCooldown = 0.3,
	},
} :: Types.WeaponDefinition
