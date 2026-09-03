--!strict
-- Main/Large. Migrado desde la Configuration del Tool
-- ServerStorage.WeaponTools.Main.Large, que ya no la lleva: este fichero ES
-- la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 5,
		BeamWidth0 = 0.2,
		BeamWidth1 = 0.3,
		FullDamageDistance = 15,
		HitDamage = 20,
		HitMarkEffect = "Pellet",
		MaxSpread = 4.5,
		MinSpread = 4.5,
		MuzzleFlashSize0 = 1.3,
		MuzzleFlashSize1 = 1.6,
		NumProjectiles = 5,
		RecoilDecay = 0.95,
		RecoilMax = 1.6,
		RecoilMin = 1.5,
		ReloadTime = 2.4,
		ShotCooldown = 0.6,
		ZeroDamageDistance = 110,
	},
} :: Types.WeaponDefinition
