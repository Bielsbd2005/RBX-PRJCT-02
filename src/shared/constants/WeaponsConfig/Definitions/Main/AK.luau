--!strict
-- Generado por tools/weapons/dump-weapon-definitions.luau a partir de
-- ServerStorage.WeaponTools.Main.AK. Editar a mano es válido: este
-- fichero ES la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 30,
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 14,
		MaxSpread = 0.6,
		MuzzleFlashSize0 = 1.1,
		MuzzleFlashSize1 = 1.4,
		RecoilDecay = 0.81,
		RecoilMax = 0.1,
		RecoilMin = 0.1,
		ReloadTime = 2,
		ShotCooldown = 0.125,
		ShotEffect = "Bullet",
	},
} :: Types.WeaponDefinition
