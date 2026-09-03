--!strict
-- Generado por tools/weapons/dump-weapon-definitions.luau a partir de
-- ServerStorage.WeaponTools.Special.RPG. Editar a mano es válido: este
-- fichero ES la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 1,
		BeamWidth0 = 3,
		BeamWidth1 = 1,
		BlastPressure = 20000,
		BlastRadius = 16,
		BulletSpeed = 260,
		ExplodeOnImpact = true,
		GravityFactor = 0,
		HitDamage = 100,
		HitMarkEffect = "Explosion",
		MuzzleFlashSize0 = 1.1,
		MuzzleFlashSize1 = 1.4,
		RecoilDecay = 0.81,
		RecoilMax = 0.5,
		RecoilMin = 0.25,
		ShotCooldown = 2.5,
		ShotEffect = "Rocket",
		ShouldMovePart = true,
	},
} :: Types.WeaponDefinition
