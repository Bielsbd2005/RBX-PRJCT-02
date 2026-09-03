--!strict
-- Main/Sniper. Migrado desde la Configuration del Tool
-- ServerStorage.WeaponTools.Main.Sniper, que ya no la lleva: este fichero ES
-- la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 1,
		CrosshairScale = 3,
		GravityFactor = 0.5,
		HasScope = true,
		HitDamage = 100,
		MuzzleFlashSize0 = 1.25,
		MuzzleFlashSize1 = 1.8,
		RecoilDecay = 0.75,
		RecoilMax = 1.5,
		RecoilMin = 1,
		ReloadTime = 3,
		ShotCooldown = 1.5,
		ZoomFactor = 4.5,
	},
} :: Types.WeaponDefinition
