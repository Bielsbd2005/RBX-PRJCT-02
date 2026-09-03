--!strict
-- Generado por tools/weapons/dump-weapon-definitions.luau a partir de
-- ServerStorage.WeaponTools.Special.UZI. Editar a mano es válido: este
-- fichero ES la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 30,
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 9,
		MaxSpread = 1,
		MuzzleFlashSize0 = 0.75,
		MuzzleFlashSize1 = 0.95,
		RecoilDecay = 0.87,
		RecoilMax = 0.55,
		RecoilMin = 0.5,
		ShotCooldown = 0.05,
		ShotEffect = "Bullet",
	},
} :: Types.WeaponDefinition
