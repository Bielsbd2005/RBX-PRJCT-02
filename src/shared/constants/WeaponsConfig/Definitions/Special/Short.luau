--!strict
-- Special/Short (Uncommon). Escopeta recortada: seis perdigones, dos cartuchos,
-- letal a bocajarro y nula a media distancia (falloff corto). Stats de partida
-- escritos a mano; este fichero ES la fuente de verdad. Claves y defaults:
-- Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 2,
		BeamWidth0 = 0.2,
		BeamWidth1 = 0.3,
		FullDamageDistance = 15,
		HitDamage = 12,
		HitMarkEffect = "Pellet",
		MaxSpread = 5,
		MinSpread = 5,
		MuzzleFlashSize0 = 1.3,
		MuzzleFlashSize1 = 1.6,
		NumProjectiles = 6,
		RecoilDecay = 0.95,
		RecoilMax = 2,
		RecoilMin = 1.6,
		ReloadTime = 1.8,
		ShotCooldown = 0.7,
		ShotEffect = "Bullet",
		ZeroDamageDistance = 120,
	},
} :: Types.WeaponDefinition
