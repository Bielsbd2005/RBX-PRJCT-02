--!strict
-- Special/Default (arma especial de inicio). Pistola semiautomática: fiable y
-- discreta, referencia inferior del resto de especiales. Stats de partida
-- escritos a mano; este fichero ES la fuente de verdad. Claves y defaults:
-- Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 12,
		FireMode = "Semiautomatic",
		GravityFactor = 0.5,
		HitDamage = 12,
		MaxSpread = 0.4,
		MuzzleFlashSize0 = 0.75,
		MuzzleFlashSize1 = 0.95,
		RecoilDecay = 0.85,
		RecoilMax = 0.5,
		RecoilMin = 0.3,
		ReloadTime = 1.6,
		ShotCooldown = 0.25,
		ShotEffect = "Bullet",
	},
} :: Types.WeaponDefinition
