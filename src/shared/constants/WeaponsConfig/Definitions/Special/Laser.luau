--!strict
-- Special/Laser (Epic). Arma de energía: proyectil muy rápido sin gravedad,
-- sin dispersión, trazador Plasma y marca Scorch. Stats de partida escritos a
-- mano; este fichero ES la fuente de verdad. Claves y defaults: Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 20,
		BeamWidth0 = 0.5,
		BeamWidth1 = 0.5,
		BulletSpeed = 2000,
		FireMode = "Automatic",
		GravityFactor = 0,
		HitDamage = 22,
		HitMarkEffect = "Scorch",
		HitMarkHeatEffect = true,
		MaxSpread = 0.2,
		MuzzleFlashSize0 = 0.9,
		MuzzleFlashSize1 = 1.1,
		RecoilDecay = 0.8,
		RecoilMax = 0.2,
		RecoilMin = 0.1,
		ReloadTime = 2.2,
		ShotCooldown = 0.18,
		ShotEffect = "Plasma",
		TracerFadeTime = 0.15,
	},
} :: Types.WeaponDefinition
