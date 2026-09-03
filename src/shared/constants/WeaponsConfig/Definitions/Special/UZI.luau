--!strict
-- Special/UZI. Migrado desde la Configuration del Tool
-- ServerStorage.WeaponTools.Special.UZI, que ya no la lleva: este fichero ES
-- la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 8,
		MaxSpread = 1.2,
		MuzzleFlashSize0 = 0.75,
		MuzzleFlashSize1 = 0.95,
		RecoilDecay = 0.87,
		RecoilMax = 0.55,
		RecoilMin = 0.5,
		ShotCooldown = 0.05,
	},
} :: Types.WeaponDefinition
