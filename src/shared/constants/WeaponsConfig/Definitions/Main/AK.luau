--!strict
-- Main/AK. Migrado desde la Configuration del Tool
-- ServerStorage.WeaponTools.Main.AK, que ya no la lleva: este fichero ES
-- la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 15,
		MaxSpread = 0.6,
		MuzzleFlashSize0 = 1.1,
		MuzzleFlashSize1 = 1.4,
		RecoilDecay = 0.81,
		RecoilMax = 0.1,
		RecoilMin = 0.1,
		ShotCooldown = 0.135,
	},
} :: Types.WeaponDefinition
