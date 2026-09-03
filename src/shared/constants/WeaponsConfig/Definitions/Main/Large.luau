--!strict
-- Generado por tools/weapons/dump-weapon-definitions.luau a partir de
-- ServerStorage.WeaponTools.Main.Large. Editar a mano es válido: este
-- fichero ES la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 5,
		BeamWidth0 = 0.2,
		BeamWidth1 = 0.3,
		FullDamageDistance = 25,
		HitDamage = 20,
		HitMarkEffect = "Pellet",
		MaxSpread = 4,
		MinSpread = 4,
		MuzzleFlashSize0 = 1.3,
		MuzzleFlashSize1 = 1.6,
		NumProjectiles = 5,
		RecoilDecay = 0.95,
		RecoilMax = 1.6,
		RecoilMin = 1.5,
		ReloadTime = 2,
		ShotCooldown = 0.4,
		ShotEffect = "Bullet",
		ZeroDamageDistance = 250,
	},
} :: Types.WeaponDefinition
